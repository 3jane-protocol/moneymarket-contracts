// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";

import {SafeHelper} from "../utils/SafeHelper.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {IProtocolConfig, CreditLineConfig} from "../../src/interfaces/IProtocolConfig.sol";
import {IMorpho, IMorphoCredit, Id, Market, Position} from "../../src/interfaces/IMorpho.sol";
import {MathLib} from "../../src/libraries/MathLib.sol";
import {ProtocolConfigLib} from "../../src/libraries/ProtocolConfigLib.sol";
import {SharesMathLib} from "../../src/libraries/SharesMathLib.sol";

/// @title Lift3JaneNestedBorrowCapSafe
/// @notice Queues and executes reusable cap lifts for 3Jane's nested borrower via Safe + Timelock.
/// @dev The target cap is the final borrower credit line in native 6-decimal waUSDC units. This script does not borrow.
contract Lift3JaneNestedBorrowCapSafe is Script, SafeHelper, TimelockHelper {
    using MathLib for uint256;
    using SharesMathLib for uint256;

    address private constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address private constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address private constant PROTOCOL_CONFIG = 0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E;
    address private constant BORROWER = 0x3Ff3ff33D20a086834A095ed6ed562c9e189291b;

    CreditLine private constant CREDIT_LINE = CreditLine(0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9);
    Id private constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    struct CapLiftPlan {
        uint256 targetBorrowerCap;
        uint256 currentBorrowerCredit;
        uint256 currentBorrowerDebt;
        uint256 currentMarketBorrow;
        uint256 currentDebtCap;
        uint256 requiredDebtCap;
        uint256 finalDebtCap;
        uint256 currentMaxCreditLine;
        uint256 temporaryMaxCreditLine;
        uint256 restoredMaxCreditLine;
        uint256 vv;
        uint128 drp;
        bool liftMaxCreditLine;
        bool liftDebtCap;
    }

    function run(uint256 targetBorrowerCapWaUsdc) external {
        this.schedule(targetBorrowerCapWaUsdc, false);
    }

    function run(uint256 targetBorrowerCapWaUsdc, bool send) external {
        this.schedule(targetBorrowerCapWaUsdc, send);
    }

    function schedule(uint256 targetBorrowerCapWaUsdc, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(TIMELOCK)
    {
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        CapLiftPlan memory plan = _buildPlan(targetBorrowerCapWaUsdc);
        (address[] memory targets, uint256[] memory values, bytes[] memory datas) = _buildTimelockBatch(plan);
        bytes32 salt = _generateSalt(plan);
        bytes32 predecessor = bytes32(0);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        _logPlan("Schedule 3Jane Nested Borrow Cap Lift", plan, operationId, send);

        if (isOperation(TIMELOCK, operationId)) {
            logOperationState(TIMELOCK, operationId);
            console2.log("");
            console2.log("Operation already exists. Use execute() when ready.");
            return;
        }

        simulateExecution(TIMELOCK, targets, values, datas);
        console2.log("");

        uint256 minDelay = getMinDelay(TIMELOCK);
        console2.log("Timelock delay:", minDelay, "seconds (%d hours)", minDelay / 3600);
        console2.log("");

        bytes memory scheduleCalldata = encodeScheduleBatch(targets, values, datas, predecessor, salt, minDelay);
        addToBatch(TIMELOCK, scheduleCalldata);

        if (send) {
            console2.log("Sending schedule transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully.");
            console2.log("Operation ID:", vm.toString(operationId));
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    function execute(uint256 targetBorrowerCapWaUsdc, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(TIMELOCK)
    {
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        CapLiftPlan memory plan = _buildPlan(targetBorrowerCapWaUsdc);
        (address[] memory targets, uint256[] memory values, bytes[] memory datas) = _buildTimelockBatch(plan);
        bytes32 salt = _generateSalt(plan);
        bytes32 predecessor = bytes32(0);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        _logPlan("Execute 3Jane Nested Borrow Cap Lift", plan, operationId, send);
        logOperationState(TIMELOCK, operationId);
        console2.log("");
        requireOperationReady(TIMELOCK, operationId);

        bytes memory executeCalldata = encodeExecuteBatch(targets, values, datas, predecessor, salt);
        addToBatch(TIMELOCK, executeCalldata);

        if (send) {
            console2.log("Sending execute transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully.");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    function checkStatus(uint256 targetBorrowerCapWaUsdc) external view {
        CapLiftPlan memory plan = _buildPlan(targetBorrowerCapWaUsdc);
        (address[] memory targets, uint256[] memory values, bytes[] memory datas) = _buildTimelockBatch(plan);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, bytes32(0), _generateSalt(plan));

        _logPlan("Check 3Jane Nested Borrow Cap Lift", plan, operationId, false);
        logOperationState(TIMELOCK, operationId);
    }

    function preview(uint256 targetBorrowerCapWaUsdc) external view {
        CapLiftPlan memory plan = _buildPlan(targetBorrowerCapWaUsdc);
        bytes32 operationId;
        _logPlan("Preview 3Jane Nested Borrow Cap Lift", plan, operationId, false);
    }

    function _buildPlan(uint256 targetBorrowerCapWaUsdc) private view returns (CapLiftPlan memory plan) {
        require(targetBorrowerCapWaUsdc > 0, "target cap required");
        require(CREDIT_LINE.prover() == address(0), "prover-enabled credit line unsupported");

        IMorphoCredit morphoCredit = IMorphoCredit(CREDIT_LINE.MORPHO());
        IMorpho morpho = IMorpho(address(morphoCredit));
        IProtocolConfig config = IProtocolConfig(PROTOCOL_CONFIG);
        CreditLineConfig memory creditLineConfig = config.getCreditLineConfig();

        require(creditLineConfig.maxLTV > 0, "max ltv unset");

        Position memory position = morpho.position(MARKET_ID, BORROWER);
        Market memory market = morpho.market(MARKET_ID);

        uint256 currentBorrowerDebt =
            uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        uint256 borrowerHeadroomAfterLift =
            targetBorrowerCapWaUsdc > currentBorrowerDebt ? targetBorrowerCapWaUsdc - currentBorrowerDebt : 0;
        uint256 requiredDebtCap = uint256(market.totalBorrowAssets) + borrowerHeadroomAfterLift;
        uint256 currentDebtCap = config.config(ProtocolConfigLib.DEBT_CAP);
        uint256 currentMaxCreditLine = creditLineConfig.maxCreditLine;
        uint256 temporaryMaxCreditLine =
            currentMaxCreditLine < targetBorrowerCapWaUsdc ? targetBorrowerCapWaUsdc : currentMaxCreditLine;
        uint256 vv = targetBorrowerCapWaUsdc.wDivUp(creditLineConfig.maxLTV) + 1;

        require(targetBorrowerCapWaUsdc > uint256(position.collateral), "target must exceed current borrower credit");
        require(targetBorrowerCapWaUsdc >= creditLineConfig.minCreditLine, "target below min credit line");
        require(vv <= creditLineConfig.maxVV, "computed vv exceeds max vv");
        require(targetBorrowerCapWaUsdc.wDivDown(vv) <= creditLineConfig.maxLTV, "computed vv exceeds max ltv");

        (, uint128 drp,) = morphoCredit.borrowerPremium(MARKET_ID, BORROWER);

        plan = CapLiftPlan({
            targetBorrowerCap: targetBorrowerCapWaUsdc,
            currentBorrowerCredit: uint256(position.collateral),
            currentBorrowerDebt: currentBorrowerDebt,
            currentMarketBorrow: uint256(market.totalBorrowAssets),
            currentDebtCap: currentDebtCap,
            requiredDebtCap: requiredDebtCap,
            finalDebtCap: currentDebtCap > requiredDebtCap ? currentDebtCap : requiredDebtCap,
            currentMaxCreditLine: currentMaxCreditLine,
            temporaryMaxCreditLine: temporaryMaxCreditLine,
            restoredMaxCreditLine: currentMaxCreditLine,
            vv: vv,
            drp: drp,
            liftMaxCreditLine: currentMaxCreditLine < targetBorrowerCapWaUsdc,
            liftDebtCap: currentDebtCap < requiredDebtCap
        });
    }

    function _buildTimelockBatch(CapLiftPlan memory plan)
        private
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory datas)
    {
        uint256 count = 1;
        if (plan.liftMaxCreditLine) count += 2;
        if (plan.liftDebtCap) count += 1;

        targets = new address[](count);
        values = new uint256[](count);
        datas = new bytes[](count);

        uint256 index;

        if (plan.liftMaxCreditLine) {
            targets[index] = PROTOCOL_CONFIG;
            datas[index] = abi.encodeCall(
                IProtocolConfig.setConfig, (ProtocolConfigLib.MAX_CREDIT_LINE, plan.temporaryMaxCreditLine)
            );
            index++;
        }

        if (plan.liftDebtCap) {
            targets[index] = PROTOCOL_CONFIG;
            datas[index] = abi.encodeCall(IProtocolConfig.setConfig, (ProtocolConfigLib.DEBT_CAP, plan.finalDebtCap));
            index++;
        }

        targets[index] = address(CREDIT_LINE);
        datas[index] = _buildSetCreditLineCall(plan);
        index++;

        if (plan.liftMaxCreditLine) {
            targets[index] = PROTOCOL_CONFIG;
            datas[index] = abi.encodeCall(
                IProtocolConfig.setConfig, (ProtocolConfigLib.MAX_CREDIT_LINE, plan.restoredMaxCreditLine)
            );
        }
    }

    function _buildSetCreditLineCall(CapLiftPlan memory plan) private pure returns (bytes memory) {
        Id[] memory ids = new Id[](1);
        address[] memory borrowers = new address[](1);
        uint256[] memory vvs = new uint256[](1);
        uint256[] memory credits = new uint256[](1);
        uint128[] memory drps = new uint128[](1);

        ids[0] = MARKET_ID;
        borrowers[0] = BORROWER;
        vvs[0] = plan.vv;
        credits[0] = plan.targetBorrowerCap;
        drps[0] = plan.drp;

        return abi.encodeCall(CREDIT_LINE.setCreditLines, (ids, borrowers, vvs, credits, drps));
    }

    function _generateSalt(CapLiftPlan memory plan) private pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "3Jane nested borrower cap lift: ",
                BORROWER,
                MARKET_ID,
                plan.targetBorrowerCap,
                plan.finalDebtCap,
                plan.currentMaxCreditLine,
                plan.temporaryMaxCreditLine,
                plan.vv,
                plan.drp,
                plan.liftMaxCreditLine,
                plan.liftDebtCap
            )
        );
    }

    function _logPlan(string memory label, CapLiftPlan memory plan, bytes32 operationId, bool send) private view {
        console2.log("===", label, "===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE));
        console2.log("Timelock address:", TIMELOCK);
        console2.log("ProtocolConfig address:", PROTOCOL_CONFIG);
        console2.log("CreditLine address:", address(CREDIT_LINE));
        console2.log("Borrower:", BORROWER);
        console2.log("Market ID:", vm.toString(Id.unwrap(MARKET_ID)));
        if (operationId != bytes32(0)) console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Send to Safe:", send);
        console2.log("");

        console2.log("Current borrower credit:", plan.currentBorrowerCredit);
        console2.log("Target borrower credit:", plan.targetBorrowerCap);
        console2.log("Current borrower debt:", plan.currentBorrowerDebt);
        console2.log("Current market borrow:", plan.currentMarketBorrow);
        console2.log("");

        console2.log("Current DEBT_CAP:", plan.currentDebtCap);
        console2.log("Required DEBT_CAP:", plan.requiredDebtCap);
        console2.log("Final DEBT_CAP:", plan.finalDebtCap);
        console2.log("Lift DEBT_CAP:", plan.liftDebtCap);
        console2.log("");

        console2.log("Current MAX_CREDIT_LINE:", plan.currentMaxCreditLine);
        console2.log("Temporary MAX_CREDIT_LINE:", plan.temporaryMaxCreditLine);
        console2.log("Restored MAX_CREDIT_LINE:", plan.restoredMaxCreditLine);
        console2.log("Lift MAX_CREDIT_LINE:", plan.liftMaxCreditLine);
        console2.log("");

        console2.log("Computed VV:", plan.vv);
        console2.log("Preserved DRP:", plan.drp);
        console2.log("Timelock calls:", _callCount(plan));
        console2.log("");
    }

    function _callCount(CapLiftPlan memory plan) private pure returns (uint256 count) {
        count = 1;
        if (plan.liftDebtCap) count++;
        if (plan.liftMaxCreditLine) count += 2;
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
