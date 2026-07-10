// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";

contract LCCPauseMetamorphicTest is LCCBase {
    function testFuzzPauseResumeMatchesUnpausedLifecycle(uint8 rawPausePoint, uint32 rawDuration) public {
        uint256 pausePoint = bound(uint256(rawPausePoint), 0, 7);
        uint256 duration = bound(uint256(rawDuration), 1, 13 days);

        ILCCVault.VaultParams memory params = _auctionParams();
        LCCVault runA = _newVault(params);
        LCCVault runB = _newVault(params);
        _approveActors(runA);
        _approveActors(runB);

        bytes32 unpausedHash = _runScript(runA, type(uint256).max, 0);
        bytes32 pausedHash = _runScript(runB, pausePoint, duration);

        assertEq(pausedHash, unpausedHash);
    }

    function testFuzzShutdownWhilePausedMatchesShutdownAtSameEffectiveTime(uint32 rawDuration) public {
        uint256 duration = bound(uint256(rawDuration), 1, 13 days);
        ILCCVault.VaultParams memory params = _auctionParams();
        LCCVault unpausedRun = _newVault(params);
        LCCVault pausedRun = _newVault(params);
        _approveActors(unpausedRun);
        _approveActors(pausedRun);

        vm.warp(START + 1);
        vm.prank(alice);
        unpausedRun.deposit(100e18);
        vm.prank(alice);
        pausedRun.deposit(100e18);
        vm.prank(bob);
        unpausedRun.deposit(100e18);
        vm.prank(bob);
        pausedRun.deposit(100e18);

        vm.warp(START + NORMAL);
        vm.prank(owner);
        unpausedRun.openEpochCall(0, 200e18);
        vm.prank(owner);
        pausedRun.openEpochCall(0, 200e18);

        uint256 pauseAt = START + NORMAL + PRE_CALL + 10;
        vm.warp(pauseAt);
        vm.prank(owner);
        unpausedRun.shutdown();
        bytes32 unpausedHash = _stateHash(unpausedRun, 0);

        vm.prank(owner);
        pausedRun.pause();
        vm.warp(pauseAt + duration);
        vm.prank(owner);
        pausedRun.shutdown();

        assertEq(_stateHash(pausedRun, 0), unpausedHash);
        assertEq(pausedRun.shutdownState().timestamp, unpausedRun.shutdownState().timestamp);
        assertEq(pausedRun.shutdownState().epoch, unpausedRun.shutdownState().epoch);
        (, bool paused,, uint64 accumulated) = pausedRun.pauseState();
        assertFalse(paused);
        assertEq(accumulated, duration);
        assertEq(_effectiveTime(pausedRun), pauseAt);
    }

    function _runScript(LCCVault target, uint256 pausePoint, uint256 duration) internal returns (bytes32) {
        uint256 treasuryBefore = margin.balanceOf(treasury);
        uint256 shift;

        shift = _maybePause(target, pausePoint, 0, START + 1, shift, duration);
        vm.warp(START + 1 + shift);
        vm.prank(alice);
        target.deposit(100e18);
        vm.prank(bob);
        target.deposit(50e18);
        vm.prank(carol);
        target.deposit(50e18);

        shift = _maybePause(target, pausePoint, 1, START + NORMAL, shift, duration);
        vm.warp(START + NORMAL + shift);
        vm.prank(owner);
        target.openEpochCall(0, 200e18);

        shift = _maybePause(target, pausePoint, 2, START + NORMAL + PRE_CALL, shift, duration);
        vm.warp(START + NORMAL + PRE_CALL + shift);
        vm.prank(alice);
        target.fundCall(false);

        shift = _maybePause(target, pausePoint, 3, START + NORMAL + PRE_CALL + FUNDING, shift, duration);
        vm.warp(START + NORMAL + PRE_CALL + FUNDING + shift);
        target.finalizeEpochSlash(0);

        shift = _maybePause(target, pausePoint, 4, START + NORMAL + PRE_CALL + FUNDING + 5, shift, duration);
        vm.warp(START + NORMAL + PRE_CALL + FUNDING + 5 + shift);
        vm.prank(carol);
        target.takeAuction(40e18);

        shift = _maybePause(target, pausePoint, 5, START + EPOCH, shift, duration);
        vm.warp(START + EPOCH + shift);
        target.materializeAccount(alice);

        shift = _maybePause(target, pausePoint, 6, START + EPOCH + 1, shift, duration);
        vm.warp(START + EPOCH + 1 + shift);
        vm.prank(alice);
        target.requestExit();

        shift = _maybePause(target, pausePoint, 7, START + 2 * EPOCH, shift, duration);
        vm.warp(START + 2 * EPOCH + shift);
        vm.prank(alice);
        target.claimExitedMargin(alice);

        return _stateHash(target, margin.balanceOf(treasury) - treasuryBefore);
    }

    function _maybePause(
        LCCVault target,
        uint256 pausePoint,
        uint256 point,
        uint256 effectiveTimestamp,
        uint256 shift,
        uint256 duration
    ) internal returns (uint256) {
        if (pausePoint != point) return shift;

        vm.warp(effectiveTimestamp + shift);
        vm.prank(owner);
        target.pause();
        assertEq(_effectiveTime(target), effectiveTimestamp);

        vm.warp(effectiveTimestamp + shift + duration);
        assertEq(_effectiveTime(target), effectiveTimestamp);
        vm.prank(owner);
        target.unpause();

        return shift + duration;
    }

    function _stateHash(LCCVault target, uint256 treasuryDelta) internal view returns (bytes32) {
        bytes32 accountsHash =
            keccak256(abi.encode(target.getAccount(alice), target.getAccount(bob), target.getAccount(carol)));
        bytes32 epochsHash =
            keccak256(abi.encode(target.getEpochState(0), target.getEpochState(1), target.getAuctionState(0)));
        bytes32 globalHash = keccak256(abi.encode(target.totals(), target.syncState(), target.calledEpochs()));
        bytes32 outcomesHash = keccak256(
            abi.encode(
                target.fundedEpoch(0, alice),
                target.fundedEpoch(0, bob),
                target.fundedEpoch(0, carol),
                target.defaultedEpoch(0, alice),
                target.defaultedEpoch(0, bob),
                target.defaultedEpoch(0, carol)
            )
        );
        bytes32 balancesHash = keccak256(
            abi.encode(
                target.exitBucketMarginByMaturity(2),
                target.exitBucketCommitmentByMaturity(2),
                treasuryDelta,
                margin.balanceOf(address(target))
            )
        );
        return keccak256(abi.encode(accountsHash, epochsHash, globalHash, outcomesHash, balancesHash));
    }

    function _approveActors(LCCVault target) internal {
        _mintAndApprove(target, alice, 0, 0);
        _mintAndApprove(target, bob, 0, 0);
        _mintAndApprove(target, carol, 0, 0);
    }
}
