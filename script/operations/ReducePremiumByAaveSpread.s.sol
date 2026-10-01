// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {IMorpho, IMorphoCredit, Id, Position} from "../../src/interfaces/IMorpho.sol";
import {ICreditLine} from "../../src/interfaces/ICreditLine.sol";
import {IProtocolConfig} from "../../src/interfaces/IProtocolConfig.sol";
import {IAaveMarket, ReserveDataLegacy} from "../../src/irm/adaptive-curve-irm/interfaces/IAaveMarket.sol";
import {MathLib} from "../../src/libraries/MathLib.sol";

/**
 * @title ReducePremiumByAaveSpread
 * @notice Reduce borrower premium rates by the Aave borrow spread
 * @dev Reads borrowers from JSON, queries on-chain state, calculates Aave spread,
 *      and updates premium rates via Safe multisig batch transaction
 */
contract ReducePremiumByAaveSpread is Script, SafeHelper {
    using MathLib for uint256;

    uint256 constant WAD = 1e18;

    /// @notice Struct for parsing borrower JSON data
    struct BorrowerData {
        address borrower;
    }

    /// @notice Struct for JSON parsing - fields ordered to match alphabetized JSON
    /// @dev JSON fields alphabetically: borrower_address, credit, drp, vv
    struct CreditLineData {
        address borrower_address; // 1st alphabetically
        uint256 credit; // 2nd alphabetically
        uint128 drp; // 3rd alphabetically
        uint256 vv; // 4th alphabetically
    }

    /// @notice Main execution function
    /// @param send Whether to send transaction to Safe API (true) or just simulate (false)
    function run(bool send) public isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF)) {
        // Check base fee
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        console2.log("=== Reducing Premium Rates by Aave Spread ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("");

        // Load addresses
        address morphoAddress = vm.envAddress("MORPHO_ADDRESS");
        address creditLineAddress = vm.envAddress("CREDIT_LINE_ADDRESS");
        bytes32 marketIdBytes = vm.envBytes32("MARKET_ID");
        Id marketId = Id.wrap(marketIdBytes);

        IMorpho morpho = IMorpho(morphoAddress);
        ICreditLine creditLine = ICreditLine(creditLineAddress);

        console2.log("MorphoCredit:", morphoAddress);
        console2.log("CreditLine:", creditLineAddress);
        console2.log("Market ID:", vm.toString(marketIdBytes));
        console2.log("");

        // Step 1: Load historical vv values from all credit-lines JSON files
        console2.log("=== Loading historical vv values ===");
        (address[] memory vvAddresses, uint256[] memory vvValues) = _loadVvValues();
        console2.log("");

        // Step 2: Load borrower addresses
        console2.log("=== Loading borrower addresses ===");
        string memory borrowersJson = vm.readFile("data/borrowers-2025-10-22.json");
        bytes memory borrowersData = vm.parseJson(borrowersJson);
        address[] memory borrowerAddresses = abi.decode(borrowersData, (address[]));
        console2.log("Loaded", borrowerAddresses.length, "borrowers");
        console2.log("");

        // Step 3: Calculate Aave spread
        console2.log("=== Calculating Aave spread ===");
        uint256 aaveSpread = _calculateAaveSpread();
        console2.log("Aave borrow-supply spread (per second):", aaveSpread);
        console2.log("Aave spread APR: %d bps", (aaveSpread * 365 days * 10000) / WAD);
        console2.log("");

        // Step 4: Query on-chain state and prepare batch
        console2.log("=== Querying on-chain state ===");

        // Temporary arrays (will resize after filtering)
        Id[] memory tempIds = new Id[](borrowerAddresses.length);
        address[] memory tempBorrowers = new address[](borrowerAddresses.length);
        uint256[] memory tempVvs = new uint256[](borrowerAddresses.length);
        uint256[] memory tempCredits = new uint256[](borrowerAddresses.length);
        uint128[] memory tempRates = new uint128[](borrowerAddresses.length);

        uint256 count = 0;
        uint256 skippedZeroCredit = 0;
        uint256 skippedNoVv = 0;

        for (uint256 i = 0; i < borrowerAddresses.length; i++) {
            address borrower = borrowerAddresses[i];

            console2.log("");
            console2.log("=== Processing borrower", count + 1, "===");
            console2.log("Address:", borrower);

            // Query on-chain position
            Position memory pos = morpho.position(marketId, borrower);
            uint256 credit = uint256(pos.collateral);
            console2.log("On-chain credit:", credit);

            // Skip if credit is 0
            if (credit == 0) {
                console2.log("Skipping - zero credit");
                skippedZeroCredit++;
                continue;
            }

            // Get vv from lookup arrays
            uint256 vv = _findVv(vvAddresses, vvValues, borrower);
            console2.log("Historical vv from lookup:", vv);
            if (vv == 0) {
                console2.log("ERROR: Missing vv");
                skippedNoVv++;
                continue;
            }

            // Store original vv before adjustment
            uint256 originalVv = vv;

            // Ensure vv satisfies maxLTV constraint: credit / vv <= maxLTV
            // This means: vv >= credit * WAD / maxLTV
            // Query maxLTV from ProtocolConfig
            uint256 maxLTV = _getMaxLTV(morphoAddress);
            uint256 minRequiredVv = credit.wMulDown(WAD).wDivUp(maxLTV);

            if (vv < minRequiredVv) {
                console2.log("Adjustment needed:");
                console2.log("  Current vv:", vv);
                console2.log("  Min required:", minRequiredVv);
                vv = minRequiredVv;
                console2.log("  Adjusted vv to:", vv);
            } else {
                console2.log("No adjustment needed");
            }

            // Query current premium rate
            (, uint128 currentRate,) = IMorphoCredit(morphoAddress).borrowerPremium(marketId, borrower);

            // Calculate new rate (floor at 1 wei)
            uint128 newRate;
            if (currentRate > aaveSpread) {
                newRate = uint128(currentRate - aaveSpread);
                if (newRate == 0) newRate = 1;
            } else {
                newRate = 1; // Floor at 1 wei
            }

            // Add to batch arrays
            tempIds[count] = marketId;
            tempBorrowers[count] = borrower;
            tempVvs[count] = vv;
            tempCredits[count] = credit;
            tempRates[count] = newRate;

            console2.log("");
            console2.log("--- Summary ---");
            console2.log("Final VV:", vv);
            console2.log("Credit:", credit);
            console2.log("Old rate:", currentRate);
            console2.log("New rate:", newRate);
            if (currentRate > newRate) {
                console2.log("Reduction:", currentRate - newRate);
            }

            count++;
        }

        console2.log("");
        console2.log("Total borrowers:", borrowerAddresses.length);
        console2.log("Will update:", count);
        console2.log("Skipped (zero credit):", skippedZeroCredit);
        console2.log("Skipped (missing vv):", skippedNoVv);
        console2.log("");

        if (count == 0) {
            console2.log("No borrowers to update. Exiting.");
            return;
        }

        // Resize arrays to actual count
        Id[] memory ids = new Id[](count);
        address[] memory borrowers = new address[](count);
        uint256[] memory vvs = new uint256[](count);
        uint256[] memory credits = new uint256[](count);
        uint128[] memory rates = new uint128[](count);

        for (uint256 i = 0; i < count; i++) {
            ids[i] = tempIds[i];
            borrowers[i] = tempBorrowers[i];
            vvs[i] = tempVvs[i];
            credits[i] = tempCredits[i];
            rates[i] = tempRates[i];
        }

        // Step 5: Build Safe batch
        console2.log("=== Building Safe batch ===");
        bytes memory setCreditLinesCall =
            abi.encodeCall(creditLine.setCreditLines, (ids, borrowers, vvs, credits, rates));
        addToBatch(creditLineAddress, setCreditLinesCall);
        console2.log("Added setCreditLines call with", count, "borrowers");
        console2.log("");

        // Execute the batch
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("Next steps:");
            console2.log("1. Multisig signers must approve the transaction in Safe UI");
            console2.log("2. Once threshold reached, anyone can execute");
            console2.log("3. All", count, "premium rates will be reduced atomically");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    /// @notice Load vv values from all credit-lines JSON files
    function _loadVvValues() private returns (address[] memory addresses, uint256[] memory values) {
        string[] memory files = new string[](14);
        files[0] = "data/credit-lines-09-15-2025.json";
        files[1] = "data/credit-lines-09-18-2025.json";
        files[2] = "data/credit-lines-09-24-2025.json";
        files[3] = "data/credit-lines-1.json";
        files[4] = "data/credit-lines-10-01-2025.json";
        files[5] = "data/credit-lines-2.json";
        files[6] = "data/credit-lines-3.json";
        files[7] = "data/credit-lines-4.json";
        files[8] = "data/credit-lines-5.json";
        files[9] = "data/credit-lines-6.json";
        files[10] = "data/credit-lines-7.json";
        files[11] = "data/credit-lines-messi.json";
        files[12] = "data/credit-lines-test.json";
        files[13] = "data/missing-10-25-2025.json";

        // First pass: count total entries
        uint256 totalCount = 0;
        for (uint256 i = 0; i < files.length; i++) {
            try vm.readFile(files[i]) returns (string memory json) {
                bytes memory data = vm.parseJson(json);
                CreditLineData[] memory creditLines = abi.decode(data, (CreditLineData[]));
                totalCount += creditLines.length;
            } catch {
                continue;
            }
        }

        // Allocate arrays
        addresses = new address[](totalCount);
        values = new uint256[](totalCount);

        // Second pass: populate arrays
        uint256 idx = 0;
        for (uint256 i = 0; i < files.length; i++) {
            try vm.readFile(files[i]) returns (string memory json) {
                bytes memory data = vm.parseJson(json);
                CreditLineData[] memory creditLines = abi.decode(data, (CreditLineData[]));

                for (uint256 j = 0; j < creditLines.length; j++) {
                    addresses[idx] = creditLines[j].borrower_address;
                    values[idx] = creditLines[j].vv;
                    idx++;
                }
            } catch {
                continue;
            }
        }

        console2.log("Loaded vv values for", totalCount, "borrowers");
    }

    /// @notice Find vv value for a borrower address
    function _findVv(address[] memory addresses, uint256[] memory values, address borrower)
        private
        pure
        returns (uint256)
    {
        for (uint256 i = 0; i < addresses.length; i++) {
            if (addresses[i] == borrower) {
                return values[i];
            }
        }
        return 0;
    }

    /// @notice Calculate Aave USDC borrow-supply spread
    function _calculateAaveSpread() private view returns (uint256) {
        address aavePool = vm.envOr("AAVE_POOL", address(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2));
        address usdc = vm.envOr("USDC_ADDRESS", address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));

        ReserveDataLegacy memory reserveData = IAaveMarket(aavePool).getReserveData(usdc);

        // Aave rates are APR in RAY (1e27), convert to WAD
        uint256 aaveSupplyAPR = uint256(reserveData.currentLiquidityRate) / 1e9;
        uint256 aaveBorrowAPR = uint256(reserveData.currentVariableBorrowRate) / 1e9;

        // Calculate spread as APR, then convert to per-second
        uint256 spreadAPR = aaveBorrowAPR > aaveSupplyAPR ? aaveBorrowAPR - aaveSupplyAPR : 0;
        uint256 spreadPerSecond = spreadAPR / 365 days;

        return spreadPerSecond;
    }

    /// @notice Get maxLTV from ProtocolConfig
    function _getMaxLTV(address morphoAddress) private view returns (uint256) {
        address protocolConfig = IMorphoCredit(morphoAddress).protocolConfig();
        return IProtocolConfig(protocolConfig).getCreditLineConfig().maxLTV;
    }

    /// @notice Check if base fee is acceptable
    function _baseFeeOkay() private view returns (bool) {
        uint256 basefeeLimit = vm.envOr("BASE_FEE_LIMIT", uint256(50)) * 1e9;
        if (block.basefee >= basefeeLimit) {
            console2.log("Base fee too high: %d gwei > %d gwei limit", block.basefee / 1e9, basefeeLimit / 1e9);
            return false;
        }
        console2.log("Base fee OK: %d gwei", block.basefee / 1e9);
        return true;
    }

    /// @notice Alternative entry point with default simulation mode
    function run() external {
        run(false);
    }
}
