// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {IMorpho, IMorphoCredit, Id, Position} from "../../src/interfaces/IMorpho.sol";
import {AaveRebateEventsLib} from "../../src/libraries/AaveRebateEventsLib.sol";
import {DelayedRepaymentRebateLib} from "../../src/libraries/DelayedRepaymentRebateLib.sol";
import {MorphoCreditBalancesLib} from "../../src/libraries/periphery/MorphoCreditBalancesLib.sol";

/// @title ComputeDelayedRepaymentRebateReport
/// @notice Computes report-only USDC rebates for repayments delayed through the incident repayment EOA.
contract ComputeDelayedRepaymentRebateReport is Script {
    using DelayedRepaymentRebateLib for uint256;
    using MorphoCreditBalancesLib for IMorphoCredit;

    address private constant MORPHO_CREDIT = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant WAUSDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;
    address private constant REPAYMENT_EOA = 0x1226858E04b9d077258F153275613734421cD06B;
    address private constant SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    Id private constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    uint256 private constant MAINNET_CHAIN_ID = 1;
    uint256 private constant DEFAULT_START_TIMESTAMP = 1_776_533_700; // 2026-04-18 17:35:00 UTC
    uint256 private constant SAFE_REPAY_BLOCK = 24_965_941;
    uint256 private constant SAFE_REPAY_TIMESTAMP = 1_777_227_491; // 2026-04-26 18:18:11 UTC
    uint256 private constant SAFE_NONCE = 241;
    uint256 private constant DEFAULT_RESIDUAL_THRESHOLD_USDC = 25e6;

    bytes32 private constant SAFE_REPAY_TX = 0xb1b251da7683d50bf1c8febf842d9248f31f72106e2de0a8edc3582bf16e84da;

    string private constant DEFAULT_OUTPUT = "data/delayed-repayment-rebate-report-2026-04-18-safe-241.json";

    struct SafeRepayment {
        address borrower;
        uint256 repaidWaUsdc;
        uint256 repaidUsdc;
    }

    struct ReceiptLot {
        bytes32 txHash;
        uint256 blockNumber;
        uint256 timestamp;
        uint256 receivedUsdc;
        uint256 receivedWaUsdc;
        uint256 cappedPrincipalUsdc;
        uint256 cappedPrincipalWaUsdc;
        uint256 startDebtUsdc;
        uint256 startDebtWaUsdc;
        uint256 endDebtUsdc;
        uint256 endDebtWaUsdc;
        uint256 interestRebateUsdc;
    }

    struct ReportRow {
        address borrower;
        uint256 receiptLotCount;
        uint256 safeRepaidUsdc;
        uint256 safeRepaidWaUsdc;
        uint256 totalReceivedUsdc;
        uint256 totalCappedPrincipalUsdc;
        uint256 interestRebateUsdc;
        uint256 postSafeDebtUsdc;
        uint256 residualCleanupUsdc;
        uint256 totalRebateUsdc;
        string lotsJson;
    }

    struct RunContext {
        uint256 latestBlock;
        uint256 startTimestamp;
        uint256 startBlock;
        uint256 residualThresholdUsdc;
        bool verbose;
    }

    function run() external {
        _run(
            DEFAULT_START_TIMESTAMP,
            vm.envOr("DELAYED_REPAYMENT_RESIDUAL_THRESHOLD_USDC", DEFAULT_RESIDUAL_THRESHOLD_USDC),
            DEFAULT_OUTPUT,
            false
        );
    }

    function run(string memory outputPath, bool verbose) external {
        _run(
            DEFAULT_START_TIMESTAMP,
            vm.envOr("DELAYED_REPAYMENT_RESIDUAL_THRESHOLD_USDC", DEFAULT_RESIDUAL_THRESHOLD_USDC),
            outputPath,
            verbose
        );
    }

    function run(uint256 residualThresholdUsdc, string memory outputPath, bool verbose) external {
        _run(DEFAULT_START_TIMESTAMP, residualThresholdUsdc, outputPath, verbose);
    }

    function run(uint256 startTimestamp, uint256 residualThresholdUsdc, string memory outputPath, bool verbose)
        external
    {
        _run(startTimestamp, residualThresholdUsdc, outputPath, verbose);
    }

    function _run(uint256 startTimestamp, uint256 residualThresholdUsdc, string memory outputPath, bool verbose)
        internal
    {
        RunContext memory ctx;
        ctx.latestBlock = block.number;
        ctx.startTimestamp = startTimestamp;
        ctx.residualThresholdUsdc = residualThresholdUsdc;
        ctx.verbose = verbose;

        require(block.chainid == MAINNET_CHAIN_ID, "run on mainnet fork");
        require(ctx.latestBlock >= SAFE_REPAY_BLOCK, "fork before safe repay");

        console2.log("=== Delayed Repayment Rebate Report ===");
        console2.log("Start timestamp:", startTimestamp);
        console2.log("Safe repay block:", SAFE_REPAY_BLOCK);
        console2.log("Safe repay timestamp:", SAFE_REPAY_TIMESTAMP);
        console2.log("Residual threshold (USDC base units):", residualThresholdUsdc);
        console2.log("");

        ctx.startBlock = _findBlockForTimestamp(startTimestamp, ctx.latestBlock);
        require(ctx.startBlock < SAFE_REPAY_BLOCK, "start after safe repay");

        console2.log("Start block:", ctx.startBlock);
        console2.log("");

        SafeRepayment[] memory repayments = _collectSafeRepayments();
        (ReportRow[] memory rows, uint256 rowCount, string memory auditJson, uint256 auditCount, Totals memory totals) =
            _computeRows(ctx, repayments);

        _writeReport(outputPath, ctx, repayments.length, rows, rowCount, auditJson, auditCount, totals);

        console2.log("Safe-repaid borrowers:", repayments.length);
        console2.log("Eligible borrowers:", rowCount);
        console2.log("Receipt lots:", totals.receiptLots);
        console2.log("Interest rebate (USDC base units):", totals.interestRebateUsdc);
        console2.log("Residual cleanup (USDC base units):", totals.residualCleanupUsdc);
        console2.log("Total rebate (USDC base units):", totals.totalRebateUsdc);
        console2.log("Output written to:", outputPath);
    }

    struct Totals {
        uint256 receiptLots;
        uint256 totalReceivedUsdc;
        uint256 totalCappedPrincipalUsdc;
        uint256 interestRebateUsdc;
        uint256 residualCleanupUsdc;
        uint256 totalRebateUsdc;
    }

    function _computeRows(RunContext memory ctx, SafeRepayment[] memory repayments)
        internal
        returns (
            ReportRow[] memory rows,
            uint256 rowCount,
            string memory auditJson,
            uint256 auditCount,
            Totals memory totals
        )
    {
        rows = new ReportRow[](repayments.length);
        auditJson = "[";

        for (uint256 i = 0; i < repayments.length; i++) {
            ReceiptLot[] memory lots = _collectReceiptLots(ctx.startBlock, repayments[i].borrower);
            if (lots.length == 0) {
                auditJson = _appendAuditJson(auditJson, auditCount, repayments[i]);
                auditCount++;
                continue;
            }

            ReportRow memory row = _computeBorrowerRow(ctx, repayments[i], lots);
            rows[rowCount] = row;
            rowCount++;

            totals.receiptLots += row.receiptLotCount;
            totals.totalReceivedUsdc += row.totalReceivedUsdc;
            totals.totalCappedPrincipalUsdc += row.totalCappedPrincipalUsdc;
            totals.interestRebateUsdc += row.interestRebateUsdc;
            totals.residualCleanupUsdc += row.residualCleanupUsdc;
            totals.totalRebateUsdc += row.totalRebateUsdc;

            if (ctx.verbose) {
                console2.log("Borrower:", row.borrower);
                console2.log("  receipt lots:", row.receiptLotCount);
                console2.log("  received:", row.totalReceivedUsdc);
                console2.log("  interest rebate:", row.interestRebateUsdc);
                console2.log("  residual cleanup:", row.residualCleanupUsdc);
                console2.log("  total rebate:", row.totalRebateUsdc);
            }
        }

        auditJson = string.concat(auditJson, "]");
    }

    function _computeBorrowerRow(RunContext memory ctx, SafeRepayment memory repayment, ReceiptLot[] memory lots)
        internal
        returns (ReportRow memory row)
    {
        row.borrower = repayment.borrower;
        row.receiptLotCount = lots.length;
        row.safeRepaidUsdc = repayment.repaidUsdc;
        row.safeRepaidWaUsdc = repayment.repaidWaUsdc;
        row.lotsJson = "[";
        row.postSafeDebtUsdc = _postSafeDebtUsdc(repayment.borrower);

        for (uint256 i = 0; i < lots.length; i++) {
            ReceiptLot memory lot = _computeReceiptLot(lots[i], repayment.borrower);
            if (row.postSafeDebtUsdc == 0) lot.interestRebateUsdc = 0;

            row.totalReceivedUsdc += lot.receivedUsdc;
            row.totalCappedPrincipalUsdc += lot.cappedPrincipalUsdc;
            row.interestRebateUsdc += lot.interestRebateUsdc;
            row.lotsJson = _appendLotJson(row.lotsJson, i, lot);
        }

        row.lotsJson = string.concat(row.lotsJson, "]");
        row.residualCleanupUsdc =
            DelayedRepaymentRebateLib.residualCleanup(row.postSafeDebtUsdc, ctx.residualThresholdUsdc);
        row.totalRebateUsdc = row.interestRebateUsdc + row.residualCleanupUsdc;
    }

    function _computeReceiptLot(ReceiptLot memory lot, address borrower) internal returns (ReceiptLot memory) {
        uint256 receiptTimestamp = _rollForkAndWarp(lot.blockNumber);
        (lot.startDebtWaUsdc, lot.startDebtUsdc) = _borrowerDebtAtCurrentBlock(borrower);
        lot.timestamp = receiptTimestamp;
        lot.receivedWaUsdc = IERC4626(WAUSDC).previewDeposit(lot.receivedUsdc);
        lot.cappedPrincipalWaUsdc = DelayedRepaymentRebateLib.cappedPrincipal(lot.receivedWaUsdc, lot.startDebtWaUsdc);
        lot.cappedPrincipalUsdc = IERC4626(WAUSDC).convertToAssets(lot.cappedPrincipalWaUsdc);

        _rollForkAndWarpToTimestamp(SAFE_REPAY_BLOCK - 1, SAFE_REPAY_TIMESTAMP);
        (lot.endDebtWaUsdc, lot.endDebtUsdc) = _borrowerDebtAtCurrentBlock(borrower);
        uint256 interestRebateWaUsdc = DelayedRepaymentRebateLib.delayedInterest(
            lot.cappedPrincipalWaUsdc, lot.startDebtWaUsdc, lot.endDebtWaUsdc
        );
        lot.interestRebateUsdc = IERC4626(WAUSDC).convertToAssets(interestRebateWaUsdc);

        return lot;
    }

    function _collectSafeRepayments() internal returns (SafeRepayment[] memory repayments) {
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = AaveRebateEventsLib.REPAY_EVENT_SIG;
        topics[1] = bytes32(Id.unwrap(MARKET_ID));

        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(SAFE_REPAY_BLOCK, SAFE_REPAY_BLOCK, MORPHO_CREDIT, topics);
        SafeRepayment[] memory temp = new SafeRepayment[](logs.length);
        uint256 count = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].transactionHash != SAFE_REPAY_TX) continue;
            if (logs[i].topics.length <= AaveRebateEventsLib.borrowerTopicIndex(AaveRebateEventsLib.REPAY_EVENT_SIG)) {
                continue;
            }

            address borrower = DelayedRepaymentRebateLib.topicAddress(logs[i].topics[3]);
            (uint256 assets,) = abi.decode(logs[i].data, (uint256, uint256));
            uint256 index = _indexOf(temp, count, borrower);
            if (index == type(uint256).max) {
                temp[count] = SafeRepayment({borrower: borrower, repaidWaUsdc: assets, repaidUsdc: 0});
                count++;
            } else {
                temp[index].repaidWaUsdc += assets;
            }
        }

        _rollForkAndWarp(SAFE_REPAY_BLOCK);

        repayments = new SafeRepayment[](count);
        for (uint256 i = 0; i < count; i++) {
            temp[i].repaidUsdc = IERC4626(WAUSDC).convertToAssets(temp[i].repaidWaUsdc);
            repayments[i] = temp[i];
        }
    }

    function _collectReceiptLots(uint256 startBlock, address borrower) internal returns (ReceiptLot[] memory lots) {
        bytes32[] memory topics = new bytes32[](3);
        topics[0] = DelayedRepaymentRebateLib.TRANSFER_EVENT_SIG;
        topics[1] = DelayedRepaymentRebateLib.addressTopic(borrower);
        topics[2] = DelayedRepaymentRebateLib.addressTopic(REPAYMENT_EOA);

        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(startBlock, SAFE_REPAY_BLOCK - 1, USDC, topics);
        lots = new ReceiptLot[](logs.length);

        for (uint256 i = 0; i < logs.length; i++) {
            uint256 receivedUsdc = abi.decode(logs[i].data, (uint256));
            lots[i] = ReceiptLot({
                txHash: logs[i].transactionHash,
                blockNumber: logs[i].blockNumber,
                timestamp: 0,
                receivedUsdc: receivedUsdc,
                receivedWaUsdc: 0,
                cappedPrincipalUsdc: 0,
                cappedPrincipalWaUsdc: 0,
                startDebtUsdc: 0,
                startDebtWaUsdc: 0,
                endDebtUsdc: 0,
                endDebtWaUsdc: 0,
                interestRebateUsdc: 0
            });
        }
    }

    function _postSafeDebtUsdc(address borrower) internal returns (uint256) {
        _rollForkAndWarp(SAFE_REPAY_BLOCK);
        (, uint256 debtUsdc) = _borrowerDebtAtCurrentBlock(borrower);
        return debtUsdc;
    }

    function _borrowerDebtAtCurrentBlock(address borrower)
        internal
        view
        returns (uint256 debtWaUsdc, uint256 debtUsdc)
    {
        Position memory position = IMorpho(MORPHO_CREDIT).position(MARKET_ID, borrower);
        if (position.borrowShares == 0) return (0, 0);

        debtWaUsdc = IMorphoCredit(MORPHO_CREDIT).expectedBorrowAssetsWithPremium(MARKET_ID, borrower);
        debtUsdc = IERC4626(WAUSDC).convertToAssets(debtWaUsdc);
    }

    function _findBlockForTimestamp(uint256 targetTimestamp, uint256 highBlock) internal returns (uint256 targetBlock) {
        require(_rollForkAndWarp(highBlock) >= targetTimestamp, "fork before target");

        uint256 low = 1;
        uint256 high = highBlock;
        targetBlock = highBlock;

        while (low <= high) {
            uint256 mid = (low + high) / 2;

            if (_rollForkAndWarp(mid) >= targetTimestamp) {
                targetBlock = mid;
                if (mid == 0) break;
                high = mid - 1;
            } else {
                low = mid + 1;
            }
        }

        _rollForkAndWarp(targetBlock);
    }

    function _rollForkAndWarp(uint256 blockNumber) internal returns (uint256 timestamp) {
        vm.rollFork(blockNumber);
        timestamp = vm.getBlockTimestamp();
        vm.warp(timestamp);
    }

    function _rollForkAndWarpToTimestamp(uint256 blockNumber, uint256 timestamp) internal {
        vm.rollFork(blockNumber);
        vm.warp(timestamp);
    }

    function _writeReport(
        string memory outputPath,
        RunContext memory ctx,
        uint256 safeRepaidBorrowers,
        ReportRow[] memory rows,
        uint256 rowCount,
        string memory auditJson,
        uint256 auditCount,
        Totals memory totals
    ) internal {
        string memory json = "{\n";
        json = string.concat(json, '  "metadata": {\n');
        json = string.concat(json, '    "marketId": "', vm.toString(Id.unwrap(MARKET_ID)), '",\n');
        json = string.concat(json, '    "morphoCredit": "', vm.toString(MORPHO_CREDIT), '",\n');
        json = string.concat(json, '    "usdc": "', vm.toString(USDC), '",\n');
        json = string.concat(json, '    "wausdc": "', vm.toString(WAUSDC), '",\n');
        json = string.concat(json, '    "repaymentEoa": "', vm.toString(REPAYMENT_EOA), '",\n');
        json = string.concat(json, '    "safe": "', vm.toString(SAFE), '",\n');
        json = string.concat(json, '    "safeTxHash": "', vm.toString(SAFE_REPAY_TX), '",\n');
        json = string.concat(json, '    "safeNonce": ', vm.toString(SAFE_NONCE), ",\n");
        json = string.concat(json, '    "startTimestamp": ', vm.toString(ctx.startTimestamp), ",\n");
        json = string.concat(json, '    "startBlock": ', vm.toString(ctx.startBlock), ",\n");
        json = string.concat(json, '    "safeRepayTimestamp": ', vm.toString(SAFE_REPAY_TIMESTAMP), ",\n");
        json = string.concat(json, '    "safeRepayBlock": ', vm.toString(SAFE_REPAY_BLOCK), ",\n");
        json = string.concat(json, '    "interestBasis": "full_expected_borrower_debt_growth_with_pending_premium",\n');
        json = string.concat(json, '    "penaltyTreatment": "excluded",\n');
        json = string.concat(json, '    "principalPolicy": "received_usdc_capped_at_debt_at_receipt",\n');
        json = string.concat(
            json, '    "residualCleanupPolicy": "matched borrowers with post-safe expected debt below threshold",\n'
        );
        json =
            string.concat(json, '    "postSafeDebtPolicy": "no delayed repayment rebate if post-safe debt is zero",\n');
        json = string.concat(json, '    "residualThresholdUsdc": ', vm.toString(ctx.residualThresholdUsdc), "\n");
        json = string.concat(json, "  },\n");

        json = string.concat(json, '  "totals": {\n');
        json = string.concat(json, '    "safeRepaidBorrowers": ', vm.toString(safeRepaidBorrowers), ",\n");
        json = string.concat(json, '    "eligibleBorrowers": ', vm.toString(rowCount), ",\n");
        json = string.concat(json, '    "unmatchedSafeRepaidBorrowers": ', vm.toString(auditCount), ",\n");
        json = string.concat(json, '    "receiptLots": ', vm.toString(totals.receiptLots), ",\n");
        json = string.concat(json, '    "totalReceivedUsdc": ', vm.toString(totals.totalReceivedUsdc), ",\n");
        json = string.concat(
            json, '    "totalCappedPrincipalUsdc": ', vm.toString(totals.totalCappedPrincipalUsdc), ",\n"
        );
        json = string.concat(json, '    "interestRebateUsdc": ', vm.toString(totals.interestRebateUsdc), ",\n");
        json = string.concat(json, '    "residualCleanupUsdc": ', vm.toString(totals.residualCleanupUsdc), ",\n");
        json = string.concat(json, '    "totalRebateUsdc": ', vm.toString(totals.totalRebateUsdc), "\n");
        json = string.concat(json, "  },\n");

        json = string.concat(json, '  "borrowers": [\n');
        for (uint256 i = 0; i < rowCount; i++) {
            json = _appendRowJson(json, rows[i]);
            if (i + 1 < rowCount) json = string.concat(json, ",");
            json = string.concat(json, "\n");
        }
        json = string.concat(json, "  ],\n");
        json = string.concat(json, '  "audit": {\n');
        json = string.concat(json, '    "safeRepaidWithoutMatchedReceipt": ', auditJson, "\n");
        json = string.concat(json, "  }\n");
        json = string.concat(json, "}\n");

        vm.writeFile(outputPath, json);
    }

    function _appendRowJson(string memory json, ReportRow memory row) internal pure returns (string memory) {
        json = string.concat(json, "    {\n");
        json = string.concat(json, '      "address": "', vm.toString(row.borrower), '",\n');
        json = string.concat(json, '      "receiptLotCount": ', vm.toString(row.receiptLotCount), ",\n");
        json = string.concat(json, '      "safeRepaidUsdc": ', vm.toString(row.safeRepaidUsdc), ",\n");
        json = string.concat(json, '      "safeRepaidWaUsdc": ', vm.toString(row.safeRepaidWaUsdc), ",\n");
        json = string.concat(json, '      "totalReceivedUsdc": ', vm.toString(row.totalReceivedUsdc), ",\n");
        json =
            string.concat(json, '      "totalCappedPrincipalUsdc": ', vm.toString(row.totalCappedPrincipalUsdc), ",\n");
        json = string.concat(json, '      "interestRebateUsdc": ', vm.toString(row.interestRebateUsdc), ",\n");
        json = string.concat(json, '      "postSafeDebtUsdc": ', vm.toString(row.postSafeDebtUsdc), ",\n");
        json = string.concat(json, '      "residualCleanupUsdc": ', vm.toString(row.residualCleanupUsdc), ",\n");
        json = string.concat(json, '      "totalRebateUsdc": ', vm.toString(row.totalRebateUsdc), ",\n");
        json = string.concat(json, '      "receiptLots": ', row.lotsJson, "\n");
        json = string.concat(json, "    }");
        return json;
    }

    function _appendLotJson(string memory json, uint256 index, ReceiptLot memory lot)
        internal
        pure
        returns (string memory)
    {
        if (index > 0) json = string.concat(json, ",");
        json = string.concat(json, "\n        {");
        json = string.concat(json, '\n          "txHash": "', vm.toString(lot.txHash), '",');
        json = string.concat(json, '\n          "blockNumber": ', vm.toString(lot.blockNumber), ",");
        json = string.concat(json, '\n          "timestamp": ', vm.toString(lot.timestamp), ",");
        json = string.concat(json, '\n          "receivedUsdc": ', vm.toString(lot.receivedUsdc), ",");
        json = string.concat(json, '\n          "receivedWaUsdc": ', vm.toString(lot.receivedWaUsdc), ",");
        json = string.concat(json, '\n          "cappedPrincipalUsdc": ', vm.toString(lot.cappedPrincipalUsdc), ",");
        json = string.concat(json, '\n          "cappedPrincipalWaUsdc": ', vm.toString(lot.cappedPrincipalWaUsdc), ",");
        json = string.concat(json, '\n          "startDebtUsdc": ', vm.toString(lot.startDebtUsdc), ",");
        json = string.concat(json, '\n          "startDebtWaUsdc": ', vm.toString(lot.startDebtWaUsdc), ",");
        json = string.concat(json, '\n          "endDebtUsdc": ', vm.toString(lot.endDebtUsdc), ",");
        json = string.concat(json, '\n          "endDebtWaUsdc": ', vm.toString(lot.endDebtWaUsdc), ",");
        json = string.concat(json, '\n          "interestRebateUsdc": ', vm.toString(lot.interestRebateUsdc));
        json = string.concat(json, "\n        }");
        return json;
    }

    function _appendAuditJson(string memory json, uint256 index, SafeRepayment memory repayment)
        internal
        pure
        returns (string memory)
    {
        if (index > 0) json = string.concat(json, ",");
        json = string.concat(json, "\n      {");
        json = string.concat(json, '\n        "address": "', vm.toString(repayment.borrower), '",');
        json = string.concat(json, '\n        "safeRepaidUsdc": ', vm.toString(repayment.repaidUsdc), ",");
        json = string.concat(json, '\n        "safeRepaidWaUsdc": ', vm.toString(repayment.repaidWaUsdc));
        json = string.concat(json, "\n      }");
        return json;
    }

    function _indexOf(SafeRepayment[] memory items, uint256 length, address borrower) internal pure returns (uint256) {
        for (uint256 i = 0; i < length; i++) {
            if (items[i].borrower == borrower) return i;
        }
        return type(uint256).max;
    }
}
