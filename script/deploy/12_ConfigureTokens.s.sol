// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IUSD3 {
    function setSUSD3(address _sUSD3) external;
    function setPerformanceFeeRecipient(address recipient) external;
    function syncTrancheShare() external;
    function setWhitelistEnabled(bool _enabled) external;
    function setMinDeposit(uint256 _minDeposit) external;
    function setMinCommitmentTime(uint256 _minCommitmentTime) external;
    function setDepositorWhitelist(address _depositor, bool _allowed) external;
}

contract ConfigureTokens is Script {
    function run() external {
        // Load deployed addresses from env variables
        address usd3 = vm.envAddress("USD3_ADDRESS");
        address susd3 = vm.envAddress("SUSD3_ADDRESS");
        address helper = vm.envAddress("HELPER_ADDRESS");
        address owner = vm.envAddress("OWNER_ADDRESS");

        // Load configuration parameters (with defaults for testnet)
        uint256 minDeposit = vm.envOr("MIN_DEPOSIT", uint256(100e6)); // 100 USDC default
        uint256 minCommitmentTime = vm.envOr("MIN_COMMITMENT_TIME", uint256(7 days)); // 7 days default
        bool whitelistEnabled = vm.envOr("WHITELIST_ENABLED", false); // Disabled by default for testnet

        console.log("Configuring token relationships...");
        console.log("  USD3:", usd3);
        console.log("  sUSD3:", susd3);
        console.log("  Helper:", helper);
        console.log("  Owner/Management:", owner);

        // Broadcast as the owner/management address
        vm.startBroadcast(owner);

        // Configure USD3
        console.log("\nConfiguring USD3...");
        IUSD3(usd3).setSUSD3(susd3);
        console.log("  - Set sUSD3 address");

        IUSD3(usd3).setPerformanceFeeRecipient(susd3);
        console.log("  - Set performance fee recipient to sUSD3");

        // Sync tranche share in USD3 (reads from ProtocolConfig)
        IUSD3(usd3).syncTrancheShare();
        console.log("  - Synced tranche share in USD3");

        // Configure deposit parameters
        IUSD3(usd3).setMinDeposit(minDeposit);
        console.log("  - Set minimum deposit to", minDeposit / 1e6, "USDC");

        IUSD3(usd3).setMinCommitmentTime(minCommitmentTime);
        console.log("  - Set minimum commitment time to", minCommitmentTime / 1 days, "days");

        // Configure whitelist
        IUSD3(usd3).setWhitelistEnabled(whitelistEnabled);
        console.log("  - Whitelist enabled:", whitelistEnabled);

        // Add Helper to depositor whitelist (allows it to extend commitments)
        IUSD3(usd3).setDepositorWhitelist(helper, true);
        console.log("  - Added Helper to depositor whitelist");

        // Configure sUSD3 with same parameters
        console.log("\nConfiguring sUSD3...");
        IUSD3(susd3).setMinDeposit(minDeposit);
        console.log("  - Set minimum deposit to", minDeposit / 1e6, "USDC");

        IUSD3(susd3).setMinCommitmentTime(minCommitmentTime);
        console.log("  - Set minimum commitment time to", minCommitmentTime / 1 days, "days");

        IUSD3(susd3).setWhitelistEnabled(whitelistEnabled);
        console.log("  - Whitelist enabled:", whitelistEnabled);

        IUSD3(susd3).setDepositorWhitelist(helper, true);
        console.log("  - Added Helper to depositor whitelist");

        vm.stopBroadcast();

        console.log("\nToken configuration complete!");

        // Don't save to file during DeployAll - DeployAll handles persistence
    }

    function _loadAddress(string memory key) internal view returns (address) {
        string memory chainId = vm.toString(block.chainid);
        string memory deploymentsPath = string.concat("deployments/", chainId, "/latest.json");
        string memory json = vm.readFile(deploymentsPath);
        return vm.parseJsonAddress(json, string.concat(".", key));
    }

    function _updateDeploymentStatus() internal {
        string memory chainId = vm.toString(block.chainid);
        string memory deploymentsPath = string.concat("deployments/", chainId, "/");
        string memory latestFile = string.concat(deploymentsPath, "latest.json");

        // Read existing deployment data
        string memory existingJson = vm.readFile(latestFile);

        // Create updated JSON with configuration status
        string memory json = "deployment";

        // Copy all existing addresses and data
        vm.serializeAddress(json, "timelock", vm.parseJsonAddress(existingJson, ".timelock"));
        vm.serializeAddress(json, "protocolConfig", vm.parseJsonAddress(existingJson, ".protocolConfig"));
        vm.serializeAddress(json, "protocolConfigImpl", vm.parseJsonAddress(existingJson, ".protocolConfigImpl"));
        vm.serializeAddress(json, "morphoCredit", vm.parseJsonAddress(existingJson, ".morphoCredit"));
        vm.serializeAddress(json, "morphoCreditImpl", vm.parseJsonAddress(existingJson, ".morphoCreditImpl"));
        vm.serializeAddress(json, "markdownManager", vm.parseJsonAddress(existingJson, ".markdownManager"));
        vm.serializeAddress(json, "creditLine", vm.parseJsonAddress(existingJson, ".creditLine"));
        vm.serializeAddress(json, "insuranceFund", vm.parseJsonAddress(existingJson, ".insuranceFund"));
        vm.serializeAddress(json, "adaptiveCurveIrm", vm.parseJsonAddress(existingJson, ".adaptiveCurveIrm"));

        // Copy token addresses if they exist
        try vm.parseJsonAddress(existingJson, ".waUSDC") returns (address waUSDC) {
            vm.serializeAddress(json, "waUSDC", waUSDC);
        } catch {}

        try vm.parseJsonAddress(existingJson, ".usd3") returns (address usd3) {
            vm.serializeAddress(json, "usd3", usd3);
        } catch {}

        try vm.parseJsonAddress(existingJson, ".susd3") returns (address susd3) {
            vm.serializeAddress(json, "susd3", susd3);
        } catch {}

        try vm.parseJsonBytes32(existingJson, ".marketId") returns (bytes32 marketId) {
            vm.serializeBytes32(json, "marketId", marketId);
        } catch {}

        // Add configuration status
        string memory finalJson = vm.serializeBool(json, "tokensConfigured", true);

        // Write updated JSON
        vm.writeJson(finalJson, latestFile);

        console.log("Configuration status saved to deployment file");
    }
}
