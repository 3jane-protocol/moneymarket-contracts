// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {IERC4626} from "../../../../lib/openzeppelin/contracts/interfaces/IERC4626.sol";
import {LCCVault} from "../../../../src/lcc/LCCVault.sol";
import {ILCCVault} from "../../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCWiringCheck} from "../../../utils/LCCWiringCheck.sol";

/**
 * @title DeployLCCImplementation v1.2
 * @notice Deploy the shared LCCVault implementation with its protocol-wide immutable wiring.
 * @dev LCCAuctionLib and LCCConfigLib are externally linked. Forge deploys and links both during broadcast; every
 *      future implementation redeploy must deploy and link both libraries again. The implementation CREATE2 address
 *      is deployer-dependent because the linked library addresses are embedded in its initcode.
 *
 *      This script intentionally imports LCCVault without LCCVaultFactory so each retains its canonical optimizer
 *      settings.
 *
 *      Usage:
 *      NOTIFICATION_VAULT=<address> TREASURY=<address> forge script \
 *        script/deploy/upgrade/v1.2/03_DeployLCCImplementation.s.sol \
 *        --rpc-url mainnet --broadcast --verify
 */
contract DeployLCCImplementation is Script, LCCWiringCheck {
    address internal constant USD3_PROXY = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;

    function run() external returns (address vaultImpl) {
        address notificationVault = vm.envAddress("NOTIFICATION_VAULT");
        require(notificationVault != address(0), "NOTIFICATION_VAULT not set");
        require(notificationVault.code.length > 0, "NOTIFICATION_VAULT has no code");

        address treasury = vm.envAddress("TREASURY");
        require(treasury != address(0), "TREASURY not set");

        require(IERC4626(notificationVault).asset() == USD3_PROXY, "NotificationVault asset mismatch");
        address fundingAsset = IERC4626(USD3_PROXY).asset();
        require(fundingAsset != address(0), "USD3 asset not set");

        console2.log("=== Deploying v1.2 LCCVault Implementation ===");
        console2.log("NotificationVault:", notificationVault);
        console2.log("USD3:", USD3_PROXY);
        console2.log("Funding asset:", fundingAsset);
        console2.log("Treasury:", treasury);
        console2.log("");

        vm.startBroadcast();

        LCCVault implementation = new LCCVault{salt: "3jane"}(notificationVault, treasury);
        vaultImpl = address(implementation);

        vm.stopBroadcast();

        ILCCVault.AssetConfig memory config = _requireLCCWiring(vaultImpl, USD3_PROXY);
        require(config.notificationVault == notificationVault, "LCCVault NotificationVault mismatch");
        require(config.fundingAsset == fundingAsset, "LCCVault funding asset mismatch");
        require(config.treasury == treasury, "LCCVault treasury mismatch");

        console2.log("=== LCCVault Implementation Deployed ===");
        console2.log("Address:", vaultImpl);
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Verify LCCAuctionLib, LCCConfigLib, and LCCVault on Etherscan");
        console2.log("  2. Record both linked library addresses for future implementation upgrades");
        console2.log("  3. Run 04_DeployLCCBeaconAndFactory.s.sol with:");
        console2.log("     LCC_VAULT_IMPL=%s", vaultImpl);

        return vaultImpl;
    }
}
