// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {ERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    TransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {NotificationVault} from "../../../../src/usd3/NotificationVault.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {Setup} from "../utils/Setup.sol";

contract NotificationVaultInvariantsTest is StdInvariant, Setup {
    uint64 internal constant COOLDOWN = 3 days;
    uint64 internal constant WINDOW = 2 days;

    NotificationVault public vault;
    USD3 public usd3;
    NotificationVaultHandler public handler;

    address[] internal actors;

    function setUp() public override {
        super.setUp();

        usd3 = USD3(address(strategy));
        NotificationVault implementation = new NotificationVault(address(usd3));
        ProxyAdmin proxyAdmin = new ProxyAdmin(management);
        bytes memory initData = abi.encodeCall(NotificationVault.initialize, (management, keeper, COOLDOWN, WINDOW));
        vault = NotificationVault(
            address(new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData))
        );

        actors.push(makeAddr("notification-actor-0"));
        actors.push(makeAddr("notification-actor-1"));
        actors.push(makeAddr("notification-actor-2"));
        actors.push(makeAddr("notification-actor-3"));

        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            deal(address(underlyingAsset), actor, 2_000e6);
            vm.startPrank(actor);
            underlyingAsset.approve(address(usd3), type(uint256).max);
            usd3.deposit(2_000e6, actor);
            ERC20(address(usd3)).approve(address(vault), type(uint256).max);
            vault.deposit(1_000e6, actor);
            vm.stopPrank();
        }

        handler = new NotificationVaultHandler(address(vault), address(usd3), management, actors);
        _configureTargets();
    }

    function _configureTargets() internal {
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = NotificationVaultHandler.deposit.selector;
        selectors[1] = NotificationVaultHandler.startCooldown.selector;
        selectors[2] = NotificationVaultHandler.cancelCooldown.selector;
        selectors[3] = NotificationVaultHandler.transfer.selector;
        selectors[4] = NotificationVaultHandler.delegatedTransferFrom.selector;
        selectors[5] = NotificationVaultHandler.withdraw.selector;
        selectors[6] = NotificationVaultHandler.redeem.selector;
        selectors[7] = NotificationVaultHandler.delegatedWithdraw.selector;
        selectors[8] = NotificationVaultHandler.delegatedRedeem.selector;
        selectors[9] = NotificationVaultHandler.toggleBypass.selector;
        selectors[10] = NotificationVaultHandler.warp.selector;
        selectors[11] = NotificationVaultHandler.shutdown.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_shareSolvency() public view {
        uint256 balanceSum;
        for (uint256 i; i < actors.length; ++i) {
            balanceSum += ERC20(address(vault)).balanceOf(actors[i]);
        }

        assertEq(balanceSum, ERC20(address(vault)).totalSupply(), "unaccounted NotificationVault shares");
    }

    function invariant_cooldownedSharesCannotTransferWithoutExplicitEscape() public view {
        assertFalse(handler.cooldownTransferViolation(), "cooldowned shares transferred without bypass or shutdown");
        assertFalse(handler.operationAccountingViolation(), "successful operation broke share accounting");
    }

    function invariant_delegatedOperationsRemainOwnerKeyed() public view {
        assertFalse(handler.delegatedOwnershipViolation(), "delegated operation used spender cooldown state");
        assertFalse(handler.allowanceAccountingViolation(), "delegated operation consumed the wrong allowance");
    }

    function invariant_cooldownStateIsCoherent() public view {
        bool shutdown = ITokenizedStrategy(address(vault)).isShutdown();

        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            (uint256 cooldownEnd, uint256 windowEnd, uint256 cooldownShares) = vault.getCooldownStatus(actor);

            if (cooldownShares == 0) {
                assertEq(cooldownEnd, 0, "cleared cooldown retained its end");
                assertEq(windowEnd, 0, "cleared cooldown retained its window");
                continue;
            }

            assertGt(cooldownEnd, 0, "active cooldown has no end");
            assertEq(windowEnd - cooldownEnd, vault.withdrawalWindow(), "cooldown window is malformed");

            if (!shutdown && !vault.cooldownBypass(actor)) {
                assertLe(
                    cooldownShares,
                    ERC20(address(vault)).balanceOf(actor),
                    "restricted cooldown is orphaned from owner balance"
                );
            }
        }
    }
}

contract NotificationVaultHandler is Test {
    struct CooldownSnapshot {
        uint256 cooldownEnd;
        uint256 windowEnd;
        uint256 shares;
    }

    NotificationVault public immutable vault;
    ERC20 public immutable usd3;
    address public immutable management;

    address[] internal actors;

    bool public cooldownTransferViolation;
    bool public delegatedOwnershipViolation;
    bool public allowanceAccountingViolation;
    bool public operationAccountingViolation;

    constructor(address vault_, address usd3_, address management_, address[] memory actors_) {
        vault = NotificationVault(vault_);
        usd3 = ERC20(usd3_);
        management = management_;
        actors = actors_;
    }

    function deposit(uint256 actorSeed, uint256 assetsSeed) external {
        if (ITokenizedStrategy(address(vault)).isShutdown()) return;

        address actor = _actor(actorSeed);
        uint256 balance = usd3.balanceOf(actor);
        if (balance == 0) return;

        uint256 assets = bound(assetsSeed, 1, balance);
        vm.prank(actor);
        try vault.deposit(assets, actor) {} catch {}
    }

    function startCooldown(uint256 actorSeed, uint256 sharesSeed) external {
        address actor = _actor(actorSeed);
        uint256 balance = ERC20(address(vault)).balanceOf(actor);
        if (balance == 0) return;

        uint256 shares = bound(sharesSeed, 1, balance);
        vm.prank(actor);
        try vault.startCooldown(shares) {} catch {}
    }

    function cancelCooldown(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        vm.prank(actor);
        try vault.cancelCooldown() {} catch {}
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        (address from, address to) = _actorPair(fromSeed, toSeed);
        uint256 balanceBefore = ERC20(address(vault)).balanceOf(from);
        if (balanceBefore == 0) return;

        uint256 amount = bound(amountSeed, 1, balanceBefore);
        uint256 toBalanceBefore = ERC20(address(vault)).balanceOf(to);
        uint256 supplyBefore = ERC20(address(vault)).totalSupply();
        CooldownSnapshot memory fromCooldown = _cooldown(from);
        CooldownSnapshot memory toCooldown = _cooldown(to);
        bool shouldBlock = _cooldownBlocksTransfer(from, amount, balanceBefore, fromCooldown.shares);

        vm.prank(from);
        try ERC20(address(vault)).transfer(to, amount) returns (bool success) {
            if (!success || shouldBlock) cooldownTransferViolation = true;
            if (
                ERC20(address(vault)).balanceOf(from) != balanceBefore - amount
                    || ERC20(address(vault)).balanceOf(to) != toBalanceBefore + amount
                    || ERC20(address(vault)).totalSupply() != supplyBefore || !_cooldownEquals(from, fromCooldown)
                    || !_cooldownEquals(to, toCooldown)
            ) operationAccountingViolation = true;
        } catch {
            if (!shouldBlock) operationAccountingViolation = true;
        }
    }

    function delegatedTransferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _otherActor(ownerSeed, spenderSeed);
        address to = _otherActor(ownerSeed, toSeed);
        uint256 balanceBefore = ERC20(address(vault)).balanceOf(owner);
        if (balanceBefore == 0) return;

        uint256 amount = bound(amountSeed, 1, balanceBefore);
        uint256 toBalanceBefore = ERC20(address(vault)).balanceOf(to);
        CooldownSnapshot memory ownerCooldown = _cooldown(owner);
        CooldownSnapshot memory spenderCooldown = _cooldown(spender);
        bool shouldBlock = _cooldownBlocksTransfer(owner, amount, balanceBefore, ownerCooldown.shares);

        vm.prank(owner);
        ERC20(address(vault)).approve(spender, amount + 1);
        uint256 allowanceBefore = ERC20(address(vault)).allowance(owner, spender);

        vm.prank(spender);
        try ERC20(address(vault)).transferFrom(owner, to, amount) returns (bool success) {
            if (!success || shouldBlock) cooldownTransferViolation = true;
            if (ERC20(address(vault)).allowance(owner, spender) != allowanceBefore - amount) {
                allowanceAccountingViolation = true;
            }
            if (
                ERC20(address(vault)).balanceOf(owner) != balanceBefore - amount
                    || ERC20(address(vault)).balanceOf(to) != toBalanceBefore + amount
                    || !_cooldownEquals(owner, ownerCooldown) || !_cooldownEquals(spender, spenderCooldown)
            ) delegatedOwnershipViolation = true;
        } catch {
            if (ERC20(address(vault)).allowance(owner, spender) != allowanceBefore) {
                allowanceAccountingViolation = true;
            }
            if (!shouldBlock) delegatedOwnershipViolation = true;
        }
    }

    function withdraw(uint256 ownerSeed, uint256 receiverSeed, uint256 assetsSeed) external {
        (address owner, address receiver) = _actorPair(ownerSeed, receiverSeed);
        uint256 balanceBefore = ERC20(address(vault)).balanceOf(owner);
        uint256 assetValue = ITokenizedStrategy(address(vault)).convertToAssets(balanceBefore);
        if (assetValue == 0) return;

        uint256 assets = bound(assetsSeed, 1, assetValue);
        uint256 maxWithdraw = ITokenizedStrategy(address(vault)).maxWithdraw(owner);
        CooldownSnapshot memory ownerCooldown = _cooldown(owner);
        uint256 supplyBefore = ERC20(address(vault)).totalSupply();

        vm.prank(owner);
        try vault.withdraw(assets, receiver, owner) returns (uint256 burnedShares) {
            if (assets > maxWithdraw) operationAccountingViolation = true;
            _validateBurn(owner, balanceBefore, supplyBefore, burnedShares, ownerCooldown);
        } catch {
            if (assets <= maxWithdraw) operationAccountingViolation = true;
        }
    }

    function redeem(uint256 ownerSeed, uint256 receiverSeed, uint256 sharesSeed) external {
        (address owner, address receiver) = _actorPair(ownerSeed, receiverSeed);
        uint256 balanceBefore = ERC20(address(vault)).balanceOf(owner);
        if (balanceBefore == 0) return;

        uint256 shares = bound(sharesSeed, 1, balanceBefore);
        uint256 maxRedeem = ITokenizedStrategy(address(vault)).maxRedeem(owner);
        CooldownSnapshot memory ownerCooldown = _cooldown(owner);
        uint256 supplyBefore = ERC20(address(vault)).totalSupply();

        vm.prank(owner);
        try vault.redeem(shares, receiver, owner) returns (uint256) {
            if (shares > maxRedeem) operationAccountingViolation = true;
            _validateBurn(owner, balanceBefore, supplyBefore, shares, ownerCooldown);
        } catch {
            if (shares <= maxRedeem) operationAccountingViolation = true;
        }
    }

    function delegatedWithdraw(uint256 ownerSeed, uint256 spenderSeed, uint256 assetsSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _otherActor(ownerSeed, spenderSeed);
        uint256 balanceBefore = ERC20(address(vault)).balanceOf(owner);
        uint256 assetValue = ITokenizedStrategy(address(vault)).convertToAssets(balanceBefore);
        if (assetValue == 0) return;

        uint256 assets = bound(assetsSeed, 1, assetValue);
        uint256 requiredAllowance = ITokenizedStrategy(address(vault)).previewWithdraw(assets);
        uint256 maxWithdraw = ITokenizedStrategy(address(vault)).maxWithdraw(owner);
        uint256 supplyBefore = ERC20(address(vault)).totalSupply();
        CooldownSnapshot memory ownerCooldown = _cooldown(owner);
        CooldownSnapshot memory spenderCooldown = _cooldown(spender);

        vm.prank(owner);
        ERC20(address(vault)).approve(spender, requiredAllowance + 1);
        uint256 allowanceBefore = ERC20(address(vault)).allowance(owner, spender);

        vm.prank(spender);
        try vault.withdraw(assets, spender, owner) returns (uint256 burnedShares) {
            if (assets > maxWithdraw) delegatedOwnershipViolation = true;
            if (ERC20(address(vault)).allowance(owner, spender) != allowanceBefore - burnedShares) {
                allowanceAccountingViolation = true;
            }
            if (!_cooldownEquals(spender, spenderCooldown)) delegatedOwnershipViolation = true;
            _validateBurn(owner, balanceBefore, supplyBefore, burnedShares, ownerCooldown);
        } catch {
            if (ERC20(address(vault)).allowance(owner, spender) != allowanceBefore) {
                allowanceAccountingViolation = true;
            }
            if (assets <= maxWithdraw) delegatedOwnershipViolation = true;
        }
    }

    function delegatedRedeem(uint256 ownerSeed, uint256 spenderSeed, uint256 sharesSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _otherActor(ownerSeed, spenderSeed);
        uint256 balanceBefore = ERC20(address(vault)).balanceOf(owner);
        if (balanceBefore == 0) return;

        uint256 shares = bound(sharesSeed, 1, balanceBefore);
        uint256 maxRedeem = ITokenizedStrategy(address(vault)).maxRedeem(owner);
        uint256 supplyBefore = ERC20(address(vault)).totalSupply();
        CooldownSnapshot memory ownerCooldown = _cooldown(owner);
        CooldownSnapshot memory spenderCooldown = _cooldown(spender);

        vm.prank(owner);
        ERC20(address(vault)).approve(spender, shares + 1);
        uint256 allowanceBefore = ERC20(address(vault)).allowance(owner, spender);

        vm.prank(spender);
        try vault.redeem(shares, spender, owner) returns (uint256) {
            if (shares > maxRedeem) delegatedOwnershipViolation = true;
            if (ERC20(address(vault)).allowance(owner, spender) != allowanceBefore - shares) {
                allowanceAccountingViolation = true;
            }
            if (!_cooldownEquals(spender, spenderCooldown)) delegatedOwnershipViolation = true;
            _validateBurn(owner, balanceBefore, supplyBefore, shares, ownerCooldown);
        } catch {
            if (ERC20(address(vault)).allowance(owner, spender) != allowanceBefore) {
                allowanceAccountingViolation = true;
            }
            if (shares <= maxRedeem) delegatedOwnershipViolation = true;
        }
    }

    function toggleBypass(uint256 actorSeed, bool allowed) external {
        address actor = _actor(actorSeed);

        if (!allowed && vault.cooldownBypass(actor)) {
            (,, uint256 cooldownShares) = vault.getCooldownStatus(actor);
            if (cooldownShares > ERC20(address(vault)).balanceOf(actor)) {
                vm.prank(actor);
                vault.cancelCooldown();
            }
        }

        vm.prank(management);
        vault.setCooldownBypass(actor, allowed);
    }

    function warp(uint256 actorSeed, uint256 timeSeed) external {
        address actor = _actor(actorSeed);
        (uint256 cooldownEnd, uint256 windowEnd, uint256 cooldownShares) = vault.getCooldownStatus(actor);
        uint256 target;

        if (cooldownShares != 0 && timeSeed % 3 == 0 && cooldownEnd >= block.timestamp) {
            target = cooldownEnd;
        } else if (cooldownShares != 0 && timeSeed % 3 == 1 && windowEnd >= block.timestamp) {
            target = windowEnd;
        } else if (cooldownShares != 0 && windowEnd >= block.timestamp) {
            target = windowEnd + 1;
        } else {
            target = block.timestamp + bound(timeSeed, 1 hours, 20 days);
        }

        vm.warp(target);
        vm.roll(block.number + 1);
    }

    function shutdown(uint256 shutdownSeed) external {
        if (ITokenizedStrategy(address(vault)).isShutdown() || shutdownSeed % 8 != 0) return;

        vm.prank(management);
        ITokenizedStrategy(address(vault)).shutdownStrategy();
    }

    function _validateBurn(
        address owner,
        uint256 balanceBefore,
        uint256 supplyBefore,
        uint256 burnedShares,
        CooldownSnapshot memory cooldownBefore
    ) internal {
        if (
            ERC20(address(vault)).balanceOf(owner) != balanceBefore - burnedShares
                || ERC20(address(vault)).totalSupply() != supplyBefore - burnedShares
        ) operationAccountingViolation = true;

        CooldownSnapshot memory cooldownAfter = _cooldown(owner);
        if (cooldownBefore.shares == 0) {
            if (!_sameCooldown(cooldownAfter, cooldownBefore)) delegatedOwnershipViolation = true;
        } else if (burnedShares >= cooldownBefore.shares) {
            if (cooldownAfter.cooldownEnd != 0 || cooldownAfter.windowEnd != 0 || cooldownAfter.shares != 0) {
                delegatedOwnershipViolation = true;
            }
        } else if (
            cooldownAfter.cooldownEnd != cooldownBefore.cooldownEnd
                || cooldownAfter.windowEnd != cooldownBefore.windowEnd
                || cooldownAfter.shares != cooldownBefore.shares - burnedShares
        ) {
            delegatedOwnershipViolation = true;
        }
    }

    function _cooldownBlocksTransfer(address owner, uint256 amount, uint256 balance, uint256 cooldownShares)
        internal
        view
        returns (bool)
    {
        if (
            ITokenizedStrategy(address(vault)).isShutdown() || vault.cooldownDuration() == 0
                || vault.cooldownBypass(owner) || cooldownShares == 0
        ) return false;

        uint256 nonCooldownShares = balance > cooldownShares ? balance - cooldownShares : 0;
        return amount > nonCooldownShares;
    }

    function _cooldown(address actor) internal view returns (CooldownSnapshot memory snapshot) {
        (snapshot.cooldownEnd, snapshot.windowEnd, snapshot.shares) = vault.getCooldownStatus(actor);
    }

    function _cooldownEquals(address actor, CooldownSnapshot memory expected) internal view returns (bool) {
        return _sameCooldown(_cooldown(actor), expected);
    }

    function _sameCooldown(CooldownSnapshot memory lhs, CooldownSnapshot memory rhs) internal pure returns (bool) {
        return lhs.cooldownEnd == rhs.cooldownEnd && lhs.windowEnd == rhs.windowEnd && lhs.shares == rhs.shares;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _otherActor(uint256 actorSeed, uint256 otherSeed) internal view returns (address) {
        uint256 actorIndex = actorSeed % actors.length;
        uint256 otherIndex = (actorIndex + 1 + (otherSeed % (actors.length - 1))) % actors.length;
        return actors[otherIndex];
    }

    function _actorPair(uint256 actorSeed, uint256 otherSeed) internal view returns (address, address) {
        return (_actor(actorSeed), _otherActor(actorSeed, otherSeed));
    }
}
