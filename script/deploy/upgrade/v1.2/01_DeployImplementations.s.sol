// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {sUSD3} from "../../../../src/usd3/sUSD3.sol";

/**
 * @title DeployImplementations v1.2
 * @notice Idempotently deploy the USD3 and sUSD3 implementations for the v1.2 release.
 * @dev Both units use CREATE2 with the shared salt, so a unit whose bytecode is already on-chain at its predicted
 *      address is skipped instead of reverting on the collision.
 *
 *      Usage:
 *      forge script script/deploy/upgrade/v1.2/01_DeployImplementations.s.sol \
 *        --rpc-url mainnet --broadcast --verify
 */
contract DeployImplementations is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant SALT = bytes32("3jane");

    function run() external returns (address usd3Impl, address susd3Impl) {
        console2.log("=== Deploying v1.2 Implementations ===");
        console2.log("");

        usd3Impl = _predict(type(USD3).creationCode);
        susd3Impl = _predict(type(sUSD3).creationCode);

        vm.startBroadcast();

        if (usd3Impl.code.length == 0) {
            console2.log("Deploying USD3 implementation...");
            USD3 usd3 = new USD3{salt: SALT}();
            require(address(usd3) == usd3Impl, "USD3 implementation address mismatch");
        } else {
            console2.log("USD3 implementation already deployed");
        }
        console2.log("  USD3:", usd3Impl);

        if (susd3Impl.code.length == 0) {
            console2.log("Deploying sUSD3 implementation...");
            sUSD3 susd3 = new sUSD3{salt: SALT}();
            require(address(susd3) == susd3Impl, "sUSD3 implementation address mismatch");
        } else {
            console2.log("sUSD3 implementation already deployed");
        }
        console2.log("  sUSD3:", susd3Impl);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Verify the contracts on Etherscan");
        console2.log("  2. Run 05_ScheduleUSD3v12Upgrade.s.sol with:");
        console2.log("     USD3_IMPL=%s", usd3Impl);
        console2.log("     SUSD3_IMPL=%s", susd3Impl);

        return (usd3Impl, susd3Impl);
    }

    function _predict(bytes memory initCode) internal pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", CREATE2_DEPLOYER, SALT, keccak256(initCode))))));
    }
}
