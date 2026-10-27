// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {LCCLeveragedFundHelper} from "../../../src/lcc/LCCLeveragedFundHelper.sol";

/// @title DeployLCCLeveragedFundHelper
/// @notice Deploys and verifies the LCC leveraged funding helper against canonical Morpho Blue, the LCC vault factory,
///         and USD3l. It grants no USD3l cooldown bypass; until USD3l management grants one, entries work and every
///         unwind reverts.
/// @dev `verify` deploys a reference helper with the same constructor arguments on the simulated chain and requires
///      the deployed runtime code hash to match it.
/// @dev Usage:
///      FOUNDRY_PROFILE=script LCC_FACTORY=<factory> yarn script:forge \
///      script/deploy/lcc/DeployLCCLeveragedFundHelper.s.sol:DeployLCCLeveragedFundHelper \
///      --account <deployer> --sender <deployer> --rpc-url <rpc-url> [--broadcast --verify]
///      Verify an existing deployment with --sig "verify(address)" <helper>.
contract DeployLCCLeveragedFundHelper is Script {
    address internal constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant USD3L = 0xDF697c55f0D696CA9E3E624cD52d8186C6745904;
    address internal constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function run() external returns (address helperAddress) {
        require(block.chainid == 1, "mainnet only");
        address factory = _factory();
        _requireDependencies();

        vm.startBroadcast();
        LCCLeveragedFundHelper helper = new LCCLeveragedFundHelper(MORPHO_BLUE, factory, USD3L);
        vm.stopBroadcast();
        helperAddress = address(helper);

        _verify(helperAddress, factory);
        console2.log("LCCLeveragedFundHelper:", helperAddress);
        console2.log("Runtime code hash:", vm.toString(helperAddress.codehash));
        console2.log("USD3l cooldown bypass granted:", _bypassGranted(helperAddress));
    }

    function verify(address helperAddress) external {
        require(block.chainid == 1, "mainnet only");
        require(helperAddress.code.length > 0, "helper has no code");
        address factory = _factory();
        _requireDependencies();

        _verify(helperAddress, factory);

        LCCLeveragedFundHelper expected = new LCCLeveragedFundHelper(MORPHO_BLUE, factory, USD3L);
        require(helperAddress.codehash == address(expected).codehash, "runtime code hash mismatch");

        console2.log("LCCLeveragedFundHelper:", helperAddress);
        console2.log("Runtime code hash:", vm.toString(helperAddress.codehash));
        console2.log("USD3l cooldown bypass granted:", _bypassGranted(helperAddress));
    }

    function _verify(address helperAddress, address factory) private view {
        LCCLeveragedFundHelper helper = LCCLeveragedFundHelper(helperAddress);
        require(helper.morpho() == MORPHO_BLUE, "morpho mismatch");
        require(helper.factory() == factory, "factory mismatch");
        require(helper.usd3l() == USD3L, "USD3l mismatch");
        require(helper.usd3() == USD3, "USD3 mismatch");
        require(helper.usdc() == USDC, "USDC mismatch");
        require(IERC20(USD3L).allowance(helperAddress, MORPHO_BLUE) == type(uint256).max, "USD3l allowance mismatch");
        require(IERC20(USDC).allowance(helperAddress, MORPHO_BLUE) == type(uint256).max, "USDC allowance mismatch");
    }

    function _requireDependencies() private view {
        require(MORPHO_BLUE.code.length > 0, "Morpho Blue missing");
        require(IERC4626(USD3L).asset() == USD3, "USD3l asset mismatch");
        require(IERC4626(USD3).asset() == USDC, "USD3 asset mismatch");
    }

    function _factory() private view returns (address factory) {
        factory = vm.envAddress("LCC_FACTORY");
        require(factory != address(0) && factory.code.length > 0, "invalid LCC_FACTORY");
    }

    function _bypassGranted(address helperAddress) private view returns (bool) {
        (bool ok, bytes memory data) =
            USD3L.staticcall(abi.encodeWithSignature("cooldownBypass(address)", helperAddress));
        require(ok && data.length == 32, "cooldownBypass read failed");
        return abi.decode(data, (bool));
    }
}
