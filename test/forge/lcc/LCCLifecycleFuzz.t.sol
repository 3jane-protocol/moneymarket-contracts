// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LCCMockToken} from "./LCCBase.t.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCAuctionLib} from "../../../src/lcc/libraries/LCCAuctionLib.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {ORACLE_PRICE_SCALE, BPS} from "../../../src/libraries/ConstantsLib.sol";
import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";

contract LCCLifecycleFuzz is LCCBase {
    uint256 internal constant MIN_EXIT_CAP_BPS = 313;
    uint256 internal constant MAX_EXIT_DELAY_EPOCHS = 64;
    uint256 internal constant MAX_EPOCH_LENGTH = 30 days;
    uint256 internal constant MIN_PROTOCOL_CAP = 4_000_000e18;
    uint256 internal constant MAX_PROTOCOL_CAP = 100_000_000e18;
    uint256 internal constant MIN_USER_CAP = 1_000_000e18;
    uint256 internal constant ACTOR_LIQUIDITY = 100_000_000e18;

    address internal dave = makeAddr("dave");

    struct ParamSeed {
        uint256 epochLength;
        uint256 normalDuration;
        uint256 preCallDuration;
        uint256 fundingDuration;
        uint256 marginRatioBps;
        uint256 protocolCommitmentCap;
        uint256 userCommitmentCap;
        uint256 exitCapBps;
        uint256 exitDelayEpochs;
        uint256 minCommitmentEpochs;
        uint256 minDepositAssets;
        uint256 auctionMode;
        uint256 auctionStepCount;
        uint256 auctionStepDecayRateBps;
        uint256 maxAuctionAwardBps;
        uint256 slashFeeBps;
    }

    function testFuzz_LifecycleConservesMargin(
        ParamSeed memory seed,
        uint256 priceSeed,
        uint256 callBps,
        uint256 fillSeed
    ) public {
        ILCCVault.VaultParams memory params = _boundParams(seed);
        _deployFuzzVault(params);
        _assertBelowMinDepositReverts(params, fillSeed);
        uint256 price = _setBoundedOraclePrice(priceSeed);

        uint256 depositAmount = _depositAmount(params, price, fillSeed, 3);
        _deposit(alice, depositAmount);
        _deposit(bob, depositAmount);

        vm.warp(vault.phaseEndsAt(0, ILCCVault.Phase.Normal));
        _deposit(carol, depositAmount);

        vm.warp(params.startTimestamp + params.epochLength);
        vault.materializeAccount(alice);
        vault.materializeAccount(bob);
        vault.materializeAccount(carol);

        uint256 claimableExitMargin = _requestAndMatureExitIfPossible(carol, params);
        assertGt(claimableExitMargin, 0);

        uint256 callEpoch = vault.currentEpoch();
        vm.warp(vault.phaseEndsAt(callEpoch, ILCCVault.Phase.Normal));
        uint256 activeCommitment = vault.totals().activeCommitment;
        uint256 callAmount = _callAmount(activeCommitment, callBps);
        vm.prank(owner);
        vault.openEpochCall(callEpoch, callAmount);

        vm.warp(vault.phaseEndsAt(callEpoch, ILCCVault.Phase.PreCall));
        vm.prank(alice);
        vault.fundCall(false);
        vm.prank(bob);
        vault.fundCall(true);

        vm.warp(vault.phaseEndsAt(callEpoch, ILCCVault.Phase.Funding));
        vault.finalizeEpochSlash(callEpoch);
        _maybeTakePartialAuction(callEpoch, fillSeed);

        vm.warp(vault.phaseEndsAt(callEpoch, ILCCVault.Phase.Closed));
        vault.finalizeEpochSlash(callEpoch);
        _materializeActors(_threeActors());
        _assertConservation(_threeActors(), 0);

        vm.prank(owner);
        vault.shutdown();
        _drainAndAssertOnlyDust(_threeActors());
    }

    function testFuzz_AllFundedEpochCollectsAtLeastCallAmount(
        ParamSeed memory seed,
        uint96[4] memory deposits,
        uint256 callBps
    ) public {
        ILCCVault.VaultParams memory params = _boundParams(seed);
        _deployFuzzVault(params);
        _assertBelowMinDepositReverts(params, deposits[0]);
        uint256 price = _setBoundedOraclePrice(uint256(deposits[0]) + uint256(deposits[1]));
        address[] memory actors = _fourActors();

        for (uint256 i = 0; i < actors.length; ++i) {
            uint256 assets = _depositAmount(params, price, uint256(deposits[i]), actors.length);
            vm.prank(actors[i]);
            vault.deposit(assets);
        }

        vm.warp(vault.phaseEndsAt(0, ILCCVault.Phase.Normal));
        uint256 callAmount = _callAmount(vault.totals().activeCommitment, callBps);
        vm.prank(owner);
        vault.openEpochCall(0, callAmount);

        vm.warp(vault.phaseEndsAt(0, ILCCVault.Phase.PreCall));
        for (uint256 i = 0; i < actors.length; ++i) {
            vm.prank(actors[i]);
            vault.fundCall(false);
        }

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertGe(state.fundedAmount, state.callAmount);
    }

    function testFuzz_TerminalDrainLeavesOnlyDust(ParamSeed memory seed, uint256 priceSeed) public {
        ILCCVault.VaultParams memory params = _boundParams(seed);
        params.maxEpochs = bound(priceSeed, 1, 4);
        _deployFuzzVault(params);
        _assertBelowMinDepositReverts(params, priceSeed);
        uint256 price = _setBoundedOraclePrice(priceSeed);

        uint256 depositAmount = _depositAmount(params, price, priceSeed, 3);
        _deposit(alice, depositAmount);
        _deposit(bob, depositAmount);
        _deposit(carol, depositAmount);

        vm.warp(vault.phaseEndsAt(0, ILCCVault.Phase.Normal));
        uint256 callAmount = _callAmount(vault.totals().activeCommitment, priceSeed);
        vm.prank(owner);
        vault.openEpochCall(0, callAmount);

        vm.warp(vault.phaseEndsAt(0, ILCCVault.Phase.PreCall));
        vm.prank(alice);
        vault.fundCall(false);
        vm.prank(bob);
        vault.fundCall(true);

        vm.warp(vault.phaseEndsAt(0, ILCCVault.Phase.Funding));
        vault.finalizeEpochSlash(0);

        uint256 terminalStart = vault.phaseEndsAt(params.maxEpochs - 1, ILCCVault.Phase.Closed);
        vm.warp(terminalStart + 1);
        _drainAndAssertOnlyDust(_threeActors());
    }

    function _boundParams(ParamSeed memory seed) internal view returns (ILCCVault.VaultParams memory params) {
        // Keep this in sync with LCCConfigLib.t.sol's _boundParams copy.
        params = _params(address(oracle), MIN_PROTOCOL_CAP, MIN_USER_CAP, MIN_EXIT_CAP_BPS);
        params.maxEpochs = 0;
        params.epochLength = bound(seed.epochLength, 4, MAX_EPOCH_LENGTH);
        bool auctionEnabled = seed.auctionMode % 2 == 1 && params.epochLength >= 5;
        (params.normalDuration, params.preCallDuration, params.fundingDuration) =
            _boundPhaseDurations(seed, params.epochLength, auctionEnabled);
        params.marginRatioBps = bound(seed.marginRatioBps, 1, BPS);
        params.protocolCommitmentCap = bound(seed.protocolCommitmentCap, MIN_PROTOCOL_CAP, MAX_PROTOCOL_CAP);
        params.userCommitmentCap = bound(seed.userCommitmentCap, MIN_USER_CAP, params.protocolCommitmentCap);
        params.exitCapBps = bound(seed.exitCapBps, MIN_EXIT_CAP_BPS, BPS);
        params.exitDelayEpochs = bound(seed.exitDelayEpochs, 1, MAX_EXIT_DELAY_EPOCHS);
        params.minCommitmentEpochs = bound(seed.minCommitmentEpochs, 0, MAX_EXIT_DELAY_EPOCHS);
        params.minDepositAssets = bound(seed.minDepositAssets, 0, 1e18);

        if (auctionEnabled) {
            uint256 closedWindow =
                params.epochLength - params.normalDuration - params.preCallDuration - params.fundingDuration;
            params.auctionStepCount = bound(seed.auctionStepCount, 2, closedWindow);
            params.auctionStepDecayRateBps = bound(seed.auctionStepDecayRateBps, 1, BPS);
            params.maxAuctionAwardBps = bound(seed.maxAuctionAwardBps, 1, BPS);
            params.slashFeeBps = bound(seed.slashFeeBps, 0, BPS);
        } else {
            params.auctionStepCount = 0;
            params.auctionStepDecayRateBps = 0;
            params.maxAuctionAwardBps = 0;
            params.slashFeeBps = 0;
        }
    }

    function _boundPhaseDurations(ParamSeed memory seed, uint256 epochLength, bool auctionEnabled)
        internal
        view
        returns (uint256 normal, uint256 preCall, uint256 funding)
    {
        uint256 phaseBudget = auctionEnabled ? epochLength - 2 : epochLength;
        normal = bound(seed.normalDuration, 1, phaseBudget - 2);
        preCall = bound(seed.preCallDuration, 1, phaseBudget - normal - 1);
        funding = bound(seed.fundingDuration, 1, phaseBudget - normal - preCall);
    }

    function _deployFuzzVault(ILCCVault.VaultParams memory params) internal {
        _deployVaultWithParams(params);
        _mintAndApprove(alice, ACTOR_LIQUIDITY, ACTOR_LIQUIDITY);
        _mintAndApprove(bob, ACTOR_LIQUIDITY, ACTOR_LIQUIDITY);
        _mintAndApprove(carol, ACTOR_LIQUIDITY, ACTOR_LIQUIDITY);
        _mintAndApprove(dave, ACTOR_LIQUIDITY, ACTOR_LIQUIDITY);
    }

    function _setBoundedOraclePrice(uint256 priceSeed) internal returns (uint256 price) {
        price = bound(priceSeed, ORACLE_PRICE_SCALE / 100, ORACLE_PRICE_SCALE * 100);
        oracle.setPrice(price);
    }

    function _depositAmount(ILCCVault.VaultParams memory params, uint256 price, uint256 amountSeed, uint256 actorCount)
        internal
        view
        returns (uint256 assets)
    {
        uint256 lower = Math.max(params.minDepositAssets, 1e18);
        uint256 commitmentBudget = Math.min(params.userCommitmentCap, params.protocolCommitmentCap / actorCount);
        uint256 maxAssets = Math.mulDiv(commitmentBudget, params.marginRatioBps * ORACLE_PRICE_SCALE, price * BPS);
        uint256 upper = Math.min(maxAssets, 10e18);
        if (upper <= lower) return lower;
        return bound(amountSeed, lower, upper);
    }

    function _callAmount(uint256 activeCommitment, uint256 callBpsSeed) internal pure returns (uint256) {
        uint256 callBps = 1 + (callBpsSeed % BPS);
        uint256 callAmount = Math.mulDiv(activeCommitment, callBps, BPS);
        if (callAmount == 0) return 1;
        return callAmount;
    }

    function _assertBelowMinDepositReverts(ILCCVault.VaultParams memory params, uint256 amountSeed) internal {
        if (params.minDepositAssets <= 1) return;

        uint256 belowMin = bound(amountSeed, 1, params.minDepositAssets - 1);
        vm.expectRevert(LCCErrorsLib.InvalidAmount.selector);
        vm.prank(dave);
        vault.deposit(belowMin);
    }

    function _requestAndMatureExitIfPossible(address actor, ILCCVault.VaultParams memory params)
        internal
        returns (uint256 claimableExitMargin)
    {
        vault.materializeAccount(actor);
        ILCCVault.Account memory account = vault.getAccount(actor);
        if (account.exitRequested && !account.exitClaimed) return 0;
        if (account.pendingMargin != 0 || account.pendingCommitment != 0) return 0;
        if (account.activeMargin == 0 || account.activeCommitment == 0) return 0;

        uint256 requestEpoch = account.commitmentStartEpoch + params.minCommitmentEpochs;
        if (vault.currentEpoch() < requestEpoch) vm.warp(params.startTimestamp + requestEpoch * params.epochLength);
        if (vault.currentEpoch() < requestEpoch) return 0;

        vm.prank(actor);
        uint256 maturity = vault.requestExit();
        vm.warp(params.startTimestamp + maturity * params.epochLength);
        vault.materializeAccount(actor);

        claimableExitMargin = vault.getAccount(actor).claimableExitMargin;
    }

    function _maybeTakePartialAuction(uint256 epoch, uint256 fillSeed) internal {
        uint256 slot = vault.syncState().pendingAuctionEpochPlusOne;
        if (slot != epoch + 1) return;

        uint256 deadline = vault.phaseEndsAt(epoch, ILCCVault.Phase.Funding);
        uint256 windowEnd = vault.phaseEndsAt(epoch, ILCCVault.Phase.Closed);
        uint256 elapsed = fillSeed % (windowEnd - deadline);
        vm.warp(deadline + elapsed);

        LCCAuctionLib.AuctionState memory auction = vault.getAuctionState(epoch);
        uint256 remaining = auction.shortfallAmount - auction.filledAmount;
        if (remaining == 0) return;
        uint256 balance = LCCMockToken(vault.assetConfig().fundingAsset).balanceOf(dave);
        uint256 fillMax = Math.min(remaining, balance);
        if (fillMax == 0) return;
        uint256 fill = fillMax == 1 ? 1 : bound(fillSeed / 2, 1, fillMax - 1);

        vm.prank(dave);
        vault.takeAuction(fill);
    }

    function _materializeActors(address[] memory actors) internal {
        for (uint256 i = 0; i < actors.length; ++i) {
            vault.materializeAccount(actors[i]);
        }
    }

    function _assertConservation(address[] memory actors, uint256 initialTreasuryMargin) internal view {
        MarginSums memory sums = _marginSums(actors);
        (uint256 returnPoolEpochs, uint256 marginRatioSum) =
            _assertTreasuryAndEpochConservation(vault.calledEpochs(), initialTreasuryMargin);
        ILCCVault.Totals memory totals = vault.totals();
        uint256 marginDustBound = actors.length * (returnPoolEpochs + marginRatioSum);
        assertLe(sums.activeMargin, totals.activeMargin);
        assertLe(uint256(totals.activeMargin) - sums.activeMargin, marginDustBound);
        assertLe(sums.activeCommitment, totals.activeCommitment);
        assertEq(sums.pendingMargin, totals.pendingMargin);
        assertEq(sums.pendingCommitment, totals.pendingCommitment);

        uint256 auctionInventory;
        uint256 slot = vault.syncState().pendingAuctionEpochPlusOne;
        if (slot != 0) {
            LCCAuctionLib.AuctionState memory auction = vault.getAuctionState(slot - 1);
            auctionInventory = auction.marginPool - auction.marginAwarded;
        }
        assertEq(
            margin.balanceOf(address(vault)),
            uint256(totals.activeMargin) + uint256(totals.pendingMargin) + sums.claimableMargin + auctionInventory
                + vault.pendingTreasuryMargin()
        );
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function _drainAndAssertOnlyDust(address[] memory actors) internal {
        for (uint256 i = 0; i < actors.length; ++i) {
            vault.materializeAccount(actors[i]);
            ILCCVault.Account memory account = vault.getAccount(actors[i]);
            if (account.activeMargin + account.pendingMargin + account.claimableExitMargin == 0) continue;

            vm.prank(actors[i]);
            vault.claimRemainingMargin(actors[i]);
        }

        uint256 claimableMargin;
        for (uint256 i = 0; i < actors.length; ++i) {
            claimableMargin += vault.getAccount(actors[i]).claimableExitMargin;
        }

        uint256 dustBound = _marginDustBound(actors.length);
        vault.sweepTreasury();
        assertLe(
            uint256(vault.totals().activeMargin) + uint256(vault.totals().pendingMargin) + claimableMargin, dustBound
        );
        assertLe(margin.balanceOf(address(vault)), dustBound);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function _threeActors() internal view returns (address[] memory actors) {
        actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
    }

    function _fourActors() internal view returns (address[] memory actors) {
        actors = new address[](4);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        actors[3] = dave;
    }
}
