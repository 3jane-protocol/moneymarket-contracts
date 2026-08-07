// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LCCMockToken, LCCMockUSD3} from "./LCCBase.t.sol";
import {Test} from "../../../lib/forge-std/src/Test.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {LCCVaultFactory} from "../../../src/lcc/LCCVaultFactory.sol";
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

    function testFinalizedCallPrefixAdvancesInSlashFinalizationTransaction() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        assertFalse(vault.getEpochState(0).slashFinalized);
        assertEq(vault.syncState().finalizedCallPrefix, 0);

        _finishFunding();
        vault.finalizeEpochSlash(0);

        assertTrue(vault.getEpochState(0).slashFinalized);
        assertEq(vault.syncState().finalizedCallPrefix, 1);
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
        LCCAuctionLib.AuctionState memory auction = vault.getAuctionState(0);
        SettlementReference memory settlement = _referenceSettlement(
            auction.marginPool, 0, auction.shortfallAmount, auction.shortfallAmount, 5_000, 1_000, true
        );
        assertEq(settledOverCapExposure, safelyMeasuredGhost - 2 * settlement.fee);
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
    uint256 public ghostReturnCreditCount;

    modifier capWatch() {
        ILCCVault.RiskConfig memory configBefore = invariantVault.riskConfig();
        uint256 capBefore = configBefore.protocolCommitmentCap;
        uint256 awardCapBefore = configBefore.maxAuctionAwardBps;
        bool shutdownBefore = invariantVault.shutdownState().active;
        vm.recordLogs();
        _ensureReturnCreditCoverage();
        _;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertDisposalsRespectHeadroom(logs, capBefore, awardCapBefore, shutdownBefore);
        _countReturnCredits(logs);
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
        margin_.approve(address(vault_), type(uint256).max);
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
        try invariantVault.deposit(amount, actor, 1, type(uint256).max, true, type(uint256).max) returns (uint256) {
            // marginAsset enters the vault only via deposit; count the exact amount pulled in. Slash disposal may
            // accrue pending treasury margin in the same transaction, which remains in the vault until swept.
            ghostCumDeposited += amount;
        } catch (bytes memory reason) {
            if (!_expectedDepositError(reason)) fail();
        }
    }

    function delegatedDeposit(uint256 beneficiarySeed, uint256 amountSeed) external capWatch {
        if (invariantVault.shutdownState().active) return;
        if (_isTerminal(invariantVault)) return;
        _sync();

        address beneficiary = actors[_index(beneficiarySeed)];
        uint256 amount = _range(amountSeed, 1, 10e18);
        ILCCVault.Account memory account = invariantVault.getAccount(beneficiary);
        if (account.exitRequested && !account.exitClaimed) return;

        try invariantVault.deposit(amount, beneficiary, 1, type(uint256).max, true, type(uint256).max) returns (
            uint256
        ) {
            // The handler is the role-gated payer, but all credited state and account-sum causality belongs to the
            // tracked beneficiary. Count margin only after the delegated deposit succeeds.
            ghostCumDeposited += amount;
        } catch (bytes memory reason) {
            // UnauthorizedDepositOperator is intentionally absent: this handler is always granted the role.
            if (!_expectedDepositError(reason)) fail();
        }
    }

    function bounceFull(uint256 actorSeed) external capWatch {
        // The capWatch bootstrap creates the first return credit before this body and counts it afterward. Preserve
        // that credited account for one action so bounce cannot erase the coverage witness before it is counted.
        if (ghostReturnCreditCount == 0) return;

        address actor = actors[_index(actorSeed)];
        // Bounce must exercise complete accounts rather than degenerating into bounded-replay reverts.
        try invariantVault.materializeAccount(actor) {}
        catch (bytes memory reason) {
            if (!_expectedMaterializeError(reason)) fail();
            return;
        }

        ILCCVault.Account memory account = invariantVault.getAccount(actor);
        if (account.activeMargin == 0 || account.activeCommitment == 0) return;
        if (account.exitRequested && !account.exitClaimed) return;
        if (account.pendingMargin != 0 || account.pendingCommitment != 0) return;

        uint256 vaultBalanceBefore = invariantMargin.balanceOf(address(invariantVault));
        uint256 treasuryBalanceBefore = invariantMargin.balanceOf(_treasury());
        try invariantVault.bounceCommitment(actor, account.activeCommitment) returns (uint256) {
            _recordMarginOut(vaultBalanceBefore, treasuryBalanceBefore);
        } catch (bytes memory reason) {
            if (!_expectedBounceFullError(reason)) fail();
        }
    }

    function bouncePartial(uint256 actorSeed, uint256 amountSeed) external capWatch {
        // See bounceFull: both bounce paths join the campaign once the forced default witness is durable.
        if (ghostReturnCreditCount == 0) return;

        address actor = actors[_index(actorSeed)];
        // Bounce must exercise complete accounts rather than degenerating into bounded-replay reverts.
        try invariantVault.materializeAccount(actor) {}
        catch (bytes memory reason) {
            if (!_expectedMaterializeError(reason)) fail();
            return;
        }

        ILCCVault.Account memory account = invariantVault.getAccount(actor);
        if (account.activeMargin == 0 || account.activeCommitment == 0) return;
        if (account.exitRequested && !account.exitClaimed) return;
        if (account.pendingMargin != 0 || account.pendingCommitment != 0) return;
        uint256 commitment = _range(amountSeed, 1, account.activeCommitment);

        uint256 vaultBalanceBefore = invariantMargin.balanceOf(address(invariantVault));
        uint256 treasuryBalanceBefore = invariantMargin.balanceOf(_treasury());
        try invariantVault.bounceCommitment(actor, commitment) returns (uint256) {
            _recordMarginOut(vaultBalanceBefore, treasuryBalanceBefore);
        } catch (bytes memory reason) {
            if (!_expectedBouncePartialError(reason)) fail();
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
            try invariantVault.deposit(1e18, actor, 1, type(uint256).max, true, type(uint256).max) returns (uint256) {
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
        if (invariantVault.syncState().pendingAuctionEpochPlusOne != 0 && protocolCap != currentProtocolCap) return;

        uint256 userCap = _fuzzedUserCap(userCapSeed, maxCap, currentUtilization);
        uint256 exitCapBps = _range(exitCapSeed, 313, 5_000);

        vm.prank(invariantOwner);
        try invariantVault.setRiskCaps(protocolCap, userCap, exitCapBps, 0) {
            // The invariant body already declines readings during live auctions, so mirror that discipline here and
            // check after the call because its sync can kick one. The ghost is the last safely measured conservative
            // bound; protocol-cap changes are frozen once a live auction exists.
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

        // Every called epoch in this harness has a validated snapshot, so shutdown disposal is live-oracle
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

    function _ensureReturnCreditCoverage() internal {
        if (
            ghostReturnCreditCount != 0 || invariantVault.shutdownState().active || _isTerminal(invariantVault)
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
            invariantVault.deposit(depositAmount, actor, 1, type(uint256).max, true, type(uint256).max);
            ghostCumDeposited += depositAmount;
            account = invariantVault.getAccount(actor);
        }
        if (account.pendingCommitment != 0 || account.activeCommitment <= 1) return;

        ILCCVault.RiskConfig memory config = invariantVault.riskConfig();
        uint256 userCap = account.activeCommitment / 2;
        // Protocol headroom stays deliberately ample while the live user cap sits below this actor's utilization,
        // so the forced default's full-share return credit re-attributes commitment above the user cap (the
        // deliberately reopened M-01 behavior) and the conservation dust bound sees a live return credit. The
        // counter only accepts genuinely over-cap credits, and a skewed margin-to-commitment shape can leave one
        // forced round's credit at or below the cap; that round still homogenizes every defaulter's ratio to
        // returnCommitment/returnPool, so a retry from the homogenized state credits above the halved cap.
        vm.prank(invariantOwner);
        invariantVault.setRiskCaps(10_000_000e18, userCap, config.exitCapBps, config.minDepositAssets);
        vm.prank(invariantOwner);
        invariantVault.setMaxAuctionAwardBps(0);

        vm.warp(invariantVault.phaseEndsAt(epoch, ILCCVault.Phase.Normal));
        vm.prank(invariantOwner);
        invariantVault.openEpochCall(epoch, 1);

        vm.warp(invariantVault.phaseEndsAt(epoch, ILCCVault.Phase.Closed));
        invariantVault.finalizeEpochSlash(epoch);
        invariantVault.materializeAccount(actor);
        vm.prank(invariantOwner);
        invariantVault.setMaxAuctionAwardBps(config.maxAuctionAwardBps);
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

    function _assertDisposalsRespectHeadroom(
        Vm.Log[] memory logs,
        uint256 capBefore,
        uint256 awardCapBefore,
        bool shutdownBefore
    ) internal {
        uint256 protocolCap = capBefore;
        uint256 awardCap = awardCapBefore;
        bool shutdownActive = shutdownBefore;
        uint256 maxEpochs = invariantVault.epochConfig().maxEpochs;

        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(invariantVault) || entry.topics.length == 0) continue;

            if (entry.topics[0] == LCCEventsLib.RiskCapUpdated.selector) {
                (protocolCap,,,) = abi.decode(entry.data, (uint256, uint256, uint256, uint256));
                continue;
            }
            if (entry.topics[0] == LCCEventsLib.AuctionAwardCapUpdated.selector) {
                awardCap = abi.decode(entry.data, (uint256));
                continue;
            }
            if (entry.topics[0] == LCCEventsLib.EmergencyShutdown.selector) {
                shutdownActive = true;
                continue;
            }
            if (entry.topics.length != 2 || entry.topics[0] != LCCEventsLib.SlashSurplusDisposed.selector) continue;

            _assertDisposalRespectsHeadroom(entry, protocolCap, awardCap, shutdownActive, maxEpochs);
        }
    }

    function _assertDisposalRespectsHeadroom(
        Vm.Log memory entry,
        uint256 protocolCap,
        uint256 awardCap,
        bool shutdownActive,
        uint256 maxEpochs
    ) internal {
        uint256 epoch = uint256(entry.topics[1]);
        (,, uint256 returnCommitment) = abi.decode(entry.data, (uint256, uint256, uint256));
        ILCCVault.EpochState memory state = invariantVault.getEpochState(epoch);
        uint256 funded = state.fundedAmount + state.fundedUsersRemainingCommitment;
        uint256 slashed = state.commitmentDenominator - funded;
        ILCCVault.ShutdownState memory shutdownState = invariantVault.shutdownState();
        bool auctionEligible = state.callAmount > state.fundedAmount && awardCap != 0
            && (!shutdownActive || shutdownState.timestamp >= invariantVault.phaseEndsAt(epoch, ILCCVault.Phase.Closed));
        uint256 headroom = (maxEpochs != 0 && epoch >= maxEpochs - 1) || !auctionEligible
            ? slashed
            : Math.min(slashed, Math.saturatingSub(protocolCap, funded));
        if (returnCommitment > headroom) fail();
    }

    /// @dev Coverage signal for the reopened M-01 behavior: counts return credits from persisted disposals whose
    /// account now sits above the live `userCommitmentCap`, keeping `_ensureReturnCreditCoverage` re-forcing its
    /// scenario until an over-live-cap credit is actually observed. It is not by itself a clamp killer: the count
    /// compares against the live cap while a reintroduced clamp would bound by the call-open snapshot, and the
    /// handler lowers the cap on a quarter of `setRiskCaps` draws, so an organic credit taken while
    /// `liveCap < snapshotCap` can still trip the counter under a clamped implementation. The clamp itself is
    /// killed deterministically by LCCReturnPool.t.sol's testReturnCreditIsFullPairedShareAndCanExceedUserCap,
    /// testPendingExposureDoesNotReduceReturnCommitmentCredit,
    /// testReplayCompletesAndConservesAcrossTwoConsecutiveDefaultEpochs, and
    /// testReturnedCommitmentConservedAndBacksNextCallDenominator. The epoch returnPool read filters disposals
    /// whose state rolled back under a caught revert (recorded logs survive those); a rolled-back credit passes
    /// the exposure check only when its account already exceeds the live cap. Full-share attribution is separately
    /// enforced by the totals-vs-accounts commitment dust bound.
    function _countReturnCredits(Vm.Log[] memory logs) internal {
        uint256 userCommitmentCap = invariantVault.riskConfig().userCommitmentCap;
        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter != address(invariantVault) || entry.topics.length != 3
                    || entry.topics[0] != LCCEventsLib.ReturnPoolCredited.selector
            ) continue;
            if (invariantVault.getEpochState(uint256(entry.topics[2])).returnPool == 0) continue;
            ILCCVault.Account memory account = invariantVault.getAccount(address(uint160(uint256(entry.topics[1]))));
            if (account.activeCommitment + account.pendingCommitment <= userCommitmentCap) continue;
            ++ghostReturnCreditCount;
        }
    }

    function _expectDepositRevert(address actor, uint256 amount, bytes4 selector) internal {
        vm.prank(actor);
        try invariantVault.deposit(amount, actor, 1, type(uint256).max, true, type(uint256).max) {
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

    function _expectedBounceFullError(bytes memory reason) internal pure returns (bool) {
        bytes4 selector = _revertSelector(reason);
        return _expectedMaterializeError(reason) || selector == LCCErrorsLib.InvalidPhase.selector
            || selector == LCCErrorsLib.InvalidAmount.selector || selector == LCCErrorsLib.ExitInProgress.selector
            || selector == LCCErrorsLib.PendingDepositExists.selector;
    }

    function _expectedBouncePartialError(bytes memory reason) internal pure returns (bool) {
        bytes4 selector = _revertSelector(reason);
        return _expectedBounceFullError(reason) || selector == LCCErrorsLib.InvalidAmount.selector
            || selector == LCCErrorsLib.ExitInProgress.selector;
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
    uint256 internal constant ACCOUNTS_SLOT = 14;
    uint256 internal constant EXIT_EXPOSURE_MAPPING_SLOT = 23;
    uint256 internal constant EXIT_MATURITIES_MAPPING_SLOT = 24;

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
        factory.grantRole(factory.BOUNCER_ROLE(), address(handler));
        factory.grantRole(factory.DEPOSIT_OPERATOR_ROLE(), address(handler));
        margin.mint(address(handler), 1_000_000e18);
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
        // dust accounting for both sides of the paired share.
        (uint256 returnPoolEpochs, uint256 marginRatioSum, uint256 commitmentRatioSum) =
            _assertTreasuryAndEpochConservation(called, initialTreasuryMargin);

        ILCCVault.Totals memory totals = vault.totals();
        uint256 n = invariantActors.length;
        // Margin dust bound: return-pool re-attribution floors each defaulter's paired share (up to one unit per
        // defaulter per return-pool epoch) and, when the leveraged commitment share floors to zero at low price, the
        // paired-drop orphans up to returnPool/returnCommitment of that account's margin (_pairedReturnPoolShare).
        // Actor count times those ratios. The ratio terms are regime-dependent: when returnCommitment pins at
        // MIN_RETURN_COMMITMENT while the pool stays large, ceil(returnPool/returnCommitment) carries an
        // amount-scale factor, so the bound is loose (and carries little information) in that regime and is tight
        // only away from it.
        uint256 marginDustBound = n * (returnPoolEpochs + marginRatioSum);
        assertLe(activeMargin, totals.activeMargin);
        assertLe(uint256(totals.activeMargin) - activeMargin, marginDustBound);
        // Commitment dust bound. Per return-pool epoch j, replay loses at most one flooring unit per defaulter and,
        // when a defaulter's margin share floors to zero, pair-drops a commitment share below
        // ceil(returnCommitment_j / returnPool_j): the n * (returnPoolEpochs + commitmentRatioSum) term. The second
        // term covers the pair-drop orphan cross term (LCCPairDropOrphan.t.sol): margin orphaned by an earlier
        // epoch's pair-drop — bounded by marginDustBound, since slashing re-absorbs prior margin orphans and each
        // disposal re-orphans at most a returnPool_j/slashedMargin_j <= 1 fraction of them — is slashed into a later
        // epoch j's pool and converted at that epoch's ratio, attributing up to
        // orphan * returnCommitment_j / slashedMargin_j <= marginDustBound * ceil(returnCommitment_j / returnPool_j)
        // commitment to no account (returnPool_j <= slashedMargin_j). This residual is attribution, not solvency:
        // the orphaned margin stays in the vault balance (exact solvency assertEq below), and value-moving errors
        // are separately caught by the treasury reconciliation and ghost-flow ledger. Away from the
        // MIN_RETURN_COMMITMENT-pinned regime both terms scale only with per-epoch state ratios, so a reintroduced
        // per-user cap clamp on the credit — whose orphan is a raw slice of a live account's commitment —
        // overshoots the bound there; in the pinned regime the bound itself carries an amount-scale factor, and
        // the clamp is killed by the deterministic LCCReturnPool tests instead.
        uint256 commitmentDustBound = n * (returnPoolEpochs + commitmentRatioSum) + marginDustBound * commitmentRatioSum;
        assertLe(activeCommitment, totals.activeCommitment);
        assertLe(uint256(totals.activeCommitment) - activeCommitment, commitmentDustBound);
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

    function invariant_FinalizedCallPrefixMatchesSlashFinalizationAtomically() public view {
        uint256[] memory called = vault.calledEpochs();
        uint256 finalizedPrefix = vault.syncState().finalizedCallPrefix;
        assertLe(finalizedPrefix, called.length);

        // Invariants run after every handler transaction, so this forbids an externally observable state in which
        // slashFinalized changed without the leading replay prefix advancing in that same transaction.
        for (uint256 i = 0; i < called.length; ++i) {
            assertEq(vault.getEpochState(called[i]).slashFinalized, i < finalizedPrefix);
        }
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
            uint256 maxAward = Math.mulDiv(auction.marginPool, BPS, BPS + vault.riskConfig().slashFeeBps);
            uint256 maxOffered = LCCAuctionLib.offeredPool(
                maxAward, closedWindow - 1, auctionConfig.auctionStepDuration, auctionConfig.auctionStepDecayRateBps
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
            if (auction.shortfallAmount == 0) {
                assertEq(auction.marginAwarded, 0);
                continue;
            }

            uint256 slashFeeBps = vault.riskConfig().slashFeeBps;
            uint256 maxAward = Math.mulDiv(auction.marginPool, BPS, BPS + slashFeeBps);
            uint256 eligiblePool = Math.mulDiv(auction.marginPool, auction.filledAmount, auction.shortfallAmount);
            uint256 eligibleAward = Math.mulDiv(eligiblePool, BPS, BPS + slashFeeBps);
            assertLe(auction.marginAwarded, maxAward);
            assertLe(auction.marginAwarded, eligibleAward);
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
        assertGt(handler.ghostReturnCreditCount(), 0, "return-credit path was not exercised");
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

/// @dev Disposes the same shutdown-truncated auction after moving the live oracle to opposite sides of the
/// return-commitment dust boundary. Both branches must produce the absolute result implied by the call-open snapshot.
contract LCCOracleSnapshotTest is LCCBase {
    function setUp() public override {
        super.setUp();
        _deployAuctionVault();

        _deposit(alice, 100e18);
        oracle.setPrice(5_556e18);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);
        vm.prank(carol);
        vault.takeAuction(50e18, 0, type(uint256).max);
    }

    function testCalledEpochDisposalUsesCallOpenPriceAcrossPostOpenLivePrices() public {
        uint256 snapshot = vm.snapshotState();
        LCCAuctionLib.AuctionState memory auction = vault.getAuctionState(0);
        SettlementReference memory settlement = _referenceSettlement(
            auction.marginPool, 0, auction.filledAmount, auction.shortfallAmount, 5_000, 1_000, false
        );
        uint256 expectedCommitment =
            Math.mulDiv(Math.mulDiv(settlement.baseReturn, 5_556e18, ORACLE_PRICE_SCALE), BPS, 5_000);

        oracle.setPrice(4_999e18);
        vm.prank(owner);
        vault.shutdown();
        ILCCVault.EpochState memory lowLivePrice = vault.getEpochState(0);
        uint256 lowLivePriceTreasury = vault.pendingTreasuryMargin();
        assertEq(lowLivePrice.returnPool, settlement.baseReturn);
        assertEq(lowLivePrice.returnCommitment, expectedCommitment);
        assertEq(lowLivePriceTreasury, settlement.fee);

        assertTrue(vm.revertToState(snapshot), "low-price branch restore failed");
        oracle.setPrice(ORACLE_PRICE_SCALE);
        vm.prank(owner);
        vault.shutdown();
        ILCCVault.EpochState memory highLivePrice = vault.getEpochState(0);

        assertEq(highLivePrice.returnPool, settlement.baseReturn);
        assertEq(highLivePrice.returnCommitment, expectedCommitment);
        assertEq(vault.pendingTreasuryMargin(), settlement.fee);
        assertTrue(vm.revertToStateAndDelete(snapshot), "high-price branch restore failed");
    }
}

/// @dev Falsifiability fixture for settlement classification. Both branches start from the same live auction at the
/// first zero-award step. One fully fills and therefore returns the filled pool less the fee floor; the other reaches
/// the natural end unfilled and diverts the gross pool. This compares observed state transitions and never reads an
/// exit bucket or reconstructs the production cutoff.
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

    function invariant_CutoffSettlementPathsDivergeByFilledEligibility() public {
        uint256 snapshot = vm.snapshotState();

        vm.prank(bob);
        (, uint256 award) = vault.takeAuction(type(uint256).max, 0, type(uint256).max);
        assertEq(award, 0);
        ILCCVault.EpochState memory eager = vault.getEpochState(0);
        uint256 eagerTreasury = vault.pendingTreasuryMargin();
        SettlementReference memory expected = _referenceSettlement(50e18, 0, 50e18, 50e18, 5_000, 1_000, true);
        assertEq(eager.returnPool, expected.baseReturn);
        assertEq(eagerTreasury, expected.fee);

        assertTrue(vm.revertToState(snapshot), "eager snapshot restore failed");
        vm.warp(vault.phaseEndsAt(0, ILCCVault.Phase.Closed));
        vault.materializeAccount(bob);
        ILCCVault.EpochState memory postFold = vault.getEpochState(0);

        assertEq(postFold.returnPool, 0);
        assertEq(postFold.returnCommitment, 0);
        assertEq(vault.pendingTreasuryMargin(), 50e18);
        assertGt(eager.returnPool, postFold.returnPool);
        assertLt(eagerTreasury, vault.pendingTreasuryMargin());

        ILCCVault.Totals memory totals = vault.totals();
        assertLe(
            uint256(totals.activeCommitment) + uint256(totals.pendingCommitment),
            vault.riskConfig().protocolCommitmentCap
        );
        assertTrue(vm.revertToStateAndDelete(snapshot), "post-fold snapshot restore failed");
    }
}

/// @dev Settlement economics at equal fill must depend on the auction opportunity frozen from the funding deadline,
/// not on whether a caller happened to materialize the auction record during the Closed window.
contract LCCTouchOrderStatefulInvariantTest is LCCBase {
    LCCCutoffNoOpHandler internal touchOrderHandler;

    function setUp() public override {
        super.setUp();
        _deployAuctionVault();

        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);

        touchOrderHandler = new LCCCutoffNoOpHandler();
        targetContract(address(touchOrderHandler));
    }

    function invariant_EqualFillSettlementIsTouchOrderIndependent() public {
        uint256 snapshot = vm.snapshotState();
        uint256 closedEnd = vault.phaseEndsAt(0, ILCCVault.Phase.Closed);

        _finishFunding();
        vault.finalizeEpochSlash(0);
        vm.warp(closedEnd);
        vault.materializeAccount(bob);
        ILCCVault.EpochState memory kickedEarly = vault.getEpochState(0);
        uint256 kickedEarlyTreasury = vault.pendingTreasuryMargin();
        assertEq(kickedEarly.returnPool, 0);
        assertEq(kickedEarly.returnCommitment, 0);
        assertEq(kickedEarlyTreasury, 50e18);

        assertTrue(vm.revertToState(snapshot), "early-kick snapshot restore failed");
        vm.warp(closedEnd + 1);
        vault.finalizeEpochSlash(0);
        ILCCVault.EpochState memory untouchedLate = vault.getEpochState(0);
        assertEq(untouchedLate.returnPool, kickedEarly.returnPool);
        assertEq(untouchedLate.returnCommitment, kickedEarly.returnCommitment);
        assertEq(vault.pendingTreasuryMargin(), kickedEarlyTreasury);

        assertTrue(vm.revertToState(snapshot), "late-finalization snapshot restore failed");
        vm.warp(closedEnd + 1);
        vm.prank(owner);
        vault.shutdown();
        ILCCVault.EpochState memory shutdownFinalized = vault.getEpochState(0);
        assertEq(shutdownFinalized.returnPool, kickedEarly.returnPool);
        assertEq(shutdownFinalized.returnCommitment, kickedEarly.returnCommitment);
        assertEq(vault.pendingTreasuryMargin(), kickedEarlyTreasury);

        assertTrue(vm.revertToStateAndDelete(snapshot), "shutdown snapshot restore failed");
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
        assertGt(handler.ghostReturnCreditCount(), 0, "return-credit path was not exercised");
    }
}

contract LCCMinCommitmentStatefulInvariantTest is LCCTerminalStatefulInvariantTest {
    function _terminalParams() internal view override returns (ILCCVault.VaultParams memory params) {
        params = super._terminalParams();
        params.minCommitmentEpochs = 2;
    }
}

contract LCCRegistryInvariantHandler is Test {
    uint256 internal constant PAYER_MODE_SELF = 0;
    uint256 internal constant PAYER_MODE_AUTHORIZED = 1;
    uint256 internal constant PAYER_MODE_UNAUTHORIZED = 2;

    struct AdmissionPreState {
        bool policyOn;
        address slot;
        bool slotOpen;
        bool targetOpen;
        bool modelAdmits;
    }

    LCCVaultFactory internal immutable invariantFactory;
    LCCVault internal immutable firstVault;
    LCCVault internal immutable secondVault;
    LCCVault internal immutable thirdVault;
    address internal immutable invariantOwner;
    address internal immutable invariantBouncer;
    address[] internal actors;

    // Deposit-state ghosts are causal: successful transitions use only observations captured before the deposit and
    // modelAdmits. No post-deposit vaultOf or other post-state value may flow into slotVault or grandfathered.
    mapping(address => mapping(address => bool)) public ghostDepositedInto;
    mapping(address => address) public slotVault;
    mapping(address => mapping(address => bool)) public grandfathered;
    bool public admissionOracleHealthy = true;
    uint256 public openOutsideSlotActorEvaluations;

    modifier recordSetCoverage() {
        _;
        _recordSetCoverage();
    }

    constructor(
        LCCVaultFactory factory_,
        LCCVault firstVault_,
        LCCVault secondVault_,
        LCCVault thirdVault_,
        address owner_,
        address bouncer_,
        address[] memory actors_
    ) {
        invariantFactory = factory_;
        firstVault = firstVault_;
        secondVault = secondVault_;
        thirdVault = thirdVault_;
        invariantOwner = owner_;
        invariantBouncer = bouncer_;
        actors = actors_;

        LCCMockToken marginToken = LCCMockToken(firstVault_.assetConfig().marginAsset);
        marginToken.approve(address(firstVault_), type(uint256).max);
        marginToken.approve(address(secondVault_), type(uint256).max);
        marginToken.approve(address(thirdVault_), type(uint256).max);

        for (uint256 i = 0; i < actors_.length; ++i) {
            ghostDepositedInto[actors_[i]][address(firstVault_)] = true;
            slotVault[actors_[i]] = address(firstVault_);
        }
    }

    function depositFirst(uint256 actorSeed, uint256 amountSeed) external recordSetCoverage {
        _deposit(firstVault, actorSeed, amountSeed, false);
    }

    function depositSecond(uint256 actorSeed, uint256 amountSeed) external recordSetCoverage {
        _deposit(secondVault, actorSeed, amountSeed, false);
    }

    function depositThird(uint256 actorSeed, uint256 amountSeed) external recordSetCoverage {
        _deposit(thirdVault, actorSeed, amountSeed, false);
    }

    function closeFirst(uint256 actorSeed) external recordSetCoverage {
        _close(firstVault, actorSeed);
    }

    function closeSecond(uint256 actorSeed) external recordSetCoverage {
        _close(secondVault, actorSeed);
    }

    function closeThird(uint256 actorSeed) external recordSetCoverage {
        _close(thirdVault, actorSeed);
    }

    function toggleWhitelist() external recordSetCoverage {
        bool enabled = invariantFactory.whitelistEnabled();
        vm.prank(invariantOwner);
        invariantFactory.setWhitelistEnabled(!enabled);
    }

    function toggleOneVaultPolicy() external recordSetCoverage {
        bool enabled = invariantFactory.oneVaultPolicyEnabled();
        vm.prank(invariantOwner);
        invariantFactory.setOneVaultPolicyEnabled(!enabled);
    }

    /// @dev Raw negative-control helpers are deliberately excluded from the selector set and bypass the causal state
    /// machine. They model a wrongful policy-on admission by briefly disabling production enforcement, then restore it.
    function simulateUnauthorizedPolicyOnSecondPosition(uint256 actorSeed, uint256 amountSeed) external {
        _simulateUnauthorizedRaw(secondVault, actorSeed, amountSeed);
    }

    function simulateUnauthorizedPolicyOnThirdPosition(uint256 actorSeed, uint256 amountSeed) external {
        _simulateUnauthorizedRaw(thirdVault, actorSeed, amountSeed);
    }

    function simulateUnauthorizedPolicyOnFirstPosition(uint256 actorSeed, uint256 amountSeed) external {
        _simulateUnauthorizedRaw(firstVault, actorSeed, amountSeed);
    }

    /// @dev This negative control routes the simulated defect through the deposit state machine. Its pre-state sees
    /// policy-on, while only the production call is temporarily allowed through, so modelAdmits can latch the defect.
    function simulateUnauthorizedPolicyOnSecondPositionThroughHandler(uint256 actorSeed, uint256 amountSeed)
        external
        recordSetCoverage
    {
        _deposit(secondVault, actorSeed, amountSeed, true);
    }

    function _deposit(LCCVault target, uint256 actorSeed, uint256 amountSeed, bool simulateUnauthorized) internal {
        uint256 beneficiaryIndex = actorSeed % actors.length;
        address beneficiary = actors[beneficiaryIndex];
        uint256 payerMode = simulateUnauthorized ? PAYER_MODE_SELF : (actorSeed / actors.length) % 3;
        address payer = beneficiary;
        if (payerMode == PAYER_MODE_AUTHORIZED) payer = address(this);
        if (payerMode == PAYER_MODE_UNAUTHORIZED) payer = actors[(beneficiaryIndex + 1) % actors.length];

        AdmissionPreState memory pre = _snapshotAdmission(beneficiary, target);
        uint256 amount = bound(amountSeed, 1, 10e18);

        if (simulateUnauthorized) {
            require(pre.policyOn && !pre.modelAdmits, "NOT_UNAUTHORIZED_PRESTATE");
            vm.prank(invariantOwner);
            invariantFactory.setOneVaultPolicyEnabled(false);
        }

        bool succeeded;
        vm.prank(payer);
        try target.deposit(amount, beneficiary, 1, type(uint256).max, true, type(uint256).max) returns (uint256) {
            succeeded = true;
        } catch (bytes memory reason) {
            bytes4 selector = _revertSelector(reason);
            if (payerMode == PAYER_MODE_UNAUTHORIZED) {
                // The factory's payer-role gate runs before the whitelist and one-vault checks, so an unauthorized
                // payer that reaches the factory must revert with UnauthorizedDepositOperator; a later admission
                // error means the gate ran too late. Vault-side reverts before the factory call stay acceptable.
                if (
                    selector == LCCErrorsLib.RegisteredElsewhere.selector
                        || selector == LCCErrorsLib.NotWhitelistedDepositor.selector
                ) admissionOracleHealthy = false;
            } else if (
                selector != LCCErrorsLib.RegisteredElsewhere.selector
                    && selector != LCCErrorsLib.NotWhitelistedDepositor.selector
            ) {
                fail();
            }
        }

        if (simulateUnauthorized) {
            vm.prank(invariantOwner);
            invariantFactory.setOneVaultPolicyEnabled(true);
        }

        if (succeeded) {
            if (payerMode == PAYER_MODE_UNAUTHORIZED) {
                admissionOracleHealthy = false;
                return;
            }
            // Every causal ghost is keyed on the credited beneficiary, never the payer.
            ghostDepositedInto[beneficiary][address(target)] = true;
            _recordSuccessfulDeposit(beneficiary, address(target), pre);
        }
    }

    function _snapshotAdmission(address actor, LCCVault target) internal view returns (AdmissionPreState memory pre) {
        pre.policyOn = invariantFactory.oneVaultPolicyEnabled();
        address preNamed = invariantFactory.vaultOf(actor);
        bool preNamedOpen = preNamed != address(0) && hasOpenExposure(preNamed, actor);
        pre.slot = slotVault[actor];
        pre.slotOpen = pre.slot != address(0) && hasOpenExposure(pre.slot, actor);
        pre.targetOpen = hasOpenExposure(address(target), actor);
        pre.modelAdmits = preNamed == address(0) || preNamed == address(target) || !preNamedOpen;
    }

    function _recordSuccessfulDeposit(address actor, address target, AdmissionPreState memory pre) internal {
        if (!pre.policyOn) {
            if (pre.slotOpen && pre.slot != target) grandfathered[actor][pre.slot] = true;
            grandfathered[actor][target] = false;
            slotVault[actor] = target;
            return;
        }

        if (!pre.modelAdmits) {
            admissionOracleHealthy = false;
            return;
        }

        if (pre.slot == address(0) || !pre.slotOpen || (pre.slot == target && pre.targetOpen)) {
            grandfathered[actor][target] = false;
            slotVault[actor] = target;
            return;
        }

        // Defensive: a policy-on admission may not displace a different live causal slot, even if the named pointer
        // somehow makes the production mirror admit. Do not heal the causal ghosts from post-state.
        admissionOracleHealthy = false;
    }

    function _close(LCCVault target, uint256 actorSeed) internal {
        address actor = actors[actorSeed % actors.length];
        ILCCVault.Account memory account = target.getAccount(actor);
        if (account.activeCommitment != 0 && !account.exitRequested && account.pendingCommitment == 0) {
            vm.prank(invariantBouncer);
            target.bounceCommitment(actor, account.activeCommitment);
        }
        if (!hasOpenExposure(address(target), actor)) {
            grandfathered[actor][address(target)] = false;
            if (slotVault[actor] == address(target)) slotVault[actor] = address(0);
        }
    }

    function _simulateUnauthorizedRaw(LCCVault target, uint256 actorSeed, uint256 amountSeed) internal {
        address actor = actors[actorSeed % actors.length];
        require(invariantFactory.oneVaultPolicyEnabled(), "POLICY_ALREADY_OFF");

        vm.prank(invariantOwner);
        invariantFactory.setOneVaultPolicyEnabled(false);
        vm.prank(actor);
        target.deposit(bound(amountSeed, 1, 10e18), actor, 1, type(uint256).max, true, type(uint256).max);
        // This history ghost supports R3 only; the causal admission state machine intentionally does not observe the
        // call.
        ghostDepositedInto[actor][address(target)] = true;
        vm.prank(invariantOwner);
        invariantFactory.setOneVaultPolicyEnabled(true);
    }

    function _recordSetCoverage() internal {
        address[] memory familyVaults = invariantFactory.allVaults();
        for (uint256 i = 0; i < actors.length; ++i) {
            address actor = actors[i];
            address slot = slotVault[actor];
            for (uint256 j = 0; j < familyVaults.length; ++j) {
                address familyVault = familyVaults[j];
                if (familyVault != slot && hasOpenExposure(familyVault, actor)) {
                    ++openOutsideSlotActorEvaluations;
                    break;
                }
            }
        }
    }

    /// @dev Independent test oracle for the production closure predicate. Keep this field-wise instead of calling
    /// `isAccountClosed`: registry invariants must detect omissions or loosenings in that production boolean.
    function hasOpenExposure(address target, address actor) public view returns (bool) {
        ILCCVault.Account memory account = ILCCVault(target).getAccount(actor);
        return account.activeMargin != 0 || account.activeCommitment != 0 || account.pendingMargin != 0
            || account.pendingCommitment != 0 || account.claimableExitMargin != 0
            || (account.exitRequested && !account.exitClaimed);
    }
}

abstract contract LCCRegistryInvariantBase is LCCBase {
    LCCRegistryInvariantHandler internal registryHandler;
    LCCVault internal secondRegistryVault;
    LCCVault internal thirdRegistryVault;
    address[] internal registryActors;

    function setUp() public virtual override {
        super.setUp();
        secondRegistryVault = _newVault(_params(CAP, CAP));
        thirdRegistryVault = _newVault(_params(CAP, CAP));

        registryActors.push(alice);
        registryActors.push(bob);
        registryActors.push(carol);
        for (uint256 i = 0; i < 3; ++i) {
            address actor = makeAddr(string.concat("lcc-registry-invariant-actor-", vm.toString(i)));
            registryActors.push(actor);
            _mintAndApprove(vault, actor, 1_000_000e18, 0);
        }

        for (uint256 i = 0; i < registryActors.length; ++i) {
            address actor = registryActors[i];
            _mintAndApprove(secondRegistryVault, actor, 0, 0);
            _mintAndApprove(thirdRegistryVault, actor, 0, 0);
            vm.prank(actor);
            vault.deposit(1e18, actor, 1, type(uint256).max, true, type(uint256).max);
        }

        address[] memory dewhitelisted = new address[](1);
        dewhitelisted[0] = registryActors[registryActors.length - 1];
        factory.setDepositorsWhitelisted(dewhitelisted, false);

        registryHandler = new LCCRegistryInvariantHandler(
            factory, vault, secondRegistryVault, thirdRegistryVault, owner, bouncer, registryActors
        );
        factory.grantRole(factory.DEPOSIT_OPERATOR_ROLE(), address(registryHandler));
        margin.mint(address(registryHandler), 1_000_000e18);
        bytes4[] memory selectors = new bytes4[](_includeToggleHandlers() ? 8 : 6);
        selectors[0] = LCCRegistryInvariantHandler.depositFirst.selector;
        selectors[1] = LCCRegistryInvariantHandler.depositSecond.selector;
        selectors[2] = LCCRegistryInvariantHandler.depositThird.selector;
        selectors[3] = LCCRegistryInvariantHandler.closeFirst.selector;
        selectors[4] = LCCRegistryInvariantHandler.closeSecond.selector;
        selectors[5] = LCCRegistryInvariantHandler.closeThird.selector;
        if (_includeToggleHandlers()) {
            selectors[6] = LCCRegistryInvariantHandler.toggleWhitelist.selector;
            selectors[7] = LCCRegistryInvariantHandler.toggleOneVaultPolicy.selector;
        }
        targetContract(address(registryHandler));
        targetSelector(FuzzSelector({addr: address(registryHandler), selectors: selectors}));
    }

    function _includeToggleHandlers() internal pure virtual returns (bool);

    function invariant_OpenPositionsAreCoveredByCausalSlotOrGrandfatheredSet() public view {
        for (uint256 i = 0; i < registryActors.length; ++i) {
            address actor = registryActors[i];
            address slot = registryHandler.slotVault(actor);
            // Documents the transition invariant S ∉ G. Every ghost writer maintains it unconditionally; the
            // load-bearing reachable-state check is the open-position containment below.
            assertTrue(slot == address(0) || !registryHandler.grandfathered(actor, slot));
            address[] memory familyVaults = factory.allVaults();
            for (uint256 j = 0; j < familyVaults.length; ++j) {
                address familyVault = familyVaults[j];
                if (registryHandler.hasOpenExposure(familyVault, actor)) {
                    assertTrue(familyVault == slot || registryHandler.grandfathered(actor, familyVault));
                }
            }
        }
    }

    function invariant_AdmissionOracleLatchRemainsHealthy() public view {
        assertTrue(registryHandler.admissionOracleHealthy());
    }

    function invariant_R3_WarmRegistryAlwaysPointsToAGhostDepositedVault() public view {
        for (uint256 i = 0; i < registryActors.length; ++i) {
            address actor = registryActors[i];
            address registered = factory.vaultOf(actor);
            assertTrue(registered == address(0) || registryHandler.ghostDepositedInto(actor, registered));
        }
    }

    function _familyOpenVaultCount(address actor) internal view returns (uint256 count) {
        address[] memory familyVaults = factory.allVaults();
        for (uint256 i = 0; i < familyVaults.length; ++i) {
            if (registryHandler.hasOpenExposure(familyVaults[i], actor)) ++count;
        }
    }

    function _actorsWithGrandfatheredOpenPositions() internal view returns (uint256 count) {
        address[] memory familyVaults = factory.allVaults();
        for (uint256 i = 0; i < registryActors.length; ++i) {
            address actor = registryActors[i];
            for (uint256 j = 0; j < familyVaults.length; ++j) {
                address familyVault = familyVaults[j];
                if (
                    registryHandler.grandfathered(actor, familyVault)
                        && registryHandler.hasOpenExposure(familyVault, actor)
                ) {
                    ++count;
                    break;
                }
            }
        }
    }

    function assertOpenSubsetOfSlotOnly() external view {
        for (uint256 i = 0; i < registryActors.length; ++i) {
            address actor = registryActors[i];
            address slot = registryHandler.slotVault(actor);
            address[] memory familyVaults = factory.allVaults();
            for (uint256 j = 0; j < familyVaults.length; ++j) {
                if (registryHandler.hasOpenExposure(familyVaults[j], actor)) assertEq(familyVaults[j], slot);
            }
        }
    }

    function afterInvariant() public {
        emit log_named_uint("actors with grandfathered open positions", _actorsWithGrandfatheredOpenPositions());
        emit log_named_uint(
            "actor evaluations with an open vault outside the causal slot",
            registryHandler.openOutsideSlotActorEvaluations()
        );
    }
}

contract LCCRegistryStatefulInvariantTest is LCCRegistryInvariantBase {
    function _includeToggleHandlers() internal pure override returns (bool) {
        return true;
    }

    function testControl1RawTwoVaultBugFailsContainmentButNotLatch() public {
        address actor = registryActors[0];

        registryHandler.simulateUnauthorizedPolicyOnSecondPosition(0, 1e18);

        assertEq(_familyOpenVaultCount(actor), 2);
        vm.expectRevert();
        this.invariant_OpenPositionsAreCoveredByCausalSlotOrGrandfatheredSet();
        this.invariant_AdmissionOracleLatchRemainsHealthy();
    }

    function testControl2SaturationThenThirdVaultBugDefeatsOldArithmeticButFailsSetContainment() public {
        address actor = registryActors[0];

        registryHandler.toggleOneVaultPolicy();
        registryHandler.depositSecond(0, 1e18);
        registryHandler.depositFirst(0, 1e18);
        registryHandler.toggleOneVaultPolicy();
        registryHandler.simulateUnauthorizedPolicyOnThirdPosition(0, 1e18);

        uint256 familyOpen = _familyOpenVaultCount(actor);
        assertEq(familyOpen, 3);
        assertLe(familyOpen - 2, 1, "round-5 count subtraction would have rejected the bug");
        assertEq(registryHandler.slotVault(actor), address(vault));
        assertTrue(registryHandler.grandfathered(actor, address(secondRegistryVault)));
        assertFalse(registryHandler.grandfathered(actor, address(vault)));
        vm.expectRevert();
        this.invariant_OpenPositionsAreCoveredByCausalSlotOrGrandfatheredSet();
        this.invariant_AdmissionOracleLatchRemainsHealthy();
    }

    function testControl3PointerCyclingDoesNotLeaveClosedVaultCovered() public {
        address actor = registryActors[0];

        registryHandler.toggleOneVaultPolicy();
        registryHandler.depositSecond(0, 1e18);
        registryHandler.depositFirst(0, 1e18);
        registryHandler.depositThird(0, 1e18);
        registryHandler.closeFirst(0);
        assertFalse(registryHandler.hasOpenExposure(address(vault), actor));
        assertFalse(registryHandler.grandfathered(actor, address(vault)));
        assertTrue(registryHandler.slotVault(actor) != address(vault));

        registryHandler.toggleOneVaultPolicy();
        registryHandler.simulateUnauthorizedPolicyOnFirstPosition(0, 1e18);
        vm.expectRevert();
        this.invariant_OpenPositionsAreCoveredByCausalSlotOrGrandfatheredSet();
        this.invariant_AdmissionOracleLatchRemainsHealthy();
    }

    function testControl4HandlerObservedUnauthorizedAdmissionFailsContainmentAndLatch() public {
        registryHandler.simulateUnauthorizedPolicyOnSecondPositionThroughHandler(0, 1e18);

        vm.expectRevert();
        this.invariant_OpenPositionsAreCoveredByCausalSlotOrGrandfatheredSet();
        vm.expectRevert();
        this.invariant_AdmissionOracleLatchRemainsHealthy();
    }

    function testControl5GrandfatheredSetIsLoadBearing() public {
        address actor = registryActors[0];

        registryHandler.toggleOneVaultPolicy();
        registryHandler.depositSecond(0, 1e18);

        assertEq(_familyOpenVaultCount(actor), 2);
        assertTrue(registryHandler.grandfathered(actor, address(vault)));
        this.invariant_OpenPositionsAreCoveredByCausalSlotOrGrandfatheredSet();
        this.invariant_AdmissionOracleLatchRemainsHealthy();

        vm.expectRevert();
        this.assertOpenSubsetOfSlotOnly();
    }

    function testControl6ClosedCausalSlotAllowsNewPolicyOnSlotAlongsideGrandfatheredPosition() public {
        address actor = registryActors[0];

        registryHandler.toggleOneVaultPolicy();
        registryHandler.depositSecond(0, 1e18);
        registryHandler.toggleOneVaultPolicy();
        registryHandler.closeSecond(0);
        assertEq(registryHandler.slotVault(actor), address(0));
        assertTrue(registryHandler.grandfathered(actor, address(vault)));

        registryHandler.depositThird(0, 1e18);
        assertEq(registryHandler.slotVault(actor), address(thirdRegistryVault));
        assertEq(_familyOpenVaultCount(actor), 2);
        this.invariant_OpenPositionsAreCoveredByCausalSlotOrGrandfatheredSet();
        this.invariant_AdmissionOracleLatchRemainsHealthy();
    }
}

contract LCCRegistryToggleFreeStatefulInvariantTest is LCCRegistryInvariantBase {
    function _includeToggleHandlers() internal pure override returns (bool) {
        return false;
    }

    function invariant_StrongPolicyOnAtMostOneOpenFamilyVault() public view {
        assertTrue(factory.oneVaultPolicyEnabled());
        for (uint256 i = 0; i < registryActors.length; ++i) {
            assertLe(_familyOpenVaultCount(registryActors[i]), 1);
        }
    }
}
