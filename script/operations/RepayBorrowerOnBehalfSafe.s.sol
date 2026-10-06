// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20, IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {SafeHelper} from "../utils/SafeHelper.sol";
import {IHelper} from "../../src/interfaces/IHelper.sol";
import {IMorpho, IMorphoCredit, Id, MarketParams, Position} from "../../src/interfaces/IMorpho.sol";
import {IProtocolConfig} from "../../src/interfaces/IProtocolConfig.sol";
import {MarketParamsLib} from "../../src/libraries/MarketParamsLib.sol";
import {MorphoCreditBalancesLib} from "../../src/libraries/periphery/MorphoCreditBalancesLib.sol";
import {MorphoCreditLib} from "../../src/libraries/periphery/MorphoCreditLib.sol";

/// @title RepayBorrowerOnBehalfSafe
/// @notice Proposes one protocol Safe batch that fully repays a borrower's MorphoCredit debt through Helper.
/// @dev The batch calls USDC.approve(HELPER, cap), Helper.repay with the full-repayment sentinel, then
///      USDC.approve(HELPER, 0). The cap adds a configurable buffer because debt continues to grow between proposal
///      creation and Safe execution. The final approval clears any unused allowance. `simulateFunding` deals USDC only
///      to the Safe in the fork simulation; real execution still requires the Safe to hold enough USDC.
/// @dev After full repayment, CreditLine.settle for this borrower takes the zero-debt path in
///      MorphoCredit.settleAccount.
/// @dev Usage (default 100 bps buffer):
///      FOUNDRY_PROFILE=script WALLET_TYPE=account SAFE_PROPOSER_ACCOUNT=<account> SAFE_NONCE=<nonce> \
///      yarn script:forge script/operations/RepayBorrowerOnBehalfSafe.s.sol:RepayBorrowerOnBehalfSafe \
///      --sig "run(address,bool,bool)" <borrower> true false --rpc-url <rpc-url>
/// @dev Usage (custom buffer in bps):
///      FOUNDRY_PROFILE=script WALLET_TYPE=account SAFE_PROPOSER_ACCOUNT=<account> SAFE_NONCE=<nonce> \
///      yarn script:forge script/operations/RepayBorrowerOnBehalfSafe.s.sol:RepayBorrowerOnBehalfSafe \
///      --sig "run(address,uint256,bool,bool)" <borrower> <bufferBps> true false --rpc-url <rpc-url>
contract RepayBorrowerOnBehalfSafe is Script, SafeHelper {
    using MarketParamsLib for MarketParams;
    using MorphoCreditBalancesLib for IMorphoCredit;
    using MorphoCreditLib for IMorphoCredit;

    uint256 public constant DEFAULT_BUFFER_BPS = 100;
    uint256 public constant MAX_BUFFER_BPS = 1000;

    uint256 private constant BPS = 10_000;

    address private constant PROTOCOL_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address private constant MORPHO_CREDIT = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;
    address private constant HELPER = 0x2A66F992bF227D2e50eF19EDD21503C3c4F3f682;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant WAUSDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;

    Id private constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    struct Snapshot {
        uint256 safeUsdcBalance;
        uint256 helperAllowance;
        uint256 borrowShares;
        uint256 estimatedDebtWaUsdc;
        uint256 estimatedDebtUsdc;
        bool marketFrozen;
    }

    /// @notice Builds a full-repayment batch using the default 100 bps buffer.
    function run(address borrower, bool send, bool simulateFunding) external isBatch(PROTOCOL_SAFE) {
        _run(borrower, DEFAULT_BUFFER_BPS, send, simulateFunding);
    }

    /// @notice Builds a full-repayment batch using a caller-selected buffer of at most 1,000 bps.
    function run(address borrower, uint256 bufferBps, bool send, bool simulateFunding) external isBatch(PROTOCOL_SAFE) {
        _run(borrower, bufferBps, send, simulateFunding);
    }

    /// @notice Logs the current debt estimate, default-buffer cap, Safe balance, and market freeze status.
    function preview(address borrower) external view {
        _validateBorrower(borrower);
        _marketParams();

        Snapshot memory state = _snapshot(borrower);
        require(state.borrowShares > 0, "borrower has no debt");

        (uint256 cap, uint256 bufferUsdc) = _approvalCap(state.estimatedDebtUsdc, DEFAULT_BUFFER_BPS);
        _logPreview(borrower, state, DEFAULT_BUFFER_BPS, bufferUsdc, cap);
    }

    function _run(address borrower, uint256 bufferBps, bool send, bool simulateFunding) private {
        _validateBorrower(borrower);
        require(bufferBps <= MAX_BUFFER_BPS, "buffer exceeds 1,000 bps");

        if (simulateFunding) deployMode = DeployMode.PRODUCTION;

        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        MarketParams memory marketParams = _marketParams();
        Snapshot memory liveState = _snapshot(borrower);
        require(liveState.borrowShares > 0, "borrower has no debt");
        require(!liveState.marketFrozen, "market is frozen");

        (uint256 cap, uint256 bufferUsdc) = _approvalCap(liveState.estimatedDebtUsdc, bufferBps);

        if (simulateFunding && liveState.safeUsdcBalance < cap) {
            console2.log("Simulation only: setting protocol Safe USDC balance to approval cap");
            deal(USDC, PROTOCOL_SAFE, cap);
        }

        Snapshot memory beforeState = _snapshot(borrower);
        require(beforeState.safeUsdcBalance >= cap, "protocol Safe USDC balance insufficient");

        _logPlan(borrower, bufferBps, bufferUsdc, cap, send, simulateFunding, liveState, beforeState);

        bytes memory approveReturn = addToBatch(USDC, abi.encodeCall(IERC20.approve, (HELPER, cap)));
        require(abi.decode(approveReturn, (bool)), "approval to cap failed");

        addToBatch(HELPER, abi.encodeCall(IHelper.repay, (marketParams, type(uint256).max, borrower, "")));

        bytes memory clearReturn = addToBatch(USDC, abi.encodeCall(IERC20.approve, (HELPER, 0)));
        require(abi.decode(clearReturn, (bool)), "approval clear failed");

        require(getTotalBatches() == 1, "SafeHelper split repayment batch");
        (uint256 txCount,) = getBatchInfo(0);
        require(txCount == 3, "repayment batch must contain three calls");

        Snapshot memory afterState = _snapshot(borrower);
        uint256 actualUsdcPaid = _validateSimulation(cap, beforeState, afterState);
        _logSimulation(cap, actualUsdcPaid, beforeState, afterState);

        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully.");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    function _validateBorrower(address borrower) private pure {
        require(borrower != address(0), "borrower is zero address");
    }

    function _marketParams() private view returns (MarketParams memory marketParams) {
        marketParams = IMorpho(MORPHO_CREDIT).idToMarketParams(MARKET_ID);
        require(Id.unwrap(marketParams.id()) == Id.unwrap(MARKET_ID), "market id mismatch");
        require(marketParams.loanToken == WAUSDC, "unexpected loan token");
        require(marketParams.collateralToken == USDC, "unexpected collateral token");
    }

    function _snapshot(address borrower) private view returns (Snapshot memory state) {
        Position memory position = IMorpho(MORPHO_CREDIT).position(MARKET_ID, borrower);
        state.safeUsdcBalance = IERC20(USDC).balanceOf(PROTOCOL_SAFE);
        state.helperAllowance = IERC20(USDC).allowance(PROTOCOL_SAFE, HELPER);
        state.borrowShares = position.borrowShares;
        state.marketFrozen = _isMarketFrozen();

        if (position.borrowShares > 0) {
            state.estimatedDebtWaUsdc =
                IMorphoCredit(MORPHO_CREDIT).expectedBorrowAssetsWithPremium(MARKET_ID, borrower);
            state.estimatedDebtUsdc = IERC4626(WAUSDC).previewMint(state.estimatedDebtWaUsdc);
        }
    }

    function _isMarketFrozen() private view returns (bool) {
        IMorphoCredit morphoCredit = IMorphoCredit(MORPHO_CREDIT);
        uint256 cycleCount = morphoCredit.getPaymentCycleLength(MARKET_ID);
        uint256 cycleDuration = IProtocolConfig(morphoCredit.protocolConfig()).getCycleDuration();

        if (cycleCount == 0 || cycleDuration == 0) return true;

        uint256 lastCycleEnd = morphoCredit.paymentCycle(MARKET_ID, cycleCount - 1);
        return block.timestamp >= lastCycleEnd + cycleDuration;
    }

    function _approvalCap(uint256 estimatedDebtUsdc, uint256 bufferBps)
        private
        pure
        returns (uint256 cap, uint256 bufferUsdc)
    {
        uint256 scaledBuffer = estimatedDebtUsdc * bufferBps;
        bufferUsdc = scaledBuffer / BPS;
        if (scaledBuffer % BPS != 0) ++bufferUsdc;
        cap = estimatedDebtUsdc + bufferUsdc;
    }

    function _validateSimulation(uint256 cap, Snapshot memory beforeState, Snapshot memory afterState)
        private
        pure
        returns (uint256 actualUsdcPaid)
    {
        require(afterState.borrowShares == 0, "borrower debt not fully repaid");
        require(afterState.safeUsdcBalance < beforeState.safeUsdcBalance, "Safe USDC did not decrease");

        actualUsdcPaid = beforeState.safeUsdcBalance - afterState.safeUsdcBalance;
        require(actualUsdcPaid <= cap, "Safe USDC spend exceeded cap");
        require(afterState.helperAllowance == 0, "Helper allowance not cleared");
    }

    function _logPreview(address borrower, Snapshot memory state, uint256 bufferBps, uint256 bufferUsdc, uint256 cap)
        private
        pure
    {
        console2.log("=== Borrower Full Repayment Preview ===");
        console2.log("Borrower:", borrower);
        console2.log("Borrow shares:", state.borrowShares);
        console2.log("Estimated debt (waUSDC base units):", state.estimatedDebtWaUsdc);
        console2.log("Estimated debt (USDC base units):", state.estimatedDebtUsdc);
        console2.log("Buffer (bps):", bufferBps);
        console2.log("Buffer (USDC base units):", bufferUsdc);
        console2.log("Approval cap (USDC base units):", cap);
        console2.log("Protocol Safe USDC balance:", state.safeUsdcBalance);
        console2.log("Protocol Safe Helper allowance:", state.helperAllowance);
        console2.log("Market frozen:", state.marketFrozen);
        console2.log("");
    }

    function _logPlan(
        address borrower,
        uint256 bufferBps,
        uint256 bufferUsdc,
        uint256 cap,
        bool send,
        bool simulateFunding,
        Snapshot memory liveState,
        Snapshot memory beforeState
    ) private pure {
        console2.log("=== Protocol Safe Full Repayment on Behalf ===");
        console2.log("Protocol Safe:", PROTOCOL_SAFE);
        console2.log("Borrower:", borrower);
        console2.log("Helper:", HELPER);
        console2.log("Borrow shares:", liveState.borrowShares);
        console2.log("Estimated debt (waUSDC base units):", liveState.estimatedDebtWaUsdc);
        console2.log("Estimated debt (USDC base units):", liveState.estimatedDebtUsdc);
        console2.log("Buffer (bps):", bufferBps);
        console2.log("Buffer (USDC base units):", bufferUsdc);
        console2.log("Approval cap (USDC base units):", cap);
        console2.log("Live protocol Safe USDC balance:", liveState.safeUsdcBalance);
        console2.log("Simulation protocol Safe USDC balance:", beforeState.safeUsdcBalance);
        console2.log("Pre-existing Helper allowance:", liveState.helperAllowance);
        console2.log("Market frozen:", liveState.marketFrozen);
        console2.log("Synthetic simulation funding:", simulateFunding);
        console2.log("Send to Safe API:", send);
        console2.log("Batch call 1: USDC.approve(Helper, cap)");
        console2.log("Batch call 2: Helper.repay(..., type(uint256).max, borrower, empty data)");
        console2.log("Batch call 3: USDC.approve(Helper, 0)");
        console2.log("");
    }

    function _logSimulation(
        uint256 cap,
        uint256 actualUsdcPaid,
        Snapshot memory beforeState,
        Snapshot memory afterState
    ) private pure {
        console2.log("=== Fork Simulation Result ===");
        console2.log("Borrow shares before:", beforeState.borrowShares);
        console2.log("Borrow shares after:", afterState.borrowShares);
        console2.log("Safe USDC before:", beforeState.safeUsdcBalance);
        console2.log("Safe USDC after:", afterState.safeUsdcBalance);
        console2.log("Actual USDC paid:", actualUsdcPaid);
        console2.log("Unused approval buffer:", cap - actualUsdcPaid);
        console2.log("Helper allowance after:", afterState.helperAllowance);
        console2.log("");
    }

    function _baseFeeOkay() private view returns (bool) {
        uint256 basefeeLimit = vm.envOr("BASE_FEE_LIMIT", uint256(50)) * 1e9;
        if (block.basefee >= basefeeLimit) {
            console2.log("Base fee too high: %d gwei > %d gwei limit", block.basefee / 1e9, basefeeLimit / 1e9);
            return false;
        }
        console2.log("Base fee OK: %d gwei", block.basefee / 1e9);
        return true;
    }
}
