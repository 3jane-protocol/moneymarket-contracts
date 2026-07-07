// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LCCMockToken, LCCMockUSD3} from "./LCCBase.t.sol";
import {Test} from "../../../lib/forge-std/src/Test.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCAuctionLib} from "../../../src/lcc/libraries/LCCAuctionLib.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";

/// @dev Reverts that lazy materialization is allowed to surface: the live-auction replay barrier and a
/// zero/reverting oracle at a pending slash disposal. Anything else must fail the invariant.
function _expectedMaterializeError(bytes memory reason) pure returns (bool) {
    if (reason.length < 4) return false;
    bytes4 selector;
    assembly {
        selector := mload(add(reason, 32))
    }
    return selector == LCCErrorsLib.AccountMaterializationIncomplete.selector
        || selector == LCCErrorsLib.OraclePriceInvalid.selector;
}

contract LCCInvariantTest is LCCBase {
    function testFinalizedEpochConservesCallOpenMargin() public {
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(300e18);
        _fund(alice);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        uint256 disposedSlash = margin.balanceOf(treasury) + state.returnPool;

        assertEq(state.marginReleased + state.fundedUsersRemainingMargin + disposedSlash, state.marginAtCallOpen);
    }
}

contract LCCInvariantHandler is Test {
    LCCVault internal invariantVault;
    LCCMockToken internal invariantMargin;
    LCCMockUSD3 internal invariantUsd3;
    address internal invariantOwner;
    address[] internal actors;

    constructor(LCCVault vault_, LCCMockToken margin_, LCCMockUSD3 usd3_, address owner_, address[] memory actors_) {
        invariantVault = vault_;
        invariantMargin = margin_;
        invariantUsd3 = usd3_;
        invariantOwner = owner_;
        actors = actors_;
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        if (invariantVault.shutdownState().active) return;
        if (_terminal()) return;
        _sync();
        if (invariantVault.syncState().pendingAuctionEpochPlusOne != 0) return;

        address actor = actors[_index(actorSeed)];
        uint256 amount = _range(amountSeed, 1e18, 10e18);
        ILCCVault.Account memory account = invariantVault.getAccount(actor);
        if (account.exitRequested && !account.exitClaimed) return;

        uint256 commitment = amount * 10_000 / invariantVault.epochConfig().marginRatioBps;
        if (
            invariantVault.totals().activeCommitment + invariantVault.totals().pendingCommitment + commitment
                > invariantVault.riskConfig().protocolCommitmentCap
        ) {
            return;
        }
        if (
            account.activeCommitment + account.pendingCommitment + commitment
                > invariantVault.riskConfig().userCommitmentCap
        ) {
            return;
        }

        vm.prank(actor);
        invariantVault.deposit(amount);
    }

    function requestExit(uint256 actorSeed) external {
        _sync();
        if (invariantVault.shutdownState().active) return;
        if (_terminal()) return;
        if (invariantVault.syncState().pendingAuctionEpochPlusOne != 0) return;

        address actor = actors[_index(actorSeed)];
        ILCCVault.Account memory account = invariantVault.getAccount(actor);
        if (account.exitRequested && !account.exitClaimed) return;
        if (account.pendingMargin != 0 || account.pendingCommitment != 0) return;
        if (account.activeMargin == 0 || account.activeCommitment == 0) return;

        vm.prank(actor);
        invariantVault.requestExit();
    }

    function openCall(uint256 amountSeed) external {
        _sync();
        if (invariantVault.shutdownState().active) return;
        if (_terminal()) return;
        if (invariantVault.syncState().pendingAuctionEpochPlusOne != 0) return;
        if (invariantVault.currentPhase() != ILCCVault.Phase.PreCall) return;

        uint256 epoch = invariantVault.currentEpoch();
        if (invariantVault.getEpochState(epoch).callOpened) return;
        if (_hasPriorUnsettledCall(epoch)) return;

        uint256 denominator = invariantVault.totals().activeCommitment;
        if (denominator == 0) return;
        uint256 amount = _range(amountSeed, 1, denominator);

        vm.prank(invariantOwner);
        invariantVault.openEpochCall(epoch, amount);
    }

    function fund(uint256 actorSeed) external {
        _sync();
        if (invariantVault.shutdownState().active) return;
        if (invariantVault.currentPhase() != ILCCVault.Phase.Funding) return;

        address actor = actors[_index(actorSeed)];
        uint256 epoch = invariantVault.currentEpoch();
        ILCCVault.EpochState memory state = invariantVault.getEpochState(epoch);
        if (!state.callOpened || state.slashFinalized || invariantVault.fundedEpoch(epoch, actor)) return;
        if (invariantVault.obligationOf(epoch, actor) == 0) return;

        if (actorSeed % 4 == 0) {
            address payer = actors[(actorSeed / 4) % actors.length];
            vm.prank(payer);
            invariantVault.fundCall(actor);
        } else {
            bool roll = (actorSeed / 32) % 2 == 0;
            ILCCVault.Account memory account = invariantVault.getAccount(actor);
            if (roll && account.exitRequested && !account.exitClaimed) roll = false;
            vm.prank(actor);
            invariantVault.fundCall(roll);
        }
    }

    function takeAuction(uint256 actorSeed, uint256 fillSeed) external {
        if (invariantVault.shutdownState().active) return;

        uint256 slot = invariantVault.syncState().pendingAuctionEpochPlusOne;
        if (slot == 0) return;
        uint256 epoch = slot - 1;
        if (block.timestamp >= invariantVault.phaseEndsAt(epoch, ILCCVault.Phase.Closed)) {
            return;
        }

        LCCAuctionLib.AuctionState memory state = invariantVault.getAuctionState(epoch);
        uint256 remaining = state.shortfallAmount - state.filledAmount;
        if (remaining == 0) return;

        address actor = actors[_index(actorSeed)];
        uint256 fill = _range(fillSeed, 1, remaining);

        vm.prank(actor);
        invariantVault.takeAuction(fill);
    }

    function warpIntoClosed(uint256 seed) external {
        uint256 epoch = invariantVault.currentEpoch();
        uint256 fundingEnd = invariantVault.phaseEndsAt(epoch, ILCCVault.Phase.Funding);
        uint256 epochEnd = invariantVault.phaseEndsAt(epoch, ILCCVault.Phase.Closed);
        if (epochEnd <= fundingEnd + 1) return;

        uint256 target = fundingEnd + _range(seed, 0, epochEnd - fundingEnd - 1);
        if (target <= block.timestamp) return;
        vm.warp(target);
    }

    function finalizeCall(uint256 epochSeed) external {
        uint256[] memory called = invariantVault.calledEpochs();
        if (called.length == 0) return;

        uint256 epoch = called[epochSeed % called.length];
        ILCCVault.EpochState memory state = invariantVault.getEpochState(epoch);
        if (!state.callOpened || state.slashFinalized) return;
        if (block.timestamp < invariantVault.phaseEndsAt(epoch, ILCCVault.Phase.Funding)) return;

        invariantVault.finalizeEpochSlash(epoch);
    }

    function materialize(uint256 actorSeed) external {
        if (_liveAuction()) return;
        address actor = actors[_index(actorSeed)];

        invariantVault.materializeAccount(actor);
    }

    function claimExit(uint256 actorSeed) external {
        _sync();
        if (invariantVault.syncState().pendingAuctionEpochPlusOne != 0) return;

        address actor = actors[_index(actorSeed)];
        if (invariantVault.claimableExitedMargin(actor) == 0) return;

        vm.prank(actor);
        invariantVault.claimExitedMargin(actor);
    }

    function claimRemaining(uint256 actorSeed) external {
        if (!invariantVault.shutdownState().active && !_terminal()) return;
        if (_liveAuction()) return;

        address actor = actors[_index(actorSeed)];
        // Sync before the guard: getAccount is a read-only preview that stops at an unfinalized slash-eligible
        // epoch and shows pre-default margin, but claimRemainingMargin's synced replay applies the default first.
        // Materializing here finalizes that epoch so the guard matches the claim and cannot pass on stale margin
        // (which would revert NothingToClaim and trip fail_on_revert).
        invariantVault.materializeAccount(actor);
        ILCCVault.Account memory account = invariantVault.getAccount(actor);
        // claimableExitMargin is included so the matured-exiter payout branch is exercised, not just active/pending.
        if (account.activeMargin + account.pendingMargin + account.claimableExitMargin == 0) return;

        vm.prank(actor);
        invariantVault.claimRemainingMargin(actor);
    }

    function setRiskCaps(uint256 protocolSeed, uint256 exitCapSeed) external {
        _sync();
        if (invariantVault.shutdownState().active) return;
        if (invariantVault.syncState().pendingAuctionEpochPlusOne != 0) return;

        uint256 currentUtilization =
            invariantVault.totals().activeCommitment + invariantVault.totals().pendingCommitment;
        uint256 maxCap = 10_000_000e18;
        if (currentUtilization >= maxCap) return;

        uint256 protocolCap = currentUtilization + _range(protocolSeed, 1, maxCap - currentUtilization);
        uint256 exitCapBps = _range(exitCapSeed, 500, 5_000);

        vm.prank(invariantOwner);
        invariantVault.setRiskCaps(protocolCap, maxCap, exitCapBps, 0);
    }

    function shutdown(uint256 seed) external {
        _sync();
        if (invariantVault.shutdownState().active) return;
        if (invariantVault.syncState().pendingAuctionEpochPlusOne != 0) return;
        if (seed % 64 != 0) return;
        if (invariantVault.totals().activeMargin + invariantVault.totals().pendingMargin == 0) return;

        vm.prank(invariantOwner);
        invariantVault.shutdown();
    }

    function warpToPreCall() external {
        uint256 epoch = invariantVault.currentEpoch();
        uint256 target = invariantVault.phaseEndsAt(epoch, ILCCVault.Phase.Normal);
        if (block.timestamp > target) {
            target = invariantVault.phaseEndsAt(epoch + 1, ILCCVault.Phase.Normal);
        }
        vm.warp(target);
    }

    function warpToFunding() external {
        uint256 epoch = invariantVault.currentEpoch();
        uint256 target = invariantVault.phaseEndsAt(epoch, ILCCVault.Phase.PreCall);
        if (block.timestamp > target) {
            target = invariantVault.phaseEndsAt(epoch + 1, ILCCVault.Phase.PreCall);
        }
        vm.warp(target);
    }

    function warpPastFunding() external {
        uint256 epoch = invariantVault.currentEpoch();
        uint256 target = invariantVault.phaseEndsAt(epoch, ILCCVault.Phase.Funding);
        if (block.timestamp > target) {
            target = invariantVault.phaseEndsAt(epoch + 1, ILCCVault.Phase.Funding);
        }
        vm.warp(target);
    }

    function warpToTerminal(uint256 seed) external {
        uint256 me = invariantVault.epochConfig().maxEpochs;
        if (me == 0) return;
        uint256 target = invariantVault.phaseEndsAt(me - 1, ILCCVault.Phase.Closed) + _range(seed, 0, 300);
        if (target <= block.timestamp) return;
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
        uint256 finalizedPrefix = invariantVault.syncState().finalizedCallPrefix;
        return finalizedPrefix < called.length && called[finalizedPrefix] < epoch;
    }

    function _terminal() internal view returns (bool) {
        uint256 me = invariantVault.epochConfig().maxEpochs;
        return me != 0 && invariantVault.currentEpoch() >= me;
    }

    function _liveAuction() internal view returns (bool) {
        uint256 slot = invariantVault.syncState().pendingAuctionEpochPlusOne;
        return slot != 0 && block.timestamp < invariantVault.phaseEndsAt(slot - 1, ILCCVault.Phase.Closed);
    }

    function _sync() internal {
        if (invariantVault.syncState().pendingAuctionEpochPlusOne != 0) return;
        try invariantVault.materializeAccount(actors[0]) {}
        catch (bytes memory reason) {
            if (!_expectedMaterializeError(reason)) fail();
        }
    }
}

contract LCCStatefulInvariantTest is LCCBase {
    LCCInvariantHandler internal handler;
    address[] internal invariantActors;

    function setUp() public virtual override {
        super.setUp();
        _setupHandler();
    }

    function _setupHandler() internal {
        invariantActors.push(alice);
        invariantActors.push(bob);
        invariantActors.push(carol);
        for (uint256 i = 0; i < 5; ++i) {
            address actor = makeAddr(string.concat("lcc-invariant-actor-", vm.toString(i)));
            invariantActors.push(actor);
            _mintAndApprove(actor, 1_000_000e18, 1_000_000e18);
        }

        handler = new LCCInvariantHandler(vault, margin, usd3, owner, invariantActors);
        targetContract(address(handler));
    }

    function invariant_DerivedActiveBalancesMatchGlobalTotals() public {
        if (vault.syncState().pendingAuctionEpochPlusOne != 0) return;
        try vault.materializeAccount(invariantActors[0]) {}
        catch (bytes memory reason) {
            if (!_expectedMaterializeError(reason)) fail();
            return;
        }
        if (vault.syncState().pendingAuctionEpochPlusOne != 0) return;

        for (uint256 i = 0; i < invariantActors.length; ++i) {
            try vault.materializeAccount(invariantActors[i]) {}
            catch (bytes memory reason) {
                if (!_expectedMaterializeError(reason)) fail();
                return;
            }
        }

        uint256 activeMargin;
        uint256 activeCommitment;
        uint256 pendingMargin;
        uint256 pendingCommitment;
        uint256 claimableMargin;

        for (uint256 i = 0; i < invariantActors.length; ++i) {
            ILCCVault.Account memory account = vault.getAccount(invariantActors[i]);
            activeMargin += account.activeMargin;
            activeCommitment += account.activeCommitment;
            pendingMargin += account.pendingMargin;
            pendingCommitment += account.pendingCommitment;
            claimableMargin += account.claimableExitMargin;
        }

        uint256 dustBound = vault.calledEpochs().length * invariantActors.length;
        assertLe(activeMargin, vault.totals().activeMargin);
        assertLe(vault.totals().activeMargin - activeMargin, dustBound);
        assertLe(activeCommitment, vault.totals().activeCommitment);
        assertLe(vault.totals().activeCommitment - activeCommitment, dustBound);
        assertEq(pendingMargin, vault.totals().pendingMargin);
        assertEq(pendingCommitment, vault.totals().pendingCommitment);

        uint256 auctionInventory;
        uint256 slot = vault.syncState().pendingAuctionEpochPlusOne;
        if (slot != 0) {
            LCCAuctionLib.AuctionState memory auction = vault.getAuctionState(slot - 1);
            auctionInventory = auction.marginPool - auction.marginAwarded;
        }
        assertGe(margin.balanceOf(address(vault)), activeMargin + pendingMargin + claimableMargin + auctionInventory);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function invariant_AuctionFillAndAwardBounds() public view {
        uint256[] memory called = vault.calledEpochs();
        for (uint256 i = 0; i < called.length; ++i) {
            LCCAuctionLib.AuctionState memory auction = vault.getAuctionState(called[i]);
            assertLe(auction.filledAmount, auction.shortfallAmount);
            assertLe(auction.marginAwarded, auction.marginPool);
        }
    }
}

contract LCCAuctionStatefulInvariantTest is LCCStatefulInvariantTest {
    function setUp() public override {
        LCCBase.setUp();
        _deployAuctionVault();
        _setupHandler();
    }
}

contract LCCTerminalStatefulInvariantTest is LCCStatefulInvariantTest {
    function setUp() public override {
        LCCBase.setUp();
        ILCCVault.VaultParams memory params = _auctionParams();
        params.maxEpochs = 4;
        _deployVaultWithParams(params);
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _setupHandler();
    }

    function afterInvariant() public {
        // Warp past the last epoch's Closed window (terminal) and drain every actor, asserting no margin is stranded.
        uint256 terminalStart = vault.phaseEndsAt(vault.epochConfig().maxEpochs - 1, ILCCVault.Phase.Closed);
        if (block.timestamp <= terminalStart + 300) {
            vm.warp(terminalStart + 301);
        }

        for (uint256 i = 0; i < invariantActors.length; ++i) {
            address actor = invariantActors[i];
            // Settles any pending auction and finalizes slashes so the has-margin check below matches the claim's
            // own synced replay; one call suffices given the vault has at most maxEpochs called epochs.
            vault.materializeAccount(actor);

            ILCCVault.Account memory account = vault.getAccount(actor);
            if (account.activeMargin + account.pendingMargin + account.claimableExitMargin == 0) continue;

            vm.prank(actor);
            vault.claimRemainingMargin(actor);
        }

        uint256 claimableMargin;
        for (uint256 i = 0; i < invariantActors.length; ++i) {
            claimableMargin += vault.getAccount(invariantActors[i]).claimableExitMargin;
        }

        uint256 dustBound = vault.calledEpochs().length * invariantActors.length;
        assertLe(
            uint256(vault.totals().activeMargin) + uint256(vault.totals().pendingMargin) + claimableMargin, dustBound
        );
    }
}
