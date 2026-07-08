// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {PYTLockerFactory} from "../../../../src/jane/PYTLockerFactory.sol";

/// @title DeployPYTLockerFactory v1.1.4
/// @notice Deploy the PYTLockerFactory for the v1.1.4 release.
/// @dev Uses OWNER_ADDRESS as the initial factory owner.
contract DeployPYTLockerFactory is Script {
    function run() external returns (address factoryAddress) {
        address owner = vm.envAddress("OWNER_ADDRESS");
        require(owner != address(0), "OWNER_ADDRESS not set");

        console2.log("=== Deploying v1.1.4 PYTLockerFactory ===");
        console2.log("");
        console2.log("Owner:", owner);
        console2.log("");

        vm.startBroadcast();

        PYTLockerFactory factory = new PYTLockerFactory{salt: "3jane"}(owner);
        factoryAddress = address(factory);

        vm.stopBroadcast();

        console2.log("PYTLockerFactory:", factoryAddress);
        console2.log("Factory owner:", factory.owner());
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Verify the contract on Etherscan");
        console2.log("  2. Save PYT_LOCKER_FACTORY=%s for v1.1.4 release records", factoryAddress);
        console2.log("  3. Owner can create lockers with createLocker(YT_ADDRESS)");

        return factoryAddress;
    }
}
