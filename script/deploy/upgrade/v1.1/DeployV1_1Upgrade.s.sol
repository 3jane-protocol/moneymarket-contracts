// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

// Phase 1: Deploy new contracts
import {DeployJane} from "./01_DeployJane.s.sol";
import {DeployMarkdownController} from "./02_DeployMarkdownController.s.sol";
import {DeployRewardsDistributor} from "./03_DeployRewardsDistributor.s.sol";
import {DeployHelperV2} from "./05_DeployHelperV2.s.sol";

// Phase 2: Upgrade existing contracts
import {UpgradeMorphoCredit} from "./10_UpgradeMorphoCredit.s.sol";
import {UpgradeIRM} from "./11_UpgradeIRM.s.sol";
import {UpgradeUSD3} from "./12_UpgradeUSD3.s.sol";
import {UpgradeSUSD3} from "./13_UpgradeSUSD3.s.sol";

// Phase 3: Configure contracts - MUST be done via Safe multisig
// Use script/operations/ConfigureV1_1Safe.s.sol instead of direct execution

/**
 * @title DeployV1_1Upgrade
 * @notice Orchestration script for v1.1 protocol upgrade
 * @dev Executes all deployment, upgrade, and configuration scripts in sequence
 *
 *      Execution Phases:
 *      Phase 1: Deploy new contracts (Jane, MarkdownController, RewardsDistributor, HelperV2)
 *      Phase 2: Deploy new implementations (MorphoCredit, IRM, USD3, sUSD3)
 *      Phase 3: Configure contracts via Safe multisig (use ConfigureV1_1Safe.s.sol)
 *
 *      ⚠️ CRITICAL:
 *      - This script only executes Phase 1 & 2 (deployments)
 *      - Phase 3 MUST be done via Safe multisig using script/operations/ConfigureV1_1Safe.s.sol
 *      - Phase 4-7 (upgrades) go through TimelockController via Safe multisig
 *
 *      Environment Variables Required:
 *      - OWNER_ADDRESS: Protocol owner address
 *      - DISTRIBUTOR_ADDRESS: Jane token distributor address
 *      - MORPHO_ADDRESS: MorphoCredit proxy address
 *      - USD3_ADDRESS: USD3 proxy address
 *      - SUSD3_ADDRESS: sUSD3 proxy address
 *      - IRM_ADDRESS: IRM proxy address
 *      - PROTOCOL_CONFIG: ProtocolConfig address
 *      - USDC_ADDRESS: USDC token address
 *      - WAUSDC_ADDRESS: Wrapped Aave USDC address
 *      - MARKET_ID: Morpho market identifier
 *      - Optional: FULL_MARKDOWN_DURATION, SUBORDINATED_DEBT_CAP_BPS, SUBORDINATED_DEBT_FLOOR_BPS, MAX_LM_MINTABLE
 */
contract DeployV1_1Upgrade is Script {
    struct DeployedAddresses {
        address jane;
        address markdownController;
        address rewardsDistributor;
        address helperV2;
        address morphoCreditImpl;
        address irmImpl;
        address usd3Impl;
        address susd3Impl;
    }

    function run() external returns (DeployedAddresses memory deployed) {
        console.log("========================================");
        console.log("V1.1 PROTOCOL UPGRADE DEPLOYMENT");
        console.log("========================================");
        console.log("");

        // ====================================================================
        // PHASE 1: DEPLOY NEW CONTRACTS
        // ====================================================================
        console.log("========================================");
        console.log("PHASE 1: DEPLOY NEW CONTRACTS");
        console.log("========================================");
        console.log("");

        console.log("1/4: Deploying Jane token...");
        DeployJane deployJane = new DeployJane();
        deployed.jane = deployJane.run();
        console.log("  Deployed at:", deployed.jane);
        console.log("");

        console.log("2/4: Deploying MarkdownController...");
        DeployMarkdownController deployMarkdownController = new DeployMarkdownController();
        deployed.markdownController = deployMarkdownController.run();
        console.log("  Deployed at:", deployed.markdownController);
        console.log("");

        console.log("3/4: Deploying RewardsDistributor...");
        DeployRewardsDistributor deployRewardsDistributor = new DeployRewardsDistributor();
        deployed.rewardsDistributor = deployRewardsDistributor.run();
        console.log("  Deployed at:", deployed.rewardsDistributor);
        console.log("");

        console.log("4/4: Deploying HelperV2...");
        DeployHelperV2 deployHelperV2 = new DeployHelperV2();
        deployed.helperV2 = deployHelperV2.run();
        console.log("  Deployed at:", deployed.helperV2);
        console.log("");

        console.log("Phase 1 complete");
        console.log("");

        // ====================================================================
        // PHASE 2: DEPLOY NEW IMPLEMENTATIONS (NO UPGRADES)
        // ====================================================================
        console.log("========================================");
        console.log("PHASE 2: DEPLOY NEW IMPLEMENTATIONS");
        console.log("========================================");
        console.log("NOTE: This phase ONLY deploys implementations");
        console.log("NOTE: Actual upgrades MUST be scheduled via TimelockController");
        console.log("");

        console.log("1/4: Deploying new MorphoCredit implementation...");
        UpgradeMorphoCredit upgradeMorphoCredit = new UpgradeMorphoCredit();
        deployed.morphoCreditImpl = upgradeMorphoCredit.run();
        console.log("  New implementation:", deployed.morphoCreditImpl);
        console.log("");

        console.log("2/4: Deploying new IRM implementation...");
        UpgradeIRM upgradeIRM = new UpgradeIRM();
        deployed.irmImpl = upgradeIRM.run();
        console.log("  New implementation:", deployed.irmImpl);
        console.log("");

        console.log("3/4: Deploying new USD3 implementation...");
        UpgradeUSD3 upgradeUSD3 = new UpgradeUSD3();
        deployed.usd3Impl = upgradeUSD3.run();
        console.log("  New implementation:", deployed.usd3Impl);
        console.log("");

        console.log("4/4: Deploying new sUSD3 implementation...");
        UpgradeSUSD3 upgradeSUSD3 = new UpgradeSUSD3();
        deployed.susd3Impl = upgradeSUSD3.run();
        console.log("  New implementation:", deployed.susd3Impl);
        console.log("");

        console.log("Phase 2 complete - implementations deployed");
        console.log("");

        // ====================================================================
        // PHASE 3: CONFIGURE CONTRACTS (VIA SAFE MULTISIG)
        // ====================================================================
        console.log("========================================");
        console.log("PHASE 3: CONFIGURE CONTRACTS");
        console.log("========================================");
        console.log("");
        console.log(unicode"⚠️  IMPORTANT: Phase 3 configuration MUST be done via Safe multisig");
        console.log("");
        console.log("This orchestration script ONLY deploys new contracts (Phase 1)");
        console.log("and new implementations (Phase 2).");
        console.log("");
        console.log("Phase 3 configuration modifies existing protocol state and");
        console.log("requires multisig approval for security.");
        console.log("");
        console.log("To execute Phase 3 configuration:");
        console.log("  1. Run simulation:");
        console.log("     yarn script:forge script/operations/ConfigureV1_1Safe.s.sol \\");
        console.log("       --sig \"run(bool)\" false --sender $OWNER_ADDRESS");
        console.log("");
        console.log("  2. Propose to Safe:");
        console.log("     yarn script:forge script/operations/ConfigureV1_1Safe.s.sol \\");
        console.log("       --sig \"run(bool)\" true --sender $OWNER_ADDRESS --broadcast");
        console.log("");
        console.log("  3. Approve in Safe UI");
        console.log("  4. Execute once threshold reached");
        console.log("");
        console.log("Phase 3 will batch 10 operations atomically:");
        console.log("  - Jane: Grant MINTER_ROLE, set MarkdownController, transfer ownership (x2)");
        console.log("  - MorphoCredit: Set HelperV2");
        console.log("  - CreditLine: Set MarkdownController");
        console.log("  - ProtocolConfig: Set 4 configuration values");
        console.log("");

        // ====================================================================
        // DEPLOYMENT SUMMARY
        // ====================================================================
        console.log("========================================");
        console.log("DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("");

        console.log("New Contracts:");
        console.log("  Jane:                ", deployed.jane);
        console.log("  MarkdownController:  ", deployed.markdownController);
        console.log("  RewardsDistributor:  ", deployed.rewardsDistributor);
        console.log("  HelperV2:            ", deployed.helperV2);
        console.log("");

        console.log("New Implementations:");
        console.log("  MorphoCredit:        ", deployed.morphoCreditImpl);
        console.log("  IRM:                 ", deployed.irmImpl);
        console.log("  USD3:                ", deployed.usd3Impl);
        console.log("  sUSD3:               ", deployed.susd3Impl);
        console.log("");

        // ====================================================================
        // NEXT STEPS: TIMELOCK WORKFLOW
        // ====================================================================
        console.log("========================================");
        console.log("CRITICAL NEXT STEPS - TIMELOCK WORKFLOW");
        console.log("========================================");
        console.log("");
        console.log("All proxy upgrades MUST go through TimelockController:");
        console.log("  Timelock: 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2");
        console.log("  Min delay: 2 days");
        console.log("");

        console.log("=== RECOMMENDED APPROACH: Combined Scripts ===");
        console.log("");
        console.log("STEP 1: Schedule all 4 upgrades at once");
        console.log("  yarn script:forge script/operations/ScheduleAllUpgrades.s.sol \\");
        console.log("    --sig \"run(address,address,address,address,bool)\" \\");
        console.log("    ", deployed.morphoCreditImpl, "\\");
        console.log("    ", deployed.irmImpl, "\\");
        console.log("    ", deployed.usd3Impl, "\\");
        console.log("    ", deployed.susd3Impl, "false");
        console.log("");
        console.log("  Returns: Single operation ID for all 4 upgrades");
        console.log("");

        console.log("STEP 2: Wait 2 days (172800 seconds)");
        console.log("");

        console.log("STEP 3: Execute all 4 upgrades at once");
        console.log("  yarn script:forge script/operations/ExecuteAllUpgrades.s.sol \\");
        console.log("    --sig \"run(bytes32,uint256,bool)\" \\");
        console.log("    <operationId> <prevUnlockTime> false");
        console.log("");
        console.log("  This creates a Safe batch with 7 operations:");
        console.log("    1. USD3.setPerformanceFee(0)");
        console.log("    2. USD3.setProfitMaxUnlockTime(0)");
        console.log("    3. USD3.report() [BEFORE upgrade]");
        console.log("    4. Timelock.executeBatch() -> Upgrades all 4 implementations + USD3.reinitialize()");
        console.log("    5. USD3.report() [AFTER reinitialize]");
        console.log("    6. USD3.syncTrancheShare() [Sets performanceFee to TRANCHE_SHARE_VARIANT]");
        console.log("    7. USD3.setProfitMaxUnlockTime(prevUnlockTime)");
        console.log("");

        console.log("=== ALTERNATIVE: Individual Scripts ===");
        console.log("");
        console.log("For granular control, use individual scheduling/execution scripts:");
        console.log("  - ScheduleMorphoCreditUpgrade.s.sol");
        console.log("  - ScheduleIRMUpgrade.s.sol");
        console.log("  - ScheduleUSD3AtomicBatch.s.sol");
        console.log("  - ScheduleSUSD3Upgrade.s.sol");
        console.log("");
        console.log("See V1_1_DEPLOYMENT_COMMANDS.md for detailed instructions");
        console.log("");

        console.log("=== IMPORTANT NOTES ===");
        console.log("");
        console.log("- Combined approach: 1 operation ID to track (simpler)");
        console.log("- Individual approach: 4 operation IDs to track (more control)");
        console.log("- USD3 atomic batch prevents user losses during waUSDC -> USDC migration");
        console.log("- All 4 implementations upgrade atomically in Safe batch");
        console.log("- Test reference: test/forge/usd3/integration/USD3UpgradeMultisigBatch.t.sol");
        console.log("");

        return deployed;
    }
}
