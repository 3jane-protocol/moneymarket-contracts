// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {BeaconProxy} from "../../../lib/openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Ownable} from "../../../lib/openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "../../../lib/openzeppelin/contracts/proxy/utils/Initializable.sol";
import {stdError} from "../../../lib/forge-std/src/StdError.sol";

import {LCCBase} from "./LCCBase.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {LCCVaultFactory} from "../../../src/lcc/LCCVaultFactory.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {BPS} from "../../../src/libraries/ConstantsLib.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";

contract LCCVaultV2 is LCCVault {
    constructor(address notificationVault_, address treasury_) LCCVault(notificationVault_, treasury_) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract LCCProxyTest is LCCBase {
    function testReinitializeReverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(_params(CAP, CAP));
    }

    function testDirectImplementationInitializeReverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vaultImplementation.initialize(_params(CAP, CAP));
    }

    function testBeaconUpgradeToRejectsNonOwner() public {
        LCCVaultV2 nextImplementation = new LCCVaultV2(address(notificationVault), treasury);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        beacon.upgradeTo(address(nextImplementation));
    }

    function testUpgradePreservesVaultState() public {
        _deposit(alice, 100e18);
        _openCall(50e18);

        ILCCVault.Totals memory totalsBefore = vault.totals();
        ILCCVault.Account memory accountBefore = vault.getAccount(alice);
        ILCCVault.EpochState memory epochBefore = vault.getEpochState(0);

        LCCVaultV2 nextImplementation = new LCCVaultV2(address(notificationVault), treasury);
        vm.prank(owner);
        beacon.upgradeTo(address(nextImplementation));

        LCCVaultV2 upgraded = LCCVaultV2(address(vault));
        assertEq(upgraded.version(), 2);

        ILCCVault.Totals memory totalsAfter = vault.totals();
        assertEq(totalsAfter.activeMargin, totalsBefore.activeMargin);
        assertEq(totalsAfter.activeCommitment, totalsBefore.activeCommitment);
        assertEq(totalsAfter.pendingMargin, totalsBefore.pendingMargin);
        assertEq(totalsAfter.pendingCommitment, totalsBefore.pendingCommitment);

        ILCCVault.Account memory accountAfter = vault.getAccount(alice);
        assertEq(accountAfter.activeMargin, accountBefore.activeMargin);
        assertEq(accountAfter.activeCommitment, accountBefore.activeCommitment);
        assertEq(accountAfter.calledEpochCursor, accountBefore.calledEpochCursor);

        ILCCVault.EpochState memory epochAfter = vault.getEpochState(0);
        assertEq(epochAfter.callOpened, epochBefore.callOpened);
        assertEq(epochAfter.callAmount, epochBefore.callAmount);
        assertEq(epochAfter.commitmentDenominator, epochBefore.commitmentDenominator);
        assertEq(epochAfter.marginAtCallOpen, epochBefore.marginAtCallOpen);
    }

    function testFactoryVaultsShareImmutableTreasury() public {
        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        params.slashFeeBps = BPS;

        LCCVaultFactory factory = new LCCVaultFactory(owner, address(beacon));
        vm.startPrank(owner);
        LCCVault first = LCCVault(factory.createVault(params));
        LCCVault second = LCCVault(factory.createVault(params));
        vm.stopPrank();

        _approveVault(first, alice);
        _approveVault(second, alice);

        vm.prank(alice);
        first.deposit(10e18);
        vm.prank(alice);
        second.deposit(20e18);

        vm.warp(START + NORMAL);
        vm.startPrank(owner);
        first.openEpochCall(0, 1e18);
        second.openEpochCall(0, 1e18);
        vm.stopPrank();

        _finishFunding();
        first.finalizeEpochSlash(0);
        second.finalizeEpochSlash(0);

        assertEq(margin.balanceOf(treasury), 30e18);
        assertEq(first.assetConfig().treasury, treasury);
        assertEq(second.assetConfig().treasury, treasury);
    }

    function testEmptyInitShellPanicsThenFirstCallerCanInitialize() public {
        LCCVault shell = LCCVault(address(new BeaconProxy(address(beacon), "")));

        vm.expectRevert(stdError.divisionError);
        shell.currentEpoch();

        vm.expectRevert(stdError.divisionError);
        shell.materializeAccount(alice);

        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        params.owner = alice;
        vm.prank(alice);
        shell.initialize(params);

        assertEq(shell.owner(), alice);
        assertEq(shell.epochConfig().epochLength, EPOCH);
    }

    function testWidthBoundsAtLimitPass() public {
        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        params.startTimestamp = type(uint64).max;
        _newVault(params);

        params = _params(CAP, CAP);
        params.maxEpochs = type(uint64).max;
        _newVault(params);

        params = _params(CAP, CAP);
        params.epochLength = type(uint32).max;
        params.normalDuration = type(uint32).max - 2;
        params.preCallDuration = 1;
        params.fundingDuration = 1;
        _newVault(params);

        params = _auctionParams();
        params.epochLength = type(uint32).max;
        params.normalDuration = 1;
        params.preCallDuration = 1;
        params.fundingDuration = 1;
        params.auctionStepCount = type(uint32).max - 3;
        _newVault(params);
    }

    function testWidthBoundsAboveLimitRevertInvalidParams() public {
        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        params.startTimestamp = uint256(type(uint64).max) + 1;
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        _newVault(params);

        params = _params(CAP, CAP);
        params.maxEpochs = uint256(type(uint64).max) + 1;
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        _newVault(params);

        params = _params(CAP, CAP);
        params.epochLength = uint256(type(uint32).max) + 1;
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        _newVault(params);

        params = _params(CAP, CAP);
        params.normalDuration = uint256(type(uint32).max) + 1;
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        _newVault(params);

        params = _params(CAP, CAP);
        params.preCallDuration = uint256(type(uint32).max) + 1;
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        _newVault(params);

        params = _params(CAP, CAP);
        params.fundingDuration = uint256(type(uint32).max) + 1;
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        _newVault(params);

        params = _auctionParams();
        params.auctionStepCount = uint256(type(uint32).max) + 1;
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        _newVault(params);
    }

    function _approveVault(LCCVault target, address user) internal {
        vm.startPrank(user);
        margin.approve(address(target), type(uint256).max);
        usdc.approve(address(target), type(uint256).max);
        vm.stopPrank();
    }
}
