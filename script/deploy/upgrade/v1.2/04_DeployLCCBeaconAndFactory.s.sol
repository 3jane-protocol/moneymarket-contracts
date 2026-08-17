// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {UpgradeableBeacon} from "../../../../lib/openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {LCCVaultFactory} from "../../../../src/lcc/LCCVaultFactory.sol";
import {ILCCVault} from "../../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCWiringCheck} from "../../../utils/LCCWiringCheck.sol";
import {SevenDayTimelockCheck} from "../../../utils/SevenDayTimelockCheck.sol";

/**
 * @title DeployLCCBeaconAndFactory v1.2
 * @notice Deploy the timelock-owned LCC beacon and Safe-owned LCCVaultFactory.
 * @dev This script intentionally does not import LCCVault so LCCVaultFactory compiles at its canonical optimizer
 *      settings.
 *
 *      Usage:
 *      LCC_VAULT_IMPL=<address> SEVEN_DAY_TIMELOCK=<address> forge script \
 *        script/deploy/upgrade/v1.2/04_DeployLCCBeaconAndFactory.s.sol \
 *        --rpc-url mainnet --broadcast --verify
 */
contract DeployLCCBeaconAndFactory is Script, LCCWiringCheck, SevenDayTimelockCheck {
    address internal constant USD3_PROXY = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address internal constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    function run() external returns (address beaconAddress, address factoryAddress) {
        address lccVaultImpl = vm.envAddress("LCC_VAULT_IMPL");
        require(lccVaultImpl != address(0), "LCC_VAULT_IMPL not set");
        require(lccVaultImpl.code.length > 0, "LCC_VAULT_IMPL has no code");
        ILCCVault.AssetConfig memory config = _requireLCCWiring(lccVaultImpl, USD3_PROXY);
        require(config.treasury != address(0), "LCC_VAULT_IMPL treasury not set");

        address sevenDayTimelock = vm.envAddress("SEVEN_DAY_TIMELOCK");
        require(sevenDayTimelock != address(0), "SEVEN_DAY_TIMELOCK not set");
        require(sevenDayTimelock.code.length > 0, "SEVEN_DAY_TIMELOCK has no code");
        _requireSevenDayTimelock(sevenDayTimelock);

        console2.log("=== Deploying v1.2 LCC Beacon and Factory ===");
        console2.log("LCCVault implementation:", lccVaultImpl);
        console2.log("Beacon owner (7-day timelock):", sevenDayTimelock);
        console2.log("Factory owner (Safe):", SAFE_ADDRESS);
        console2.log("");

        vm.startBroadcast();

        UpgradeableBeacon beacon = new UpgradeableBeacon{salt: "3jane"}(lccVaultImpl, sevenDayTimelock);
        LCCVaultFactory factory = new LCCVaultFactory{salt: "3jane"}(SAFE_ADDRESS, address(beacon));
        beaconAddress = address(beacon);
        factoryAddress = address(factory);

        vm.stopBroadcast();

        require(beacon.implementation() == lccVaultImpl, "LCC beacon implementation mismatch");
        require(beacon.owner() == sevenDayTimelock, "LCC beacon owner mismatch");
        require(factory.owner() == SAFE_ADDRESS, "LCC factory owner mismatch");
        require(factory.getRoleMemberCount(factory.OWNER_ROLE()) == 1, "LCC factory owner count mismatch");
        require(factory.getRoleMemberCount(factory.DEFAULT_ADMIN_ROLE()) == 0, "LCC factory default admin held");
        require(factory.getRoleAdmin(factory.LISTER_ROLE()) == factory.OWNER_ROLE(), "LCC lister admin mismatch");
        require(factory.getRoleAdmin(factory.BOUNCER_ROLE()) == factory.OWNER_ROLE(), "LCC bouncer admin mismatch");
        require(factory.getRoleAdmin(factory.GUARDIAN_ROLE()) == factory.OWNER_ROLE(), "LCC guardian admin mismatch");
        require(
            factory.getRoleAdmin(factory.DEPOSIT_OPERATOR_ROLE()) == factory.OWNER_ROLE(),
            "LCC deposit operator admin mismatch"
        );
        require(factory.whitelistEnabled(), "LCC factory whitelist disabled at deploy");
        require(factory.oneVaultPolicyEnabled(), "LCC factory one-vault policy disabled at deploy");
        require(factory.beacon() == beaconAddress, "LCC factory beacon mismatch");
        require(factory.numVaults() == 0, "LCC factory registry not empty");

        console2.log("=== LCC Beacon and Factory Deployed ===");
        console2.log("Beacon:", beaconAddress);
        console2.log("Factory:", factoryAddress);
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Record LCC_FACTORY=%s", factoryAddress);
        console2.log("  2. Safe grants LISTER_ROLE, BOUNCER_ROLE, and GUARDIAN_ROLE");
        console2.log("  3. Grant DEPOSIT_OPERATOR_ROLE only to consent-verifying adapters or closed operators");
        console2.log("  4. Never grant DEPOSIT_OPERATOR_ROLE to a generic arbitrary-calldata router");
        console2.log("  5. Safe sets the initial depositor whitelist and optional admissions module");
        console2.log("  6. Route all beacon upgrades through the 7-day timelock");
        console2.log("  7. After 06_ExecuteUSD3v12Upgrade.s.sol executes, create vaults with CreateLCCVaultSafe.s.sol");

        return (beaconAddress, factoryAddress);
    }
}
