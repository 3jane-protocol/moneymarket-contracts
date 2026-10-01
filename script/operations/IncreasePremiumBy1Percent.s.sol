// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {IMorpho, IMorphoCredit, Id, Position, Market} from "../../src/interfaces/IMorpho.sol";
import {ICreditLine} from "../../src/interfaces/ICreditLine.sol";
import {IProtocolConfig} from "../../src/interfaces/IProtocolConfig.sol";
import {MathLib} from "../../src/libraries/MathLib.sol";

/**
 * @title IncreasePremiumBy1Percent
 * @notice Increase all active borrowers' premium rates by 1% APR
 * @dev Gets live borrowers from on-chain Borrow events, filters to those with credit > 0 or debt > 0,
 *      calculates minimum VV to satisfy LTV constraint, and updates rates via Safe batch
 */
contract IncreasePremiumBy1Percent is Script, SafeHelper {
    using MathLib for uint256;

    uint256 constant WAD = 1e18;
    uint256 constant ONE_PERCENT_APR_PER_SECOND = 317097919; // (1e18 * 0.01) / 365 days

    // Mainnet deployment addresses
    address constant MORPHO_CREDIT = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;
    address constant CREDIT_LINE = 0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9;
    Id constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);
    address constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    uint256 constant FROM_BLOCK = 23241534; // First borrow block

    function run(bool send) public isBatch(SAFE_ADDRESS) {
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        console2.log("=== Increasing Premium Rates by 1% APR ===");
        console2.log("Safe address:", SAFE_ADDRESS);
        console2.log("");

        IMorpho morpho = IMorpho(MORPHO_CREDIT);
        ICreditLine creditLine = ICreditLine(CREDIT_LINE);

        console2.log("MorphoCredit:", MORPHO_CREDIT);
        console2.log("CreditLine:", CREDIT_LINE);
        console2.log("Market ID:", vm.toString(Id.unwrap(MARKET_ID)));
        console2.log("");

        console2.log("=== Fetching Borrowers from On-Chain Events ===");
        address[] memory allBorrowers = _getBorrowersFromEvents();
        console2.log("Found %s unique borrowers from Borrow events", allBorrowers.length);
        console2.log("");

        console2.log("=== Processing Borrowers ===");

        Id[] memory tempIds = new Id[](allBorrowers.length);
        address[] memory tempBorrowers = new address[](allBorrowers.length);
        uint256[] memory tempVvs = new uint256[](allBorrowers.length);
        uint256[] memory tempCredits = new uint256[](allBorrowers.length);
        uint128[] memory tempRates = new uint128[](allBorrowers.length);

        uint256 count = 0;
        uint256 skippedNoCreditOrDebt = 0;

        uint256 maxLTV = _getMaxLTV();
        console2.log("Max LTV from ProtocolConfig:", maxLTV);
        console2.log("");

        for (uint256 i = 0; i < allBorrowers.length; i++) {
            address borrower = allBorrowers[i];

            Position memory pos = morpho.position(MARKET_ID, borrower);
            uint256 credit = uint256(pos.collateral);
            uint256 borrowShares = uint256(pos.borrowShares);

            if (credit == 0 && borrowShares == 0) {
                skippedNoCreditOrDebt++;
                continue;
            }

            console2.log("");
            console2.log("=== Borrower %s ===", count + 1);
            console2.log("Address:", borrower);
            console2.log("Credit:", credit);
            console2.log("Borrow Shares:", borrowShares);

            (, uint128 currentRate,) = IMorphoCredit(MORPHO_CREDIT).borrowerPremium(MARKET_ID, borrower);

            uint128 newRate = uint128(uint256(currentRate) + ONE_PERCENT_APR_PER_SECOND);

            uint256 vv;
            if (credit > 0) {
                vv = credit.wMulDown(WAD).wDivUp(maxLTV);
            } else {
                vv = 0;
            }

            uint256 currentRateAPRBps = (uint256(currentRate) * 365 days * 10000) / WAD;
            uint256 newRateAPRBps = (uint256(newRate) * 365 days * 10000) / WAD;

            console2.log("Current rate (per-second):", currentRate);
            console2.log("Current rate APR: %d bps", currentRateAPRBps);
            console2.log("New rate (per-second):", newRate);
            console2.log("New rate APR: %d bps", newRateAPRBps);
            console2.log("Increase: 100 bps (1%% APR)");
            console2.log("Calculated VV:", vv);

            tempIds[count] = MARKET_ID;
            tempBorrowers[count] = borrower;
            tempVvs[count] = vv;
            tempCredits[count] = credit;
            tempRates[count] = newRate;

            count++;
        }

        console2.log("");
        console2.log("=== Summary ===");
        console2.log("Total borrowers checked:", allBorrowers.length);
        console2.log("Will update:", count);
        console2.log("Skipped (no credit or debt):", skippedNoCreditOrDebt);
        console2.log("");

        if (count == 0) {
            console2.log("No borrowers to update. Exiting.");
            return;
        }

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

        console2.log("=== Building Safe Batch ===");
        bytes memory setCreditLinesCall =
            abi.encodeCall(creditLine.setCreditLines, (ids, borrowers, vvs, credits, rates));
        addToBatch(CREDIT_LINE, setCreditLinesCall);
        console2.log("Added setCreditLines call with %s borrowers", count);
        console2.log("");

        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("Next steps:");
            console2.log("1. Multisig signers must approve the transaction in Safe UI");
            console2.log("2. Once threshold reached, anyone can execute");
            console2.log("3. All %s premium rates will be increased by 1%% APR atomically", count);
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    function _getBorrowersFromEvents() private returns (address[] memory) {
        uint256 toBlock = block.number;

        console2.log("Querying Borrow events from block %s to %s", FROM_BLOCK, toBlock);

        bytes32 borrowEventSignature = keccak256("Borrow(bytes32,address,address,address,uint256,uint256)");

        bytes32[] memory topics = new bytes32[](2);
        topics[0] = borrowEventSignature;
        topics[1] = Id.unwrap(MARKET_ID);

        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(FROM_BLOCK, toBlock, MORPHO_CREDIT, topics);

        console2.log("Found %s Borrow events", logs.length);

        address[] memory uniqueBorrowers = new address[](logs.length);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            address borrower = address(uint160(uint256(logs[i].topics[2])));

            bool seen = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (uniqueBorrowers[j] == borrower) {
                    seen = true;
                    break;
                }
            }

            if (!seen) {
                uniqueBorrowers[uniqueCount] = borrower;
                uniqueCount++;
            }
        }

        address[] memory result = new address[](uniqueCount);
        for (uint256 i = 0; i < uniqueCount; i++) {
            result[i] = uniqueBorrowers[i];
        }

        return result;
    }

    function _getMaxLTV() private view returns (uint256) {
        address protocolConfig = IMorphoCredit(MORPHO_CREDIT).protocolConfig();
        return IProtocolConfig(protocolConfig).getCreditLineConfig().maxLTV;
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

    function run() external {
        run(false);
    }
}
