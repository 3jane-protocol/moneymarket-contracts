// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20, IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {SafeHelper} from "../utils/SafeHelper.sol";
import {IHelper} from "../../src/interfaces/IHelper.sol";
import {IMorpho, IMorphoCredit, Id, MarketParams, Position} from "../../src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../src/libraries/MarketParamsLib.sol";
import {MorphoCreditBalancesLib} from "../../src/libraries/periphery/MorphoCreditBalancesLib.sol";

interface IBorrowerSafe {
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool success);

    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function nonce() external view returns (uint256);
}

interface IMultiSendCallOnly {
    function multiSend(bytes calldata transactions) external payable;
}

/// @title RepayBorrowerSafeViaHelper
/// @notice Queues a protocol Safe transaction that makes its nested borrower Safe repay Morpho credit via Helper.
/// @dev The default entrypoints deal USDC to the borrower only in the fork simulation so a proposal can be created
///      before the borrower is funded onchain. The queued transaction still requires real USDC at execution time.
contract RepayBorrowerSafeViaHelper is Script, SafeHelper {
    using MarketParamsLib for MarketParams;
    using MorphoCreditBalancesLib for IMorphoCredit;

    uint8 private constant CALL = 0;
    uint8 private constant DELEGATECALL = 1;

    uint256 public constant DEFAULT_REPAY_USDC = 7_248_490e6;

    address private constant PROTOCOL_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address private constant BORROWER_SAFE = 0x3Ff3ff33D20a086834A095ed6ed562c9e189291b;
    address private constant MULTISEND_CALL_ONLY = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    address private constant MORPHO_CREDIT = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;
    address private constant HELPER = 0x2A66F992bF227D2e50eF19EDD21503C3c4F3f682;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant WAUSDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;

    Id private constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    struct Snapshot {
        uint256 usdcBalance;
        uint256 helperAllowance;
        uint256 borrowShares;
        uint256 estimatedDebtWaUsdc;
        uint256 estimatedDebtUsdc;
        uint256 borrowerSafeNonce;
    }

    /// @notice Simulates the requested repayment without sending it to the Safe API.
    function run() external {
        this.run(false);
    }

    /// @notice Builds the requested repayment and optionally sends it to the Safe API.
    /// @dev Synthetic borrower funding is enabled so this can be proposed before the real USDC arrives.
    function run(bool send) external isBatch(PROTOCOL_SAFE) {
        _run(DEFAULT_REPAY_USDC, send, true);
    }

    /// @notice Generic entrypoint for another exact USDC amount or an already-funded simulation.
    function run(uint256 repayUsdc, bool send, bool simulateFunding) external isBatch(PROTOCOL_SAFE) {
        _run(repayUsdc, send, simulateFunding);
    }

    function preview(uint256 repayUsdc) external view {
        _validateNestedSafeOwnership();
        MarketParams memory marketParams = _marketParams();
        bytes memory nestedExecCalldata = _nestedExecCalldata(marketParams, repayUsdc);
        _logPlan(repayUsdc, false, false, _snapshot(), nestedExecCalldata);
    }

    function calldataFor(uint256 repayUsdc) external view returns (bytes memory) {
        _validateNestedSafeOwnership();
        return _nestedExecCalldata(_marketParams(), repayUsdc);
    }

    function _run(uint256 repayUsdc, bool send, bool simulateFunding) private {
        require(repayUsdc > 0, "repay amount required");

        if (simulateFunding) deployMode = DeployMode.PRODUCTION;

        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        _validateNestedSafeOwnership();
        MarketParams memory marketParams = _marketParams();
        Snapshot memory liveState = _snapshot();
        require(liveState.borrowShares > 0, "borrower has no debt");

        if (simulateFunding && liveState.usdcBalance < repayUsdc) {
            console2.log("Simulation only: setting borrower Safe USDC balance to repayment amount");
            deal(USDC, BORROWER_SAFE, repayUsdc);
        }

        Snapshot memory beforeState = _snapshot();
        require(beforeState.usdcBalance >= repayUsdc, "borrower Safe USDC balance insufficient");

        bytes memory nestedExecCalldata = _nestedExecCalldata(marketParams, repayUsdc);
        _logPlan(repayUsdc, send, simulateFunding, liveState, nestedExecCalldata);

        bytes memory returnData = addToBatch(BORROWER_SAFE, nestedExecCalldata);
        require(abi.decode(returnData, (bool)), "nested Safe execution failed");

        Snapshot memory afterState = _snapshot();
        _validateSimulation(repayUsdc, beforeState, afterState);
        _logSimulation(beforeState, afterState);

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

    function _nestedExecCalldata(MarketParams memory marketParams, uint256 repayUsdc)
        private
        pure
        returns (bytes memory)
    {
        require(repayUsdc > 0, "repay amount required");

        bytes memory resetAllowance = abi.encodeCall(IERC20.approve, (HELPER, 0));
        bytes memory setAllowance = abi.encodeCall(IERC20.approve, (HELPER, repayUsdc));
        bytes memory repayCall = abi.encodeCall(IHelper.repay, (marketParams, repayUsdc, BORROWER_SAFE, ""));
        bytes memory multiSendTransactions = bytes.concat(
            _encodeMultiSendTx(CALL, USDC, resetAllowance),
            _encodeMultiSendTx(CALL, USDC, setAllowance),
            _encodeMultiSendTx(CALL, HELPER, repayCall)
        );
        bytes memory multiSendCall = abi.encodeCall(IMultiSendCallOnly.multiSend, (multiSendTransactions));

        return abi.encodeCall(
            IBorrowerSafe.execTransaction,
            (
                MULTISEND_CALL_ONLY,
                0,
                multiSendCall,
                DELEGATECALL,
                0,
                0,
                0,
                address(0),
                payable(address(0)),
                _prevalidatedSignature(PROTOCOL_SAFE)
            )
        );
    }

    function _marketParams() private view returns (MarketParams memory marketParams) {
        marketParams = IMorpho(MORPHO_CREDIT).idToMarketParams(MARKET_ID);
        require(Id.unwrap(marketParams.id()) == Id.unwrap(MARKET_ID), "market id mismatch");
        require(marketParams.loanToken == WAUSDC, "unexpected loan token");
        require(marketParams.collateralToken == USDC, "unexpected collateral token");
    }

    function _snapshot() private view returns (Snapshot memory state) {
        Position memory position = IMorpho(MORPHO_CREDIT).position(MARKET_ID, BORROWER_SAFE);
        state.usdcBalance = IERC20(USDC).balanceOf(BORROWER_SAFE);
        state.helperAllowance = IERC20(USDC).allowance(BORROWER_SAFE, HELPER);
        state.borrowShares = position.borrowShares;
        state.borrowerSafeNonce = IBorrowerSafe(BORROWER_SAFE).nonce();

        if (position.borrowShares > 0) {
            state.estimatedDebtWaUsdc =
                IMorphoCredit(MORPHO_CREDIT).expectedBorrowAssetsWithPremium(MARKET_ID, BORROWER_SAFE);
            state.estimatedDebtUsdc = IERC4626(WAUSDC).previewMint(state.estimatedDebtWaUsdc);
        }
    }

    function _validateNestedSafeOwnership() private view {
        address[] memory owners = IBorrowerSafe(BORROWER_SAFE).getOwners();
        require(owners.length == 1, "unexpected nested Safe owner count");
        require(owners[0] == PROTOCOL_SAFE, "protocol Safe is not sole nested owner");
        require(IBorrowerSafe(BORROWER_SAFE).getThreshold() == 1, "unexpected nested Safe threshold");
    }

    function _validateSimulation(uint256 repayUsdc, Snapshot memory beforeState, Snapshot memory afterState)
        private
        pure
    {
        require(afterState.usdcBalance == beforeState.usdcBalance - repayUsdc, "unexpected USDC balance change");
        require(afterState.helperAllowance == 0, "Helper allowance not consumed");
        require(afterState.borrowShares < beforeState.borrowShares, "borrow shares did not decrease");
        require(
            afterState.borrowerSafeNonce == beforeState.borrowerSafeNonce + 1, "borrower Safe nonce did not advance"
        );
    }

    function _encodeMultiSendTx(uint8 operation, address to, bytes memory data) private pure returns (bytes memory) {
        return abi.encodePacked(operation, to, uint256(0), data.length, data);
    }

    function _prevalidatedSignature(address owner) private pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));
    }

    function _logPlan(
        uint256 repayUsdc,
        bool send,
        bool simulateFunding,
        Snapshot memory liveState,
        bytes memory nestedExecCalldata
    ) private view {
        console2.log("=== Nested Borrower Safe Repayment via Helper ===");
        console2.log("Protocol Safe:", PROTOCOL_SAFE);
        console2.log("Borrower Safe:", BORROWER_SAFE);
        console2.log("Helper:", HELPER);
        console2.log("Repayment (USDC base units):", repayUsdc);
        console2.log("Repayment (whole USDC):", repayUsdc / 1e6);
        console2.log("Live borrower USDC balance:", liveState.usdcBalance);
        console2.log("Live Helper allowance:", liveState.helperAllowance);
        console2.log("Estimated debt (waUSDC):", liveState.estimatedDebtWaUsdc);
        console2.log("Estimated debt (USDC):", liveState.estimatedDebtUsdc);
        console2.log("Borrower Safe nonce:", liveState.borrowerSafeNonce);
        console2.log("Protocol Safe nonce:", IBorrowerSafe(PROTOCOL_SAFE).nonce());
        console2.log("Synthetic simulation funding:", simulateFunding);
        console2.log("Send to Safe API:", send);
        console2.log("Nested exec calldata:");
        console2.logBytes(nestedExecCalldata);
        console2.log("");
    }

    function _logSimulation(Snapshot memory beforeState, Snapshot memory afterState) private pure {
        console2.log("=== Fork Simulation Result ===");
        console2.log("Borrow shares before:", beforeState.borrowShares);
        console2.log("Borrow shares after:", afterState.borrowShares);
        console2.log("Estimated debt before (USDC):", beforeState.estimatedDebtUsdc);
        console2.log("Estimated debt after (USDC):", afterState.estimatedDebtUsdc);
        console2.log("Borrower USDC after:", afterState.usdcBalance);
        console2.log("Helper allowance after:", afterState.helperAllowance);
        console2.log("Borrower Safe nonce after:", afterState.borrowerSafeNonce);
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
