// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2, VmSafe} from "forge-std/Script.sol";

import {LCCMarginDepositHelper} from "../../src/lcc/LCCMarginDepositHelper.sol";
import {LCCVaultFactory} from "../../src/lcc/LCCVaultFactory.sol";

/// @title AuthorizeLCCTestDepositHelper
/// @notice Grants the test factory's DEPOSIT_OPERATOR_ROLE to a reviewed margin deposit helper from the test owner.
/// @dev EOA counterpart of AuthorizeLCCMarginDepositHelperSafe for the EOA-owned test factory. The helper's runtime
///      code hash is compared against a freshly compiled reference construction before any grant, so a wrong or
///      tampered helper cannot be authorized. Re-running after a successful grant is a verified no-op.
///
///      Usage:
///      FOUNDRY_PROFILE=script LCC_TEST_FACTORY=<address> TEST_OWNER=<address> \
///        LCC_MARGIN_DEPOSIT_HELPER=<address> forge script \
///        script/operations/AuthorizeLCCTestDepositHelper.s.sol --rpc-url mainnet --broadcast
contract AuthorizeLCCTestDepositHelper is Script {
    uint256 internal constant MAINNET_CHAIN_ID = 1;
    address internal constant WA_ETH_USDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;
    address internal constant WA_ETH_USDT = 0x7Bc3485026Ac48b6cf9BaF0A377477Fff5703Af8;

    function run() external {
        require(block.chainid == MAINNET_CHAIN_ID, "LCC test deployment is mainnet-only");

        LCCVaultFactory factory = LCCVaultFactory(vm.envAddress("LCC_TEST_FACTORY"));
        address testOwner = vm.envAddress("TEST_OWNER");
        address helperAddress = vm.envAddress("LCC_MARGIN_DEPOSIT_HELPER");
        require(address(factory).code.length > 0, "LCC_TEST_FACTORY has no code");
        require(testOwner != address(0), "TEST_OWNER not set");
        require(helperAddress.code.length > 0, "helper has no code");

        LCCMarginDepositHelper reviewed = new LCCMarginDepositHelper(address(factory), WA_ETH_USDC, WA_ETH_USDT);
        bytes32 reviewedCodeHash = address(reviewed).codehash;
        require(helperAddress.codehash == reviewedCodeHash, "helper runtime code hash mismatch");
        require(factory.owner() == testOwner, "TEST_OWNER is not test factory owner");
        require(factory.getRoleMemberCount(factory.OWNER_ROLE()) == 1, "factory owner count mismatch");
        require(
            factory.getRoleAdmin(factory.DEPOSIT_OPERATOR_ROLE()) == factory.OWNER_ROLE(),
            "deposit operator admin mismatch"
        );

        LCCMarginDepositHelper helper = LCCMarginDepositHelper(helperAddress);
        require(helper.factory() == address(factory), "helper factory mismatch");
        require(helper.waEthUSDC() == WA_ETH_USDC, "helper waEthUSDC mismatch");
        require(helper.waEthUSDT() == WA_ETH_USDT, "helper waEthUSDT mismatch");
        require(helper.usdc() == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "helper USDC mismatch");
        require(helper.aEthUSDC() == 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c, "helper aEthUSDC mismatch");
        require(helper.usdt() == 0xdAC17F958D2ee523a2206206994597C13D831ec7, "helper USDT mismatch");
        require(helper.aEthUSDT() == 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a, "helper aEthUSDT mismatch");

        if (!factory.isDepositOperator(helperAddress)) {
            vm.startBroadcast(testOwner);
            (VmSafe.CallerMode mode, address sender, address origin) = vm.readCallers();
            require(mode == VmSafe.CallerMode.RecurrentBroadcast, "Broadcast mode not active");
            require(sender == testOwner && origin == testOwner, "TEST_OWNER is not broadcaster");
            factory.grantRole(factory.DEPOSIT_OPERATOR_ROLE(), helperAddress);
            vm.stopBroadcast();
        }

        require(factory.isDepositOperator(helperAddress), "helper is not a deposit operator");
        console2.log("Reviewed helper runtime code hash:", vm.toString(reviewedCodeHash));
        console2.log("LCC margin deposit helper authorized on test factory:", helperAddress);
    }
}
