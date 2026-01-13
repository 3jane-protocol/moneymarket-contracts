// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Id, IMorpho, IMorphoCredit, MarketParams, Market} from "./interfaces/IMorpho.sol";
import {ICallableCredit} from "./interfaces/ICallableCredit.sol";
import {IProtocolConfig} from "./interfaces/IProtocolConfig.sol";
import {SharesMathLib} from "./libraries/SharesMathLib.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {UtilsLib} from "./libraries/UtilsLib.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IERC4626} from "../lib/openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title CallableCredit
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Manages callable credit positions where counter-protocols can draw against borrower credit
/// @dev Implements a silo + shares model for efficient pro-rata and targeted draws
/// @dev Interface uses USDC amounts, internal accounting in waUSDC
contract CallableCredit is ICallableCredit {
    using SharesMathLib for uint256;
    using SafeTransferLib for IERC20;
    using UtilsLib for uint256;

    // ============ Errors ============

    /// @notice Thrown when callable credit operations are frozen
    error CallableCreditFrozen();

    /// @notice Thrown when caller is not an authorized counter-protocol
    error NotAuthorizedCounterProtocol();

    /// @notice Thrown when borrower has insufficient shares
    error InsufficientShares();

    /// @notice Thrown when borrower has no position to close or draw from
    error NoPosition();

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when silo has insufficient principal for draw
    error InsufficientPrincipal();

    /// @notice Thrown when borrower has no credit line in MorphoCredit
    error NoCreditLine();

    /// @notice Thrown when address is zero
    error ZeroAddress();

    /// @notice Thrown when caller is not the owner
    error NotOwner();

    // ============ State Variables ============

    /// @notice Silo data per counter-protocol
    mapping(address => Silo) public silos;

    /// @notice Shares held by each borrower in each counter-protocol's silo
    mapping(address => mapping(address => uint256)) public borrowerShares;

    /// @notice Authorization status for counter-protocols
    mapping(address => bool) public authorizedCounterProtocols;

    // ============ Immutables ============

    /// @notice Address of the MorphoCredit contract
    IMorphoCredit public immutable MORPHO;

    /// @notice Address of the waUSDC token (ERC4626 vault)
    IERC4626 public immutable WAUSDC;

    /// @notice Address of the underlying USDC token
    IERC20 public immutable USDC;

    /// @notice Address of the ProtocolConfig contract
    IProtocolConfig public immutable protocolConfig;

    /// @notice Precomputed market ID
    Id public immutable marketId;

    // ============ Immutable MarketParams ============

    /// @notice Loan token address (waUSDC)
    address internal immutable LOAN_TOKEN;

    /// @notice Collateral token address
    address internal immutable COLLATERAL_TOKEN;

    /// @notice Oracle address
    address internal immutable ORACLE;

    /// @notice Interest rate model address
    address internal immutable IRM;

    /// @notice Liquidation LTV
    uint256 internal immutable LLTV;

    /// @notice Credit line address
    address internal immutable CREDIT_LINE;

    // ============ Constructor ============

    /// @notice Initialize the CallableCredit contract
    /// @param _morpho Address of the MorphoCredit contract
    /// @param _wausdc Address of the waUSDC token (ERC4626)
    /// @param _protocolConfig Address of the ProtocolConfig contract
    /// @param params Market parameters for MorphoCredit
    constructor(address _morpho, address _wausdc, address _protocolConfig, MarketParams memory params) {
        if (_morpho == address(0)) revert ZeroAddress();
        if (_wausdc == address(0)) revert ZeroAddress();
        if (_protocolConfig == address(0)) revert ZeroAddress();

        MORPHO = IMorphoCredit(_morpho);
        WAUSDC = IERC4626(_wausdc);
        USDC = IERC20(IERC4626(_wausdc).asset());
        protocolConfig = IProtocolConfig(_protocolConfig);
        marketId = Id.wrap(keccak256(abi.encode(params)));

        // Store MarketParams fields as immutables
        LOAN_TOKEN = params.loanToken;
        COLLATERAL_TOKEN = params.collateralToken;
        ORACLE = params.oracle;
        IRM = params.irm;
        LLTV = params.lltv;
        CREDIT_LINE = params.creditLine;
    }

    // ============ Modifiers ============

    /// @dev Reverts if callable credit is frozen
    modifier whenNotFrozen() {
        if (protocolConfig.getCcFrozen() != 0) revert CallableCreditFrozen();
        _;
    }

    /// @dev Reverts if caller is not the owner (inherited from MorphoCredit)
    modifier onlyOwner() {
        if (msg.sender != owner()) revert NotOwner();
        _;
    }

    /// @dev Reverts if caller is not an authorized counter-protocol
    modifier onlyAuthorizedCounterProtocol() {
        if (!authorizedCounterProtocols[msg.sender]) revert NotAuthorizedCounterProtocol();
        _;
    }

    // ============ Owner Functions ============

    /// @notice Returns the owner address (inherited from MorphoCredit)
    /// @return The owner address
    function owner() public view returns (address) {
        return IMorpho(address(MORPHO)).owner();
    }

    // ============ Admin Functions ============

    /// @inheritdoc ICallableCredit
    function setAuthorizedCounterProtocol(address counterProtocol, bool authorized) external onlyOwner {
        authorizedCounterProtocols[counterProtocol] = authorized;
        emit CounterProtocolAuthorized(counterProtocol, authorized);
    }

    // ============ Position Management ============

    /// @inheritdoc ICallableCredit
    function open(address borrower, uint256 usdcAmount) external whenNotFrozen onlyAuthorizedCounterProtocol {
        if (usdcAmount == 0) revert ZeroAmount();
        if (!_hasCreditLine(borrower)) revert NoCreditLine();

        // Convert USDC amount to waUSDC
        uint256 waUsdcAmount = WAUSDC.previewDeposit(usdcAmount);

        // Accrue premiums to ensure borrower's debt is current
        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        MORPHO.accruePremiumsForBorrowers(marketId, borrowers);

        // Borrow waUSDC from MorphoCredit on behalf of the borrower
        // The borrowed waUSDC stays in this contract (the silo)
        IMorpho(address(MORPHO)).borrow(_marketParams(), waUsdcAmount, 0, borrower, address(this));

        // Load silo into memory, update, and write back once
        Silo memory silo = silos[msg.sender];
        uint256 shares = waUsdcAmount.toSharesDown(silo.totalPrincipal, silo.totalShares);
        silo.totalPrincipal += waUsdcAmount.toUint128();
        silo.totalShares += shares.toUint128();
        silos[msg.sender] = silo;

        // Record borrower's shares (additive for multiple opens)
        borrowerShares[msg.sender][borrower] += shares;

        emit PositionOpened(msg.sender, borrower, usdcAmount, shares);
    }

    /// @inheritdoc ICallableCredit
    function close(address borrower)
        external
        whenNotFrozen
        onlyAuthorizedCounterProtocol
        returns (uint256 usdcSent, uint256 waUsdcSent)
    {
        uint256 shares = borrowerShares[msg.sender][borrower];
        if (shares == 0) revert NoPosition();

        // Load silo into memory, update, and write back once
        Silo memory silo = silos[msg.sender];
        uint256 principal = shares.toAssetsDown(silo.totalPrincipal, silo.totalShares);
        silo.totalPrincipal -= principal.toUint128();
        silo.totalShares -= shares.toUint128();
        silos[msg.sender] = silo;

        // Clear borrower's shares
        delete borrowerShares[msg.sender][borrower];

        // Accrue premiums to ensure borrower's debt is current
        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        MORPHO.accruePremiumsForBorrowers(marketId, borrowers);

        // Query actual debt and calculate repayment
        uint256 actualDebt = _getBorrowerDebt(borrower);
        uint256 toRepay = principal < actualDebt ? principal : actualDebt;
        uint256 excessWaUsdc = principal - toRepay;

        // Repay what's owed to MorphoCredit
        if (toRepay > 0) {
            IERC20(address(WAUSDC)).approve(address(MORPHO), toRepay);
            IMorpho(address(MORPHO)).repay(_marketParams(), toRepay, 0, borrower, "");
        }

        // Return excess to borrower, preferring USDC
        if (excessWaUsdc > 0) {
            (usdcSent, waUsdcSent) = _withdrawPreferUsdc(excessWaUsdc, borrower);
        }

        emit PositionClosed(msg.sender, borrower, principal, shares);
    }

    // ============ Draw Functions ============

    /// @inheritdoc ICallableCredit
    function draw(address borrower, uint256 usdcAmount, address recipient)
        external
        whenNotFrozen
        onlyAuthorizedCounterProtocol
        returns (uint256 usdcSent, uint256 waUsdcSent)
    {
        if (usdcAmount == 0) revert ZeroAmount();

        // Convert USDC amount to waUSDC needed
        uint256 waUsdcNeeded = WAUSDC.previewWithdraw(usdcAmount);

        uint256 shares = borrowerShares[msg.sender][borrower];
        if (shares == 0) revert NoPosition();

        // Load silo into memory, update, and write back once
        Silo memory silo = silos[msg.sender];
        if (waUsdcNeeded > silo.totalPrincipal) revert InsufficientPrincipal();

        uint256 sharesToBurn = waUsdcNeeded.toSharesUp(silo.totalPrincipal, silo.totalShares);
        if (sharesToBurn > shares) revert InsufficientShares();

        silo.totalPrincipal -= waUsdcNeeded.toUint128();
        silo.totalShares -= sharesToBurn.toUint128();
        silos[msg.sender] = silo;

        // Update borrower's shares
        borrowerShares[msg.sender][borrower] -= sharesToBurn;

        // Withdraw to recipient, preferring USDC
        (usdcSent, waUsdcSent) = _withdrawPreferUsdc(waUsdcNeeded, recipient);

        emit Draw(msg.sender, borrower, recipient, usdcAmount, usdcSent, waUsdcSent);
    }

    /// @inheritdoc ICallableCredit
    function draw(uint256 usdcAmount, address recipient)
        external
        whenNotFrozen
        onlyAuthorizedCounterProtocol
        returns (uint256 usdcSent, uint256 waUsdcSent)
    {
        if (usdcAmount == 0) revert ZeroAmount();

        // Convert USDC amount to waUSDC needed
        uint256 waUsdcNeeded = WAUSDC.previewWithdraw(usdcAmount);

        // Load silo into memory, update, and write back once
        Silo memory silo = silos[msg.sender];
        if (waUsdcNeeded > silo.totalPrincipal) revert InsufficientPrincipal();

        // Pro-rata draw only reduces totalPrincipal, shares remain unchanged
        // Each borrower's position shrinks proportionally via share price
        silo.totalPrincipal -= waUsdcNeeded.toUint128();
        silos[msg.sender] = silo;

        // Withdraw to recipient, preferring USDC
        (usdcSent, waUsdcSent) = _withdrawPreferUsdc(waUsdcNeeded, recipient);

        emit ProRataDraw(msg.sender, recipient, usdcAmount, usdcSent, waUsdcSent);
    }

    // ============ View Functions ============

    /// @inheritdoc ICallableCredit
    function getBorrowerPrincipal(address counterProtocol, address borrower) external view returns (uint256) {
        Silo memory silo = silos[counterProtocol];
        uint256 shares = borrowerShares[counterProtocol][borrower];

        if (shares == 0) return 0;

        return shares.toAssetsDown(silo.totalPrincipal, silo.totalShares);
    }

    /// @notice Get the market parameters
    /// @return The MarketParams struct
    function marketParams() public view returns (MarketParams memory) {
        return _marketParams();
    }

    // ============ Internal Functions ============

    /// @notice Reconstruct MarketParams from immutable fields
    /// @return The MarketParams struct
    function _marketParams() internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: LOAN_TOKEN,
            collateralToken: COLLATERAL_TOKEN,
            oracle: ORACLE,
            irm: IRM,
            lltv: LLTV,
            creditLine: CREDIT_LINE
        });
    }

    /// @notice Check if borrower has a credit line in MorphoCredit
    /// @param borrower The borrower address
    /// @return True if borrower has collateral (credit line) in MorphoCredit
    function _hasCreditLine(address borrower) internal view returns (bool) {
        return IMorpho(address(MORPHO)).position(marketId, borrower).collateral > 0;
    }

    /// @notice Get borrower's current debt in MorphoCredit
    /// @param borrower The borrower address
    /// @return The borrower's debt in waUSDC terms
    function _getBorrowerDebt(address borrower) internal view returns (uint256) {
        // Get borrower's borrow shares
        uint128 borrowShares = IMorpho(address(MORPHO)).position(marketId, borrower).borrowShares;
        if (borrowShares == 0) return 0;

        // Get market totals to convert shares to assets
        Market memory m = IMorpho(address(MORPHO)).market(marketId);
        if (m.totalBorrowShares == 0) return 0;

        // Convert shares to assets (round up for debt)
        return uint256(borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
    }

    /// @notice Withdraw waUSDC, preferring USDC up to maxRedeem
    /// @param waUsdcAmount Amount of waUSDC to withdraw
    /// @param recipient Address to receive funds
    /// @return usdcSent USDC amount sent
    /// @return waUsdcSent waUSDC amount sent (remainder if USDC redemption limited)
    function _withdrawPreferUsdc(uint256 waUsdcAmount, address recipient)
        internal
        returns (uint256 usdcSent, uint256 waUsdcSent)
    {
        uint256 maxRedeemable = WAUSDC.maxRedeem(address(this));

        if (maxRedeemable >= waUsdcAmount) {
            // Happy path: redeem all to USDC
            usdcSent = WAUSDC.redeem(waUsdcAmount, recipient, address(this));
            waUsdcSent = 0;
        } else {
            // Partial: redeem what we can, send rest as waUSDC
            if (maxRedeemable > 0) {
                usdcSent = WAUSDC.redeem(maxRedeemable, recipient, address(this));
            }
            waUsdcSent = waUsdcAmount - maxRedeemable;
            IERC20(address(WAUSDC)).safeTransfer(recipient, waUsdcSent);
        }
    }
}
