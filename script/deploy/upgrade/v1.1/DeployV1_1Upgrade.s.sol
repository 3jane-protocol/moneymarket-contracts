// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

// Phase 1: Deploy new contracts
import {DeployJane} from "./01_DeployJane.s.sol";
import {DeployMarkdownController} from "./02_DeployMarkdownController.s.sol";
import {DeployRewardsDistributor} from "./03_DeployRewardsDistributor.s.sol";
import {DeployPYTLocker} from "./04_DeployPYTLocker.s.sol";
import {DeployHelperV2} from "./05_DeployHelperV2.s.sol";

// Phase 2: Upgrade existing contracts
import {UpgradeMorphoCredit} from "./10_UpgradeMorphoCredit.s.sol";
import {UpgradeIRM} from "./11_UpgradeIRM.s.sol";
import {UpgradeUSD3} from "./12_UpgradeUSD3.s.sol";
import {UpgradeSUSD3} from "./13_UpgradeSUSD3.s.sol";

// Phase 3: Configure contracts
import {ConfigureJane} from "./20_ConfigureJane.s.sol";
import {ConfigureMorphoCredit} from "./21_ConfigureMorphoCredit.s.sol";
import {ConfigureProtocolConfig} from "./22_ConfigureProtocolConfig.s.sol";

/**
 * @title DeployV1_1Upgrade
 * @notice Orchestration script for v1.1 protocol upgrade
 * @dev Executes all deployment, upgrade, and configuration scripts in sequence
 *
 *      Execution Phases:
 *      Phase 1: Deploy new contracts (Jane, MarkdownController, RewardsDistributor, PYTLocker, HelperV2)
 *      Phase 2: Upgrade existing contracts (MorphoCredit, IRM, USD3, sUSD3)
 *      Phase 3: Configure contracts (Jane roles, MorphoCredit helper, ProtocolConfig)
 *
 *      ⚠️ CRITICAL: After running this script, execute USD3MultisigBatch separately
 *                   to generate the atomic multisig transaction for USD3 upgrade.
 *
 *      Environment Variables Required:
 *      - OWNER: Protocol owner address
 *      - MORPHO_ADDRESS: MorphoCredit proxy address
 *      - USD3_ADDRESS: USD3 proxy address
 *      - SUSD3_ADDRESS: sUSD3 proxy address
 *      - IRM_ADDRESS: IRM proxy address
 *      - PROTOCOL_CONFIG: ProtocolConfig address
 *      - USDC_ADDRESS: USDC token address
 *      - WAUSDC_ADDRESS: Wrapped Aave USDC address
 *      - MARKET_ID: Morpho market identifier
 *      - Optional: FULL_MARKDOWN_DURATION, SUBORDINATED_DEBT_CAP_BPS, SUBORDINATED_DEBT_FLOOR_BPS
 */
contract DeployV1_1Upgrade is Script {
    struct DeployedAddresses {
        address jane;
        address markdownController;
        address rewardsDistributor;
        address pytLocker;
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

        console.log("1/5: Deploying Jane token...");
        DeployJane deployJane = new DeployJane();
        deployed.jane = deployJane.run();
        console.log("  Deployed at:", deployed.jane);
        console.log("");

        console.log("2/5: Deploying MarkdownController...");
        DeployMarkdownController deployMarkdownController = new DeployMarkdownController();
        deployed.markdownController = deployMarkdownController.run();
        console.log("  Deployed at:", deployed.markdownController);
        console.log("");

        console.log("3/5: Deploying RewardsDistributor...");
        DeployRewardsDistributor deployRewardsDistributor = new DeployRewardsDistributor();
        deployed.rewardsDistributor = deployRewardsDistributor.run();
        console.log("  Deployed at:", deployed.rewardsDistributor);
        console.log("");

        console.log("4/5: Deploying PYTLocker...");
        DeployPYTLocker deployPYTLocker = new DeployPYTLocker();
        deployed.pytLocker = deployPYTLocker.run();
        console.log("  Deployed at:", deployed.pytLocker);
        console.log("");

        console.log("5/5: Deploying HelperV2...");
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
        // PHASE 3: CONFIGURE CONTRACTS
        // ====================================================================
        console.log("========================================");
        console.log("PHASE 3: CONFIGURE CONTRACTS");
        console.log("========================================");
        console.log("");

        console.log("1/3: Configuring Jane token...");
        ConfigureJane configureJane = new ConfigureJane();
        configureJane.run();
        console.log("  Jane configuration complete");
        console.log("");

        console.log("2/3: Configuring MorphoCredit...");
        ConfigureMorphoCredit configureMorphoCredit = new ConfigureMorphoCredit();
        configureMorphoCredit.run();
        console.log("  MorphoCredit configuration complete");
        console.log("");

        console.log("3/3: Configuring ProtocolConfig...");
        ConfigureProtocolConfig configureProtocolConfig = new ConfigureProtocolConfig();
        configureProtocolConfig.run();
        console.log("  ProtocolConfig configuration complete");
        console.log("");

        console.log("Phase 3 complete");
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
        console.log("  PYTLocker:           ", deployed.pytLocker);
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

        console.log("=== STEP 1: SCHEDULE UPGRADES (via Safe multisig) ===");
        console.log("");
        console.log("1a. Schedule MorphoCredit upgrade:");
        console.log("  yarn script:forge script/operations/ScheduleMorphoCreditUpgrade.s.sol \\");
        console.log("    --sig \"run(address,bool)\" \\");
        console.log("    ", deployed.morphoCreditImpl, "false");
        console.log("");

        console.log("1b. Schedule IRM upgrade:");
        console.log("  yarn script:forge script/operations/ScheduleIRMUpgrade.s.sol \\");
        console.log("    --sig \"run(address,bool)\" \\");
        console.log("    ", deployed.irmImpl, "false");
        console.log("");

        console.log("1c. Schedule USD3 ATOMIC BATCH (8 operations):");
        console.log("  CRITICAL: All 8 operations execute atomically!");
        console.log("  yarn script:forge script/operations/ScheduleUSD3AtomicBatch.s.sol \\");
        console.log("    --sig \"run(address,uint16,uint256,bool)\" \\");
        console.log("    ", deployed.usd3Impl, "<prevFee> <prevUnlockTime> false");
        console.log("  Batch operations:");
        console.log("    1. setPerformanceFee(0)");
        console.log("    2. setProfitMaxUnlockTime(0)");
        console.log("    3. report() [BEFORE upgrade]");
        console.log("    4. ProxyAdmin.upgrade()");
        console.log("    5. report() [AFTER upgrade]");
        console.log("    6. reinitialize()");
        console.log("    7. syncTrancheShare()");
        console.log("    8. setPerformanceFee(prevFee)");
        console.log("");

        console.log("=== STEP 2: WAIT FOR TIMELOCK DELAY ===");
        console.log("");
        console.log("Wait 2 days (172800 seconds) after scheduling");
        console.log("");

        console.log("=== STEP 3: EXECUTE UPGRADES (anyone can execute) ===");
        console.log("");
        console.log("Use ExecuteTimelockViaSafe.s.sol with operation IDs from Step 1");
        console.log("  yarn script:forge script/operations/ExecuteTimelockViaSafe.s.sol \\");
        console.log("    --sig \"run(bytes32,bool)\" \\");
        console.log("    <operationId> false");
        console.log("");

        console.log("=== STEP 4: SCHEDULE sUSD3 UPGRADE (AFTER USD3 completes) ===");
        console.log("");
        console.log("4a. Schedule sUSD3 upgrade:");
        console.log("  yarn script:forge script/operations/ScheduleSUSD3Upgrade.s.sol \\");
        console.log("    --sig \"run(address,bool)\" \\");
        console.log("    ", deployed.susd3Impl, "false");
        console.log("");
        console.log("4b. Wait 2 days");
        console.log("");
        console.log("4c. Execute sUSD3 upgrade via ExecuteTimelockViaSafe.s.sol");
        console.log("");

        console.log("=== IMPORTANT NOTES ===");
        console.log("");
        console.log("- Save all operation IDs from scheduling scripts");
        console.log("- USD3 atomic batch prevents user losses during waUSDC -> USDC migration");
        console.log("- sUSD3 MUST be upgraded AFTER USD3 completes");
        console.log("- Test reference: test/forge/usd3/integration/USD3UpgradeMultisigBatch.t.sol");
        console.log("");

        return deployed;
    }
}
