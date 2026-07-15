// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {KeeperRelayer} from "../../../../src/usd3/KeeperRelayer.sol";
import {IUSD3} from "../../../../src/usd3/interfaces/IUSD3.sol";

/// @title DeployKeeperRelayer
/// @notice Deploys the KeeperRelayer for the mainnet USD3/sUSD3 strategy pair.
contract DeployKeeperRelayer is Script {
    address private constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address private constant SUSD3 = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;
    address private constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address private constant THREE_JANE_DEPLOYER = 0x1226858E04b9d077258F153275613734421cD06B;

    function run() external returns (address) {
        require(USD3.code.length > 0, "USD3 has no code");

        address linkedSusd3 = IUSD3(USD3).sUSD3();
        require(linkedSusd3 == SUSD3, "USD3 sUSD3 link is not canonical sUSD3");
        address[] memory keepers = new address[](2);
        keepers[0] = THREE_JANE_DEPLOYER;
        keepers[1] = DEFAULT_SAFE;

        console2.log("=== Deploying KeeperRelayer ===");
        console2.log("USD3:", USD3);
        console2.log("On-chain sUSD3:", linkedSusd3);
        console2.log("Keeper[0] (3Jane deployer):", keepers[0]);
        console2.log("Keeper[1] (protocol Safe):", keepers[1]);
        console2.log("");

        vm.startBroadcast();

        KeeperRelayer relayer = new KeeperRelayer{salt: "3jane"}(USD3, keepers);

        vm.stopBroadcast();

        console2.log("=== KeeperRelayer Deployed ===");
        console2.log("Address:", address(relayer));
        console2.log("sUSD3:", relayer.susd3());
        console2.log("3Jane deployer keeper:", relayer.keepers(THREE_JANE_DEPLOYER));
        console2.log("Protocol Safe keeper:", relayer.keepers(DEFAULT_SAFE));
        console2.log("");

        _logHealthCheck("USD3 health check", relayer, USD3);
        _logHealthCheck("sUSD3 health check", relayer, linkedSusd3);

        console2.log("");
        console2.log("Next steps:");
        console2.log("1. export KEEPER_RELAYER=%s", address(relayer));
        console2.log(
            "2. yarn script:forge script/deploy/upgrade/v1.1.4-keeper/02_SetRelayerKeeperSafe.s.sol --rpc-url $MAINNET_RPC_URL --sig 'run(bool)' false"
        );

        return address(relayer);
    }

    function _logHealthCheck(string memory label, KeeperRelayer relayer, address strategy) private view {
        (uint32 profitLimitRatio, uint16 lossLimitRatio, bool doHealthCheck) = relayer.healthCheck(strategy);

        console2.log(label);
        console2.log("  strategy:", strategy);
        console2.log("  profit limit ratio:", profitLimitRatio);
        console2.log("  loss limit ratio:", lossLimitRatio);
        console2.log("  enabled:", doHealthCheck);
    }
}
