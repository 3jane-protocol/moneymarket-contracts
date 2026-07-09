// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LCCMockToken, LCCMockUSD3} from "./LCCBase.t.sol";
import {Test} from "../../../lib/forge-std/src/Test.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCAuctionLib} from "../../../src/lcc/libraries/LCCAuctionLib.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {OracleMock} from "../../../src/mocks/OracleMock.sol";
import {ORACLE_PRICE_SCALE, BPS} from "../../../src/libraries/ConstantsLib.sol";
import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";

function _revertSelector(bytes memory reason) pure returns (bytes4 selector) {
    if (reason.length < 4) return bytes4(0);
    assembly {
        selector := mload(add(reason, 32))
    }
}

/// @dev Reverts that lazy materialization is allowed to surface: the live-auction replay barrier and a
/// zero/reverting oracle at a pending slash disposal. Anything else must fail the invariant.
function _expectedMaterializeError(bytes memory reason) pure returns (bool) {
    bytes4 selector = _revertSelector(reason);
    return selector == LCCErrorsLib.AccountMaterializationIncomplete.selector
        || selector == LCCErrorsLib.OraclePriceInvalid.selector;
}

function _isTerminal(LCCVault vault_) view returns (bool) {
    uint256 maxEpochs = vault_.epochConfig().maxEpochs;
    return maxEpochs != 0 && vault_.currentEpoch() >= maxEpochs;
}

function _callWindowClosed(LCCVault vault_) view returns (bool) {
    uint256 maxEpochs = vault_.epochConfig().maxEpochs;
    if (maxEpochs == 0) return false;
    uint256 current = vault_.currentEpoch();
    return current >= maxEpochs
        || (current == maxEpochs - 1 && block.timestamp >= vault_.phaseEndsAt(maxEpochs - 1, ILCCVault.Phase.PreCall));
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
    OracleMock internal invariantOracle;
    address internal invariantOwner;
    address internal invariantTreasury;
    address[] internal actors;
    uint256 public ghostCumDeposited;
    uint256 public ghostCumMarginOut;

    constructor(
        LCCVault vault_,
        LCCMockToken margin_,
        LCCMockUSD3 usd3_,
        OracleMock oracle_,
        address owner_,
        address[] memory actors_
    ) {
        invariantVault = vault_;
        invariantMargin = margin_;
        invariantUsd3 = usd3_;
        invariantOracle = oracle_;
        invariantOwner = owner_;
        invariantTreasury = vault_.assetConfig().treasury;
        actors = actors_;
        ghostCumDeposited = margin_.balanceOf(address(vault_)) + margin_.balanceOf(invariantTreasury);
    }

    function perturbOracle(uint256 priceSeed) external {
        if (priceSeed % 32 == 0) {
            invariantOracle.setPrice((priceSeed / 32) % 2 == 0 ? 1 : ORACLE_PRICE_SCALE * 10_000);
            return;
        }

        invariantOracle.setPrice(_range(priceSeed, ORACLE_PRICE_SCALE / 100, ORACLE_PRICE_SCALE * 100));
    }

    function oracleOutageProbe(uint256 seed) external {
        if (seed % 16 != 0) return;

        invariantOracle.setPrice(0);
        try invariantVault.materializeAccount(actors[0]) {}
        catch (bytes memory reason) {
            if (!_expectedMaterializeError(reason)) fail();
        }
        invariantOracle.setPrice(ORACLE_PRICE_SCALE);
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        if (invariantVault.shutdownState().active) return;
        if (_isTerminal(invariantVault)) return;
        _sync();

        address actor = actors[_index(actorSeed)];
        uint256 amount = _range(amountSeed, 1e18, 10e18);
        ILCCVault.Account memory account = invariantVault.getAccount(actor);
        if (account.exitRequested && !account.exitClaimed) return;

        vm.prank(actor);
        try invariantVault.deposit(amount) returns (uint256) {
            // marginAsset enters the vault only via deposit; count the exact amount pulled in. A synced slash-fee
            // disposal in the same tx moves margin to the treasury, which the ledger's treasury term accounts for.
            ghostCumDeposited += amount;
        } catch (bytes memory reason) {
            if (!_expectedDepositError(reason)) fail();
        }
    }

    function requestExit(uint256 actorSeed) external {
        _sync();
        if (invariantVault.shutdownState().active) return;
        if (_isTerminal(invariantVault)) return;

        address actor = actors[_index(actorSeed)];
        try invariantVault.materializeAccount(actor) {}
        catch (bytes memory reason) {
            if (!_expectedSyncedOracleError(reason)) fail();
            return;
        }
        ILCCVault.Account memory account = invariantVault.getAccount(actor);
        if (account.exitRequested && !account.exitClaimed) return;
        if (account.pendingMargin != 0 || account.pendingCommitment != 0) return;
        if (account.activeMargin == 0 || account.activeCommitment == 0) return;
        if (
            invariantVault.currentEpoch()
                < account.commitmentStartEpoch + invariantVault.epochConfig().minCommitmentEpochs
        ) return;

        vm.prank(actor);
        try invariantVault.requestExit() returns (uint256 maturity) {
            ILCCVault.RiskConfig memory riskConfig = invariantVault.riskConfig();
            uint256 capacity = Math.mulDiv(riskConfig.protocolCommitmentCap, riskConfig.exitCapBps, BPS);
            if (account.activeCommitment <= capacity) {
                assertLe(invariantVault.exitBucketCommitmentByMaturity(maturity), capacity);
            }
        } catch (bytes memory reason) {
            if (!_expectedRequestExitError(reason)) fail();
        }
    }

    function openCall(uint256 amountSeed) external {
        _sync();
        if (invariantVault.shutdownState().active) return;
        if (_isTerminal(invariantVault)) return;
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
        uint256 obligation = invariantVault.obligationOf(epoch, actor);
        if (obligation == 0) return;

        // A payer who cannot cover the fundingAsset obligation would revert on transferFrom; that is the
        // real "chose not to fund -> slashed" path, so skip rather than fail. Under a high oracle price the
        // obligation can exceed the actor's minted funding balance.
        LCCMockToken fundingAsset = LCCMockToken(invariantUsd3.asset());

        if (actorSeed % 4 == 0) {
            address payer = actors[(actorSeed / 4) % actors.length];
            if (fundingAsset.balanceOf(payer) < obligation) return;
            uint256 vaultBalanceBefore = invariantMargin.balanceOf(address(invariantVault));
            uint256 treasuryBalanceBefore = invariantMargin.balanceOf(_treasury());
            vm.prank(payer);
            invariantVault.fundCall(actor);
            _recordMarginOut(vaultBalanceBefore, treasuryBalanceBefore);
        } else {
            if (fundingAsset.balanceOf(actor) < obligation) return;
            bool roll = (actorSeed / 32) % 2 == 0;
            ILCCVault.Account memory account = invariantVault.getAccount(actor);
            if (roll && account.exitRequested && !account.exitClaimed) roll = false;
            ILCCVault.Totals memory totals = invariantVault.totals();
            uint256 vaultBalanceBefore = invariantMargin.balanceOf(address(invariantVault));
            uint256 treasuryBalanceBefore = invariantMargin.balanceOf(_treasury());
            vm.prank(actor);
            invariantVault.fundCall(roll);
            if (roll) {
                ILCCVault.Account memory accountAfter = invariantVault.getAccount(actor);
                ILCCVault.Totals memory totalsAfter = invariantVault.totals();
                assertEq(accountAfter.activeMargin, account.activeMargin);
                assertEq(accountAfter.activeCommitment, account.activeCommitment);
                assertEq(totalsAfter.activeMargin, totals.activeMargin);
                assertEq(totalsAfter.activeCommitment, totals.activeCommitment);
                assertTrue(invariantVault.fundedEpoch(epoch, actor));
            }
            _recordMarginOut(vaultBalanceBefore, treasuryBalanceBefore);
        }
    }

    function probeEarlyRequestExit(uint256 actorSeed) external {
        if (invariantVault.epochConfig().minCommitmentEpochs == 0) return;
        if (invariantVault.shutdownState().active || _isTerminal(invariantVault)) return;
        _sync();
        if (invariantVault.syncState().pendingAuctionEpochPlusOne != 0) return;
        if (invariantVault.syncState().finalizedCallPrefix < invariantVault.calledEpochs().length) return;

        address actor = actors[_index(actorSeed)];
        ILCCVault.Account memory account = invariantVault.getAccount(actor);
        if (account.exitRequested && !account.exitClaimed) return;
        if (account.pendingMargin != 0 || account.pendingCommitment != 0) return;

        if (account.activeMargin == 0 || account.activeCommitment == 0) {
            if (invariantVault.currentPhase() != ILCCVault.Phase.Normal) return;
            if (invariantVault.getEpochState(invariantVault.currentEpoch()).callOpened) return;
            vm.prank(actor);
            try invariantVault.deposit(1e18) returns (uint256) {
                ghostCumDeposited += 1e18;
            } catch {
                return;
            }
            account = invariantVault.getAccount(actor);
        }

        if (
            invariantVault.currentEpoch()
                >= account.commitmentStartEpoch + invariantVault.epochConfig().minCommitmentEpochs
        ) return;

        _expectRequestExitRevert(actor, LCCErrorsLib.CommitmentNotMature.selector);
    }

    function probeDoubleFund(uint256 actorSeed) external {
        _sync();
        if (invariantVault.shutdownState().active) return;
        if (invariantVault.currentPhase() != ILCCVault.Phase.Funding) return;

        address actor = actors[_index(actorSeed)];
        uint256 epoch = invariantVault.currentEpoch();
        ILCCVault.EpochState memory state = invariantVault.getEpochState(epoch);
        if (!state.callOpened || state.slashFinalized || invariantVault.fundedEpoch(epoch, actor)) return;
        uint256 obligation = invariantVault.obligationOf(epoch, actor);
        if (obligation == 0 || LCCMockToken(invariantUsd3.asset()).balanceOf(actor) < obligation) return;

        uint256 vaultBalanceBefore = invariantMargin.balanceOf(address(invariantVault));
        uint256 treasuryBalanceBefore = invariantMargin.balanceOf(_treasury());
        vm.prank(actor);
        invariantVault.fundCall(false);
        _recordMarginOut(vaultBalanceBefore, treasuryBalanceBefore);

        _expectFundRevert(actor, false, LCCErrorsLib.AlreadyFunded.selector);
    }

    function probeFundAfterSlashFinalized(uint256 actorSeed) external {
        _sync();
        if (invariantVault.shutdownState().active) return;

        uint256 epoch = invariantVault.currentEpoch();
        ILCCVault.EpochState memory state = invariantVault.getEpochState(epoch);
        if (!state.callOpened) return;
        if (!state.slashFinalized) {
            if (block.timestamp < invariantVault.phaseEndsAt(epoch, ILCCVault.Phase.Funding)) return;
            invariantVault.finalizeEpochSlash(epoch);
            state = invariantVault.getEpochState(epoch);
            if (!state.slashFinalized) return;
        }

        _expectFundRevert(actors[_index(actorSeed)], false, LCCErrorsLib.InvalidPhase.selector);
    }

    function probeRollWhileExiting(uint256 actorSeed) external {
        _sync();
        if (invariantVault.shutdownState().active || _isTerminal(invariantVault)) return;
        if (invariantVault.currentPhase() != ILCCVault.Phase.Funding) return;

        address actor = actors[_index(actorSeed)];
        ILCCVault.Account memory account = invariantVault.getAccount(actor);
        if (!account.exitRequested || account.exitClaimed) return;

        uint256 epoch = invariantVault.currentEpoch();
        ILCCVault.EpochState memory state = invariantVault.getEpochState(epoch);
        if (!state.callOpened || state.slashFinalized || invariantVault.fundedEpoch(epoch, actor)) return;
        uint256 obligation = invariantVault.obligationOf(epoch, actor);
        if (obligation == 0 || LCCMockToken(invariantUsd3.asset()).balanceOf(actor) < obligation) return;

        _expectFundRevert(actor, true, LCCErrorsLib.ExitInProgress.selector);
    }

    function probeDepositWhileExiting(uint256 actorSeed) external {
        _sync();
        if (invariantVault.shutdownState().active || _isTerminal(invariantVault)) return;
        if (invariantVault.syncState().pendingAuctionEpochPlusOne != 0) return;

        address actor = actors[_index(actorSeed)];
        try invariantVault.materializeAccount(actor) {}
        catch (bytes memory reason) {
            if (!_expectedSyncedOracleError(reason)) fail();
            return;
        }
        ILCCVault.Account memory account = invariantVault.getAccount(actor);
        if (!account.exitRequested || account.exitClaimed) return;

        _expectDepositRevert(actor, 1e18, LCCErrorsLib.ExitInProgress.selector);
    }

    function probeTerminalGuards(uint256 actorSeed) external {
        if (invariantVault.shutdownState().active) return;
        if (!_isTerminal(invariantVault)) return;
        ILCCVault.SyncState memory syncState = invariantVault.syncState();
        if (syncState.pendingAuctionEpochPlusOne != 0) return;
        if (syncState.finalizedCallPrefix < invariantVault.calledEpochs().length) return;

        address actor = actors[_index(actorSeed)];
        _expectDepositRevert(actor, 1e18, LCCErrorsLib.VaultTerminal.selector);

        uint256 epoch = invariantVault.currentEpoch();
        vm.prank(invariantOwner);
        try invariantVault.openEpochCall(epoch, 1) {
            fail();
        } catch (bytes memory reason) {
            assertEq(_revertSelector(reason), LCCErrorsLib.VaultTerminal.selector);
        }

        _expectRequestExitRevert(actor, LCCErrorsLib.VaultTerminal.selector);
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
        // Cap the fill at the actor's fundingAsset balance: takeAuction pulls `fill` via transferFrom, and under a
        // high oracle price the shortfall can exceed the actor's minted balance, which would revert on liquidity
        // rather than a vault invariant.
        uint256 balance = LCCMockToken(invariantUsd3.asset()).balanceOf(actor);
        if (balance == 0) return;
        uint256 fill = _range(fillSeed, 1, remaining < balance ? remaining : balance);

        uint256 vaultBalanceBefore = invariantMargin.balanceOf(address(invariantVault));
        uint256 treasuryBalanceBefore = invariantMargin.balanceOf(_treasury());
        vm.prank(actor);
        invariantVault.takeAuction(fill);
        _recordMarginOut(vaultBalanceBefore, treasuryBalanceBefore);
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
        address actor = actors[_index(actorSeed)];

        try invariantVault.materializeAccount(actor) {}
        catch (bytes memory reason) {
            if (!_expectedSyncedOracleError(reason)) fail();
        }
    }

    function claimExit(uint256 actorSeed) external {
        _sync();

        address actor = actors[_index(actorSeed)];
        if (invariantVault.claimableExitedMargin(actor) == 0) return;

        uint256 vaultBalanceBefore = invariantMargin.balanceOf(address(invariantVault));
        uint256 treasuryBalanceBefore = invariantMargin.balanceOf(_treasury());
        vm.prank(actor);
        try invariantVault.claimExitedMargin(actor) returns (uint256) {
            _recordMarginOut(vaultBalanceBefore, treasuryBalanceBefore);
        } catch (bytes memory reason) {
            if (!_expectedMaterializeError(reason)) fail();
        }
    }

    function claimRemaining(uint256 actorSeed) external {
        if (!invariantVault.shutdownState().active && !_isTerminal(invariantVault)) return;

        address actor = actors[_index(actorSeed)];
        // Sync before the guard: getAccount is a read-only preview that stops at an unfinalized slash-eligible
        // epoch and shows pre-default margin, but claimRemainingMargin's synced replay applies the default first.
        // Materializing here finalizes that epoch so the guard matches the claim and cannot pass on stale margin.
        try invariantVault.materializeAccount(actor) {}
        catch (bytes memory reason) {
            if (!_expectedSyncedOracleError(reason)) fail();
            return;
        }
        ILCCVault.Account memory account = invariantVault.getAccount(actor);
        // claimableExitMargin is included so the matured-exiter payout branch is exercised, not just active/pending.
        if (account.activeMargin + account.pendingMargin + account.claimableExitMargin == 0) return;

        uint256 vaultBalanceBefore = invariantMargin.balanceOf(address(invariantVault));
        uint256 treasuryBalanceBefore = invariantMargin.balanceOf(_treasury());
        vm.prank(actor);
        try invariantVault.claimRemainingMargin(actor) returns (uint256) {
            _recordMarginOut(vaultBalanceBefore, treasuryBalanceBefore);
        } catch (bytes memory reason) {
            if (!_expectedMaterializeError(reason)) fail();
        }
    }

    function setRiskCaps(uint256 protocolSeed, uint256 exitCapSeed) external {
        _sync();
        if (invariantVault.shutdownState().active) return;

        ILCCVault.Totals memory totals = invariantVault.totals();
        uint256 currentUtilization = totals.activeCommitment + totals.pendingCommitment;
        uint256 maxCap = 10_000_000e18;
        uint256 existingCap = invariantVault.riskConfig().protocolCommitmentCap;
        // Floor the fuzzed cap at a realistic minimum: a degenerate sub-1e18 protocolCap (reachable when utilization
        // is 0) floors the exit-bucket capacity (protocolCap*exitCapBps/BPS) to 0, which requestExit legitimately
        // rejects with InvalidParams (_assignExitMaturity, LCCVault.sol:1290) -- an unrealistic owner action, not a
        // behavior worth fuzzing.
        uint256 floorCap = currentUtilization < 1e18 ? 1e18 : currentUtilization;
        // A synced cap reduction can first settle a live auction under old-cap headroom, then leave going-concern
        // totals transiently above the new cap. Keep live-auction cap reductions out of this invariant handler.
        if (invariantVault.syncState().pendingAuctionEpochPlusOne != 0 && floorCap < existingCap) {
            floorCap = existingCap;
        }
        if (floorCap >= maxCap) return;

        uint256 protocolCap = floorCap + _range(protocolSeed, 0, maxCap - floorCap);
        uint256 exitCapBps = _range(exitCapSeed, 500, 5_000);

        vm.prank(invariantOwner);
        try invariantVault.setRiskCaps(protocolCap, maxCap, exitCapBps, 0) {}
        catch (bytes memory reason) {
            if (!_expectedSyncedOracleError(reason)) fail();
        }
    }

    function shutdown(uint256 seed) external {
        _sync();
        if (invariantVault.shutdownState().active) return;
        if (seed % 64 != 0) return;
        ILCCVault.Totals memory totals = invariantVault.totals();
        if (totals.activeMargin + totals.pendingMargin == 0) return;

        // shutdown() is onlyOwner with no synced modifier and an oracle-free wind-down disposal, so its only revert
        // (ShutdownActive) is already guarded above; call it directly and let any unexpected revert fail the run.
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

    function _treasury() internal view returns (address) {
        return invariantTreasury;
    }

    function _expectDepositRevert(address actor, uint256 amount, bytes4 selector) internal {
        vm.prank(actor);
        try invariantVault.deposit(amount) {
            fail();
        } catch (bytes memory reason) {
            assertEq(_revertSelector(reason), selector);
        }
    }

    function _expectRequestExitRevert(address actor, bytes4 selector) internal {
        vm.prank(actor);
        try invariantVault.requestExit() {
            fail();
        } catch (bytes memory reason) {
            assertEq(_revertSelector(reason), selector);
        }
    }

    function _expectFundRevert(address actor, bool roll, bytes4 selector) internal {
        vm.prank(actor);
        try invariantVault.fundCall(roll) {
            fail();
        } catch (bytes memory reason) {
            assertEq(_revertSelector(reason), selector);
        }
    }

    // Per-action revert whitelists are kept minimal: only selectors reachable AND legitimate for that specific call.
    // `_expectedMaterializeError` (the _replayForUpdate barrier + oracle-disposal revert) is the base for the actions
    // that run _replayForUpdate: deposit, requestExit, and the claims (LCCVault.sol:300,337,373,394). deposit adds
    // CapExceeded (only thrown in deposit, LCCVault.sol:314) and InvalidAmount; requestExit adds InvalidAmount (a
    // synced default can zero its commitment after the stale guard) and ExitCapacityReached. Claims add NOTHING
    // beyond the base -- their preconditions make NoExitRequested/ExitNotMature/NothingToClaim unreachable, so
    // catching those would mask a preview-vs-claim divergence. materialize/setRiskCaps do NO per-account replay
    // (materializeAccount uses the bounded _replayAndRecordDefaults; setRiskCaps only folds global state), so the
    // only revert their synced fold can surface is the oracle-disposal one -- see `_expectedSyncedOracleError`.

    function _expectedDepositError(bytes memory reason) internal pure returns (bool) {
        bytes4 selector = _revertSelector(reason);
        return _expectedMaterializeError(reason) || selector == LCCErrorsLib.CapExceeded.selector
            || selector == LCCErrorsLib.InvalidAmount.selector;
    }

    function _expectedRequestExitError(bytes memory reason) internal pure returns (bool) {
        bytes4 selector = _revertSelector(reason);
        return _expectedMaterializeError(reason) || selector == LCCErrorsLib.InvalidAmount.selector
            || selector == LCCErrorsLib.ExitCapacityReached.selector;
    }

    function _expectedSyncedOracleError(bytes memory reason) internal pure returns (bool) {
        return _revertSelector(reason) == LCCErrorsLib.OraclePriceInvalid.selector;
    }

    /// @dev Records margin that left the vault to a non-treasury recipient (funder release, filler award, exit
    /// payout). A slash-fee disposal to the treasury can piggyback on any synced action; the ledger already
    /// subtracts the treasury balance, so the treasury portion is excluded here to avoid double-counting.
    function _recordMarginOut(uint256 vaultBalanceBefore, uint256 treasuryBalanceBefore) internal {
        uint256 vaultBalanceAfter = invariantMargin.balanceOf(address(invariantVault));
        if (vaultBalanceAfter >= vaultBalanceBefore) return;
        uint256 vaultDecrease = vaultBalanceBefore - vaultBalanceAfter;
        uint256 treasuryIncrease = invariantMargin.balanceOf(_treasury()) - treasuryBalanceBefore;
        ghostCumMarginOut += vaultDecrease - treasuryIncrease;
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
    uint256 internal initialTreasuryMargin;

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

        // Baseline the treasury margin the same moment the handler seeds its ghost ledger, so the treasury
        // reconciliation and the ghost-flow ledger agree on the pre-run treasury balance.
        initialTreasuryMargin = margin.balanceOf(treasury);
        handler = new LCCInvariantHandler(vault, margin, usd3, oracle, owner, invariantActors);
        targetContract(address(handler));
    }

    function invariant_DerivedActiveBalancesMatchGlobalTotals() public {
        if (!_materializeEveryoneForInvariant()) return;

        uint256 activeMargin;
        uint256 activeCommitment;
        uint256 pendingMargin;
        uint256 pendingCommitment;
        uint256 claimableMargin;

        MarginSums memory sums = _marginSums(invariantActors);
        activeMargin = sums.activeMargin;
        activeCommitment = sums.activeCommitment;
        pendingMargin = sums.pendingMargin;
        pendingCommitment = sums.pendingCommitment;
        claimableMargin = sums.claimableMargin;

        uint256[] memory called = vault.calledEpochs();
        // Single pass over the called epochs: asserts treasury + per-epoch conservation and returns the return-pool
        // margin dust accounting.
        (uint256 returnPoolEpochs, uint256 marginRatioSum) =
            _assertTreasuryAndEpochConservation(called, initialTreasuryMargin);

        ILCCVault.Totals memory totals = vault.totals();
        uint256 n = invariantActors.length;
        // Margin dust bound: return-pool re-attribution floors each defaulter's paired share (up to one unit per
        // defaulter per return-pool epoch) and, when the leveraged commitment share floors to zero at low price, the
        // paired-drop orphans up to returnPool/returnCommitment of that account's margin (LCCVault.sol:1110-1114).
        // Actor count times those ratios, with no amount-scale term, so a real margin over-count cannot hide under it.
        uint256 marginDustBound = n * (returnPoolEpochs + marginRatioSum);
        assertLe(activeMargin, totals.activeMargin);
        assertLe(uint256(totals.activeMargin) - activeMargin, marginDustBound);
        // Commitment: only the account-over-attribution direction is bounded (accounts can never back more than
        // totals). The reverse gap (totals > sum(accounts)) is a benign, self-healing orphan with NO tight bound:
        // disposal adds the full leveraged returnCommitment to totals (LCCVault.sol:932) while per-account
        // re-attribution floors/clamps it under a high oracle price or a setRiskCaps headroom clamp, and the
        // remainder recycles out of totals at the next slash (LCCVault.sol:806,811). It moves no margin -- only ever
        // conservatively over-states callable exposure -- and the return-path commitment math is unit-covered by
        // LCCReturnPool/LCCSlashFee. Any commitment error that moves value is still caught by the exact solvency
        // assertEq, the tight margin bound, the treasury reconciliation, and the ghost-flow ledger.
        assertLe(activeCommitment, totals.activeCommitment);
        assertEq(pendingMargin, totals.pendingMargin);
        assertEq(pendingCommitment, totals.pendingCommitment);

        uint256 auctionInventory;
        uint256 slot = vault.syncState().pendingAuctionEpochPlusOne;
        if (slot != 0) {
            LCCAuctionLib.AuctionState memory auction = vault.getAuctionState(slot - 1);
            auctionInventory = auction.marginPool - auction.marginAwarded;
        }
        assertEq(
            margin.balanceOf(address(vault)),
            uint256(totals.activeMargin) + uint256(totals.pendingMargin) + claimableMargin + auctionInventory
        );
        _assertGhostFlowLedger();
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function invariant_LiveAuctionSolvencyLowerBound() public view {
        ILCCVault.Totals memory totals = vault.totals();
        uint256 auctionInventory;
        uint256 slot = vault.syncState().pendingAuctionEpochPlusOne;
        if (slot != 0) {
            LCCAuctionLib.AuctionState memory auction = vault.getAuctionState(slot - 1);
            auctionInventory = auction.marginPool - auction.marginAwarded;
        }

        assertGe(
            margin.balanceOf(address(vault)),
            uint256(totals.activeMargin) + uint256(totals.pendingMargin) + auctionInventory
        );
    }

    function invariant_GoingConcernProtocolCap() public {
        if (!_materializeEveryoneForInvariant()) return;
        if (vault.shutdownState().active || _callWindowClosed(vault)) return;

        ILCCVault.Totals memory totals = vault.totals();
        assertLe(
            uint256(totals.activeCommitment) + uint256(totals.pendingCommitment),
            vault.riskConfig().protocolCommitmentCap
        );
    }

    function invariant_AuctionRampBound() public view {
        uint256[] memory called = vault.calledEpochs();
        ILCCVault.AuctionConfig memory auctionConfig = vault.auctionConfig();
        if (auctionConfig.auctionStepDuration == 0) return;

        for (uint256 i = 0; i < called.length; ++i) {
            uint256 epoch = called[i];
            ILCCVault.EpochState memory state = vault.getEpochState(epoch);
            if (!state.slashFinalized || state.slashedMargin == 0) continue;

            LCCAuctionLib.AuctionState memory auction = vault.getAuctionState(epoch);
            if (auction.marginPool == 0) continue;

            uint256 closedWindow =
                vault.phaseEndsAt(epoch, ILCCVault.Phase.Closed) - vault.phaseEndsAt(epoch, ILCCVault.Phase.Funding);
            uint256 maxOffered = LCCAuctionLib.offeredPool(
                auction.marginPool,
                closedWindow - 1,
                auctionConfig.auctionStepDuration,
                auctionConfig.auctionStepDecayRateBps
            );
            assertLe(auction.marginAwarded, maxOffered);
        }
    }

    function _assertGhostFlowLedger() internal view {
        assertEq(
            margin.balanceOf(address(vault)),
            handler.ghostCumDeposited() - handler.ghostCumMarginOut() - margin.balanceOf(treasury)
        );
    }

    function _materializeEveryoneForInvariant() internal returns (bool) {
        if (vault.syncState().pendingAuctionEpochPlusOne != 0) return false;
        try vault.materializeAccount(invariantActors[0]) {}
        catch (bytes memory reason) {
            if (!_expectedMaterializeError(reason)) fail();
            return false;
        }
        if (vault.syncState().pendingAuctionEpochPlusOne != 0) return false;

        for (uint256 i = 1; i < invariantActors.length; ++i) {
            try vault.materializeAccount(invariantActors[i]) {}
            catch (bytes memory reason) {
                if (!_expectedMaterializeError(reason)) fail();
                return false;
            }
        }
        return vault.syncState().pendingAuctionEpochPlusOne == 0;
    }

    function invariant_AuctionFillAndAwardBounds() public view {
        uint256[] memory called = vault.calledEpochs();
        for (uint256 i = 0; i < called.length; ++i) {
            LCCAuctionLib.AuctionState memory auction = vault.getAuctionState(called[i]);
            assertLe(auction.filledAmount, auction.shortfallAmount);
            assertLe(auction.marginAwarded, auction.marginPool);
        }
    }

    function afterInvariant() public virtual {
        if (!vault.shutdownState().active) {
            vm.prank(owner);
            vault.shutdown();
        }
        _drainRemainingMargin();
    }

    function _drainRemainingMargin() internal {
        uint256 calledLength = vault.calledEpochs().length;
        uint256 materializePasses = calledLength / 64 + 2;
        for (uint256 i = 0; i < invariantActors.length; ++i) {
            address actor = invariantActors[i];
            for (uint256 j = 0; j < materializePasses; ++j) {
                vault.materializeAccount(actor);
            }

            ILCCVault.Account memory account = vault.getAccount(actor);
            if (account.activeMargin + account.pendingMargin + account.claimableExitMargin == 0) continue;

            vm.prank(actor);
            vault.claimRemainingMargin(actor);
        }

        uint256 claimableMargin;
        for (uint256 i = 0; i < invariantActors.length; ++i) {
            claimableMargin += vault.getAccount(invariantActors[i]).claimableExitMargin;
        }

        uint256 dustBound = _marginDustBound(invariantActors.length);
        assertLe(
            uint256(vault.totals().activeMargin) + uint256(vault.totals().pendingMargin) + claimableMargin, dustBound
        );
    }
}

contract LCCAuctionStatefulInvariantTest is LCCStatefulInvariantTest {
    function setUp() public override {
        LCCBase.setUp();
        _deployAuctionVault();
        _setupHandler();
    }
}

contract LCCStressedGeometryStatefulInvariantTest is LCCStatefulInvariantTest {
    function setUp() public override {
        LCCBase.setUp();
        ILCCVault.VaultParams memory params = _auctionParams();
        params.epochLength = 97;
        params.normalDuration = 1;
        params.preCallDuration = 1;
        params.fundingDuration = 93;
        params.auctionStepCount = 2;
        params.marginRatioBps = 9_999;
        params.exitDelayEpochs = 8;
        params.exitCapBps = 313;
        params.minDepositAssets = 1e18;
        _deployVaultWithParams(params);
        _setupHandler();
    }
}

contract LCCHighDecayAuctionStatefulInvariantTest is LCCStatefulInvariantTest {
    function setUp() public override {
        LCCBase.setUp();
        ILCCVault.VaultParams memory params = _auctionParams();
        params.auctionStepCount = 2;
        params.auctionStepDecayRateBps = 9_999;
        params.slashFeeBps = 10_000;
        params.maxAuctionAwardBps = 500;
        _deployVaultWithParams(params);
        _setupHandler();
    }
}

contract LCCTerminalStatefulInvariantTest is LCCStatefulInvariantTest {
    function setUp() public override {
        LCCBase.setUp();
        _deployVaultWithParams(_terminalParams());
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _setupHandler();
    }

    function _terminalParams() internal view virtual returns (ILCCVault.VaultParams memory params) {
        params = _auctionParams();
        params.maxEpochs = 4;
    }

    function afterInvariant() public override {
        // Warp past the last epoch's Closed window (terminal) and drain every actor, asserting no margin is stranded.
        uint256 terminalStart = vault.phaseEndsAt(vault.epochConfig().maxEpochs - 1, ILCCVault.Phase.Closed);
        if (block.timestamp <= terminalStart + 300) {
            vm.warp(terminalStart + 301);
        }

        _drainRemainingMargin();
    }
}

contract LCCMinCommitmentStatefulInvariantTest is LCCTerminalStatefulInvariantTest {
    function _terminalParams() internal view override returns (ILCCVault.VaultParams memory params) {
        params = super._terminalParams();
        params.minCommitmentEpochs = 2;
    }
}
