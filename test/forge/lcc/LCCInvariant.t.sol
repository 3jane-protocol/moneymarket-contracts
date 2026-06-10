// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LCCMockToken} from "./LCCBase.t.sol";
import {Test} from "../../../lib/forge-std/src/Test.sol";
import {LeveragedCallableCreditVault} from "../../../src/lcc/LeveragedCallableCreditVault.sol";
import {ILeveragedCallableCreditVault} from "../../../src/lcc/interfaces/ILeveragedCallableCreditVault.sol";

contract LCCInvariantTest is LCCBase {
    function testFinalizedEpochConservesCallOpenMargin() public {
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(300e18);
        _fund(alice);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        ILeveragedCallableCreditVault.EpochState memory state = vault.getEpochState(0);
        uint256 slashed = margin.balanceOf(treasury);

        assertEq(state.rawMarginReleased + state.honoredRawMarginRemaining + slashed, state.rawMarginAtCallOpen);
    }
}

contract LCCInvariantHandler is Test {
    LeveragedCallableCreditVault internal invariantVault;
    LCCMockToken internal invariantMargin;
    address internal invariantOwner;
    address[] internal actors;

    constructor(LeveragedCallableCreditVault vault_, LCCMockToken margin_, address owner_, address[] memory actors_) {
        invariantVault = vault_;
        invariantMargin = margin_;
        invariantOwner = owner_;
        actors = actors_;
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        if (invariantVault.shutdownActive()) return;
        _sync();

        address actor = actors[_index(actorSeed)];
        uint256 amount = _range(amountSeed, 1e18, 10e18);
        ILeveragedCallableCreditVault.Account memory account = invariantVault.getAccount(actor);
        if (account.exitRequested && !account.exitClaimed) return;

        uint256 callable = amount * 10_000 / invariantVault.marginRatioBps();
        if (
            invariantVault.totalActiveCallableUsdc() + invariantVault.totalPendingCallableUsdc() + callable
                > invariantVault.protocolCallableCapUsdc()
        ) {
            return;
        }
        if (account.activeCallableUsdc + account.pendingCallableUsdc + callable > invariantVault.userCallableCapUsdc()) return;

        vm.prank(actor);
        invariantVault.deposit(amount, actor);
    }

    function requestExit(uint256 actorSeed) external {
        _sync();
        if (invariantVault.shutdownActive()) return;

        address actor = actors[_index(actorSeed)];
        ILeveragedCallableCreditVault.Account memory account = invariantVault.getAccount(actor);
        if (account.exitRequested && !account.exitClaimed) return;
        if (account.pendingMargin != 0 || account.pendingCallableUsdc != 0) return;
        if (account.activeMargin == 0 || account.activeCallableUsdc == 0) return;

        vm.prank(actor);
        invariantVault.requestExit();
    }

    function openCall(uint256 amountSeed) external {
        _sync();
        if (invariantVault.shutdownActive()) return;
        if (invariantVault.currentPhase() != ILeveragedCallableCreditVault.Phase.PreCall) return;

        uint256 epoch = invariantVault.currentEpoch();
        if (invariantVault.getEpochState(epoch).callOpened) return;
        if (_hasPriorUnsettledCall(epoch)) return;

        uint256 denominator = invariantVault.totalActiveCallableUsdc();
        if (denominator == 0) return;
        uint256 amount = _range(amountSeed, 1, denominator);

        vm.prank(invariantOwner);
        invariantVault.openEpochCall(epoch, amount);
    }

    function fund(uint256 actorSeed) external {
        _sync();
        if (invariantVault.shutdownActive()) return;
        if (invariantVault.currentPhase() != ILeveragedCallableCreditVault.Phase.Funding) return;

        address actor = actors[_index(actorSeed)];
        uint256 epoch = invariantVault.currentEpoch();
        ILeveragedCallableCreditVault.EpochState memory state = invariantVault.getEpochState(epoch);
        if (!state.callOpened || state.slashFinalized || invariantVault.fundedEpoch(epoch, actor)) return;
        if (invariantVault.obligationOf(epoch, actor) == 0) return;

        vm.prank(actor);
        invariantVault.fundEpochCall(epoch);
    }

    function finalizeCall(uint256 epochSeed) external {
        uint256[] memory called = invariantVault.calledEpochs();
        if (called.length == 0) return;

        uint256 epoch = called[epochSeed % called.length];
        ILeveragedCallableCreditVault.EpochState memory state = invariantVault.getEpochState(epoch);
        if (!state.callOpened || state.slashFinalized) return;
        if (block.timestamp < invariantVault.phaseEndsAt(epoch, ILeveragedCallableCreditVault.Phase.Funding)) return;

        invariantVault.finalizeEpochSlash(epoch);
    }

    function materialize(uint256 actorSeed) external {
        address actor = actors[_index(actorSeed)];

        invariantVault.materializeAccount(actor);
    }

    function claimExit(uint256 actorSeed) external {
        _sync();

        address actor = actors[_index(actorSeed)];
        if (invariantVault.claimableExitedMargin(actor) == 0) return;

        vm.prank(actor);
        invariantVault.claimExitedMargin(actor);
    }

    function claimEmergency(uint256 actorSeed) external {
        if (!invariantVault.shutdownActive()) return;

        address actor = actors[_index(actorSeed)];
        ILeveragedCallableCreditVault.Account memory account = invariantVault.getAccount(actor);
        if (account.activeMargin + account.pendingMargin == 0) return;

        vm.prank(actor);
        invariantVault.claimEmergencyMargin(actor);
    }

    function setRiskCaps(uint256 protocolSeed, uint256 exitCapSeed) external {
        _sync();
        if (invariantVault.shutdownActive()) return;

        uint256 currentUtilization =
            invariantVault.totalActiveCallableUsdc() + invariantVault.totalPendingCallableUsdc();
        uint256 maxCap = 10_000_000e18;
        if (currentUtilization >= maxCap) return;

        uint256 protocolCap = currentUtilization + _range(protocolSeed, 1, maxCap - currentUtilization);
        uint256 exitCapBps = _range(exitCapSeed, 500, 5_000);

        vm.prank(invariantOwner);
        invariantVault.setRiskCaps(protocolCap, maxCap, exitCapBps);
    }

    function shutdown(uint256 seed) external {
        _sync();
        if (invariantVault.shutdownActive()) return;
        if (seed % 64 != 0) return;
        if (invariantVault.totalActiveMargin() + invariantVault.totalPendingMargin() == 0) return;

        vm.prank(invariantOwner);
        invariantVault.shutdown();
    }

    function warpToPreCall() external {
        uint256 epoch = invariantVault.currentEpoch();
        uint256 target = invariantVault.phaseEndsAt(epoch, ILeveragedCallableCreditVault.Phase.Normal);
        if (block.timestamp > target) {
            target = invariantVault.phaseEndsAt(epoch + 1, ILeveragedCallableCreditVault.Phase.Normal);
        }
        vm.warp(target);
    }

    function warpToFunding() external {
        uint256 epoch = invariantVault.currentEpoch();
        uint256 target = invariantVault.phaseEndsAt(epoch, ILeveragedCallableCreditVault.Phase.PreCall);
        if (block.timestamp > target) {
            target = invariantVault.phaseEndsAt(epoch + 1, ILeveragedCallableCreditVault.Phase.PreCall);
        }
        vm.warp(target);
    }

    function warpPastFunding() external {
        uint256 epoch = invariantVault.currentEpoch();
        uint256 target = invariantVault.phaseEndsAt(epoch, ILeveragedCallableCreditVault.Phase.Funding);
        if (block.timestamp > target) {
            target = invariantVault.phaseEndsAt(epoch + 1, ILeveragedCallableCreditVault.Phase.Funding);
        }
        vm.warp(target);
    }

    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + _range(secondsSeed, 1, 80));
    }

    function _index(uint256 seed) internal view returns (uint256) {
        return seed % actors.length;
    }

    function _range(uint256 seed, uint256 min, uint256 max) internal pure returns (uint256) {
        return min + (seed % (max - min + 1));
    }

    function _hasPriorUnsettledCall(uint256 epoch) internal view returns (bool) {
        uint256[] memory called = invariantVault.calledEpochs();
        uint256 finalizedPrefix = invariantVault.finalizedCallPrefix();
        return finalizedPrefix < called.length && called[finalizedPrefix] < epoch;
    }

    function _sync() internal {
        invariantVault.materializeAccount(actors[0]);
    }
}

contract LCCStatefulInvariantTest is LCCBase {
    LCCInvariantHandler internal handler;
    address[] internal invariantActors;

    function setUp() public override {
        super.setUp();

        invariantActors.push(alice);
        invariantActors.push(bob);
        invariantActors.push(carol);
        for (uint256 i = 0; i < 5; ++i) {
            address actor = makeAddr(string.concat("lcc-invariant-actor-", vm.toString(i)));
            invariantActors.push(actor);
            _mintAndApprove(actor, 1_000_000e18, 1_000_000e18);
        }

        handler = new LCCInvariantHandler(vault, margin, owner, invariantActors);
        targetContract(address(handler));
    }

    function invariant_DerivedActiveBalancesMatchGlobalTotals() public {
        for (uint256 i = 0; i < invariantActors.length; ++i) {
            vault.materializeAccount(invariantActors[i]);
        }

        uint256 activeMargin;
        uint256 activeCallable;
        uint256 pendingMargin;
        uint256 pendingCallable;
        uint256 claimableMargin;

        for (uint256 i = 0; i < invariantActors.length; ++i) {
            ILeveragedCallableCreditVault.Account memory account = vault.getAccount(invariantActors[i]);
            activeMargin += account.activeMargin;
            activeCallable += account.activeCallableUsdc;
            pendingMargin += account.pendingMargin;
            pendingCallable += account.pendingCallableUsdc;
            claimableMargin += account.claimableExitMargin;
        }

        assertEq(activeMargin, vault.totalActiveMargin());
        assertEq(activeCallable, vault.totalActiveCallableUsdc());
        assertEq(pendingMargin, vault.totalPendingMargin());
        assertEq(pendingCallable, vault.totalPendingCallableUsdc());
        assertGe(margin.balanceOf(address(vault)), activeMargin + pendingMargin + claimableMargin);
    }
}
