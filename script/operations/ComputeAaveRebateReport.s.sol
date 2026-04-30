// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {IMorpho, Id, Market, Position} from "../../src/interfaces/IMorpho.sol";
import {IAaveMarket} from "../../src/irm/adaptive-curve-irm/interfaces/IAaveMarket.sol";
import {AaveRebateEventsLib} from "../../src/libraries/AaveRebateEventsLib.sol";
import {AaveRebateMathLib} from "../../src/libraries/AaveRebateMathLib.sol";
import {SharesMathLib} from "../../src/libraries/SharesMathLib.sol";

/// @title ComputeAaveRebateReport
/// @notice Computes report-only USDC rebates for Aave borrow-index growth above 5% APR.
contract ComputeAaveRebateReport is Script {
    using SharesMathLib for uint256;

    address private constant MORPHO_CREDIT = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;
    address private constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant WAUSDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;

    Id private constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    uint256 private constant MAINNET_CHAIN_ID = 1;
    uint256 private constant FROM_BLOCK = 23241534;
    uint256 private constant DEFAULT_START_TIMESTAMP = 1_776_533_700; // 2026-04-18 17:35:00 UTC
    uint256 private constant DEFAULT_END_TIMESTAMP = 1_777_420_800; // 2026-04-29 00:00:00 UTC
    uint256 private constant AAVE_FREEZE_TIMESTAMP = 1_776_538_320; // 2026-04-18 18:52:00 UTC
    uint256 private constant BASELINE_APR_BPS = 500;

    string private constant DEFAULT_OUTPUT = "data/aave-rebate-report-2026-04-18-2026-04-29.json";

    struct Boundary {
        address borrower;
        uint256 blockNumber;
    }

    struct ReportRow {
        address borrower;
        uint256 intervalCount;
        uint256 startDebtUsdc;
        uint256 endDebtUsdc;
        uint256 rebateUsdc;
        string intervalsJson;
    }

    struct RunContext {
        uint256 latestBlock;
        uint256 startTimestamp;
        uint256 endTimestamp;
        uint256 startBlock;
        uint256 endBlock;
        bool verbose;
    }

    function run() external {
        _run(DEFAULT_START_TIMESTAMP, DEFAULT_END_TIMESTAMP, DEFAULT_OUTPUT, false);
    }

    function run(string memory outputPath, bool verbose) external {
        _run(DEFAULT_START_TIMESTAMP, DEFAULT_END_TIMESTAMP, outputPath, verbose);
    }

    function run(uint256 startTimestamp, uint256 endTimestamp, string memory outputPath, bool verbose) external {
        _run(startTimestamp, endTimestamp, outputPath, verbose);
    }

    function _run(uint256 startTimestamp, uint256 endTimestamp, string memory outputPath, bool verbose) internal {
        require(startTimestamp < endTimestamp, "invalid window");

        RunContext memory ctx;
        ctx.latestBlock = block.number;
        ctx.startTimestamp = startTimestamp;
        ctx.endTimestamp = endTimestamp;
        ctx.verbose = verbose;

        require(block.chainid == MAINNET_CHAIN_ID, "run on mainnet fork");
        require(ctx.latestBlock >= FROM_BLOCK, "fork before borrower scan block");

        console2.log("=== Aave Over-5% Rebate Report ===");
        console2.log("Start timestamp:", startTimestamp);
        console2.log("End timestamp:", endTimestamp);
        console2.log("Baseline APR bps:", BASELINE_APR_BPS);
        console2.log("Incident reference: Aave rsETH freezes started at 2026-04-18 18:52 UTC");
        console2.log("");

        ctx.startBlock = _findBlockForTimestamp(startTimestamp, ctx.latestBlock);
        ctx.endBlock = _findBlockForTimestamp(endTimestamp, ctx.latestBlock);
        require(ctx.endBlock >= FROM_BLOCK, "report end before borrower scan block");

        console2.log("Start block:", ctx.startBlock);
        console2.log("End block:", ctx.endBlock);
        console2.log("");

        address[] memory borrowers = _collectBorrowers(ctx.endBlock);
        Boundary[] memory boundaries = _collectBoundaries(ctx.startBlock, ctx.endBlock);

        console2.log("Borrowers discovered:", borrowers.length);
        console2.log("Debt-change boundaries:", boundaries.length);
        console2.log("");

        (ReportRow[] memory rows, uint256 rowCount, uint256 totalRebate) = _computeRows(ctx, borrowers, boundaries);

        _writeReport(outputPath, ctx, rows, rowCount, borrowers.length, boundaries.length, totalRebate);

        console2.log("Eligible borrowers:", rowCount);
        console2.log("Total rebate (USDC base units):", totalRebate);
        console2.log("Output written to:", outputPath);
    }

    function _computeRows(RunContext memory ctx, address[] memory borrowers, Boundary[] memory boundaries)
        internal
        returns (ReportRow[] memory rows, uint256 rowCount, uint256 totalRebate)
    {
        rows = new ReportRow[](borrowers.length);

        for (uint256 i = 0; i < borrowers.length; i++) {
            (ReportRow memory row, bool hadDebt) = _computeBorrower(ctx, borrowers[i], boundaries);
            if (!hadDebt && row.startDebtUsdc == 0 && row.endDebtUsdc == 0 && row.rebateUsdc == 0) continue;

            rows[rowCount] = row;
            totalRebate += row.rebateUsdc;
            rowCount++;

            if (ctx.verbose) {
                console2.log("Borrower:", row.borrower);
                console2.log("  intervals:", row.intervalCount);
                console2.log("  start debt:", row.startDebtUsdc);
                console2.log("  end debt:", row.endDebtUsdc);
                console2.log("  rebate:", row.rebateUsdc);
            }
        }
    }

    function _computeBorrower(RunContext memory ctx, address borrower, Boundary[] memory boundaries)
        internal
        returns (ReportRow memory row, bool hadDebt)
    {
        row.borrower = borrower;
        row.startDebtUsdc = _borrowerDebtUsdcAt(ctx.startBlock, borrower);
        row.endDebtUsdc = _borrowerDebtUsdcAt(ctx.endBlock, borrower);
        row.intervalsJson = "[";

        uint256 fromBlock = ctx.startBlock;
        while (fromBlock < ctx.endBlock) {
            uint256 nextBlock = _nextBoundaryBlock(boundaries, borrower, fromBlock, ctx.endBlock);
            (uint256 rebate, uint256 startDebtUsdc, uint256 endDebtUsdc, uint256 exposureUsdc, bool counted) =
                _intervalRebate(borrower, fromBlock, nextBlock);

            if (startDebtUsdc > 0 || endDebtUsdc > 0) hadDebt = true;
            if (counted) {
                if (ctx.verbose) {
                    row.intervalsJson = _appendIntervalJson(
                        row.intervalsJson,
                        row.intervalCount,
                        fromBlock,
                        nextBlock,
                        startDebtUsdc,
                        endDebtUsdc,
                        exposureUsdc,
                        rebate
                    );
                }
                row.intervalCount++;
            }
            row.rebateUsdc += rebate;

            fromBlock = nextBlock;
        }

        row.intervalsJson = string.concat(row.intervalsJson, "]");
    }

    function _appendIntervalJson(
        string memory json,
        uint256 index,
        uint256 fromBlock,
        uint256 toBlock,
        uint256 startDebtUsdc,
        uint256 endDebtUsdc,
        uint256 exposureUsdc,
        uint256 rebateUsdc
    ) internal pure returns (string memory) {
        if (index > 0) json = string.concat(json, ",");

        json = string.concat(json, "\n        {");
        json = string.concat(json, '\n          "fromBlock": ', vm.toString(fromBlock), ",");
        json = string.concat(json, '\n          "toBlock": ', vm.toString(toBlock), ",");
        json = string.concat(json, '\n          "startDebtUsdc": ', vm.toString(startDebtUsdc), ",");
        json = string.concat(json, '\n          "endDebtUsdc": ', vm.toString(endDebtUsdc), ",");
        json = string.concat(json, '\n          "exposureUsdc": ', vm.toString(exposureUsdc), ",");
        json = string.concat(json, '\n          "rebateUsdc": ', vm.toString(rebateUsdc));
        json = string.concat(json, "\n        }");

        return json;
    }

    function _intervalRebate(address borrower, uint256 fromBlock, uint256 toBlock)
        internal
        returns (uint256 rebate, uint256 startDebtUsdc, uint256 endDebtUsdc, uint256 exposureUsdc, bool counted)
    {
        if (toBlock <= fromBlock) return (0, 0, 0, 0, false);

        vm.rollFork(fromBlock);
        uint256 fromTimestamp = vm.getBlockTimestamp();
        startDebtUsdc = _borrowerDebtUsdc(borrower);
        uint256 startIndex = IAaveMarket(AAVE_POOL).getReserveNormalizedVariableDebt(USDC);

        vm.rollFork(toBlock);
        uint256 toTimestamp = vm.getBlockTimestamp();
        endDebtUsdc = _borrowerDebtUsdc(borrower);
        uint256 endIndex = IAaveMarket(AAVE_POOL).getReserveNormalizedVariableDebt(USDC);

        if (toTimestamp <= fromTimestamp) return (0, startDebtUsdc, endDebtUsdc, 0, false);

        exposureUsdc = _average(startDebtUsdc, endDebtUsdc);
        counted = exposureUsdc > 0;
        rebate = AaveRebateMathLib.intervalRebateWithAverageDebt(
            startDebtUsdc, endDebtUsdc, startIndex, endIndex, toTimestamp - fromTimestamp, BASELINE_APR_BPS
        );
    }

    function _borrowerDebtUsdcAt(uint256 blockNumber, address borrower) internal returns (uint256) {
        vm.rollFork(blockNumber);
        return _borrowerDebtUsdc(borrower);
    }

    function _borrowerDebtUsdc(address borrower) internal view returns (uint256) {
        IMorpho morpho = IMorpho(MORPHO_CREDIT);
        Position memory position = morpho.position(MARKET_ID, borrower);
        if (position.borrowShares == 0) return 0;

        Market memory market = morpho.market(MARKET_ID);
        uint256 debtWaUsdc =
            uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);

        return IERC4626(WAUSDC).convertToAssets(debtWaUsdc);
    }

    function _nextBoundaryBlock(Boundary[] memory boundaries, address borrower, uint256 fromBlock, uint256 endBlock)
        internal
        pure
        returns (uint256 nextBlock)
    {
        nextBlock = endBlock;
        for (uint256 i = 0; i < boundaries.length; i++) {
            if (boundaries[i].borrower != borrower) continue;
            if (boundaries[i].blockNumber <= fromBlock) continue;
            if (boundaries[i].blockNumber < nextBlock) nextBlock = boundaries[i].blockNumber;
        }
    }

    function _collectBorrowers(uint256 endBlock) internal returns (address[] memory borrowers) {
        require(endBlock >= FROM_BLOCK, "report end before borrower scan block");

        bytes32[] memory topics = new bytes32[](2);
        topics[0] = AaveRebateEventsLib.BORROW_EVENT_SIG;
        topics[1] = bytes32(Id.unwrap(MARKET_ID));

        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(FROM_BLOCK, endBlock, MORPHO_CREDIT, topics);
        address[] memory temp = new address[](logs.length);
        uint256 borrowerTopicIndex = AaveRebateEventsLib.borrowerTopicIndex(AaveRebateEventsLib.BORROW_EVENT_SIG);
        uint256 count = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length <= borrowerTopicIndex) continue;
            address borrower = address(uint160(uint256(logs[i].topics[borrowerTopicIndex])));
            if (_contains(temp, count, borrower)) continue;

            temp[count] = borrower;
            count++;
        }

        borrowers = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            borrowers[i] = temp[i];
        }
    }

    function _collectBoundaries(uint256 startBlock, uint256 endBlock) internal returns (Boundary[] memory) {
        Boundary[] memory borrowBoundaries = _boundariesFor(startBlock, endBlock, AaveRebateEventsLib.BORROW_EVENT_SIG);
        Boundary[] memory repayBoundaries = _boundariesFor(startBlock, endBlock, AaveRebateEventsLib.REPAY_EVENT_SIG);
        Boundary[] memory premiumBoundaries =
            _boundariesFor(startBlock, endBlock, AaveRebateEventsLib.PREMIUM_ACCRUED_EVENT_SIG);
        Boundary[] memory settledBoundaries =
            _boundariesFor(startBlock, endBlock, AaveRebateEventsLib.ACCOUNT_SETTLED_EVENT_SIG);

        return _concatBoundaries(borrowBoundaries, repayBoundaries, premiumBoundaries, settledBoundaries);
    }

    function _boundariesFor(uint256 startBlock, uint256 endBlock, bytes32 eventSig)
        internal
        returns (Boundary[] memory boundaries)
    {
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = eventSig;
        topics[1] = bytes32(Id.unwrap(MARKET_ID));

        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(startBlock, endBlock, MORPHO_CREDIT, topics);
        Boundary[] memory temp = new Boundary[](logs.length);
        uint256 borrowerTopicIndex = AaveRebateEventsLib.borrowerTopicIndex(eventSig);
        uint256 count = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length <= borrowerTopicIndex) continue;
            temp[count] = Boundary({
                borrower: address(uint160(uint256(logs[i].topics[borrowerTopicIndex]))),
                blockNumber: logs[i].blockNumber
            });
            count++;
        }

        boundaries = new Boundary[](count);
        for (uint256 i = 0; i < count; i++) {
            boundaries[i] = temp[i];
        }
    }

    function _concatBoundaries(Boundary[] memory a, Boundary[] memory b, Boundary[] memory c, Boundary[] memory d)
        internal
        pure
        returns (Boundary[] memory result)
    {
        result = new Boundary[](a.length + b.length + c.length + d.length);
        uint256 index = 0;
        index = _copyBoundaries(result, a, index);
        index = _copyBoundaries(result, b, index);
        index = _copyBoundaries(result, c, index);
        _copyBoundaries(result, d, index);
    }

    function _copyBoundaries(Boundary[] memory result, Boundary[] memory source, uint256 index)
        internal
        pure
        returns (uint256)
    {
        for (uint256 i = 0; i < source.length; i++) {
            result[index] = source[i];
            index++;
        }
        return index;
    }

    function _findBlockForTimestamp(uint256 targetTimestamp, uint256 highBlock) internal returns (uint256 targetBlock) {
        vm.rollFork(highBlock);
        require(vm.getBlockTimestamp() >= targetTimestamp, "fork before target");

        uint256 low = 1;
        uint256 high = highBlock;
        targetBlock = highBlock;

        while (low <= high) {
            uint256 mid = (low + high) / 2;
            vm.rollFork(mid);

            if (vm.getBlockTimestamp() >= targetTimestamp) {
                targetBlock = mid;
                if (mid == 0) break;
                high = mid - 1;
            } else {
                low = mid + 1;
            }
        }

        vm.rollFork(targetBlock);
    }

    function _writeReport(
        string memory outputPath,
        RunContext memory ctx,
        ReportRow[] memory rows,
        uint256 rowCount,
        uint256 discoveredBorrowers,
        uint256 boundaryCount,
        uint256 totalRebate
    ) internal {
        string memory json = "{\n";
        json = string.concat(json, '  "metadata": {\n');
        json = string.concat(json, '    "marketId": "', vm.toString(Id.unwrap(MARKET_ID)), '",\n');
        json = string.concat(json, '    "morphoCredit": "', vm.toString(MORPHO_CREDIT), '",\n');
        json = string.concat(json, '    "aavePool": "', vm.toString(AAVE_POOL), '",\n');
        json = string.concat(json, '    "usdc": "', vm.toString(USDC), '",\n');
        json = string.concat(json, '    "wausdc": "', vm.toString(WAUSDC), '",\n');
        json = string.concat(json, '    "startTimestamp": ', vm.toString(ctx.startTimestamp), ",\n");
        json = string.concat(json, '    "endTimestamp": ', vm.toString(ctx.endTimestamp), ",\n");
        json = string.concat(json, '    "startBlock": ', vm.toString(ctx.startBlock), ",\n");
        json = string.concat(json, '    "endBlock": ', vm.toString(ctx.endBlock), ",\n");
        json = string.concat(json, '    "borrowerDiscoveryFromBlock": ', vm.toString(FROM_BLOCK), ",\n");
        json = string.concat(json, '    "baselineAprBps": ', vm.toString(BASELINE_APR_BPS), ",\n");
        json =
            string.concat(json, '    "rateMethod": "Aave normalized variable debt index growth vs 5% APR baseline",\n');
        json = string.concat(json, '    "baselineCompoundingMethod": "repo_wTaylorCompounded",\n');
        json = string.concat(json, '    "debtExposureMethod": "arithmetic_mean_start_end",\n');
        json = string.concat(json, '    "configuredStartReason": "rsETH rate spike boundary selected by operators",\n');
        json = string.concat(json, '    "aaveFreezeTimestamp": ', vm.toString(AAVE_FREEZE_TIMESTAMP), ",\n");
        json = string.concat(
            json, '    "aaveFreezeNote": "Aave governance thread reports freezes at 2026-04-18 18:52 UTC",\n'
        );
        json = string.concat(
            json,
            '    "incidentReference": "Aave governance rsETH incident thread says freezes started at 2026-04-18 18:52 UTC"\n'
        );
        json = string.concat(json, "  },\n");

        json = string.concat(json, '  "totals": {\n');
        json = string.concat(json, '    "borrowersDiscovered": ', vm.toString(discoveredBorrowers), ",\n");
        json = string.concat(json, '    "debtChangeBoundaries": ', vm.toString(boundaryCount), ",\n");
        json = string.concat(json, '    "eligibleBorrowers": ', vm.toString(rowCount), ",\n");
        json = string.concat(json, '    "totalRebateUsdc": ', vm.toString(totalRebate), "\n");
        json = string.concat(json, "  },\n");
        json = string.concat(json, '  "borrowers": [\n');

        for (uint256 i = 0; i < rowCount; i++) {
            json = string.concat(json, "    {\n");
            json = string.concat(json, '      "address": "', vm.toString(rows[i].borrower), '",\n');
            json = string.concat(json, '      "intervalCount": ', vm.toString(rows[i].intervalCount), ",\n");
            json = string.concat(json, '      "startDebtUsdc": ', vm.toString(rows[i].startDebtUsdc), ",\n");
            json = string.concat(json, '      "endDebtUsdc": ', vm.toString(rows[i].endDebtUsdc), ",\n");
            json = string.concat(json, '      "rebateUsdc": ', vm.toString(rows[i].rebateUsdc));
            if (ctx.verbose) {
                json = string.concat(json, ",\n");
                json = string.concat(json, '      "intervals": ', rows[i].intervalsJson, "\n");
            } else {
                json = string.concat(json, "\n");
            }
            json = string.concat(json, "    }");
            if (i + 1 < rowCount) json = string.concat(json, ",");
            json = string.concat(json, "\n");
        }

        json = string.concat(json, "  ]\n");
        json = string.concat(json, "}\n");

        vm.writeFile(outputPath, json);
    }

    function _contains(address[] memory items, uint256 length, address item) internal pure returns (bool) {
        for (uint256 i = 0; i < length; i++) {
            if (items[i] == item) return true;
        }
        return false;
    }

    function _average(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a / 2) + (b / 2) + ((a % 2 + b % 2) / 2);
    }
}
