// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Id, IMorpho, IMorphoCredit, MarketParams, Market} from "./interfaces/IMorpho.sol";
import {ICallableCredit} from "./interfaces/ICallableCredit.sol";
import {IProtocolConfig} from "./interfaces/IProtocolConfig.sol";
import {SharesMathLib} from "./libraries/SharesMathLib.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {UtilsLib} from "./libraries/UtilsLib.sol";
import {ProtocolConfigLib} from "./libraries/ProtocolConfigLib.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IERC4626} from "../lib/openzeppelin/contracts/interfaces/IERC4626.sol";
import {Initializable} from "../lib/openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "../lib/openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20 as IERC20OZ} from "../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CallableCredit
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Manages callable credit positions where counter-protocols can draw against borrower credit
/// @dev Implements a silo + shares model for efficient pro-rata and targeted draws
/// @dev Principal tracked in USDC (draw cap), waUSDC tracked at silo level for close reconciliation
contract CallableCredit is ICallableCredit, Initializable, ReentrancyGuard {
    using SharesMathLib for uint256;
    using SafeTransferLib for IERC20;
    using UtilsLib for uint256;

    // ============ State Variables ============

    /// @notice Silo data per counter-protocol
    mapping(address => Silo) public silos;

    /// @notice Shares held by each borrower in each counter-protocol's silo
    mapping(address => mapping(address => uint256)) public borrowerShares;

    /// @notice Authorization status for counter-protocols
    mapping(address => bool) public authorizedCounterProtocols;

    /// @notice Per-borrower total CC waUSDC across all silos
    mapping(address => uint256) public borrowerTotalCcWaUsdc;

    /// @notice Total CC waUSDC across all silos
    uint128 public totalCcWaUsdc;

    /// @notice Throttle state for rate limiting CC opens
    ThrottleState public throttle;

    /// @notice Borrower allowance per counter-protocol in USDC
    mapping(address borrower => mapping(address counterProtocol => uint256)) public borrowerAllowance;

    /// @dev Storage gap for future upgrades
    uint256[50] private __gap;

    // ============ Immutables ============

    /// @notice Address of the MorphoCredit contract
    IMorphoCredit public immutable MORPHO;

    /// @notice Address of the waUSDC token (ERC4626 vault)
    IERC4626 public immutable WAUSDC;

    /// @notice Address of the underlying USDC token
    IERC20 public immutable USDC;

    /// @notice Address of the ProtocolConfig contract
    IProtocolConfig public immutable PROTOCOL_CONFIG;

    /// @notice Precomputed market ID
    Id public immutable MARKET_ID;

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

    /// @notice Initialize the CallableCredit implementation contract
    /// @param _morpho Address of the MorphoCredit contract
    /// @param _wausdc Address of the waUSDC token (ERC4626)
    /// @param _protocolConfig Address of the ProtocolConfig contract
    /// @param _marketId Market ID in MorphoCredit
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _morpho, address _wausdc, address _protocolConfig, Id _marketId) {
        if (_morpho == address(0)) revert ErrorsLib.ZeroAddress();
        if (_wausdc == address(0)) revert ErrorsLib.ZeroAddress();
        if (_protocolConfig == address(0)) revert ErrorsLib.ZeroAddress();

        MORPHO = IMorphoCredit(_morpho);
        WAUSDC = IERC4626(_wausdc);
        USDC = IERC20(IERC4626(_wausdc).asset());
        PROTOCOL_CONFIG = IProtocolConfig(_protocolConfig);
        MARKET_ID = _marketId;

        // Retrieve and store MarketParams fields as immutables
        MarketParams memory params = IMorpho(_morpho).idToMarketParams(_marketId);
        if (params.loanToken == address(0)) revert ErrorsLib.ZeroAddress();
        LOAN_TOKEN = params.loanToken;
        COLLATERAL_TOKEN = params.collateralToken;
        ORACLE = params.oracle;
        IRM = params.irm;
        LLTV = params.lltv;
        CREDIT_LINE = params.creditLine;

        _disableInitializers();
    }

    /// @notice Initialize the CallableCredit proxy
    /// @dev Called once during proxy deployment
    function initialize() external initializer {
        SafeERC20.forceApprove(IERC20OZ(address(WAUSDC)), address(MORPHO), type(uint256).max);
    }

    // ============ Modifiers ============

    /// @dev Reverts if callable credit is frozen
    modifier whenNotFrozen() {
        if (PROTOCOL_CONFIG.getCcFrozen() != 0) revert ErrorsLib.CallableCreditFrozen();
        _;
    }

    /// @dev Reverts if caller is not the owner (inherited from MorphoCredit)
    modifier onlyOwner() {
        if (msg.sender != owner()) revert ErrorsLib.NotOwner();
        _;
    }

    /// @dev Reverts if caller is not an authorized counter-protocol
    modifier onlyAuthorizedCounterProtocol() {
        if (!authorizedCounterProtocols[msg.sender]) revert ErrorsLib.NotAuthorizedCounterProtocol();
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

    // ============ Borrower Functions ============

    /// @inheritdoc ICallableCredit
    function approve(address counterProtocol, uint256 amount) external {
        borrowerAllowance[msg.sender][counterProtocol] = amount;
        emit Approval(msg.sender, counterProtocol, amount);
    }

    // ============ Position Management ============

    /// @inheritdoc ICallableCredit
    function open(address borrower, uint256 usdcAmount)
        external
        nonReentrant
        whenNotFrozen
        onlyAuthorizedCounterProtocol
    {
        if (usdcAmount == 0) revert ErrorsLib.ZeroAssets();
        if (!_hasCreditLine(borrower)) revert ErrorsLib.NoCreditLine();

        // Convert USDC to waUSDC (rounds up to ensure silo has enough for draws)
        uint256 waUsdcAmount = WAUSDC.previewWithdraw(usdcAmount);

        (uint256 feeUsdc, uint256 feeWaUsdc, address feeRecipient) = _calculateOriginationFee(usdcAmount);
        _beforeOpen(borrower, usdcAmount, waUsdcAmount, feeUsdc);

        // Load silo, update shares/principal/waUSDC, write back
        Silo memory silo = silos[msg.sender];
        uint256 shares = usdcAmount.toSharesDown(silo.totalPrincipal, silo.totalShares);
        silo.totalPrincipal += usdcAmount.toUint128();
        silo.totalShares += shares.toUint128();
        silo.totalWaUsdcHeld += waUsdcAmount.toUint128();
        silos[msg.sender] = silo;

        // Update borrower shares and CC tracking
        borrowerShares[msg.sender][borrower] += shares;
        totalCcWaUsdc += waUsdcAmount.toUint128();
        borrowerTotalCcWaUsdc[borrower] += waUsdcAmount;

        // Borrow from MorphoCredit (position + fee)
        IMorpho(address(MORPHO)).borrow(_marketParams(), waUsdcAmount + feeWaUsdc, 0, borrower, address(this));

        // Send fee to recipient
        if (feeWaUsdc > 0) {
            WAUSDC.redeem(feeWaUsdc, feeRecipient, address(this));
        }

        emit PositionOpened(msg.sender, borrower, usdcAmount, shares, feeUsdc);
    }

    /// @inheritdoc ICallableCredit
    function close(address borrower)
        external
        nonReentrant
        whenNotFrozen
        onlyAuthorizedCounterProtocol
        returns (uint256 usdcSent, uint256 waUsdcSent)
    {
        uint256 shares = borrowerShares[msg.sender][borrower];
        if (shares == 0) revert ErrorsLib.NoPosition();

        // Full close: derive principal from shares
        Silo memory silo = silos[msg.sender];
        uint256 usdcPrincipal = shares.toAssetsDown(silo.totalPrincipal, silo.totalShares);

        return _close(borrower, shares, usdcPrincipal);
    }

    /// @inheritdoc ICallableCredit
    function close(address borrower, uint256 usdcAmount)
        external
        nonReentrant
        whenNotFrozen
        onlyAuthorizedCounterProtocol
        returns (uint256 usdcSent, uint256 waUsdcSent)
    {
        if (usdcAmount == 0) revert ErrorsLib.ZeroAssets();

        uint256 shares = borrowerShares[msg.sender][borrower];
        if (shares == 0) revert ErrorsLib.NoPosition();

        // Calculate shares to burn from USDC amount
        Silo memory silo = silos[msg.sender];
        uint256 sharesToBurn = usdcAmount.toSharesUp(silo.totalPrincipal, silo.totalShares);
        if (sharesToBurn > shares) revert ErrorsLib.InsufficientShares();

        // If burning all silo shares, use all silo principal directly
        // (avoids virtual share math that rounds to zero with small numbers)
        uint256 usdcPrincipal = sharesToBurn == silo.totalShares ? silo.totalPrincipal : usdcAmount;

        return _close(borrower, sharesToBurn, usdcPrincipal);
    }

    /// @notice Internal implementation of close
    /// @param borrower The borrower whose position to close
    /// @param sharesToBurn The number of shares to burn
    /// @param usdcPrincipal The USDC principal amount (for state update and event)
    function _close(address borrower, uint256 sharesToBurn, uint256 usdcPrincipal)
        internal
        returns (uint256 usdcSent, uint256 waUsdcSent)
    {
        uint256 waUsdcToClose;

        // Scoped block to reduce stack pressure
        {
            // Load silo into memory
            Silo memory silo = silos[msg.sender];

            // Calculate proportional waUSDC for the shares being closed
            // If burning all shares, use all waUSDC to avoid rounding dust
            waUsdcToClose = sharesToBurn == silo.totalShares
                ? silo.totalWaUsdcHeld
                : (sharesToBurn * silo.totalWaUsdcHeld) / silo.totalShares;

            // Update silo state
            silo.totalPrincipal -= usdcPrincipal.toUint128();
            silo.totalShares -= sharesToBurn.toUint128();
            silo.totalWaUsdcHeld -= waUsdcToClose.toUint128();
            silos[msg.sender] = silo;

            // Update borrower's shares
            borrowerShares[msg.sender][borrower] -= sharesToBurn;

            // Decrease CC waUSDC tracking
            totalCcWaUsdc -= waUsdcToClose.toUint128();
            borrowerTotalCcWaUsdc[borrower] -= waUsdcToClose;
        }

        // Accrue premiums, repay debt, and return any excess to borrower
        (, usdcSent, waUsdcSent) = _repayAndReturn(borrower, waUsdcToClose);

        emit PositionClosed(msg.sender, borrower, usdcPrincipal, sharesToBurn);
    }

    // ============ Draw Functions ============

    /// @inheritdoc ICallableCredit
    function draw(address borrower, uint256 usdcAmount, address recipient)
        external
        nonReentrant
        whenNotFrozen
        onlyAuthorizedCounterProtocol
        returns (uint256 usdcSent, uint256 waUsdcSent)
    {
        if (usdcAmount == 0) revert ErrorsLib.ZeroAssets();

        uint256 shares = borrowerShares[msg.sender][borrower];
        if (shares == 0) revert ErrorsLib.NoPosition();

        uint256 waUsdcNeeded;
        uint256 excessWaUsdc;

        // Scoped block to reduce stack pressure
        {
            // Load silo into memory
            Silo memory silo = silos[msg.sender];

            // Check against USDC principal (draw cap)
            if (usdcAmount > silo.totalPrincipal) revert ErrorsLib.InsufficientPrincipal();

            // Calculate shares to burn based on USDC amount
            uint256 sharesToBurn = usdcAmount.toSharesUp(silo.totalPrincipal, silo.totalShares);
            if (sharesToBurn > shares) revert ErrorsLib.InsufficientShares();

            // Calculate proportional waUSDC for shares being burned (like _close does)
            // If burning all shares, use all waUSDC to avoid rounding dust
            uint256 waUsdcFromShares = sharesToBurn == silo.totalShares
                ? silo.totalWaUsdcHeld
                : (sharesToBurn * silo.totalWaUsdcHeld) / silo.totalShares;

            // Calculate waUSDC needed to fulfill the USDC withdrawal
            waUsdcNeeded = WAUSDC.previewWithdraw(usdcAmount);
            if (waUsdcNeeded > silo.totalWaUsdcHeld) revert ErrorsLib.InsufficientWaUsdc();

            // Calculate excess waUSDC from appreciation (belongs to borrower)
            // Only exists when share-proportional waUSDC exceeds what's needed for the draw
            excessWaUsdc = waUsdcFromShares > waUsdcNeeded ? waUsdcFromShares - waUsdcNeeded : 0;

            // Use max(waUsdcFromShares, waUsdcNeeded) for consistent accounting
            // - If appreciation: waUsdcFromShares > waUsdcNeeded, excess goes to borrower
            // - If no appreciation: waUsdcNeeded >= waUsdcFromShares, no excess, use waUsdcNeeded
            uint256 waUsdcToDeduct = waUsdcFromShares > waUsdcNeeded ? waUsdcFromShares : waUsdcNeeded;

            // Update silo state
            silo.totalPrincipal -= usdcAmount.toUint128();
            silo.totalShares -= sharesToBurn.toUint128();
            silo.totalWaUsdcHeld -= waUsdcToDeduct.toUint128();
            silos[msg.sender] = silo;

            // Update borrower's shares
            borrowerShares[msg.sender][borrower] -= sharesToBurn;

            // Decrease CC waUSDC tracking (position is being unwound)
            totalCcWaUsdc -= waUsdcToDeduct.toUint128();
            borrowerTotalCcWaUsdc[borrower] -= waUsdcToDeduct;
        }

        // Withdraw waUsdcNeeded to recipient, preferring USDC
        (usdcSent, waUsdcSent) = _withdrawPreferUsdc(waUsdcNeeded, recipient);

        // Handle excess waUSDC: repay borrower's debt first, return remainder
        if (excessWaUsdc > 0) {
            (uint256 repaidAmount, uint256 returnedUsdc, uint256 returnedWaUsdc) =
                _repayAndReturn(borrower, excessWaUsdc);
            emit DrawExcessHandled(msg.sender, borrower, excessWaUsdc, repaidAmount, returnedUsdc, returnedWaUsdc);
        }

        emit Draw(msg.sender, borrower, recipient, usdcAmount, usdcSent, waUsdcSent);
    }

    /// @inheritdoc ICallableCredit
    function draw(uint256 usdcAmount, address recipient)
        external
        nonReentrant
        whenNotFrozen
        onlyAuthorizedCounterProtocol
        returns (uint256 usdcSent, uint256 waUsdcSent)
    {
        if (usdcAmount == 0) revert ErrorsLib.ZeroAssets();

        // Load silo into memory
        Silo memory silo = silos[msg.sender];

        // Check against USDC principal (draw cap)
        if (usdcAmount > silo.totalPrincipal) revert ErrorsLib.InsufficientPrincipal();

        // Convert USDC to waUSDC needed for withdrawal
        uint256 waUsdcNeeded = WAUSDC.previewWithdraw(usdcAmount);
        if (waUsdcNeeded > silo.totalWaUsdcHeld) revert ErrorsLib.InsufficientWaUsdc();

        // Pro-rata draw reduces principal and waUSDC, shares remain unchanged
        // Each borrower's position shrinks proportionally via share price
        // Reconciliation happens at close
        silo.totalPrincipal -= usdcAmount.toUint128();
        silo.totalWaUsdcHeld -= waUsdcNeeded.toUint128();
        silos[msg.sender] = silo;

        // Update global CC tracking for accurate cap checks
        // Note: borrowerTotalCcWaUsdc is NOT updated here because we can't iterate over
        // affected borrowers. Per-borrower tracking remains an upper bound that may permanently
        // overstate exposure after pro-rata draws (close only decrements by proportional amount).
        // This is a conservative design: per-borrower caps may be overly restrictive but never exceeded.
        totalCcWaUsdc -= waUsdcNeeded.toUint128();

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

    /// @notice Check allowance, throttle, and enforce caps before open
    /// @param borrower The borrower address
    /// @param usdcAmount The USDC amount to open
    /// @param waUsdcAmount The waUSDC amount (pre-calculated by caller)
    /// @param feeUsdc The origination fee in USDC
    function _beforeOpen(address borrower, uint256 usdcAmount, uint256 waUsdcAmount, uint256 feeUsdc) internal {
        uint256 totalCost = usdcAmount + feeUsdc;
        uint256 allowed = borrowerAllowance[borrower][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < totalCost) revert ErrorsLib.InsufficientBorrowerAllowance();
            borrowerAllowance[borrower][msg.sender] = allowed - totalCost;
        }

        _checkAndUpdateThrottle(usdcAmount);

        // Check global CC cap (% of debt cap)
        uint256 ccDebtCapBps = PROTOCOL_CONFIG.config(ProtocolConfigLib.CC_DEBT_CAP_BPS);
        if (ccDebtCapBps < 10000) {
            uint256 debtCap = PROTOCOL_CONFIG.config(ProtocolConfigLib.DEBT_CAP);
            uint256 maxCcWaUsdc = (debtCap * ccDebtCapBps) / 10000;
            if (totalCcWaUsdc + waUsdcAmount > maxCcWaUsdc) revert ErrorsLib.CcCapExceeded();
        }

        // Check per-borrower CC cap (% of credit line)
        uint256 ccCreditLineBps = PROTOCOL_CONFIG.config(ProtocolConfigLib.CC_CREDIT_LINE_BPS);
        if (ccCreditLineBps < 10000) {
            uint256 creditLine = IMorpho(address(MORPHO)).position(MARKET_ID, borrower).collateral;
            uint256 maxBorrowerCcWaUsdc = (creditLine * ccCreditLineBps) / 10000;
            if (borrowerTotalCcWaUsdc[borrower] + waUsdcAmount > maxBorrowerCcWaUsdc) revert ErrorsLib.CcCapExceeded();
        }
    }

    /// @notice Calculate origination fee for an open operation
    /// @param usdcAmount The USDC principal amount
    /// @return feeUsdc The fee in USDC
    /// @return feeWaUsdc The fee in waUSDC
    /// @return feeRecipient The fee recipient address
    function _calculateOriginationFee(uint256 usdcAmount)
        internal
        view
        returns (uint256 feeUsdc, uint256 feeWaUsdc, address feeRecipient)
    {
        feeRecipient = address(uint160(PROTOCOL_CONFIG.config(ProtocolConfigLib.CC_FEE_RECIPIENT)));
        uint256 feeBps = PROTOCOL_CONFIG.config(ProtocolConfigLib.CC_ORIGINATION_FEE_BPS);

        if (feeRecipient != address(0) && feeBps != 0) {
            feeUsdc = (usdcAmount * feeBps) / 10000;
            feeWaUsdc = WAUSDC.previewWithdraw(feeUsdc);
        }
    }

    /// @notice Check and update throttle state
    /// @param usdcAmount The USDC amount being opened
    function _checkAndUpdateThrottle(uint256 usdcAmount) internal {
        uint256 throttlePeriod = PROTOCOL_CONFIG.config(ProtocolConfigLib.CC_THROTTLE_PERIOD);
        uint256 throttleLimit = PROTOCOL_CONFIG.config(ProtocolConfigLib.CC_THROTTLE_LIMIT);
        if (throttlePeriod != 0 && throttleLimit != 0) {
            ThrottleState memory t = throttle;
            if (block.timestamp >= t.periodStart + throttlePeriod) {
                t.periodStart = uint64(block.timestamp);
                t.periodUsdc = 0;
            }
            if (t.periodUsdc + usdcAmount > throttleLimit) revert ErrorsLib.ThrottleLimitExceeded();
            t.periodUsdc += usdcAmount.toUint64();
            throttle = t;
        }
    }

    /// @notice Check if borrower has a credit line in MorphoCredit
    /// @param borrower The borrower address
    /// @return True if borrower has collateral (credit line) in MorphoCredit
    function _hasCreditLine(address borrower) internal view returns (bool) {
        return IMorpho(address(MORPHO)).position(MARKET_ID, borrower).collateral != 0;
    }

    /// @notice Get borrower's current debt in MorphoCredit
    /// @param borrower The borrower address
    /// @return The borrower's debt in waUSDC terms
    function _getBorrowerDebt(address borrower) internal view returns (uint256) {
        // Get borrower's borrow shares
        uint128 borrowShares = IMorpho(address(MORPHO)).position(MARKET_ID, borrower).borrowShares;
        if (borrowShares == 0) return 0;

        // Get market totals to convert shares to assets
        Market memory m = IMorpho(address(MORPHO)).market(MARKET_ID);
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

    /// @notice Accrue premiums, repay debt, and return any excess to borrower
    /// @param borrower The borrower address
    /// @param waUsdcAmount The waUSDC amount to process
    /// @return repaidAmount Amount repaid to MorphoCredit
    /// @return usdcReturned USDC returned to borrower
    /// @return waUsdcReturned waUSDC returned to borrower
    function _repayAndReturn(address borrower, uint256 waUsdcAmount)
        internal
        returns (uint256 repaidAmount, uint256 usdcReturned, uint256 waUsdcReturned)
    {
        _accruePremiums(borrower);

        uint256 actualDebt = _getBorrowerDebt(borrower);
        repaidAmount = waUsdcAmount < actualDebt ? waUsdcAmount : actualDebt;
        uint256 remainder = waUsdcAmount - repaidAmount;

        if (repaidAmount > 0) {
            IMorpho(address(MORPHO)).repay(_marketParams(), repaidAmount, 0, borrower, "");
        }

        if (remainder > 0) {
            (usdcReturned, waUsdcReturned) = _withdrawPreferUsdc(remainder, borrower);
        }
    }

    /// @notice Accrue premiums for a borrower
    /// @param borrower The borrower address
    function _accruePremiums(address borrower) internal {
        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        MORPHO.accruePremiumsForBorrowers(MARKET_ID, borrowers);
    }
}
