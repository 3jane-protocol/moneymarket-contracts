// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LCCMockToken, LCCMockUSD3} from "./LCCBase.t.sol";
import {Test} from "../../../lib/forge-std/src/Test.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCAuctionLib} from "../../../src/lcc/libraries/LCCAuctionLib.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {LCCEventsLib} from "../../../src/lcc/libraries/LCCEventsLib.sol";
import {OracleMock} from "../../../src/mocks/OracleMock.sol";
import {ORACLE_PRICE_SCALE, BPS} from "../../../src/libraries/ConstantsLib.sol";
import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "../../../lib/forge-std/src/Vm.sol";

function _revertSelector(bytes memory reason) pure returns (bytes4 selector) {
    if (reason.length < 4) return bytes4(0);
    assembly {
        selector := mload(add(reason, 32))
    }
}

/// @dev The bounded replay barrier is the only revert lazy materialization is allowed to surface.
function _expectedMaterializeError(bytes memory reason) pure returns (bool) {
    return _revertSelector(reason) == LCCErrorsLib.AccountMaterializationIncomplete.selector;
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
        uint256 disposedSlash = margin.balanceOf(treasury) + vault.pendingTreasuryMargin() + state.returnPool;

        assertEq(state.marginReleased + state.fundedUsersRemainingMargin + disposedSlash, state.marginAtCallOpen);
    }

    function testLiveAuctionCapWritePreservesGrandfatheredExposureGhost() public {
        _deployAuctionVault();

        _deposit(alice, 100e18);
        vm.warp(START + NORMAL);
        _deposit(bob, 500e18);
        vm.prank(owner);
        vault.openEpochCall(0, 200e18);

        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        LCCInvariantHandler replayHandler = new LCCInvariantHandler(vault, margin, usd3, oracle, owner, actors);

        uint256 protocolCap = 500e18;
        uint256 grandfatheringSeed = 4 * (protocolCap - 1);
        replayHandler.setRiskCaps(grandfatheringSeed, type(uint256).max, 313);
        uint256 safelyMeasuredGhost = replayHandler.ghostGrandfatheredOverCapExposure();
        assertEq(safelyMeasuredGhost, 700e18);

        vm.warp(START + NORMAL + PRE_CALL + FUNDING);
        replayHandler.setRiskCaps(grandfatheringSeed, type(uint256).max, 313);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);

        vm.prank(carol);
        vault.takeAuction(type(uint256).max, 0, type(uint256).max);

        ILCCVault.Totals memory totals = vault.totals();
        uint256 settledUtilization = uint256(totals.activeCommitment) + uint256(totals.pendingCommitment);
        uint256 settledOverCapExposure = Math.saturatingSub(settledUtilization, protocolCap);
        assertEq(settledOverCapExposure, safelyMeasuredGhost);
        assertLe(settledOverCapExposure, replayHandler.ghostGrandfatheredOverCapExposure());
    }
}

contract LCCInvariantHandler is Test {
    uint256 internal constant MIN_RETURN_COMMITMENT = 1e6;

    LCCVault internal invariantVault;
    LCCMockToken internal invariantMargin;
    LCCMockUSD3 internal invariantUsd3;
    OracleMock internal invariantOracle;
    address internal invariantOwner;
    address internal invariantTreasury;
    address[] internal actors;
    uint256 public ghostCumDeposited;
    uint256 public ghostCumMarginOut;
    uint256 public ghostGrandfatheredOverCapExposure;
    uint256 public ghostUserCapClampCount;

    modifier capWatch() {
        vm.recordLogs();
        _ensureUserCapClampCoverage();
        uint256 capBefore = invariantVault.riskConfig().protocolCommitmentCap;
        bool shutdownBefore = invariantVault.shutdownState().active;
        _;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertDisposalsRespectHeadroom(logs, capBefore, shutdownBefore);
        _countUserCapClamps(logs);
    }

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

    function perturbOracle(uint256 priceSeed) external capWatch {
        if (priceSeed % 32 == 0) {
            invariantOracle.setPrice((priceSeed / 32) % 2 == 0 ? 1 : ORACLE_PRICE_SCALE * 10_000);
            return;
        }

        invariantOracle.setPrice(_range(priceSeed, ORACLE_PRICE_SCALE / 100, ORACLE_PRICE_SCALE * 100));
    }

    function oracleOutageProbe(uint256 seed) external capWatch {
        if (seed % 16 != 0) return;

        invariantOracle.setPrice(0);
        try invariantVault.materializeAccount(actors[0]) {}
        catch (bytes memory reason) {
            if (!_expectedMaterializeError(reason)) fail();
        }
        invariantOracle.setPrice(ORACLE_PRICE_SCALE);
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) external capWatch {
        if (invariantVault.shutdownState().active) return;
        if (_isTerminal(invariantVault)) return;
        _sync();

        address actor = actors[_index(actorSeed)];
        uint256 amount = _range(amountSeed, 1, 10e18);
        ILCCVault.Account memory account = invariantVault.getAccount(actor);
        if (account.exitRequested && !account.exitClaimed) return;

        vm.prank(actor);
        try invariantVault.deposit(amount, 1, type(uint256).max, true, type(uint256).max) returns (uint256) {
            // marginAsset enters the vault only via deposit; count the exact amount pulled in. Slash disposal may
            // accrue pending treasury margin in the same transaction, which remains in the vault until swept.
            ghostCumDeposited += amount;
        } catch (bytes memory reason) {
            if (!_expectedDepositError(reason)) fail();
        }
    }

    function requestExit(uint256 actorSeed, uint256 maxDeferralSeed) external capWatch {
        _sync();
        if (invariantVault.shutdownState().active) return;
        if (_isTerminal(invariantVault)) return;

        // Keep 15/16 draws binding-sized while reserving 1/32 each for raw-large and unbounded requests.
        uint256 maxDeferralEpochs;
        if (maxDeferralSeed == type(uint256).max || maxDeferralSeed % 32 == 0) {
            maxDeferralEpochs = type(uint256).max;
        } else if (maxDeferralSeed % 16 == 0) {
            maxDeferralEpochs = maxDeferralSeed;
        } else {
            maxDeferralEpochs = _range(maxDeferralSeed, 0, 4);
        }

        address actor = actors[_index(actorSeed)];
        try invariantVault.materializeAccount(actor) {}
        catch (bytes memory reason) {
            if (!_expectedMaterializeError(reason)) fail();
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

        uint256 expectedMaturity = _expectedExitMaturity(account.activeCommitment);
        uint256 earliestMaturity = invariantVault.currentEpoch() + invariantVault.epochConfig().exitDelayEpochs;
        if (expectedMaturity - earliestMaturity > maxDeferralEpochs) {
            vm.prank(actor);
            try invariantVault.requestExit(maxDeferralEpochs, type(uint256).max) {
                fail();
            } catch (bytes memory reason) {
                if (!_expectedRequestExitError(reason)) {
                    assertEq(_revertSelector(reason), LCCErrorsLib.ExitDeferralExceeded.selector);
                }
            }
            return;
        }

        vm.prank(actor);
        try invariantVault.requestExit(maxDeferralEpochs, type(uint256).max) returns (uint256 maturity) {
            assertEq(maturity, expectedMaturity);
            ILCCVault.RiskConfig memory riskConfig = invariantVault.riskConfig();
            uint256 activeCommitment = invariantVault.totals().activeCommitment;
            uint256 capacity = Math.max(
                1, Math.mulDiv(Math.max(riskConfig.protocolCommitmentCap, activeCommitment), riskConfig.exitCapBps, BPS)
            );
            if (account.activeCommitment <= capacity) {
                assertLe(invariantVault.exitBucketCommitmentByMaturity(maturity), capacity);
            }
        } catch (bytes memory reason) {
            if (!_expectedRequestExitError(reason)) fail();
        }
    }

    function openCall(uint256 amountSeed) external capWatch {
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

    function fund(uint256 actorSeed) external capWatch {
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

    function probeEarlyRequestExit(uint256 actorSeed) external capWatch {
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
            try invariantVault.deposit(1e18, 1, type(uint256).max, true, type(uint256).max) returns (uint256) {
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

    function probeDoubleFund(uint256 actorSeed) external capWatch {
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

    function probeFundAfterSlashFinalized(uint256 actorSeed) external capWatch {
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

    function probeRollWhileExiting(uint256 actorSeed) external capWatch {
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

    function probeDepositWhileExiting(uint256 actorSeed) external capWatch {
        _sync();
        if (invariantVault.shutdownState().active || _isTerminal(invariantVault)) return;
        if (invariantVault.syncState().pendingAuctionEpochPlusOne != 0) return;

        uint256 epoch = invariantVault.currentEpoch();
        ILCCVault.Phase phase = invariantVault.currentPhase();
        bool immediate = phase == ILCCVault.Phase.Normal && !invariantVault.getEpochState(epoch).callOpened;
        uint256 activationEpoch = immediate ? epoch : epoch + 1;
        if (phase == ILCCVault.Phase.PreCall || _hasPriorUnsettledCall(activationEpoch)) return;
        uint256 maxEpochs = invariantVault.epochConfig().maxEpochs;
        if (maxEpochs != 0 && activationEpoch >= maxEpochs) return;

        address actor = actors[_index(actorSeed)];
        try invariantVault.materializeAccount(actor) {}
        catch (bytes memory reason) {
            if (!_expectedMaterializeError(reason)) fail();
            return;
        }
        ILCCVault.Account memory account = invariantVault.getAccount(actor);
        if (!account.exitRequested || account.exitClaimed) return;

        _expectDepositRevert(actor, 1e18, LCCErrorsLib.ExitInProgress.selector);
    }

    function probeTerminalGuards(uint256 actorSeed) external capWatch {
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

    function takeAuction(uint256 actorSeed, uint256 fillSeed) external capWatch {
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
        invariantVault.takeAuction(fill, 0, type(uint256).max);
        _recordMarginOut(vaultBalanceBefore, treasuryBalanceBefore);
    }

    function warpIntoClosed(uint256 seed) external capWatch {
        uint256 epoch = invariantVault.currentEpoch();
        uint256 fundingEnd = invariantVault.phaseEndsAt(epoch, ILCCVault.Phase.Funding);
        uint256 epochEnd = invariantVault.phaseEndsAt(epoch, ILCCVault.Phase.Closed);
        if (epochEnd <= fundingEnd + 1) return;

        uint256 target = fundingEnd + _range(seed, 0, epochEnd - fundingEnd - 1);
        if (target <= block.timestamp) return;
        vm.warp(target);
    }

    function finalizeCall(uint256 epochSeed) external capWatch {
        uint256[] memory called = invariantVault.calledEpochs();
        if (called.length == 0) return;

        uint256 epoch = called[epochSeed % called.length];
        ILCCVault.EpochState memory state = invariantVault.getEpochState(epoch);
        if (!state.callOpened || state.slashFinalized) return;
        if (block.timestamp < invariantVault.phaseEndsAt(epoch, ILCCVault.Phase.Funding)) return;

        invariantVault.finalizeEpochSlash(epoch);
    }

    function materialize(uint256 actorSeed) external capWatch returns (bool complete) {
        address actor = actors[_index(actorSeed)];

        try invariantVault.materializeAccount(actor) {
            complete = true;
        } catch (bytes memory reason) {
            if (!_expectedMaterializeError(reason)) fail();
        }
    }

    function claimExit(uint256 actorSeed) external capWatch {
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

    function claimRemaining(uint256 actorSeed) external capWatch {
        if (!invariantVault.shutdownState().active && !_isTerminal(invariantVault)) return;

        address actor = actors[_index(actorSeed)];
        // Sync before the guard: getAccount is a read-only preview that stops at an unfinalized slash-eligible
        // epoch and shows pre-default margin, but claimRemainingMargin's synced replay applies the default first.
        // Materializing here finalizes that epoch so the guard matches the claim and cannot pass on stale margin.
        try invariantVault.materializeAccount(actor) {}
        catch (bytes memory reason) {
            if (!_expectedMaterializeError(reason)) fail();
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

    function setRiskCaps(uint256 protocolSeed, uint256 userCapSeed, uint256 exitCapSeed) external capWatch {
        _sync();
        if (invariantVault.shutdownState().active) return;

        ILCCVault.Totals memory totals = invariantVault.totals();
        uint256 currentUtilization = totals.activeCommitment + totals.pendingCommitment;
        uint256 currentProtocolCap = invariantVault.riskConfig().protocolCommitmentCap;
        uint256 maxCap = 10_000_000e18;
        (bool capAvailable, uint256 protocolCap) = _fuzzedProtocolCap(protocolSeed, currentUtilization, maxCap);
        if (!capAvailable) return;
        if (invariantVault.syncState().pendingAuctionEpochPlusOne != 0 && protocolCap < currentProtocolCap) return;

        uint256 userCap = _fuzzedUserCap(userCapSeed, maxCap, currentUtilization);
        uint256 exitCapBps = _range(exitCapSeed, 313, 5_000);

        vm.prank(invariantOwner);
        try invariantVault.setRiskCaps(protocolCap, userCap, exitCapBps, 0) {
            // The invariant body already declines readings during live auctions, so mirror that discipline here and
            // check after the call because its sync can kick one. The ghost is the last safely measured conservative
            // bound, not necessarily the exact exposure after the latest live-auction cap write. A long run of such
            // writes can leave it stale until the next auction-free write; the assertion remains meaningful but weaker.
            if (invariantVault.syncState().pendingAuctionEpochPlusOne == 0) {
                totals = invariantVault.totals();
                uint256 utilizationAfter = uint256(totals.activeCommitment) + uint256(totals.pendingCommitment);
                ghostGrandfatheredOverCapExposure = Math.saturatingSub(utilizationAfter, protocolCap);
            }
        } catch (bytes memory reason) {
            if (!_expectedMaterializeError(reason)) fail();
        }
    }

    function _fuzzedProtocolCap(uint256 protocolSeed, uint256 currentUtilization, uint256 maxCap)
        internal
        view
        returns (bool available, uint256 protocolCap)
    {
        // Include base-unit-scale caps so the runtime exit-capacity clamp is exercised. The owner can also cut below
        // live utilization; those grandfathered positions retain a capacity denominator of aggregate active
        // commitment while capacity follows live utilization.
        if (currentUtilization > 1 && protocolSeed % 4 == 0) {
            // Exercise owner-authorized grandfathering: subsequent deposits and disposal may reduce, but never
            // increase, the resulting over-cap exposure.
            protocolCap = _range(protocolSeed / 4, 1, currentUtilization - 1);
        } else if (protocolSeed % 4 == 1) {
            (bool found, uint256 epoch) = _undisposedSlashEpoch();
            if (!found) return (false, 0);

            ILCCVault.EpochState memory state = invariantVault.getEpochState(epoch);
            uint256 funded = state.fundedAmount + state.fundedUsersRemainingCommitment;
            uint256 denominator = state.commitmentDenominator;
            if (denominator <= funded + MIN_RETURN_COMMITMENT) return (false, 0);
            protocolCap = _range(protocolSeed / 4, funded + MIN_RETURN_COMMITMENT, denominator - 1);
        } else {
            uint256 floorCap = Math.max(1, currentUtilization);
            if (floorCap >= maxCap) return (false, 0);
            protocolCap = _range(protocolSeed, floorCap, maxCap);
        }
        available = true;
    }

    function _fuzzedUserCap(uint256 userCapSeed, uint256 maxCap, uint256 totalUtilization)
        internal
        view
        returns (uint256 userCap)
    {
        uint256 maxUserUtilization;
        for (uint256 i = 0; i < actors.length; ++i) {
            ILCCVault.Account memory account = invariantVault.getAccount(actors[i]);
            maxUserUtilization = Math.max(maxUserUtilization, account.activeCommitment + account.pendingCommitment);
            // No account can exceed the aggregate. Equality proves the maximum without replaying the remaining
            // actors and leaves the cap draw identical to a full scan.
            if (maxUserUtilization == totalUtilization) break;
        }

        if (maxUserUtilization > 1 && userCapSeed % 4 == 0) {
            return _range(userCapSeed / 4, 1, maxUserUtilization - 1);
        }

        uint256 floorUserCap = Math.max(1, maxUserUtilization);
        if (floorUserCap >= maxCap) return maxCap;
        return _range(userCapSeed, floorUserCap, maxCap);
    }

    function shutdown(uint256 seed) external capWatch {
        _sync();
        if (invariantVault.shutdownState().active) return;
        if (seed % 64 != 0) return;
        ILCCVault.Totals memory totals = invariantVault.totals();
        if (totals.activeMargin + totals.pendingMargin == 0) return;

        // Every called epoch in this harness has a validated snapshot, so shutdown's wind-down disposal is live-oracle
        // independent. ShutdownActive is guarded above; call directly and let any unexpected revert fail the run.
        vm.prank(invariantOwner);
        invariantVault.shutdown();
    }

    function sweepTreasury() external capWatch {
        invariantVault.sweepTreasury();
    }

    function warpToPreCall() external capWatch {
        uint256 epoch = invariantVault.currentEpoch();
        uint256 target = invariantVault.phaseEndsAt(epoch, ILCCVault.Phase.Normal);
        if (block.timestamp > target) {
            target = invariantVault.phaseEndsAt(epoch + 1, ILCCVault.Phase.Normal);
        }
        vm.warp(target);
    }

    function warpToFunding() external capWatch {
        uint256 epoch = invariantVault.currentEpoch();
        uint256 target = invariantVault.phaseEndsAt(epoch, ILCCVault.Phase.PreCall);
        if (block.timestamp > target) {
            target = invariantVault.phaseEndsAt(epoch + 1, ILCCVault.Phase.PreCall);
        }
        vm.warp(target);
    }

    function warpPastFunding() external capWatch {
        uint256 epoch = invariantVault.currentEpoch();
        uint256 target = invariantVault.phaseEndsAt(epoch, ILCCVault.Phase.Funding);
        if (block.timestamp > target) {
            target = invariantVault.phaseEndsAt(epoch + 1, ILCCVault.Phase.Funding);
        }
        vm.warp(target);
    }

    function warpToTerminal(uint256 seed) external capWatch {
        uint256 me = invariantVault.epochConfig().maxEpochs;
        if (me == 0) return;
        uint256 target = invariantVault.phaseEndsAt(me - 1, ILCCVault.Phase.Closed) + _range(seed, 0, 300);
        if (target <= block.timestamp) return;
        vm.warp(target);
    }

    function warp(uint256 secondsSeed) external capWatch {
        vm.warp(block.timestamp + _range(secondsSeed, 1, 80));
    }

    function _ensureUserCapClampCoverage() internal {
        if (
            ghostUserCapClampCount != 0 || invariantVault.shutdownState().active || _isTerminal(invariantVault)
                || invariantVault.syncState().pendingAuctionEpochPlusOne != 0
        ) return;

        uint256 epoch = invariantVault.currentEpoch();
        if (
            invariantVault.currentPhase() != ILCCVault.Phase.Normal || invariantVault.getEpochState(epoch).callOpened
                || _hasPriorUnsettledCall(epoch)
        ) return;

        invariantOracle.setPrice(ORACLE_PRICE_SCALE);
        address actor = actors[0];
        ILCCVault.Account memory account = invariantVault.getAccount(actor);
        if (account.exitRequested && !account.exitClaimed) return;

        if (account.activeCommitment <= 1) {
            uint256 depositAmount = 10e18;
            vm.prank(actor);
            invariantVault.deposit(depositAmount, 1, type(uint256).max, true, type(uint256).max);
            ghostCumDeposited += depositAmount;
            account = invariantVault.getAccount(actor);
        }
        if (account.pendingCommitment != 0 || account.activeCommitment <= 1) return;

        ILCCVault.RiskConfig memory config = invariantVault.riskConfig();
        uint256 userCap = account.activeCommitment / 2;
        // Isolate the per-user branch: protocol headroom stays deliberately ample while the snapshot user cap is
        // below this actor's utilization, so replay must reduce the otherwise full return commitment.
        vm.prank(invariantOwner);
        invariantVault.setRiskCaps(10_000_000e18, userCap, config.exitCapBps, config.minDepositAssets);

        vm.warp(invariantVault.phaseEndsAt(epoch, ILCCVault.Phase.Normal));
        vm.prank(invariantOwner);
        invariantVault.openEpochCall(epoch, 1);

        vm.warp(invariantVault.phaseEndsAt(epoch, ILCCVault.Phase.Closed));
        invariantVault.finalizeEpochSlash(epoch);
        invariantVault.materializeAccount(actor);
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

    function _undisposedSlashEpoch() internal view returns (bool found, uint256 epoch) {
        uint256 pendingAuctionEpochPlusOne = invariantVault.syncState().pendingAuctionEpochPlusOne;
        if (pendingAuctionEpochPlusOne != 0) return (true, pendingAuctionEpochPlusOne - 1);

        uint256[] memory called = invariantVault.calledEpochs();
        uint256 finalizedPrefix = invariantVault.syncState().finalizedCallPrefix;
        if (finalizedPrefix >= called.length) return (false, 0);

        epoch = called[finalizedPrefix];
        found = !invariantVault.getEpochState(epoch).slashFinalized;
    }

    function _assertDisposalsRespectHeadroom(Vm.Log[] memory logs, uint256 capBefore, bool shutdownBefore) internal {
        bool windDown = shutdownBefore || _callWindowClosed(invariantVault);

        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(invariantVault) || entry.topics.length == 0) continue;

            if (entry.topics[0] == LCCEventsLib.EmergencyShutdown.selector) {
                windDown = true;
                continue;
            }
            if (entry.topics.length != 2 || entry.topics[0] != LCCEventsLib.SlashSurplusDisposed.selector) continue;

            uint256 epoch = uint256(entry.topics[1]);
            (,, uint256 returnCommitment) = abi.decode(entry.data, (uint256, uint256, uint256));
            ILCCVault.EpochState memory state = invariantVault.getEpochState(epoch);
            uint256 funded = state.fundedAmount + state.fundedUsersRemainingCommitment;
            uint256 slashed = state.commitmentDenominator - funded;
            uint256 headroom = windDown ? slashed : Math.min(slashed, Math.saturatingSub(capBefore, funded));
            if (returnCommitment > headroom) fail();
        }
    }

    function _countUserCapClamps(Vm.Log[] memory logs) internal {
        address defaultedUser;
        uint256 defaultedEpoch;
        uint256 unclampedCommitment;

        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(invariantVault) || entry.topics.length != 3) continue;

            if (entry.topics[0] == LCCEventsLib.UserDefaulted.selector) {
                defaultedUser = address(uint160(uint256(entry.topics[1])));
                defaultedEpoch = uint256(entry.topics[2]);
                (uint256 slashedMargin,) = abi.decode(entry.data, (uint256, uint256));
                ILCCVault.EpochState memory state = invariantVault.getEpochState(defaultedEpoch);
                unclampedCommitment = state.slashedMargin == 0
                    ? 0
                    : Math.mulDiv(state.returnCommitment, slashedMargin, state.slashedMargin);
                continue;
            }

            if (
                entry.topics[0] != LCCEventsLib.ReturnPoolCredited.selector
                    || address(uint160(uint256(entry.topics[1]))) != defaultedUser
                    || uint256(entry.topics[2]) != defaultedEpoch
            ) continue;

            (, uint256 creditedCommitment) = abi.decode(entry.data, (uint256, uint256));
            if (creditedCommitment < unclampedCommitment) ++ghostUserCapClampCount;
            unclampedCommitment = 0;
        }
    }

    function _expectDepositRevert(address actor, uint256 amount, bytes4 selector) internal {
        vm.prank(actor);
        try invariantVault.deposit(amount, 1, type(uint256).max, true, type(uint256).max) {
            fail();
        } catch (bytes memory reason) {
            assertEq(_revertSelector(reason), selector);
        }
    }

    function _expectRequestExitRevert(address actor, bytes4 selector) internal {
        vm.prank(actor);
        try invariantVault.requestExit(type(uint256).max, type(uint256).max) {
            fail();
        } catch (bytes memory reason) {
            assertEq(_revertSelector(reason), selector);
        }
    }

    function _expectedExitMaturity(uint256 accountCommitment) internal view returns (uint256 maturity) {
        ILCCVault.RiskConfig memory riskConfig = invariantVault.riskConfig();
        uint256 capacity = Math.max(
            1,
            Math.mulDiv(
                Math.max(riskConfig.protocolCommitmentCap, invariantVault.totals().activeCommitment),
                riskConfig.exitCapBps,
                BPS
            )
        );
        maturity = invariantVault.currentEpoch() + invariantVault.epochConfig().exitDelayEpochs;

        while (true) {
            uint256 assigned = invariantVault.exitBucketCommitmentByMaturity(maturity);
            if (assigned < capacity) {
                uint256 remaining = capacity - assigned;
                if (accountCommitment <= remaining || accountCommitment > capacity) return maturity;
            }
            unchecked {
                ++maturity;
            }
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
    // `_expectedMaterializeError` (the bounded replay barrier) is the base for the actions that run
    // _replayForUpdate: deposit, requestExit, and the claims. deposit adds the live-oracle read and the
    // activation/call-window lifecycle errors, CapExceeded, and InvalidAmount; requestExit adds InvalidAmount (a
    // synced default can zero its commitment after the stale guard). The handler predicts the first-fit maturity
    // before every bounded exit:
    // an insufficient fuzzed deferral must revert with ExitDeferralExceeded, while that selector is never accepted
    // by this whitelist. The deadline is fixed at type(uint256).max, so DeadlineExpired is likewise never accepted.
    // With eight actors holding at most one live exit each, the 128-bucket limit is unreachable and
    // ExitCapacityReached must not be accepted. Claims add NOTHING
    // beyond the base -- their preconditions make NoExitRequested/ExitNotMature/NothingToClaim unreachable, so
    // catching those would mask a preview-vs-claim divergence.

    function _expectedDepositError(bytes memory reason) internal pure returns (bool) {
        bytes4 selector = _revertSelector(reason);
        return _expectedMaterializeError(reason) || selector == LCCErrorsLib.CapExceeded.selector
            || selector == LCCErrorsLib.InvalidAmount.selector || selector == LCCErrorsLib.InvalidPhase.selector
            || selector == LCCErrorsLib.PriorCallUnsettled.selector || selector == LCCErrorsLib.VaultTerminal.selector;
    }

    function _expectedRequestExitError(bytes memory reason) internal pure returns (bool) {
        bytes4 selector = _revertSelector(reason);
        return _expectedMaterializeError(reason) || selector == LCCErrorsLib.InvalidAmount.selector;
    }

    /// @dev Records margin that left the vault to a non-treasury recipient (funder release, filler award, exit
    /// payout). Treasury accrual stays in the vault, while the separately fuzzed sweep is reconciled through the
    /// treasury-balance term in the ghost ledger.
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
    // Storage slots used only for raw invariant inspection.
    uint256 internal constant ACCOUNTS_SLOT = 15;
    uint256 internal constant EXIT_EXPOSURE_MAPPING_SLOT = 24;
    uint256 internal constant EXIT_MATURITIES_MAPPING_SLOT = 25;

    LCCInvariantHandler internal handler;
    address[] internal invariantActors;
    uint256 internal initialTreasuryMargin;

    function setUp() public virtual override {
        super.setUp();
        _assertLayoutSlot("accounts", ACCOUNTS_SLOT);
        _assertLayoutSlot("exitExposureByCallAndMaturity", EXIT_EXPOSURE_MAPPING_SLOT);
        _assertLayoutSlot("exitMaturitiesByCall", EXIT_MATURITIES_MAPPING_SLOT);
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
        // totals). The reverse gap (totals > sum(accounts)) is a benign orphan with NO tight bound. Unit-scale
        // return-share flooring is a pre-existing source, but the dominant source is the user-cap clamp: totals
        // receive the epoch's full returnCommitment while account replay can withhold up to all of it. The gap is
        // included in the next call's commitmentDenominator and therefore in its slashedCommitment, so the next
        // finalized slash removes it (LCCVault.sol:936-942). It does not clear when shutdown disables that slash,
        // because the disabled path returns before computing or removing slashedCommitment (LCCVault.sol:929-932).
        // The gap moves no margin, and the return path is unit-covered by LCCReturnPool/LCCSlashFee. Any commitment
        // error that moves value is still caught by the exact solvency assertEq, tight margin bound, treasury
        // reconciliation, and ghost-flow ledger.
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
                + vault.pendingTreasuryMargin()
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
                + vault.pendingTreasuryMargin()
        );
    }

    function invariant_OverCapExposureNeverGrows() public {
        if (!_materializeEveryoneForInvariant()) return;
        if (vault.shutdownState().active || _callWindowClosed(vault)) return;

        uint256 protocolCap = vault.riskConfig().protocolCommitmentCap;
        uint256 utilization = _settledCallableUtilization();
        uint256 overCapExposure = Math.saturatingSub(utilization, protocolCap);

        assertLe(overCapExposure, handler.ghostGrandfatheredOverCapExposure());
    }

    /// @dev Reads current totals while a call can still open; otherwise snapshots, advances to the next epoch, and
    /// executes the real sync/fold path before reading totals. No exit bucket or disposal-cutoff expression is used.
    function _settledCallableUtilization() internal returns (uint256 utilization) {
        ILCCVault.Totals memory totals = vault.totals();
        if (vault.currentPhase() < ILCCVault.Phase.Funding) {
            return uint256(totals.activeCommitment) + uint256(totals.pendingCommitment);
        }

        ILCCVault.RiskConfig memory config = vault.riskConfig();
        uint256 snapshot = vm.snapshotState();
        vm.warp(vault.phaseEndsAt(vault.currentEpoch(), ILCCVault.Phase.Closed));
        vm.prank(owner);
        vault.setRiskCaps(
            config.protocolCommitmentCap, config.userCommitmentCap, config.exitCapBps, config.minDepositAssets
        );

        totals = vault.totals();
        utilization = uint256(totals.activeCommitment) + uint256(totals.pendingCommitment);
        assertTrue(vm.revertToStateAndDelete(snapshot), "snapshot restore failed");
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
        if (!handler.materialize(0)) return false;
        if (vault.syncState().pendingAuctionEpochPlusOne != 0) return false;

        for (uint256 i = 1; i < invariantActors.length; ++i) {
            if (!handler.materialize(i)) return false;
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

    function invariant_ExitExposureListedImpliesNonzeroMargin() public view {
        uint256[] memory called = vault.calledEpochs();
        for (uint256 i = 0; i < called.length; ++i) {
            bytes32 maturitiesSlot = keccak256(abi.encode(called[i], EXIT_MATURITIES_MAPPING_SLOT));
            uint256 maturityCount = uint256(vm.load(address(vault), maturitiesSlot));
            uint256 maturitiesDataSlot = uint256(keccak256(abi.encode(maturitiesSlot)));
            bytes32 callExposureSlot = keccak256(abi.encode(called[i], EXIT_EXPOSURE_MAPPING_SLOT));

            for (uint256 j = 0; j < maturityCount; ++j) {
                uint256 maturity = uint256(vm.load(address(vault), bytes32(maturitiesDataSlot + j)));
                uint256 exposureSlot = uint256(keccak256(abi.encode(maturity, callExposureSlot)));
                uint256 marginAndCommitment = uint256(vm.load(address(vault), bytes32(exposureSlot)));
                uint256 listed = uint256(vm.load(address(vault), bytes32(exposureSlot + 3))) & 0xff;

                assertEq(listed, 1);
                assertGt(marginAndCommitment & type(uint128).max, 0);
            }
        }
    }

    function invariant_StoredActiveMarginHasCallableOrPendingCommitment() public view {
        for (uint256 i = 0; i < invariantActors.length; ++i) {
            uint256 accountSlot = uint256(keccak256(abi.encode(invariantActors[i], ACCOUNTS_SLOT)));
            uint256 activeWord = uint256(vm.load(address(vault), bytes32(accountSlot)));
            uint256 pendingWord = uint256(vm.load(address(vault), bytes32(accountSlot + 1)));
            uint256 activeMargin = uint128(activeWord);
            uint256 activeCommitment = activeWord >> 128;
            uint256 pendingCommitment = pendingWord >> 128;

            assertTrue(
                activeMargin == 0 || activeCommitment != 0 || pendingCommitment != 0,
                "stored active margin has no active or pending commitment"
            );
        }
    }

    function afterInvariant() public virtual {
        if (!vault.shutdownState().active) {
            vm.prank(owner);
            vault.shutdown();
        }
        _drainRemainingMargin();
        assertGt(handler.ghostUserCapClampCount(), 0, "user-cap clamp branch was not exercised");
    }

    function _drainRemainingMargin() internal {
        uint256 calledLength = vault.calledEpochs().length;
        uint256 materializePasses = calledLength / 64 + 2;
        for (uint256 i = 0; i < invariantActors.length; ++i) {
            address actor = invariantActors[i];
            for (uint256 j = 0; j < materializePasses; ++j) {
                handler.materialize(i);
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

contract LCCCutoffNoOpHandler {
    uint256 internal calls;

    function noop() external {
        ++calls;
    }
}

/// @dev Disposes the same called epoch after moving the live oracle to opposite sides of the return-commitment dust
/// boundary. Both branches must produce the absolute result implied by the call-open snapshot.
contract LCCOracleSnapshotTest is LCCBase {
    function setUp() public override {
        super.setUp();
        _deployAuctionVault();

        _deposit(alice, 100e18);
        oracle.setPrice(5_556e18);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);
    }

    function testCalledEpochDisposalUsesCallOpenPriceAcrossPostOpenLivePrices() public {
        uint256 snapshot = vm.snapshotState();

        oracle.setPrice(4_999e18);
        vm.warp(vault.phaseEndsAt(0, ILCCVault.Phase.Closed));
        vault.materializeAccount(bob);
        ILCCVault.EpochState memory lowLivePrice = vault.getEpochState(0);
        uint256 lowLivePriceTreasury = vault.pendingTreasuryMargin();
        assertEq(lowLivePrice.returnPool, 100e18);
        assertEq(lowLivePrice.returnCommitment, 1_111_200);
        assertEq(lowLivePriceTreasury, 0);

        assertTrue(vm.revertToState(snapshot), "low-price branch restore failed");
        oracle.setPrice(ORACLE_PRICE_SCALE);
        vm.warp(vault.phaseEndsAt(0, ILCCVault.Phase.Closed));
        vault.materializeAccount(bob);
        ILCCVault.EpochState memory highLivePrice = vault.getEpochState(0);

        assertEq(highLivePrice.returnPool, 100e18);
        assertEq(highLivePrice.returnCommitment, 1_111_200);
        assertEq(vault.pendingTreasuryMargin(), 0);
        assertTrue(vm.revertToStateAndDelete(snapshot), "high-price branch restore failed");
    }
}

/// @dev Falsifiability fixture for the disposal cutoff. Both branches start from the same live auction at the first
/// zero-award step. One settles eagerly by filling the shortfall; the other advances to the next epoch and lets the
/// real sync/fold path settle it. These paths have identical economics, so their disposal outputs must match. This
/// compares observed state transitions and never reads an exit bucket or reconstructs the production cutoff.
contract LCCCutoffStatefulInvariantTest is LCCBase {
    LCCCutoffNoOpHandler internal cutoffHandler;

    function setUp() public override {
        super.setUp();

        ILCCVault.VaultParams memory params = _auctionParams();
        params.protocolCommitmentCap = 300e18;
        _deployVaultWithParams(params);

        _deposit(carol, 100e18);
        _deposit(alice, 50e18);
        vm.prank(carol);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 1);

        _openCall(150e18);
        _fund(carol);
        _finishFunding();
        vault.finalizeEpochSlash(0);
        oracle.setPrice(2 * ORACLE_PRICE_SCALE);
        vm.warp(vault.phaseEndsAt(0, ILCCVault.Phase.Funding) + 1);

        cutoffHandler = new LCCCutoffNoOpHandler();
        targetContract(address(cutoffHandler));
    }

    function invariant_CutoffSettlementPathsMatch() public {
        uint256 snapshot = vm.snapshotState();

        vm.prank(bob);
        (, uint256 award) = vault.takeAuction(type(uint256).max, 0, type(uint256).max);
        assertEq(award, 0);
        ILCCVault.EpochState memory eager = vault.getEpochState(0);
        uint256 eagerTreasury = vault.pendingTreasuryMargin();

        assertTrue(vm.revertToState(snapshot), "eager snapshot restore failed");
        vm.warp(vault.phaseEndsAt(0, ILCCVault.Phase.Closed));
        vault.materializeAccount(bob);
        ILCCVault.EpochState memory postFold = vault.getEpochState(0);

        assertEq(eager.returnPool, postFold.returnPool, "return pool differs across equivalent settlement paths");
        assertEq(
            eager.returnCommitment,
            postFold.returnCommitment,
            "return commitment differs across equivalent settlement paths"
        );
        assertEq(
            eagerTreasury, vault.pendingTreasuryMargin(), "treasury accrual differs across equivalent settlement paths"
        );

        ILCCVault.Totals memory totals = vault.totals();
        assertLe(
            uint256(totals.activeCommitment) + uint256(totals.pendingCommitment),
            vault.riskConfig().protocolCommitmentCap
        );
        assertTrue(vm.revertToStateAndDelete(snapshot), "post-fold snapshot restore failed");
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
        assertGt(handler.ghostUserCapClampCount(), 0, "user-cap clamp branch was not exercised");
    }
}

contract LCCMinCommitmentStatefulInvariantTest is LCCTerminalStatefulInvariantTest {
    function _terminalParams() internal view override returns (ILCCVault.VaultParams memory params) {
        params = super._terminalParams();
        params.minCommitmentEpochs = 2;
    }
}
