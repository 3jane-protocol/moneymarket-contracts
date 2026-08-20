// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Script, console2, VmSafe} from "forge-std/Script.sol";
import {UpgradeableBeacon} from "../../../lib/openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {LCCVaultFactory} from "../../../src/lcc/LCCVaultFactory.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCWiringCheck} from "../../utils/LCCWiringCheck.sol";
import {SevenDayTimelockCheck} from "../../utils/SevenDayTimelockCheck.sol";

/**
 * @title DeployLCCTestFactory
 * @notice Deploys an EOA-owned test factory that shares the canonical timelock-owned LCC beacon.
 * @dev The factory is intentionally separate from the production factory so test vaults never enter the production
 *      registry. Its depositor whitelist is disabled so the isolated vault is usable for public margin-deposit
 *      testing, while the one-vault policy remains enabled. Re-running with the same broadcaster, owner, beacon, and
 *      salt fails on the expected CREATE2 collision; use verify(address) to inspect the first deployment instead.
 *
 *      Usage:
 *      FOUNDRY_PROFILE=script LCC_BEACON=<address> PRODUCTION_LCC_FACTORY=<address> TEST_OWNER=<address> forge script \
 *        script/deploy/test/DeployLCCTestFactory.s.sol --rpc-url mainnet --broadcast --verify
 */
contract DeployLCCTestFactory is Script, LCCWiringCheck, SevenDayTimelockCheck {
    uint256 internal constant MAINNET_CHAIN_ID = 1;
    address internal constant USD3_PROXY = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    bytes32 internal constant TEST_FACTORY_SALT = bytes32("3JANE_LCC_TEST_FACTORY_V2");

    function run() external returns (address factoryAddress) {
        (address beaconAddress, address productionFactoryAddress, address testOwner) = _deploymentContext();

        console2.log("=== Deploying LCC Test Factory ===");
        console2.log("Shared LCC beacon:", beaconAddress);
        console2.log("Production LCC factory:", productionFactoryAddress);
        console2.log("Test factory owner:", testOwner);
        console2.log("CREATE2 salt:", vm.toString(TEST_FACTORY_SALT));
        console2.log("");

        _startExpectedBroadcast(testOwner);
        LCCVaultFactory factory = new LCCVaultFactory{salt: TEST_FACTORY_SALT}(testOwner, beaconAddress);
        factory.setWhitelistEnabled(false);
        factoryAddress = address(factory);
        vm.stopBroadcast();

        _requireFactory(factoryAddress, beaconAddress, productionFactoryAddress, testOwner);

        console2.log("=== LCC Test Factory Deployed ===");
        console2.log("Factory:", factoryAddress);
        console2.log("");
        console2.log("Next step:");
        console2.log("  Run CreateLCCTestVault.s.sol with LCC_TEST_FACTORY=%s", factoryAddress);
    }

    /// @notice Verifies a previously deployed test factory against the configured production topology.
    function verify(address factoryAddress) external view {
        (address beaconAddress, address productionFactoryAddress, address testOwner) = _deploymentContext();
        _requireFactory(factoryAddress, beaconAddress, productionFactoryAddress, testOwner);

        console2.log("=== LCC Test Factory Verification ===");
        console2.log("Factory:", factoryAddress);
        console2.log("PASS: distinct from production factory");
        console2.log("PASS: authority, policies, beacon, and empty registry match");
    }

    function _deploymentContext()
        internal
        view
        returns (address beaconAddress, address productionFactoryAddress, address testOwner)
    {
        require(block.chainid == MAINNET_CHAIN_ID, "LCC test deployment is mainnet-only");

        beaconAddress = vm.envAddress("LCC_BEACON");
        productionFactoryAddress = vm.envAddress("PRODUCTION_LCC_FACTORY");
        testOwner = vm.envAddress("TEST_OWNER");

        require(beaconAddress != address(0) && beaconAddress.code.length > 0, "LCC_BEACON invalid");
        require(
            productionFactoryAddress != address(0) && productionFactoryAddress.code.length > 0,
            "PRODUCTION_LCC_FACTORY invalid"
        );
        require(testOwner != address(0), "TEST_OWNER not set");

        LCCVaultFactory productionFactory = LCCVaultFactory(productionFactoryAddress);
        require(productionFactory.beacon() == beaconAddress, "Production factory beacon mismatch");
        require(productionFactory.whitelistEnabled(), "Production factory whitelist disabled");
        require(productionFactory.oneVaultPolicyEnabled(), "Production factory one-vault policy disabled");

        UpgradeableBeacon beacon = UpgradeableBeacon(beaconAddress);
        address beaconOwner = beacon.owner();
        require(beaconOwner != address(0) && beaconOwner.code.length > 0, "LCC beacon owner invalid");
        _requireSevenDayTimelock(beaconOwner);

        address implementation = beacon.implementation();
        require(implementation != address(0) && implementation.code.length > 0, "LCC beacon implementation invalid");
        ILCCVault.AssetConfig memory config = _requireLCCWiring(implementation, USD3_PROXY);
        require(config.treasury != address(0), "LCC implementation treasury not set");
    }

    function _requireFactory(
        address factoryAddress,
        address beaconAddress,
        address productionFactoryAddress,
        address testOwner
    ) internal view {
        require(factoryAddress != address(0) && factoryAddress.code.length > 0, "LCC test factory invalid");
        require(factoryAddress != productionFactoryAddress, "Test factory is production factory");

        LCCVaultFactory factory = LCCVaultFactory(factoryAddress);
        require(factory.owner() == testOwner, "LCC test factory owner mismatch");
        require(factory.isOwner(testOwner), "LCC test factory owner role missing");
        require(factory.getRoleMemberCount(factory.OWNER_ROLE()) == 1, "LCC test factory owner count mismatch");
        require(factory.getRoleMemberCount(factory.DEFAULT_ADMIN_ROLE()) == 0, "LCC test factory default admin held");
        require(factory.getRoleAdmin(factory.LISTER_ROLE()) == factory.OWNER_ROLE(), "LCC lister admin mismatch");
        require(factory.getRoleAdmin(factory.BOUNCER_ROLE()) == factory.OWNER_ROLE(), "LCC bouncer admin mismatch");
        require(factory.getRoleAdmin(factory.GUARDIAN_ROLE()) == factory.OWNER_ROLE(), "LCC guardian admin mismatch");
        require(
            factory.getRoleAdmin(factory.DEPOSIT_OPERATOR_ROLE()) == factory.OWNER_ROLE(),
            "LCC deposit operator admin mismatch"
        );
        require(!factory.whitelistEnabled(), "LCC test factory whitelist enabled");
        require(factory.oneVaultPolicyEnabled(), "LCC test factory one-vault policy disabled");
        require(factory.admissionsModule() == address(0), "LCC test factory admissions module set");
        require(factory.beacon() == beaconAddress, "LCC test factory beacon mismatch");
        require(factory.numVaults() == 0, "LCC test factory registry not empty");
    }

    function _startExpectedBroadcast(address expectedBroadcaster) internal {
        vm.startBroadcast(expectedBroadcaster);
        (VmSafe.CallerMode mode, address sender, address origin) = vm.readCallers();
        require(mode == VmSafe.CallerMode.RecurrentBroadcast, "Broadcast mode not active");
        require(sender == expectedBroadcaster && origin == expectedBroadcaster, "TEST_OWNER is not broadcaster");
    }
}
