// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {Jane} from "../../src/jane/Jane.sol";
import {RewardsDistributor} from "../../src/jane/RewardsDistributor.sol";
import {IMorphoCredit} from "../../src/interfaces/IMorpho.sol";
import {ICreditLine} from "../../src/interfaces/ICreditLine.sol";
import {IProtocolConfig} from "../../src/interfaces/IProtocolConfig.sol";
import {ProtocolConfigLib} from "../../src/libraries/ProtocolConfigLib.sol";

/**
 * @title ConfigureV1_1Safe
 * @notice Configure all v1.1 protocol changes in a single atomic Safe multisig transaction
 * @dev Batches 14 operations:
 *      - MorphoCredit: set HelperV2
 *      - CreditLine: set MarkdownController
 *      - ProtocolConfig: set 8 configuration values (FULL_MARKDOWN_DURATION, TRANCHE_RATIO,
 *        MIN_SUSD3_BACKING_RATIO, TRANCHE_SHARE_VARIANT, DEBT_CAP, USD3_SUPPLY_CAP, CURVE_STEEPNESS, IRP)
 *      - USD3: set min deposit, disable whitelist, whitelist HelperV2
 *      - sUSD3: whitelist HelperV2
 */
contract ConfigureV1_1Safe is Script, SafeHelper {
    // Role identifiers from Jane.sol
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /**
     * @notice Main execution function
     * @param send Whether to send transaction to Safe API (true) or just simulate (false)
     */
    function run(bool send) external isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF)) {
        // Check base fee
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        console2.log("=== V1.1 Configuration via Safe (Single Atomic Transaction) ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("Send to Safe:", send);
        console2.log("");

        // Load addresses
        address jane = vm.envAddress("JANE_ADDRESS");
        address rewardsDistributor = vm.envAddress("REWARDS_DISTRIBUTOR_ADDRESS");
        address markdownController = vm.envAddress("MARKDOWN_CONTROLLER_ADDRESS");
        address morphoCredit = vm.envAddress("MORPHO_ADDRESS");
        address creditLine = vm.envAddress("CREDIT_LINE_ADDRESS");
        address helperV2 = vm.envAddress("HELPER_V2_ADDRESS");
        address protocolConfig = vm.envAddress("PROTOCOL_CONFIG");
        address usd3 = vm.envAddress("USD3_ADDRESS");
        address susd3 = vm.envAddress("SUSD3_ADDRESS");
        address multisig = vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF);

        // Load configuration values (with defaults)
        uint256 fullMarkdownDuration = vm.envOr("FULL_MARKDOWN_DURATION", uint256(365 days * 2));
        uint256 trancheRatio = vm.envOr("TRANCHE_RATIO", uint256(10000));
        uint256 minSusd3BackingRatio = vm.envOr("MIN_SUSD3_BACKING_RATIO", uint256(10000));
        uint256 trancheShareVariant = vm.envOr("TRANCHE_SHARE_VARIANT", uint256(10000));
        uint256 debtCap = vm.envOr("DEBT_CAP", uint256(7_000_000e6));
        uint256 supplyCap = vm.envOr("USD3_SUPPLY_CAP", uint256(50_000_000e6));
        uint256 curveSteepness = vm.envOr("CURVE_STEEPNESS", uint256(1.5 ether));
        uint256 irp = vm.envOr("IRP", uint256(0.1 ether / int256(365 days)));
        uint256 minDeposit = vm.envOr("USD3_MIN_DEPOSIT", uint256(1000e6));

        console2.log("=== Addresses ===");
        console2.log("Jane:", jane);
        console2.log("RewardsDistributor:", rewardsDistributor);
        console2.log("MarkdownController:", markdownController);
        console2.log("MorphoCredit:", morphoCredit);
        console2.log("CreditLine:", creditLine);
        console2.log("HelperV2:", helperV2);
        console2.log("ProtocolConfig:", protocolConfig);
        console2.log("USD3:", usd3);
        console2.log("sUSD3:", susd3);
        console2.log("Multisig:", multisig);
        console2.log("");

        console2.log("=== Configuration Values ===");
        console2.log("Full markdown duration:", fullMarkdownDuration / 1 days, "days");
        console2.log("Tranche ratio:", trancheRatio / 100, "%");
        console2.log("Min sUSD3 backing ratio:", minSusd3BackingRatio / 100, "%");
        console2.log("Tranche share variant:", trancheShareVariant / 100, "%");
        console2.log("Debt cap:", debtCap / 1e6, "M USDC");
        console2.log("Supply cap:", supplyCap / 1e6, "M USDC");
        console2.log("Curve steepness: %e", curveSteepness);
        console2.log("IRP (annual): %e %", (irp * 365 days));
        console2.log("Min deposit:", minDeposit / 1e6, "USDC");
        console2.log("");

        // ====================================================================
        // BATCH 2: MORPHOCREDIT & CREDITLINE CONFIGURATION (2 operations)
        // ====================================================================
        console2.log("=== [2/3] MorphoCredit & CreditLine Configuration ===");

        // 5. Set HelperV2 on MorphoCredit
        console2.log("5. MorphoCredit.setHelper(HelperV2)");
        bytes memory setHelperCall = abi.encodeCall(IMorphoCredit.setHelper, (helperV2));
        addToBatch(morphoCredit, setHelperCall);

        // 6. Set MarkdownController on CreditLine
        console2.log("6. CreditLine.setMm(MarkdownController)");
        bytes memory setMmCall = abi.encodeCall(ICreditLine.setMm, (markdownController));
        addToBatch(creditLine, setMmCall);

        console2.log("");

        // ====================================================================
        // BATCH 3: PROTOCOLCONFIG CONFIGURATION (8 operations)
        // ====================================================================
        console2.log("=== [3/4] ProtocolConfig Configuration ===");

        // 7. Set FULL_MARKDOWN_DURATION
        console2.log("7. ProtocolConfig.setConfig(FULL_MARKDOWN_DURATION)");
        bytes memory setDurationCall =
            abi.encodeCall(IProtocolConfig.setConfig, (ProtocolConfigLib.FULL_MARKDOWN_DURATION, fullMarkdownDuration));
        addToBatch(protocolConfig, setDurationCall);

        // 8. Set TRANCHE_RATIO
        console2.log("8. ProtocolConfig.setConfig(TRANCHE_RATIO)");
        bytes memory setTrancheRatioCall =
            abi.encodeCall(IProtocolConfig.setConfig, (ProtocolConfigLib.TRANCHE_RATIO, trancheRatio));
        addToBatch(protocolConfig, setTrancheRatioCall);

        // 9. Set MIN_SUSD3_BACKING_RATIO
        console2.log("9. ProtocolConfig.setConfig(MIN_SUSD3_BACKING_RATIO)");
        bytes memory setMinBackingCall = abi.encodeCall(
            IProtocolConfig.setConfig, (ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, minSusd3BackingRatio)
        );
        addToBatch(protocolConfig, setMinBackingCall);

        // 10. Set DEBT_CAP
        console2.log("10. ProtocolConfig.setConfig(DEBT_CAP)");
        bytes memory setDebtCapCall = abi.encodeCall(IProtocolConfig.setConfig, (ProtocolConfigLib.DEBT_CAP, debtCap));
        addToBatch(protocolConfig, setDebtCapCall);

        // 11. Set USD3_SUPPLY_CAP
        console2.log("11. ProtocolConfig.setConfig(USD3_SUPPLY_CAP)");
        bytes memory setSupplyCapCall =
            abi.encodeCall(IProtocolConfig.setConfig, (ProtocolConfigLib.USD3_SUPPLY_CAP, supplyCap));
        addToBatch(protocolConfig, setSupplyCapCall);

        // 12. Set CURVE_STEEPNESS
        console2.log("12. ProtocolConfig.setConfig(CURVE_STEEPNESS)");
        bytes memory setCurveSteepnessCall =
            abi.encodeCall(IProtocolConfig.setConfig, (ProtocolConfigLib.CURVE_STEEPNESS, curveSteepness));
        addToBatch(protocolConfig, setCurveSteepnessCall);

        // 13. Set IRP
        console2.log("13. ProtocolConfig.setConfig(IRP)");
        bytes memory setIrpCall = abi.encodeCall(IProtocolConfig.setConfig, (ProtocolConfigLib.IRP, irp));
        addToBatch(protocolConfig, setIrpCall);

        // 14. Set TRANCHE_SHARE_VARIANT
        console2.log("14. ProtocolConfig.setConfig(TRANCHE_SHARE_VARIANT)");
        bytes memory setTrancheShareVariantCall =
            abi.encodeCall(IProtocolConfig.setConfig, (ProtocolConfigLib.TRANCHE_SHARE_VARIANT, trancheShareVariant));
        addToBatch(protocolConfig, setTrancheShareVariantCall);

        console2.log("");

        // ====================================================================
        // BATCH 4: USD3 & sUSD3 CONFIGURATION (4 operations)
        // ====================================================================
        console2.log("=== [4/4] USD3 & sUSD3 Configuration ===");

        // 15. Set USD3 min deposit
        console2.log("15. USD3.setMinDeposit(", minDeposit / 1e6, "USDC)");
        bytes memory setMinDepositCall = abi.encodeWithSignature("setMinDeposit(uint256)", minDeposit);
        addToBatch(usd3, setMinDepositCall);

        // 16. Disable USD3 whitelist
        console2.log("16. USD3.setWhitelistEnabled(false)");
        bytes memory setWhitelistCall = abi.encodeWithSignature("setWhitelistEnabled(bool)", false);
        addToBatch(usd3, setWhitelistCall);

        // 17. Whitelist HelperV2 for USD3 3rd party deposits
        console2.log("17. USD3.setDepositorWhitelist(HelperV2, true)");
        bytes memory setUsd3DepositorCall =
            abi.encodeWithSignature("setDepositorWhitelist(address,bool)", helperV2, true);
        addToBatch(usd3, setUsd3DepositorCall);

        // 18. Whitelist HelperV2 for sUSD3 3rd party deposits
        console2.log("18. sUSD3.setDepositorWhitelist(HelperV2, true)");
        bytes memory setSusd3DepositorCall =
            abi.encodeWithSignature("setDepositorWhitelist(address,bool)", helperV2, true);
        addToBatch(susd3, setSusd3DepositorCall);

        console2.log("");

        // ====================================================================
        // EXECUTE BATCH
        // ====================================================================
        console2.log("=== Batch Summary ===");
        console2.log("Total operations: 14");
        console2.log("  - MorphoCredit/CreditLine: 2 operations");
        console2.log("  - ProtocolConfig: 8 operations");
        console2.log("  - USD3 & sUSD3: 4 operations");
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
            console2.log("3. All 14 operations will execute atomically");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    /**
     * @notice Alternative entry point with default simulation mode
     */
    function run() external {
        this.run(false);
    }

    /**
     * @notice Check if base fee is acceptable
     * @return True if base fee is below limit
     */
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
