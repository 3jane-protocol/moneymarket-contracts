// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20, IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {SafeHelper} from "../utils/SafeHelper.sol";
import {IHelper} from "../../src/interfaces/IHelper.sol";
import {IMorpho, IMorphoCredit, Id, MarketParams, Position} from "../../src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../src/libraries/MarketParamsLib.sol";
import {MorphoCreditBalancesLib} from "../../src/libraries/periphery/MorphoCreditBalancesLib.sol";
import {RebateRepaymentLib} from "../../src/libraries/RebateRepaymentLib.sol";

/// @title RepayRebatesViaHelperSafe
/// @notice Builds a Safe batch that applies merged rebate report outputs as Helper.repay calls.
contract RepayRebatesViaHelperSafe is Script, SafeHelper {
    using MarketParamsLib for MarketParams;
    using MorphoCreditBalancesLib for IMorphoCredit;
    using RebateRepaymentLib for RebateRepaymentLib.MergedRebate;

    address private constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address private constant MORPHO_CREDIT = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;
    address private constant HELPER = 0x2A66F992bF227D2e50eF19EDD21503C3c4F3f682;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant WAUSDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;

    Id private constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    string private constant DEFAULT_AAVE_REPORT = "data/aave-rebate-report-2026-04-18-2026-04-29.json";
    string private constant DEFAULT_DELAYED_REPORT = "data/delayed-repayment-rebate-report-2026-04-18-safe-241.json";
    string private constant DEFAULT_AUDIT_OUTPUT = "data/rebate-helper-safe-repayment-audit.json";

    struct AuditRow {
        address borrower;
        uint256 aaveRebateUsdc;
        uint256 delayedRebateUsdc;
        uint256 totalRebateUsdc;
        uint256 currentDebtWaUsdc;
        uint256 estimatedFullPayoffUsdc;
        RebateRepaymentLib.RepaymentAction action;
        uint256 helperAssetsArgument;
        uint256 expectedAppliedUsdc;
        uint256 auditRemainderUsdc;
    }

    struct Totals {
        uint256 aaveRebateUsdc;
        uint256 delayedRebateUsdc;
        uint256 totalRebateUsdc;
        uint256 expectedAppliedUsdc;
        uint256 auditRemainderUsdc;
        uint256 partialRepayCount;
        uint256 fullRepayCount;
        uint256 skippedZeroDebtCount;
    }

    /// @dev JSON fields alphabetically: address, endDebtUsdc, intervalCount, rebateUsdc, startDebtUsdc.
    struct AaveReportRow {
        address borrower;
        uint256 endDebtUsdc;
        uint256 intervalCount;
        uint256 rebateUsdc;
        uint256 startDebtUsdc;
    }

    /// @dev JSON fields alphabetically:
    /// blockNumber, cappedPrincipalUsdc, cappedPrincipalWaUsdc, endDebtUsdc, endDebtWaUsdc, interestRebateUsdc,
    /// receivedUsdc, receivedWaUsdc, startDebtUsdc, startDebtWaUsdc, timestamp, txHash.
    struct DelayedReceiptLot {
        uint256 blockNumber;
        uint256 cappedPrincipalUsdc;
        uint256 cappedPrincipalWaUsdc;
        uint256 endDebtUsdc;
        uint256 endDebtWaUsdc;
        uint256 interestRebateUsdc;
        uint256 receivedUsdc;
        uint256 receivedWaUsdc;
        uint256 startDebtUsdc;
        uint256 startDebtWaUsdc;
        uint256 timestamp;
        bytes32 txHash;
    }

    /// @dev JSON fields alphabetically:
    /// address, interestRebateUsdc, postSafeDebtUsdc, receiptLotCount, receiptLots, residualCleanupUsdc,
    /// safeRepaidUsdc, safeRepaidWaUsdc, totalCappedPrincipalUsdc, totalRebateUsdc, totalReceivedUsdc.
    struct DelayedReportRow {
        address borrower;
        uint256 interestRebateUsdc;
        uint256 postSafeDebtUsdc;
        uint256 receiptLotCount;
        DelayedReceiptLot[] receiptLots;
        uint256 residualCleanupUsdc;
        uint256 safeRepaidUsdc;
        uint256 safeRepaidWaUsdc;
        uint256 totalCappedPrincipalUsdc;
        uint256 totalRebateUsdc;
        uint256 totalReceivedUsdc;
    }

    function run() external {
        this.run(false);
    }

    function run(bool send) external isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE)) {
        _run(DEFAULT_AAVE_REPORT, DEFAULT_DELAYED_REPORT, DEFAULT_AUDIT_OUTPUT, send, false);
    }

    function runWithDeal() external isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE)) {
        _run(DEFAULT_AAVE_REPORT, DEFAULT_DELAYED_REPORT, DEFAULT_AUDIT_OUTPUT, false, true);
    }

    function run(
        string memory aaveReportPath,
        string memory delayedReportPath,
        string memory auditOutputPath,
        bool send
    ) external isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE)) {
        _run(aaveReportPath, delayedReportPath, auditOutputPath, send, false);
    }

    function runWithDeal(string memory aaveReportPath, string memory delayedReportPath, string memory auditOutputPath)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
    {
        _run(aaveReportPath, delayedReportPath, auditOutputPath, false, true);
    }

    function _run(
        string memory aaveReportPath,
        string memory delayedReportPath,
        string memory auditOutputPath,
        bool send,
        bool dealSafeUsdc
    ) internal {
        if (dealSafeUsdc) {
            deployMode = DeployMode.PRODUCTION;
        }

        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        address safeAddress = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        MarketParams memory marketParams = IMorpho(MORPHO_CREDIT).idToMarketParams(MARKET_ID);
        require(Id.unwrap(marketParams.id()) == Id.unwrap(MARKET_ID), "market id mismatch");
        require(marketParams.loanToken == WAUSDC, "unexpected loan token");

        console2.log("=== Rebate Repayments via Helper Safe ===");
        console2.log("Safe address:", safeAddress);
        console2.log("Helper:", HELPER);
        console2.log("Aave report:", aaveReportPath);
        console2.log("Delayed report:", delayedReportPath);
        console2.log("Audit output:", auditOutputPath);
        console2.log("Send to Safe:", send);
        console2.log("Deal Safe USDC:", dealSafeUsdc);
        console2.log("");

        (RebateRepaymentLib.MergedRebate[] memory rebates, uint256 rebateCount, Totals memory totals) =
            _loadMergedRebates(aaveReportPath, delayedReportPath);

        console2.log("Merged borrowers:", rebateCount);
        console2.log("Aave rebate (USDC base units):", totals.aaveRebateUsdc);
        console2.log("Delayed rebate (USDC base units):", totals.delayedRebateUsdc);
        console2.log("Combined rebate (USDC base units):", totals.totalRebateUsdc);
        console2.log("");

        if (dealSafeUsdc) {
            console2.log("Simulation deal: setting Safe USDC balance to combined rebate");
            deal(USDC, safeAddress, totals.totalRebateUsdc);
        }

        _ensureFunding(safeAddress, totals.totalRebateUsdc);
        _ensureAllowance(safeAddress, totals.totalRebateUsdc);

        AuditRow[] memory auditRows = new AuditRow[](rebateCount);
        for (uint256 i = 0; i < rebateCount; i++) {
            AuditRow memory row = _buildAuditRow(rebates[i]);
            auditRows[i] = row;

            if (row.action == RebateRepaymentLib.RepaymentAction.SkippedZeroDebt) {
                totals.skippedZeroDebtCount++;
            } else {
                bytes memory repayCallData =
                    abi.encodeCall(IHelper.repay, (marketParams, row.helperAssetsArgument, row.borrower, ""));
                addToBatch(HELPER, repayCallData);

                if (row.action == RebateRepaymentLib.RepaymentAction.FullRepay) {
                    totals.fullRepayCount++;
                } else {
                    totals.partialRepayCount++;
                }
            }

            totals.expectedAppliedUsdc += row.expectedAppliedUsdc;
            totals.auditRemainderUsdc += row.auditRemainderUsdc;
        }

        _writeAudit(auditOutputPath, safeAddress, auditRows, rebateCount, totals);

        console2.log("Partial repay calls:", totals.partialRepayCount);
        console2.log("Full repay calls:", totals.fullRepayCount);
        console2.log("Skipped zero-debt borrowers:", totals.skippedZeroDebtCount);
        console2.log("Expected applied (USDC base units):", totals.expectedAppliedUsdc);
        console2.log("Audit remainder (USDC base units):", totals.auditRemainderUsdc);
        console2.log("Audit written to:", auditOutputPath);
        console2.log("");

        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    function _loadMergedRebates(string memory aaveReportPath, string memory delayedReportPath)
        internal
        view
        returns (RebateRepaymentLib.MergedRebate[] memory rebates, uint256 rebateCount, Totals memory totals)
    {
        string memory aaveJson = vm.readFile(aaveReportPath);
        string memory delayedJson = vm.readFile(delayedReportPath);

        AaveReportRow[] memory aaveRows = abi.decode(vm.parseJson(aaveJson, ".borrowers"), (AaveReportRow[]));
        DelayedReportRow[] memory delayedRows =
            abi.decode(vm.parseJson(delayedJson, ".borrowers"), (DelayedReportRow[]));
        rebates = new RebateRepaymentLib.MergedRebate[](aaveRows.length + delayedRows.length);

        for (uint256 i = 0; i < aaveRows.length; i++) {
            rebateCount =
                RebateRepaymentLib.addAaveRebate(rebates, rebateCount, aaveRows[i].borrower, aaveRows[i].rebateUsdc);
            totals.aaveRebateUsdc += aaveRows[i].rebateUsdc;
            totals.totalRebateUsdc += aaveRows[i].rebateUsdc;
        }

        for (uint256 i = 0; i < delayedRows.length; i++) {
            rebateCount = RebateRepaymentLib.addDelayedRebate(
                rebates, rebateCount, delayedRows[i].borrower, delayedRows[i].totalRebateUsdc
            );
            totals.delayedRebateUsdc += delayedRows[i].totalRebateUsdc;
            totals.totalRebateUsdc += delayedRows[i].totalRebateUsdc;
        }
    }

    function _buildAuditRow(RebateRepaymentLib.MergedRebate memory rebate) internal view returns (AuditRow memory row) {
        row.borrower = rebate.borrower;
        row.aaveRebateUsdc = rebate.aaveRebateUsdc;
        row.delayedRebateUsdc = rebate.delayedRebateUsdc;
        row.totalRebateUsdc = rebate.totalRebate();

        Position memory position = IMorpho(MORPHO_CREDIT).position(MARKET_ID, rebate.borrower);
        if (position.borrowShares > 0) {
            row.currentDebtWaUsdc =
                IMorphoCredit(MORPHO_CREDIT).expectedBorrowAssetsWithPremium(MARKET_ID, rebate.borrower);
            row.estimatedFullPayoffUsdc = IERC4626(WAUSDC).previewMint(row.currentDebtWaUsdc);
        }

        RebateRepaymentLib.RepaymentSelection memory selection =
            RebateRepaymentLib.selectRepayment(row.totalRebateUsdc, row.estimatedFullPayoffUsdc);
        row.action = selection.action;
        row.helperAssetsArgument = selection.helperAssetsArgument;
        row.expectedAppliedUsdc = selection.expectedAppliedUsdc;
        row.auditRemainderUsdc = selection.auditRemainderUsdc;
    }

    function _ensureFunding(address safeAddress, uint256 totalRebateUsdc) internal view {
        uint256 balance = IERC20(USDC).balanceOf(safeAddress);
        console2.log("Safe USDC balance:", balance);
        require(balance >= totalRebateUsdc, "safe USDC balance insufficient");
    }

    function _ensureAllowance(address safeAddress, uint256 totalRebateUsdc) internal {
        uint256 allowance = IERC20(USDC).allowance(safeAddress, HELPER);
        console2.log("Safe USDC allowance to Helper:", allowance);

        if (allowance >= totalRebateUsdc) return;

        console2.log("Adding USDC approval for Helper");
        bytes memory approveCallData = abi.encodeCall(IERC20.approve, (HELPER, type(uint256).max));
        addToBatch(USDC, approveCallData);
    }

    function _writeAudit(
        string memory outputPath,
        address safeAddress,
        AuditRow[] memory rows,
        uint256 rowCount,
        Totals memory totals
    ) internal {
        string memory json = "{\n";
        json = string.concat(json, '  "metadata": {\n');
        json = string.concat(json, '    "safe": "', vm.toString(safeAddress), '",\n');
        json = string.concat(json, '    "helper": "', vm.toString(HELPER), '",\n');
        json = string.concat(json, '    "morphoCredit": "', vm.toString(MORPHO_CREDIT), '",\n');
        json = string.concat(json, '    "marketId": "', vm.toString(Id.unwrap(MARKET_ID)), '",\n');
        json = string.concat(json, '    "usdc": "', vm.toString(USDC), '",\n');
        json = string.concat(json, '    "wausdc": "', vm.toString(WAUSDC), '",\n');
        json = string.concat(json, '    "repaymentPolicy": "merge exact report base units per borrower",\n');
        json = string.concat(
            json,
            '    "fullRepaymentPolicy": "use Helper.repay with type(uint256).max when rebate covers estimated full payoff",\n'
        );
        json = string.concat(
            json, '    "debtEstimateMethod": "expectedBorrowAssetsWithPremium plus waUSDC previewMint",\n'
        );
        json = string.concat(json, '    "fundingPolicy": "Safe must be pre-funded for total merged rebate"\n');
        json = string.concat(json, "  },\n");

        json = string.concat(json, '  "totals": {\n');
        json = string.concat(json, '    "borrowers": ', vm.toString(rowCount), ",\n");
        json = string.concat(json, '    "aaveRebateUsdc": ', vm.toString(totals.aaveRebateUsdc), ",\n");
        json = string.concat(json, '    "delayedRebateUsdc": ', vm.toString(totals.delayedRebateUsdc), ",\n");
        json = string.concat(json, '    "totalRebateUsdc": ', vm.toString(totals.totalRebateUsdc), ",\n");
        json = string.concat(json, '    "expectedAppliedUsdc": ', vm.toString(totals.expectedAppliedUsdc), ",\n");
        json = string.concat(json, '    "auditRemainderUsdc": ', vm.toString(totals.auditRemainderUsdc), ",\n");
        json = string.concat(json, '    "partialRepayCount": ', vm.toString(totals.partialRepayCount), ",\n");
        json = string.concat(json, '    "fullRepayCount": ', vm.toString(totals.fullRepayCount), ",\n");
        json = string.concat(json, '    "skippedZeroDebtCount": ', vm.toString(totals.skippedZeroDebtCount), "\n");
        json = string.concat(json, "  },\n");
        json = string.concat(json, '  "borrowers": [\n');

        for (uint256 i = 0; i < rowCount; i++) {
            json = _appendAuditRow(json, rows[i]);
            if (i + 1 < rowCount) json = string.concat(json, ",");
            json = string.concat(json, "\n");
        }

        json = string.concat(json, "  ]\n");
        json = string.concat(json, "}\n");

        vm.writeFile(outputPath, json);
    }

    function _appendAuditRow(string memory json, AuditRow memory row) internal pure returns (string memory) {
        json = string.concat(json, "    {\n");
        json = string.concat(json, '      "address": "', vm.toString(row.borrower), '",\n');
        json = string.concat(json, '      "aaveRebateUsdc": ', vm.toString(row.aaveRebateUsdc), ",\n");
        json = string.concat(json, '      "delayedRebateUsdc": ', vm.toString(row.delayedRebateUsdc), ",\n");
        json = string.concat(json, '      "totalRebateUsdc": ', vm.toString(row.totalRebateUsdc), ",\n");
        json = string.concat(json, '      "currentDebtWaUsdc": ', vm.toString(row.currentDebtWaUsdc), ",\n");
        json = string.concat(json, '      "estimatedFullPayoffUsdc": ', vm.toString(row.estimatedFullPayoffUsdc), ",\n");
        json = string.concat(json, '      "action": "', _actionName(row.action), '",\n');
        json = string.concat(json, '      "helperAssetsArgument": ', vm.toString(row.helperAssetsArgument), ",\n");
        json = string.concat(json, '      "expectedAppliedUsdc": ', vm.toString(row.expectedAppliedUsdc), ",\n");
        json = string.concat(json, '      "auditRemainderUsdc": ', vm.toString(row.auditRemainderUsdc), "\n");
        json = string.concat(json, "    }");
        return json;
    }

    function _actionName(RebateRepaymentLib.RepaymentAction action) internal pure returns (string memory) {
        if (action == RebateRepaymentLib.RepaymentAction.FullRepay) return "full_repay";
        if (action == RebateRepaymentLib.RepaymentAction.PartialRepay) return "partial_repay";
        return "skipped_zero_debt";
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
