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

/// @title CallableCredit
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Manages callable credit positions where counter-protocols can draw against borrower credit
/// @dev Implements a silo + shares model for efficient pro-rata and targeted draws
/// @dev Principal tracked in USDC (draw cap), waUSDC tracked at silo level for close reconciliation
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

    /// @notice Thrown when silo has insufficient principal for draw
    error InsufficientPrincipal();

    /// @notice Thrown when silo has insufficient waUSDC for draw
    error InsufficientWaUsdc();

    /// @notice Thrown when borrower has no credit line in MorphoCredit
    error NoCreditLine();

    /// @notice Thrown when callable credit cap is exceeded
    error CcCapExceeded();

    /// @notice Thrown when throttle limit for the period is exceeded
    error ThrottleLimitExceeded();

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
    uint256 public totalCcWaUsdc;

    /// @notice Timestamp when current throttle period started
    uint64 public throttlePeriodStart;

    /// @notice USDC opened in current throttle period
    uint128 public throttlePeriodUsdc;

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
    /// @param _marketId Market ID in MorphoCredit
    constructor(address _morpho, address _wausdc, address _protocolConfig, Id _marketId) {
        if (_morpho == address(0)) revert ErrorsLib.ZeroAddress();
        if (_wausdc == address(0)) revert ErrorsLib.ZeroAddress();
        if (_protocolConfig == address(0)) revert ErrorsLib.ZeroAddress();

        MORPHO = IMorphoCredit(_morpho);
        WAUSDC = IERC4626(_wausdc);
        USDC = IERC20(IERC4626(_wausdc).asset());
        protocolConfig = IProtocolConfig(_protocolConfig);
        marketId = _marketId;

        // Retrieve and store MarketParams fields as immutables
        MarketParams memory params = IMorpho(_morpho).idToMarketParams(_marketId);
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
        if (msg.sender != owner()) revert ErrorsLib.NotOwner();
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
        if (usdcAmount == 0) revert ErrorsLib.ZeroAssets();
        if (!_hasCreditLine(borrower)) revert NoCreditLine();

        _checkAndUpdateThrottle(usdcAmount);

        // Convert USDC amount to waUSDC for borrowing
        // Use previewWithdraw (rounds up) to ensure silo always has enough waUSDC for full draws
        uint256 waUsdcAmount = WAUSDC.previewWithdraw(usdcAmount);

        // Calculate origination fee (if both fee rate and recipient are configured)
        uint256 feeUsdc;
        uint256 feeWaUsdc;
        address feeRecipient = address(uint160(protocolConfig.config(ProtocolConfigLib.CC_FEE_RECIPIENT)));
        uint256 feeBps = protocolConfig.config(ProtocolConfigLib.CC_ORIGINATION_FEE_BPS);
        if (feeRecipient != address(0) && feeBps != 0) {
            feeUsdc = (usdcAmount * feeBps) / 10000;
            feeWaUsdc = WAUSDC.previewWithdraw(feeUsdc);
        }

        // Check global CC cap (% of debt cap) - both in waUSDC terms
        // Cap checks use position amount only (fee is not tracked since it's sent away immediately)
        // >= 10000 bps (100%) means unlimited, skip check
        uint256 ccDebtCapBps = protocolConfig.config(ProtocolConfigLib.CC_DEBT_CAP_BPS);
        if (ccDebtCapBps < 10000) {
            uint256 debtCap = protocolConfig.config(ProtocolConfigLib.DEBT_CAP);
            uint256 maxCcWaUsdc = (debtCap * ccDebtCapBps) / 10000;
            if (totalCcWaUsdc + waUsdcAmount > maxCcWaUsdc) revert CcCapExceeded();
        }

        // Check per-borrower CC cap (% of credit line) - credit line is in waUSDC
        // >= 10000 bps (100%) means unlimited, skip check
        uint256 ccCreditLineBps = protocolConfig.config(ProtocolConfigLib.CC_CREDIT_LINE_BPS);
        if (ccCreditLineBps < 10000) {
            uint256 creditLine = IMorpho(address(MORPHO)).position(marketId, borrower).collateral;
            uint256 maxBorrowerCcWaUsdc = (creditLine * ccCreditLineBps) / 10000;
            if (borrowerTotalCcWaUsdc[borrower] + waUsdcAmount > maxBorrowerCcWaUsdc) revert CcCapExceeded();
        }

        // Borrow waUSDC from MorphoCredit on behalf of the borrower (position + fee)
        // Fee waUSDC is paid out immediately and remains borrower debt in MorphoCredit.
        IMorpho(address(MORPHO)).borrow(_marketParams(), waUsdcAmount + feeWaUsdc, 0, borrower, address(this));

        // Send fee to recipient (redeem waUSDC to USDC)
        if (feeWaUsdc > 0) {
            WAUSDC.redeem(feeWaUsdc, feeRecipient, address(this));
        }

        // Load silo into memory, update, and write back once
        // Silo only holds position waUSDC (fee was sent to recipient)
        Silo memory silo = silos[msg.sender];
        uint256 shares = usdcAmount.toSharesDown(silo.totalPrincipal, silo.totalShares);
        silo.totalPrincipal += usdcAmount.toUint128();
        silo.totalShares += shares.toUint128();
        silo.totalWaUsdcHeld += waUsdcAmount.toUint128();
        silos[msg.sender] = silo;

        // Record borrower's shares (additive for multiple opens)
        borrowerShares[msg.sender][borrower] += shares;

        // Update CC waUSDC tracking (position only, fee is not tracked since it's sent away)
        totalCcWaUsdc += waUsdcAmount;
        borrowerTotalCcWaUsdc[borrower] += waUsdcAmount;

        emit PositionOpened(msg.sender, borrower, usdcAmount, shares, feeUsdc);
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

        // Full close: derive principal from shares
        Silo memory silo = silos[msg.sender];
        uint256 usdcPrincipal = shares.toAssetsDown(silo.totalPrincipal, silo.totalShares);

        return _close(borrower, shares, usdcPrincipal);
    }

    /// @inheritdoc ICallableCredit
    function close(address borrower, uint256 usdcAmount)
        external
        whenNotFrozen
        onlyAuthorizedCounterProtocol
        returns (uint256 usdcSent, uint256 waUsdcSent)
    {
        if (usdcAmount == 0) revert ErrorsLib.ZeroAssets();

        uint256 shares = borrowerShares[msg.sender][borrower];
        if (shares == 0) revert NoPosition();

        // Calculate shares to burn from USDC amount
        Silo memory silo = silos[msg.sender];
        uint256 sharesToBurn = usdcAmount.toSharesUp(silo.totalPrincipal, silo.totalShares);
        if (sharesToBurn > shares) revert InsufficientShares();

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
            waUsdcToClose = (sharesToBurn * silo.totalWaUsdcHeld) / silo.totalShares;

            // Update silo state
            silo.totalPrincipal -= usdcPrincipal.toUint128();
            silo.totalShares -= sharesToBurn.toUint128();
            silo.totalWaUsdcHeld -= waUsdcToClose.toUint128();
            silos[msg.sender] = silo;

            // Update borrower's shares
            borrowerShares[msg.sender][borrower] -= sharesToBurn;

            // Decrease CC waUSDC tracking
            totalCcWaUsdc -= waUsdcToClose;
            borrowerTotalCcWaUsdc[borrower] -= waUsdcToClose;
        }

        // Accrue premiums to ensure borrower's debt is current
        _accruePremiums(borrower);

        // Scoped block for repayment logic
        {
            // Query actual debt and calculate repayment. Any accrued interest/premiums or fee debt beyond escrowed
            // waUSDC remain owed in MorphoCredit.
            uint256 actualDebt = _getBorrowerDebt(borrower);
            uint256 toRepay = waUsdcToClose < actualDebt ? waUsdcToClose : actualDebt;
            uint256 excessWaUsdc = waUsdcToClose - toRepay;

            // Repay what's owed to MorphoCredit
            if (toRepay > 0) {
                _repayToMorpho(borrower, toRepay);
            }

            // Return excess to borrower, preferring USDC
            if (excessWaUsdc > 0) {
                (usdcSent, waUsdcSent) = _withdrawPreferUsdc(excessWaUsdc, borrower);
            }
        }

        emit PositionClosed(msg.sender, borrower, usdcPrincipal, sharesToBurn);
    }

    // ============ Draw Functions ============

    /// @inheritdoc ICallableCredit
    function draw(address borrower, uint256 usdcAmount, address recipient)
        external
        whenNotFrozen
        onlyAuthorizedCounterProtocol
        returns (uint256 usdcSent, uint256 waUsdcSent)
    {
        if (usdcAmount == 0) revert ErrorsLib.ZeroAssets();

        uint256 shares = borrowerShares[msg.sender][borrower];
        if (shares == 0) revert NoPosition();

        uint256 waUsdcNeeded;
        uint256 excessWaUsdc;

        // Scoped block to reduce stack pressure
        {
            // Load silo into memory
            Silo memory silo = silos[msg.sender];

            // Check against USDC principal (draw cap)
            if (usdcAmount > silo.totalPrincipal) revert InsufficientPrincipal();

            // Calculate shares to burn based on USDC amount
            uint256 sharesToBurn = usdcAmount.toSharesUp(silo.totalPrincipal, silo.totalShares);
            if (sharesToBurn > shares) revert InsufficientShares();

            // Calculate proportional waUSDC for shares being burned (like _close does)
            // If burning all shares, use all waUSDC to avoid rounding dust
            uint256 waUsdcFromShares = sharesToBurn == silo.totalShares
                ? silo.totalWaUsdcHeld
                : (sharesToBurn * silo.totalWaUsdcHeld) / silo.totalShares;

            // Calculate waUSDC needed to fulfill the USDC withdrawal
            waUsdcNeeded = WAUSDC.previewWithdraw(usdcAmount);
            if (waUsdcNeeded > silo.totalWaUsdcHeld) revert InsufficientWaUsdc();

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
            totalCcWaUsdc -= waUsdcToDeduct;
            borrowerTotalCcWaUsdc[borrower] -= waUsdcToDeduct;
        }

        // Withdraw waUsdcNeeded to recipient, preferring USDC
        (usdcSent, waUsdcSent) = _withdrawPreferUsdc(waUsdcNeeded, recipient);

        // Handle excess waUSDC: repay borrower's debt first, return remainder
        if (excessWaUsdc > 0) {
            _accruePremiums(borrower);

            uint256 repaidAmount;
            uint256 returnedUsdc;
            uint256 returnedWaUsdc;

            // Scoped block for excess handling
            {
                uint256 actualDebt = _getBorrowerDebt(borrower);
                uint256 toRepay = excessWaUsdc < actualDebt ? excessWaUsdc : actualDebt;
                uint256 remainder = excessWaUsdc - toRepay;

                if (toRepay > 0) {
                    _repayToMorpho(borrower, toRepay);
                    repaidAmount = toRepay;
                }

                if (remainder > 0) {
                    (returnedUsdc, returnedWaUsdc) = _withdrawPreferUsdc(remainder, borrower);
                }
            }

            emit DrawExcessHandled(msg.sender, borrower, excessWaUsdc, repaidAmount, returnedUsdc, returnedWaUsdc);
        }

        emit Draw(msg.sender, borrower, recipient, usdcAmount, usdcSent, waUsdcSent);
    }

    /// @inheritdoc ICallableCredit
    function draw(uint256 usdcAmount, address recipient)
        external
        whenNotFrozen
        onlyAuthorizedCounterProtocol
        returns (uint256 usdcSent, uint256 waUsdcSent)
    {
        if (usdcAmount == 0) revert ErrorsLib.ZeroAssets();

        // Load silo into memory
        Silo memory silo = silos[msg.sender];

        // Check against USDC principal (draw cap)
        if (usdcAmount > silo.totalPrincipal) revert InsufficientPrincipal();

        // Convert USDC to waUSDC needed for withdrawal
        uint256 waUsdcNeeded = WAUSDC.previewWithdraw(usdcAmount);
        if (waUsdcNeeded > silo.totalWaUsdcHeld) revert InsufficientWaUsdc();

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
        totalCcWaUsdc -= waUsdcNeeded;

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

    /// @notice Check and update throttle state
    /// @param usdcAmount The USDC amount being opened
    function _checkAndUpdateThrottle(uint256 usdcAmount) internal {
        uint256 throttlePeriod = protocolConfig.config(ProtocolConfigLib.CC_THROTTLE_PERIOD);
        uint256 throttleLimit = protocolConfig.config(ProtocolConfigLib.CC_THROTTLE_LIMIT);
        if (throttlePeriod != 0 && throttleLimit != 0) {
            if (block.timestamp >= throttlePeriodStart + throttlePeriod) {
                throttlePeriodStart = uint64(block.timestamp);
                throttlePeriodUsdc = 0;
            }
            if (throttlePeriodUsdc + usdcAmount > throttleLimit) revert ThrottleLimitExceeded();
            throttlePeriodUsdc += uint128(usdcAmount);
        }
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

    /// @notice Accrue premiums for a borrower
    /// @param borrower The borrower address
    function _accruePremiums(address borrower) internal {
        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        MORPHO.accruePremiumsForBorrowers(marketId, borrowers);
    }

    /// @notice Repay waUSDC to MorphoCredit on behalf of a borrower
    /// @param borrower The borrower address
    /// @param amount The waUSDC amount to repay
    function _repayToMorpho(address borrower, uint256 amount) internal {
        IERC20(address(WAUSDC)).approve(address(MORPHO), amount);
        IMorpho(address(MORPHO)).repay(_marketParams(), amount, 0, borrower, "");
    }
}
