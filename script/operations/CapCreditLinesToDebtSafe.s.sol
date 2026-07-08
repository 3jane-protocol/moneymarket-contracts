// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {Vm} from "forge-std/Vm.sol";

import {SafeHelper} from "../utils/SafeHelper.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {IProtocolConfig, CreditLineConfig} from "../../src/interfaces/IProtocolConfig.sol";
import {IMorpho, IMorphoCredit, Id, MarketParams, Position} from "../../src/interfaces/IMorpho.sol";
import {MathLib} from "../../src/libraries/MathLib.sol";
import {MorphoCreditBalancesLib} from "../../src/libraries/periphery/MorphoCreditBalancesLib.sol";

/// @title CapCreditLinesToDebtSafe
/// @notice Caps active credit lines to min(current credit line, current premium-inclusive debt) via Safe + Timelock.
/// @dev Use snapshot() first, then schedule() and execute() with the same JSON file.
contract CapCreditLinesToDebtSafe is Script, SafeHelper, TimelockHelper {
    using MathLib for uint256;
    using MorphoCreditBalancesLib for IMorphoCredit;

    address private constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address private constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    CreditLine private constant CREDIT_LINE = CreditLine(0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9);
    Id private constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);
    uint256 private constant FROM_BLOCK = 23241534;

    /// @dev JSON keys are written alphabetically to match Foundry's struct decoding.
    struct SnapshotRow {
        address borrower;
        uint256 currentCredit;
        uint128 drp;
        uint256 premiumInclusiveDebt;
        uint256 snapshotBlock;
        uint256 snapshotTimestamp;
        uint256 targetCredit;
        uint256 vv;
    }

    function snapshot() external {
        string memory outputPath = string.concat("data/capped-credit-lines-", vm.toString(block.timestamp), ".json");
        snapshot(outputPath);
    }

    function snapshot(string memory outputPath) public {
        _createSnapshot(outputPath);
    }

    function schedule(bool send) external isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE)) isTimelock(TIMELOCK) {
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        string memory outputPath = string.concat("data/capped-credit-lines-", vm.toString(block.timestamp), ".json");
        SnapshotRow[] memory rows = _createSnapshot(outputPath);
        _validateSnapshotRows(rows, true);
        _scheduleRows(rows, outputPath, send);
    }

    function _createSnapshot(string memory outputPath) private returns (SnapshotRow[] memory finalRows) {
        require(block.number >= FROM_BLOCK, "fork before borrower scan block");

        IMorphoCredit morphoCredit = IMorphoCredit(CREDIT_LINE.MORPHO());
        IMorpho morpho = IMorpho(address(morphoCredit));
        MarketParams memory marketParams = morpho.idToMarketParams(MARKET_ID);
        IERC4626 waUsdc = IERC4626(marketParams.loanToken);
        CreditLineConfig memory config = IProtocolConfig(morphoCredit.protocolConfig()).getCreditLineConfig();

        require(CREDIT_LINE.prover() == address(0), "prover-enabled credit line unsupported");
        require(config.maxLTV > 0, "max ltv unset");

        console2.log("=== Snapshot Credit Lines To Premium-Inclusive Debt ===");
        console2.log("MorphoCredit:", address(morphoCredit));
        console2.log("CreditLine:", address(CREDIT_LINE));
        console2.log("Market ID:", vm.toString(Id.unwrap(MARKET_ID)));
        console2.log("From block:", FROM_BLOCK);
        console2.log("Current block:", block.number);
        console2.log("");

        address[] memory borrowers = _collectCreditLineBorrowers(address(morphoCredit));
        console2.log("Borrowers with SetCreditLine history:", borrowers.length);
        console2.log("");

        SnapshotRow[] memory rows = new SnapshotRow[](borrowers.length);
        uint256 rowCount = 0;
        uint256 totalCurrentCredit = 0;
        uint256 totalTargetCredit = 0;
        uint256 skippedNoCredit = 0;
        uint256 skippedNoReduction = 0;

        for (uint256 i = 0; i < borrowers.length; i++) {
            address borrower = borrowers[i];
            Position memory position = morpho.position(MARKET_ID, borrower);
            uint256 currentCredit = uint256(position.collateral);

            if (currentCredit == 0) {
                skippedNoCredit++;
                continue;
            }

            uint256 debt = morphoCredit.expectedBorrowAssetsWithPremium(MARKET_ID, borrower);
            uint256 targetCredit = debt < currentCredit ? debt : currentCredit;
            if (targetCredit < config.minCreditLine) targetCredit = config.minCreditLine;

            if (targetCredit >= currentCredit) {
                skippedNoReduction++;
                continue;
            }

            uint256 vv = currentCredit.wDivUp(config.maxLTV);
            require(vv <= config.maxVV, string.concat("computed VV exceeds max for ", vm.toString(borrower)));

            (, uint128 drp,) = morphoCredit.borrowerPremium(MARKET_ID, borrower);

            rows[rowCount] = SnapshotRow({
                borrower: borrower,
                currentCredit: currentCredit,
                drp: drp,
                premiumInclusiveDebt: debt,
                snapshotBlock: block.number,
                snapshotTimestamp: block.timestamp,
                targetCredit: targetCredit,
                vv: vv
            });
            rowCount++;

            totalCurrentCredit += currentCredit;
            totalTargetCredit += targetCredit;

            console2.log("Borrower:", borrower);
            console2.log("  Current credit:", currentCredit);
            console2.log("  Premium-inclusive debt:", debt);
            console2.log("  Target credit:", targetCredit);
            console2.log("  VV:", vv);
            console2.log("  DRP:", drp);
        }

        require(rowCount > 0, "no credit lines need capping");

        finalRows = new SnapshotRow[](rowCount);
        for (uint256 i = 0; i < rowCount; i++) {
            finalRows[i] = rows[i];
        }

        _writeSnapshot(finalRows, rowCount, outputPath);

        console2.log("");
        console2.log("=== Summary ===");
        console2.log("Rows written:", rowCount);
        console2.log("Skipped no current credit:", skippedNoCredit);
        console2.log("Skipped no reduction:", skippedNoReduction);
        console2.log("Total current credit (waUSDC):", totalCurrentCredit);
        console2.log("Total current credit (USDC):", waUsdc.convertToAssets(totalCurrentCredit));
        console2.log("Total target credit (waUSDC):", totalTargetCredit);
        console2.log("Total target credit (USDC):", waUsdc.convertToAssets(totalTargetCredit));
        console2.log("Total credit reduction (waUSDC):", totalCurrentCredit - totalTargetCredit);
        console2.log("Total credit reduction (USDC):", waUsdc.convertToAssets(totalCurrentCredit - totalTargetCredit));
        console2.log("Output written to:", outputPath);
    }

    function schedule(string memory jsonPath, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(TIMELOCK)
    {
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        SnapshotRow[] memory rows = _parseSnapshot(jsonPath);
        _validateSnapshotRows(rows, true);

        _scheduleRows(rows, jsonPath, send);
    }

    function _scheduleRows(SnapshotRow[] memory rows, string memory sourceLabel, bool send) private {
        bytes memory setCreditLinesCall = _buildSetCreditLinesCall(rows);
        (address[] memory targets, uint256[] memory values, bytes[] memory datas) =
            _buildTimelockBatch(setCreditLinesCall);
        bytes32 salt = _generateSalt(rows);
        bytes32 predecessor = bytes32(0);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("=== Schedule Credit Line Caps via Timelock ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE));
        console2.log("Timelock address:", TIMELOCK);
        console2.log("CreditLine address:", address(CREDIT_LINE));
        console2.log("Snapshot file:", sourceLabel);
        console2.log("Rows:", rows.length);
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Send to Safe:", send);
        console2.log("");

        if (isOperation(TIMELOCK, operationId)) {
            logOperationState(TIMELOCK, operationId);
            console2.log("Operation already exists. Use execute() when ready.");
            return;
        }

        simulateExecution(TIMELOCK, targets, values, datas);

        uint256 minDelay = getMinDelay(TIMELOCK);
        bytes memory scheduleCalldata = encodeScheduleBatch(targets, values, datas, predecessor, salt, minDelay);

        addToBatch(TIMELOCK, scheduleCalldata);

        if (send) {
            console2.log("Sending schedule transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully.");
            console2.log("Operation ID:", vm.toString(operationId));
            console2.log("Timelock delay:", minDelay);
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    function execute(string memory jsonPath, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(TIMELOCK)
    {
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        SnapshotRow[] memory rows = _parseSnapshot(jsonPath);
        _validateSnapshotRows(rows, false);

        bytes memory setCreditLinesCall = _buildSetCreditLinesCall(rows);
        (address[] memory targets, uint256[] memory values, bytes[] memory datas) =
            _buildTimelockBatch(setCreditLinesCall);
        bytes32 salt = _generateSalt(rows);
        bytes32 predecessor = bytes32(0);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("=== Execute Credit Line Caps via Timelock ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE));
        console2.log("Timelock address:", TIMELOCK);
        console2.log("CreditLine address:", address(CREDIT_LINE));
        console2.log("JSON file:", jsonPath);
        console2.log("Rows:", rows.length);
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Send to Safe:", send);
        console2.log("");

        logOperationState(TIMELOCK, operationId);
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

    function checkStatus(string memory jsonPath) external {
        SnapshotRow[] memory rows = _parseSnapshot(jsonPath);
        bytes memory setCreditLinesCall = _buildSetCreditLinesCall(rows);
        (address[] memory targets, uint256[] memory values, bytes[] memory datas) =
            _buildTimelockBatch(setCreditLinesCall);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, bytes32(0), _generateSalt(rows));

        console2.log("=== Check Credit Line Cap Operation ===");
        console2.log("Rows:", rows.length);
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("");
        logOperationState(TIMELOCK, operationId);
    }

    function verify(string memory jsonPath) external view {
        SnapshotRow[] memory rows = _parseSnapshot(jsonPath);
        IMorpho morpho = IMorpho(CREDIT_LINE.MORPHO());

        console2.log("=== Verify Credit Line Caps ===");
        console2.log("Rows:", rows.length);
        console2.log("");

        uint256 matches = 0;
        uint256 mismatches = 0;

        for (uint256 i = 0; i < rows.length; i++) {
            uint256 currentCredit = uint256(morpho.position(MARKET_ID, rows[i].borrower).collateral);
            if (currentCredit == rows[i].targetCredit) {
                matches++;
            } else {
                mismatches++;
                console2.log("Mismatch:", rows[i].borrower);
                console2.log("  Expected:", rows[i].targetCredit);
                console2.log("  Actual:", currentCredit);
            }
        }

        console2.log("");
        console2.log("Matches:", matches);
        console2.log("Mismatches:", mismatches);
    }

    function _collectCreditLineBorrowers(address morphoCreditAddress) private returns (address[] memory borrowers) {
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = keccak256("SetCreditLine(bytes32,address,uint256)");
        topics[1] = bytes32(Id.unwrap(MARKET_ID));

        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(FROM_BLOCK, block.number, morphoCreditAddress, topics);
        address[] memory temp = new address[](logs.length);
        uint256 count = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length < 3) continue;
            address borrower = address(uint160(uint256(logs[i].topics[2])));
            if (_contains(temp, count, borrower)) continue;

            temp[count] = borrower;
            count++;
        }

        borrowers = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            borrowers[i] = temp[i];
        }
    }

    function _parseSnapshot(string memory jsonPath) private view returns (SnapshotRow[] memory rows) {
        string memory json = vm.readFile(jsonPath);
        rows = abi.decode(vm.parseJson(json), (SnapshotRow[]));
        require(rows.length > 0, "empty snapshot");
    }

    function _validateSnapshotRows(SnapshotRow[] memory rows, bool requireCurrentCreditMatches) private view {
        IMorpho morpho = IMorpho(CREDIT_LINE.MORPHO());
        CreditLineConfig memory config =
            IProtocolConfig(IMorphoCredit(CREDIT_LINE.MORPHO()).protocolConfig()).getCreditLineConfig();

        for (uint256 i = 0; i < rows.length; i++) {
            require(rows[i].borrower != address(0), "zero borrower");
            require(rows[i].targetCredit >= config.minCreditLine, "target below min credit line");
            require(rows[i].targetCredit <= config.maxCreditLine, "target above max credit line");
            require(rows[i].vv > 0, "zero vv");
            require(rows[i].vv <= config.maxVV, "vv above max");
            require(rows[i].targetCredit.wDivDown(rows[i].vv) <= config.maxLTV, "target above max ltv");
            require(rows[i].targetCredit < rows[i].currentCredit, "snapshot would not reduce credit");

            if (requireCurrentCreditMatches) {
                uint256 currentCredit = uint256(morpho.position(MARKET_ID, rows[i].borrower).collateral);
                require(currentCredit == rows[i].currentCredit, "current credit changed since snapshot");
            }
        }
    }

    function _buildSetCreditLinesCall(SnapshotRow[] memory rows) private pure returns (bytes memory) {
        Id[] memory ids = new Id[](rows.length);
        address[] memory borrowers = new address[](rows.length);
        uint256[] memory vvs = new uint256[](rows.length);
        uint256[] memory credits = new uint256[](rows.length);
        uint128[] memory drps = new uint128[](rows.length);

        for (uint256 i = 0; i < rows.length; i++) {
            ids[i] = MARKET_ID;
            borrowers[i] = rows[i].borrower;
            vvs[i] = rows[i].vv;
            credits[i] = rows[i].targetCredit;
            drps[i] = rows[i].drp;
        }

        return abi.encodeCall(CREDIT_LINE.setCreditLines, (ids, borrowers, vvs, credits, drps));
    }

    function _buildTimelockBatch(bytes memory callData)
        private
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory datas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        datas = new bytes[](1);

        targets[0] = address(CREDIT_LINE);
        values[0] = 0;
        datas[0] = callData;
    }

    function _generateSalt(SnapshotRow[] memory rows) private pure returns (bytes32) {
        bytes memory packed;
        for (uint256 i = 0; i < rows.length; i++) {
            packed = abi.encodePacked(
                packed,
                rows[i].borrower,
                rows[i].currentCredit,
                rows[i].drp,
                rows[i].premiumInclusiveDebt,
                rows[i].snapshotBlock,
                rows[i].snapshotTimestamp,
                rows[i].targetCredit,
                rows[i].vv
            );
        }
        return keccak256(abi.encodePacked("Cap credit lines to premium-inclusive debt: ", packed));
    }

    function _writeSnapshot(SnapshotRow[] memory rows, uint256 rowCount, string memory outputPath) private {
        string memory json = "[";

        for (uint256 i = 0; i < rowCount; i++) {
            if (i > 0) json = string.concat(json, ",");

            json = string.concat(json, "\n  {");
            json = string.concat(json, '\n    "borrower": "', vm.toString(rows[i].borrower), '",');
            json = string.concat(json, '\n    "currentCredit": ', vm.toString(rows[i].currentCredit), ",");
            json = string.concat(json, '\n    "drp": ', vm.toString(rows[i].drp), ",");
            json = string.concat(json, '\n    "premiumInclusiveDebt": ', vm.toString(rows[i].premiumInclusiveDebt), ",");
            json = string.concat(json, '\n    "snapshotBlock": ', vm.toString(rows[i].snapshotBlock), ",");
            json = string.concat(json, '\n    "snapshotTimestamp": ', vm.toString(rows[i].snapshotTimestamp), ",");
            json = string.concat(json, '\n    "targetCredit": ', vm.toString(rows[i].targetCredit), ",");
            json = string.concat(json, '\n    "vv": ', vm.toString(rows[i].vv));
            json = string.concat(json, "\n  }");
        }

        json = string.concat(json, "\n]");
        vm.writeFile(outputPath, json);
    }

    function _contains(address[] memory values, uint256 count, address value) private pure returns (bool) {
        for (uint256 i = 0; i < count; i++) {
            if (values[i] == value) return true;
        }
        return false;
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
