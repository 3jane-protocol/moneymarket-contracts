// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup, ERC20, IUSD3} from "./utils/Setup.sol";
import {NotificationVault} from "../../../src/usd3/NotificationVault.sol";
import {INotificationVault} from "../../../src/usd3/interfaces/INotificationVault.sol";
import {USD3} from "../../../src/usd3/USD3.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {
    TransparentUpgradeableProxy
} from "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract NotificationVaultTest is Setup {
    NotificationVault public vault;
    USD3 public usd3;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public market = makeAddr("market");

    uint64 public constant COOLDOWN = 7 days;
    uint64 public constant WINDOW = 2 days;

    function setUp() public override {
        super.setUp();

        usd3 = USD3(address(strategy));
        vault = _deployVault(COOLDOWN, WINDOW);

        _mintUsd3(alice, 10_000e6);
        _mintUsd3(bob, 10_000e6);
        _mintUsd3(market, 10_000e6);

        vm.label(address(vault), "NotificationVault");
        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(market, "market");
    }

    function _deployVault(uint64 cooldown, uint64 window) internal returns (NotificationVault) {
        NotificationVault implementation = new NotificationVault(address(usd3));
        ProxyAdmin proxyAdmin = new ProxyAdmin(management);
        bytes memory initData = abi.encodeCall(NotificationVault.initialize, (management, keeper, cooldown, window));
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);
        return NotificationVault(address(proxy));
    }

    function _mintUsd3(address user, uint256 amount) internal {
        deal(address(underlyingAsset), user, amount);
        vm.startPrank(user);
        underlyingAsset.approve(address(usd3), amount);
        usd3.deposit(amount, user);
        vm.stopPrank();
    }

    function _depositToVault(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        ERC20(address(usd3)).approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }

    function test_initialization() public {
        assertEq(ITokenizedStrategy(address(vault)).asset(), address(usd3));
        assertEq(vault.symbol(), "USD3l");
        assertEq(ITokenizedStrategy(address(vault)).name(), "USD3 Notification Vault");
        assertEq(ITokenizedStrategy(address(vault)).management(), management);
        assertEq(ITokenizedStrategy(address(vault)).keeper(), keeper);
        assertEq(ITokenizedStrategy(address(vault)).performanceFeeRecipient(), management);
        assertEq(vault.cooldownDuration(), COOLDOWN);
        assertEq(vault.withdrawalWindow(), WINDOW);
    }

    function test_constructorRejectsZeroUsd3() public {
        vm.expectRevert(INotificationVault.InvalidAddress.selector);
        new NotificationVault(address(0));
    }

    function test_initializeRejectsInvalidConfig() public {
        NotificationVault implementation = new NotificationVault(address(usd3));
        ProxyAdmin proxyAdmin = new ProxyAdmin(management);

        bytes memory zeroWindow = abi.encodeCall(NotificationVault.initialize, (management, keeper, COOLDOWN, 0));
        vm.expectRevert(INotificationVault.InvalidCooldownConfig.selector);
        new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), zeroWindow);

        bytes memory zeroManagement =
            abi.encodeCall(NotificationVault.initialize, (address(0), keeper, COOLDOWN, WINDOW));
        vm.expectRevert(INotificationVault.InvalidAddress.selector);
        new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), zeroManagement);
    }

    function test_noCooldownSetters() public {
        (bool success,) =
            address(vault).call(abi.encodeWithSignature("setCooldownConfig(uint64,uint64)", uint64(0), uint64(1)));
        assertFalse(success);
    }

    function test_startCooldownRejectsSharesAboveUint128() public {
        uint256 oversizedShares = uint256(type(uint128).max) + 1;
        deal(address(vault), alice, oversizedShares);

        vm.prank(alice);
        vm.expectRevert(INotificationVault.InvalidAmount.selector);
        vault.startCooldown(oversizedShares);
    }

    function test_startCooldownRejectsWindowEndAboveUint64() public {
        uint256 shares = _depositToVault(alice, 100e6);
        vm.warp(uint256(type(uint64).max) - COOLDOWN - WINDOW + 1);

        vm.prank(alice);
        vm.expectRevert(INotificationVault.InvalidCooldownConfig.selector);
        vault.startCooldown(shares);
    }

    function test_cancelCooldownRevertsWithoutActiveCooldown() public {
        vm.prank(alice);
        vm.expectRevert(INotificationVault.NoActiveCooldown.selector);
        vault.cancelCooldown();
    }

    function test_standardDepositMintWithdrawRedeem() public {
        uint256 depositAmount = 200e6;
        uint256 shares = _depositToVault(alice, depositAmount);

        assertEq(ERC20(address(vault)).balanceOf(alice), shares);
        assertEq(ERC20(address(usd3)).balanceOf(address(vault)), depositAmount);

        vm.prank(alice);
        vault.startCooldown(shares / 2);
        skip(COOLDOWN + 1);

        vm.prank(alice);
        uint256 redeemedAssets = vault.redeem(shares / 2, alice, alice);
        assertEq(redeemedAssets, depositAmount / 2);

        vm.startPrank(alice);
        vault.startCooldown(ERC20(address(vault)).balanceOf(alice));
        skip(COOLDOWN + 1);
        vault.withdraw(depositAmount / 2, alice, alice);
        vm.stopPrank();

        assertEq(ERC20(address(vault)).balanceOf(alice), 0);
    }

    function test_noDepositLockAllowsImmediateTransfer() public {
        uint256 shares = _depositToVault(alice, 100e6);

        vm.prank(alice);
        ERC20(address(vault)).transfer(bob, shares);

        assertEq(ERC20(address(vault)).balanceOf(bob), shares);
    }

    function test_cooldownLifecycleAndPartialWithdrawalCap() public {
        uint256 shares = _depositToVault(alice, 100e6);

        vm.prank(alice);
        vault.startCooldown(shares / 2);

        (uint256 cooldownEnd, uint256 windowEnd, uint256 cooldownShares) = vault.getCooldownStatus(alice);
        assertEq(cooldownEnd, block.timestamp + COOLDOWN);
        assertEq(windowEnd, block.timestamp + COOLDOWN + WINDOW);
        assertEq(cooldownShares, shares / 2);

        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(shares / 2, alice, alice);

        skip(COOLDOWN + 1);
        assertEq(vault.availableWithdrawLimit(alice), shares / 2);

        vm.prank(alice);
        vm.expectRevert();
        vault.redeem((shares / 2) + 1, alice, alice);

        vm.prank(alice);
        vault.redeem(shares / 4, alice, alice);

        (,, cooldownShares) = vault.getCooldownStatus(alice);
        assertEq(cooldownShares, shares / 4);

        skip(WINDOW + 1);
        assertEq(vault.availableWithdrawLimit(alice), 0);

        vm.prank(alice);
        vault.cancelCooldown();
        (,, cooldownShares) = vault.getCooldownStatus(alice);
        assertEq(cooldownShares, 0);
    }

    function test_withdrawalWindowIncludesBothEndpointsAndExcludesFollowingSecond() public {
        uint256 shares = _depositToVault(alice, 90e6);

        vm.prank(alice);
        vault.startCooldown(shares);
        (uint256 cooldownEnd, uint256 windowEnd,) = vault.getCooldownStatus(alice);

        vm.warp(cooldownEnd);
        assertEq(block.timestamp, cooldownEnd);
        assertEq(vault.availableWithdrawLimit(alice), shares);
        vm.prank(alice);
        vault.redeem(shares / 3, alice, alice);

        vm.warp(windowEnd);
        assertEq(block.timestamp, windowEnd);
        assertEq(vault.availableWithdrawLimit(alice), (shares * 2) / 3);
        vm.prank(alice);
        vault.withdraw(shares / 3, alice, alice);

        vm.warp(windowEnd + 1);
        assertEq(block.timestamp, windowEnd + 1);
        assertEq(vault.availableWithdrawLimit(alice), 0);
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(1, alice, alice);
    }

    function test_transferRestrictionOnlyBlocksCooldownedShares() public {
        uint256 shares = _depositToVault(alice, 100e6);

        vm.prank(alice);
        vault.startCooldown(shares / 2);

        vm.prank(alice);
        ERC20(address(vault)).transfer(bob, shares / 2);
        assertEq(ERC20(address(vault)).balanceOf(bob), shares / 2);

        vm.prank(alice);
        vm.expectRevert(INotificationVault.InsufficientShares.selector);
        ERC20(address(vault)).transfer(bob, 1);
    }

    function test_delegatedTransferFromUsesOwnerCooldownAndConsumesAllowance() public {
        uint256 shares = _depositToVault(alice, 100e6);
        uint256 cooldownShares = shares / 2;
        uint256 transferableShares = shares - cooldownShares;

        vm.prank(alice);
        vault.startCooldown(cooldownShares);
        vm.prank(management);
        vault.setCooldownBypass(bob, true);
        vm.prank(alice);
        ERC20(address(vault)).approve(bob, shares);

        vm.prank(bob);
        vm.expectRevert(INotificationVault.InsufficientShares.selector);
        ERC20(address(vault)).transferFrom(alice, bob, transferableShares + 1);
        assertEq(ERC20(address(vault)).allowance(alice, bob), shares);

        vm.prank(bob);
        ERC20(address(vault)).transferFrom(alice, bob, transferableShares);

        assertEq(ERC20(address(vault)).allowance(alice, bob), cooldownShares);
        assertEq(ERC20(address(vault)).balanceOf(alice), cooldownShares);
        assertEq(ERC20(address(vault)).balanceOf(bob), transferableShares);
        (,, uint256 aliceCooldownShares) = vault.getCooldownStatus(alice);
        (,, uint256 bobCooldownShares) = vault.getCooldownStatus(bob);
        assertEq(aliceCooldownShares, cooldownShares);
        assertEq(bobCooldownShares, 0);
    }

    function test_delegatedWithdrawAndRedeemUseOwnerCooldownAndConsumeAllowance() public {
        uint256 shares = _depositToVault(alice, 100e6);

        vm.prank(alice);
        vault.startCooldown(shares);
        vm.prank(management);
        vault.setCooldownBypass(bob, true);
        vm.prank(alice);
        ERC20(address(vault)).approve(bob, shares);

        vm.prank(bob);
        vm.expectRevert();
        vault.withdraw(1, bob, alice);
        vm.prank(bob);
        vm.expectRevert();
        vault.redeem(1, bob, alice);
        assertEq(ERC20(address(vault)).allowance(alice, bob), shares);

        (uint256 cooldownEnd,,) = vault.getCooldownStatus(alice);
        vm.warp(cooldownEnd);

        uint256 operationShares = shares / 4;
        vm.prank(bob);
        uint256 burnedShares = vault.withdraw(operationShares, bob, alice);
        assertEq(burnedShares, operationShares);
        assertEq(ERC20(address(vault)).allowance(alice, bob), shares - operationShares);

        vm.prank(bob);
        uint256 redeemedAssets = vault.redeem(operationShares, bob, alice);
        assertEq(redeemedAssets, operationShares);
        assertEq(ERC20(address(vault)).allowance(alice, bob), shares - (2 * operationShares));

        assertEq(ERC20(address(vault)).balanceOf(alice), shares - (2 * operationShares));
        (,, uint256 aliceCooldownShares) = vault.getCooldownStatus(alice);
        (,, uint256 bobCooldownShares) = vault.getCooldownStatus(bob);
        assertEq(aliceCooldownShares, shares - (2 * operationShares));
        assertEq(bobCooldownShares, 0);
    }

    function test_zeroCooldownAllowsImmediateExitAndTransferWithLingeringCooldown() public {
        NotificationVault zeroCooldownVault = _deployVault(0, WINDOW);
        uint256 amount = 100e6;

        vm.startPrank(alice);
        ERC20(address(usd3)).approve(address(zeroCooldownVault), amount);
        uint256 shares = zeroCooldownVault.deposit(amount, alice);
        zeroCooldownVault.startCooldown(shares);
        zeroCooldownVault.redeem(shares / 2, alice, alice);
        ERC20(address(zeroCooldownVault)).transfer(bob, shares / 2);
        vm.stopPrank();

        assertEq(ERC20(address(zeroCooldownVault)).balanceOf(bob), shares / 2);
    }

    function test_shutdownSkipsCooldownForWithdrawAndTransfer() public {
        uint256 shares = _depositToVault(alice, 100e6);

        vm.prank(alice);
        vault.startCooldown(shares);

        vm.prank(management);
        ITokenizedStrategy(address(vault)).shutdownStrategy();

        vm.prank(alice);
        ERC20(address(vault)).transfer(bob, shares / 2);

        vm.prank(alice);
        vault.redeem(shares / 2, alice, alice);

        assertEq(ERC20(address(vault)).balanceOf(alice), 0);
        assertEq(ERC20(address(vault)).balanceOf(bob), shares / 2);
    }

    function test_ownerBypassSkipsCooldownButDoesNotGrantAllowance() public {
        uint256 shares = _depositToVault(market, 100e6);

        vm.prank(market);
        vault.startCooldown(shares);

        vm.prank(management);
        vault.setCooldownBypass(market, true);

        vm.prank(market);
        ERC20(address(vault)).transfer(bob, shares / 4);

        vm.prank(bob);
        vm.expectRevert();
        vault.redeem(shares / 4, bob, market);

        vm.prank(market);
        vault.redeem((shares * 3) / 4, market, market);

        assertEq(ERC20(address(vault)).balanceOf(market), 0);
        assertEq(ERC20(address(vault)).balanceOf(bob), shares / 4);
    }

    function test_setCooldownBypassOnlyManagement() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setCooldownBypass(alice, true);

        vm.prank(management);
        vault.setCooldownBypass(alice, true);
        assertTrue(vault.cooldownBypass(alice));
    }

    function test_reportAndHarvestRevert() public {
        vm.expectRevert(INotificationVault.ReportsDisabled.selector);
        vault.report();

        vm.expectRevert();
        vault.harvestAndReport();
    }

    function test_donationsRemainUnreportedAndUnswept() public {
        uint256 shares = _depositToVault(alice, 100e6);
        uint256 totalAssetsBefore = ITokenizedStrategy(address(vault)).totalAssets();

        vm.prank(bob);
        ERC20(address(usd3)).transfer(address(vault), 10e6);

        assertEq(ITokenizedStrategy(address(vault)).totalAssets(), totalAssetsBefore);
        assertEq(ERC20(address(usd3)).balanceOf(address(vault)), totalAssetsBefore + 10e6);

        vm.prank(alice);
        vault.startCooldown(shares);
        skip(COOLDOWN + 1);

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);
        assertEq(assets, totalAssetsBefore);
        assertEq(ERC20(address(usd3)).balanceOf(address(vault)), 10e6);
    }

    function test_usd3ValueChangesDoNotCreateNotificationVaultLossAbsorption() public {
        uint256 shares = _depositToVault(alice, 100e6);

        vm.prank(alice);
        vault.startCooldown(shares);
        skip(COOLDOWN + 1);

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        assertEq(assets, 100e6);
        assertEq(ERC20(address(vault)).balanceOf(alice), 0);
    }
}
