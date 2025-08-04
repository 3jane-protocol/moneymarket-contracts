// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {ITransparentUpgradeableProxy} from
    "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable} from "../../../lib/openzeppelin/contracts/access/Ownable.sol";

contract ProxyOwnershipTest is BaseTest {
    function testProxyAdminOwnershipSeparation() public view {
        // Verify that ProxyAdmin is owned by PROXY_ADMIN_OWNER, not OWNER
        assertEq(proxyAdmin.owner(), PROXY_ADMIN_OWNER, "ProxyAdmin should be owned by PROXY_ADMIN_OWNER");
        assertNotEq(proxyAdmin.owner(), OWNER, "ProxyAdmin should not be owned by OWNER");

        // Verify that Morpho is owned by OWNER
        assertEq(morpho.owner(), OWNER, "Morpho should be owned by OWNER");
        assertNotEq(morpho.owner(), PROXY_ADMIN_OWNER, "Morpho should not be owned by PROXY_ADMIN_OWNER");
    }

    function testProxyAdminCannotCallMorphoOwnerFunctions() public {
        // PROXY_ADMIN_OWNER should not be able to call Morpho owner functions
        vm.prank(PROXY_ADMIN_OWNER);
        vm.expectRevert(ErrorsLib.NotOwner.selector);
        morpho.setFeeRecipient(address(0x123));
    }

    function testMorphoOwnerCannotUpgradeProxy() public {
        // OWNER (Morpho owner) should not be able to upgrade the proxy
        MorphoCredit newImpl = new MorphoCreditMock(address(1));

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(morphoProxy)), address(newImpl), hex"");
    }

    function testOnlyProxyAdminOwnerCanChangeImplementation() public {
        // Verify that only PROXY_ADMIN_OWNER owns the ProxyAdmin
        assertEq(proxyAdmin.owner(), PROXY_ADMIN_OWNER, "ProxyAdmin should be owned by PROXY_ADMIN_OWNER");

        // Verify that a random user cannot call ProxyAdmin functions
        address randomUser = makeAddr("RandomUser");
        MorphoCredit newImpl = new MorphoCreditMock(address(1));

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomUser));
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(morphoProxy)), address(newImpl), hex"");
    }

    function testBothOwnersAreExcludedFromFuzzing() public {
        assertTrue(_isProxyRelatedAddress(OWNER), "OWNER should be excluded from fuzzing");
        assertTrue(_isProxyRelatedAddress(PROXY_ADMIN_OWNER), "PROXY_ADMIN_OWNER should be excluded from fuzzing");
    }
}
