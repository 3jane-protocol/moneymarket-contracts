// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {LCCMarginDepositHelper} from "../../../src/lcc/LCCMarginDepositHelper.sol";

/// @title DeployLCCMarginDepositHelper
/// @notice Deploys and verifies the stateless self-service LCC margin deposit helper without granting any role.
contract DeployLCCMarginDepositHelper is Script {
    address internal constant WA_ETH_USDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;
    address internal constant WA_ETH_USDT = 0x7Bc3485026Ac48b6cf9BaF0A377477Fff5703Af8;

    function run() external returns (address helperAddress) {
        require(block.chainid == 1, "mainnet only");
        address factory = vm.envAddress("LCC_FACTORY");
        require(factory != address(0) && factory.code.length > 0, "invalid LCC_FACTORY");
        require(WA_ETH_USDC.code.length > 0 && WA_ETH_USDT.code.length > 0, "StataToken missing");

        vm.startBroadcast();
        LCCMarginDepositHelper helper = new LCCMarginDepositHelper(factory, WA_ETH_USDC, WA_ETH_USDT);
        vm.stopBroadcast();
        helperAddress = address(helper);

        _verify(helper, factory);
        console2.log("LCCMarginDepositHelper:", helperAddress);
        console2.log("Runtime code hash:", vm.toString(helperAddress.codehash));
        console2.log("No DEPOSIT_OPERATOR_ROLE was granted by this script");
    }

    function verify(address helperAddress) external view {
        require(helperAddress.code.length > 0, "helper has no code");
        _verify(LCCMarginDepositHelper(helperAddress), vm.envAddress("LCC_FACTORY"));
        console2.log("Runtime code hash:", vm.toString(helperAddress.codehash));
    }

    function _verify(LCCMarginDepositHelper helper, address factory) private view {
        require(helper.factory() == factory, "factory mismatch");
        require(helper.waEthUSDC() == WA_ETH_USDC, "waEthUSDC mismatch");
        require(helper.waEthUSDT() == WA_ETH_USDT, "waEthUSDT mismatch");
        require(helper.usdc() == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "USDC mismatch");
        require(helper.aEthUSDC() == 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c, "aEthUSDC mismatch");
        require(helper.usdt() == 0xdAC17F958D2ee523a2206206994597C13D831ec7, "USDT mismatch");
        require(helper.aEthUSDT() == 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a, "aEthUSDT mismatch");
    }
}
