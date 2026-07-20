// SPDX-License-Identifier: GPL-2.0-or-later
/// @dev Exact pin keeps deployed NotificationVault bytecode canonical independent of installed solc versions.
pragma solidity =0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {
    ProxyAdmin,
    TransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {NotificationVault} from "../../../../src/usd3/NotificationVault.sol";
import {SevenDayTimelockCheck} from "../../../utils/SevenDayTimelockCheck.sol";

/**
 * @title DeployNotificationVault v1.2
 * @notice Deploy the NotificationVault implementation and an atomically initialized transparent proxy.
 * @dev This script intentionally does not import USD3.sol. NotificationVault must compile with solc 0.8.35 at the
 *      canonical Shanghai/999999 settings.
 *
 *      Usage:
 *      SEVEN_DAY_TIMELOCK=<address> NV_KEEPER=<address> NV_COOLDOWN_DURATION=<seconds> \
 *        NV_WITHDRAWAL_WINDOW=<seconds> forge script \
 *        script/deploy/upgrade/v1.2/02_DeployNotificationVault.s.sol \
 *        --rpc-url mainnet --broadcast --verify
 */
contract DeployNotificationVault is Script, SevenDayTimelockCheck {
    address internal constant USD3_PROXY = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address internal constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function run() external returns (address nvImpl, address nvProxy) {
        address sevenDayTimelock = vm.envAddress("SEVEN_DAY_TIMELOCK");
        require(sevenDayTimelock != address(0), "SEVEN_DAY_TIMELOCK not set");
        require(sevenDayTimelock.code.length > 0, "SEVEN_DAY_TIMELOCK has no code");
        _requireSevenDayTimelock(sevenDayTimelock);

        address keeper = vm.envAddress("NV_KEEPER");
        require(keeper != address(0), "NV_KEEPER not set");

        uint256 cooldownDuration = vm.envUint("NV_COOLDOWN_DURATION");
        require(cooldownDuration > 0, "NV_COOLDOWN_DURATION must be positive");
        require(cooldownDuration <= type(uint64).max, "NV_COOLDOWN_DURATION exceeds uint64");

        uint256 withdrawalWindow = vm.envUint("NV_WITHDRAWAL_WINDOW");
        require(withdrawalWindow > 0, "NV_WITHDRAWAL_WINDOW must be positive");
        require(withdrawalWindow <= type(uint64).max, "NV_WITHDRAWAL_WINDOW exceeds uint64");

        console2.log("=== Deploying v1.2 NotificationVault ===");
        console2.log("USD3 proxy:", USD3_PROXY);
        console2.log("Management (Safe):", SAFE_ADDRESS);
        console2.log("Keeper:", keeper);
        console2.log("ProxyAdmin owner (7-day timelock):", sevenDayTimelock);
        console2.log("");
        console2.log("=== WARNING: COOLDOWN CONFIG IS FIXED AT INITIALIZATION ===");
        console2.log("Cooldown duration (seconds):", cooldownDuration);
        console2.log("Withdrawal window (seconds):", withdrawalWindow);
        console2.log("Changing these values requires a NotificationVault upgrade.");
        console2.log("");

        vm.startBroadcast();

        NotificationVault implementation = new NotificationVault{salt: "3jane"}(USD3_PROXY);
        nvImpl = address(implementation);

        bytes memory initData = abi.encodeCall(
            NotificationVault.initialize, (SAFE_ADDRESS, keeper, uint64(cooldownDuration), uint64(withdrawalWindow))
        );
        nvProxy = address(new TransparentUpgradeableProxy{salt: "3jane"}(nvImpl, sevenDayTimelock, initData));

        vm.stopBroadcast();

        require(_readAddress(nvProxy, "asset()") == USD3_PROXY, "NotificationVault asset mismatch");
        require(
            _readUint64(nvProxy, "cooldownDuration()") == uint64(cooldownDuration),
            "NotificationVault cooldown mismatch"
        );
        require(
            _readUint64(nvProxy, "withdrawalWindow()") == uint64(withdrawalWindow), "NotificationVault window mismatch"
        );

        address proxyAdmin = address(uint160(uint256(vm.load(nvProxy, ADMIN_SLOT))));
        require(proxyAdmin != address(0) && proxyAdmin.code.length > 0, "NotificationVault ProxyAdmin invalid");
        require(ProxyAdmin(proxyAdmin).owner() == sevenDayTimelock, "NotificationVault ProxyAdmin owner mismatch");

        console2.log("=== NotificationVault Deployment Complete ===");
        console2.log("Implementation:", nvImpl);
        console2.log("Proxy:", nvProxy);
        console2.log("ProxyAdmin:", proxyAdmin);
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Verify the implementation and proxy on Etherscan");
        console2.log("  2. Run 03_DeployLCCImplementation.s.sol with:");
        console2.log("     NOTIFICATION_VAULT=%s", nvProxy);

        return (nvImpl, nvProxy);
    }

    function _readAddress(address target, string memory signature) internal view returns (address value) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(signature));
        require(ok && data.length == 32, "NotificationVault address read failed");
        return abi.decode(data, (address));
    }

    function _readUint64(address target, string memory signature) internal view returns (uint64 value) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(signature));
        require(ok && data.length == 32, "NotificationVault uint64 read failed");
        return abi.decode(data, (uint64));
    }
}
