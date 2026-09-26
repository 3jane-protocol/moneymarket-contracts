// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {ORACLE_PRICE_SCALE} from "../../../src/libraries/ConstantsLib.sol";
import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";

/// @dev Characterizes the pair-drop orphan residual in `_pairedReturnPoolShare`. This residual is pre-existing
/// flooring behavior and is independent of the removed per-user return-credit clamp.
///
/// Mechanism: when a defaulter's commitment share of a disposal floors to zero at a crashed call-open price, its
/// paired margin share is dropped with it and stays in `_totals.activeMargin` attributed to no account. A later
/// epoch slashes that orphaned margin again and converts it at the later call-open ratio, so its pro-rata slice of
/// that epoch's `returnCommitment` is also attributed to nobody. The per-epoch flooring bounds each carry one
/// epoch's ratio, but this residual carries the cross-epoch product
/// `(returnPool_i/returnCommitment_i) * (returnCommitment_j/returnPool_j)`, a price ratio, which is why the suite's
/// commitment dust bound adds the `marginDustBound * commitmentRatioSum` term.
///
/// The residual is attribution, not solvency — the vault's margin balance still covers every account — but it
/// inflates the next call's `commitmentDenominator` (diluting funded users' pro-rata obligations), occupies
/// `protocolCommitmentCap` headroom (which can deny deposits), and persists after shutdown as vault margin no
/// account can claim. Per dropped account and epoch it is bounded by `returnPool_i / returnCommitment_i`; with
/// `returnCommitment_i >= MIN_RETURN_COMMITMENT` (1e6 funding base units) that is at most ~1e-6 of the epoch's
/// recovered pool. Once the conversion pins at that minimum, however, the residual scales with deposit size
/// rather than staying O(1) dust, which the second test pins.
contract LCCPairDropOrphanTest is LCCBase {
    uint256 internal constant P1 = 5_000e18; // low call-open snapshot: RC1 = (A+B) * 1e-14 >= MIN_RETURN_COMMITMENT
    uint256 internal constant B_FLOOR = 99_999e9; // just under 1/(p1*leverage) = 1e14, so bob's share floors to 0

    struct Measure {
        uint256 orphanSeed;
        uint256 gapCommitment;
        uint256 gapMargin;
        uint256 returnPoolEpochs;
        uint256 marginRatioSum;
        uint256 commitmentRatioSum;
    }

    function testPairDropOrphanConvertsAtLaterEpochRatioUnattributed() public {
        uint256 orphanSeed = _buildScenario(1, P1, B_FLOOR, 1);
        Measure memory m = _measure(orphanSeed);

        // The commitment gap is the orphan's pro-rata slice of epoch 1's returned commitment (plus flooring dust):
        // bob's dropped epoch-0 margin share, slashed again in epoch 1 and converted at epoch 1's call-open ratio.
        ILCCVault.EpochState memory e1 = vault.getEpochState(1);
        uint256 expectedCrossTerm = Math.mulDiv(e1.returnCommitment, orphanSeed, e1.slashedMargin);
        assertApproxEqAbs(m.gapCommitment, expectedCrossTerm, 5, "gap is the converted orphan slice");
        assertGe(m.gapCommitment, B_FLOOR / 2, "residual is orphan-scaled, not O(1) dust");

        // The per-epoch flooring form alone cannot cover the cross term; the two-term suite bound does, and the
        // margin side stays within its unchanged bound.
        assertGt(m.gapCommitment, 3 * (m.returnPoolEpochs + m.commitmentRatioSum), "per-epoch form is insufficient");
        _assertSuiteBoundsHold(m);
    }

    // p1 scaled down with deposits keeps RC1 pinned at MIN_RETURN_COMMITMENT, so the flooring threshold M1/RC1
    // grows with the aggregate and the orphan itself scales with deposit size.
    function testOrphanResidualScalesWithDepositsWhenConversionPinsAtMinimum() public {
        uint256 scaledFloor = 9_999_900e9;
        uint256 orphanSeed = _buildScenario(100, P1 / 100, scaledFloor, 1);
        Measure memory m = _measure(orphanSeed);

        assertGe(m.gapCommitment, scaledFloor / 2, "residual scales with the deposit size");
        assertGt(m.gapCommitment, 3 * (m.returnPoolEpochs + m.commitmentRatioSum), "per-epoch form is insufficient");
        _assertSuiteBoundsHold(m);
    }

    function _buildScenario(uint256 depositScale, uint256 p1, uint256 bFloor, uint256 p2Mul)
        internal
        returns (uint256 orphanSeed)
    {
        _deployVaultWithParams(_params(CAP, CAP));

        // Epoch 0: deposits at price 1.0, oracle crash before call open, full default.
        _deposit(alice, 100e18 * depositScale);
        _deposit(bob, bFloor);
        oracle.setPrice(p1);
        _openCall(1e6);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        ILCCVault.EpochState memory e0 = vault.getEpochState(0);
        assertGt(e0.returnPool, 0, "epoch0 return pool must exist");
        assertEq(
            Math.mulDiv(e0.returnCommitment, bFloor, e0.slashedMargin), 0, "bob's commitmentShare must floor to zero"
        );
        orphanSeed = Math.mulDiv(e0.returnPool, bFloor, e0.slashedMargin);
        assertGt(orphanSeed, 0, "bob's dropped marginShare must be material");

        // Epoch 1: restored (or higher) price, fresh headroom deposit, full default again.
        oracle.setPrice(p2Mul * ORACLE_PRICE_SCALE);
        vm.warp(START + EPOCH);
        _deposit(carol, 100e18 * depositScale);
        _openCallAtEpoch(1, 1e6);
        _finishFundingAtEpoch(1);
        vault.finalizeEpochSlash(1);

        vault.materializeAccount(alice);
        vault.materializeAccount(bob);
        vault.materializeAccount(carol);

        ILCCVault.Account memory bobAccount = vault.getAccount(bob);
        assertEq(bobAccount.activeMargin, 0, "pair-drop: bob credited nothing");
        assertEq(bobAccount.activeCommitment, 0, "pair-drop: bob credited nothing");
    }

    function _measure(uint256 orphanSeed) internal view returns (Measure memory m) {
        m.orphanSeed = orphanSeed;

        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        MarginSums memory sums = _marginSums(actors);
        ILCCVault.Totals memory totals = vault.totals();

        m.gapCommitment = uint256(totals.activeCommitment) - sums.activeCommitment;
        m.gapMargin = uint256(totals.activeMargin) - sums.activeMargin;

        uint256[] memory called = vault.calledEpochs();
        for (uint256 i = 0; i < called.length; ++i) {
            ILCCVault.EpochState memory state = vault.getEpochState(called[i]);
            if (state.returnPool != 0) {
                ++m.returnPoolEpochs;
                m.marginRatioSum += Math.ceilDiv(state.returnPool, state.returnCommitment);
                m.commitmentRatioSum += Math.ceilDiv(state.returnCommitment, state.returnPool);
            }
        }
    }

    function _assertSuiteBoundsHold(Measure memory m) internal pure {
        uint256 n = 3;
        uint256 marginDustBound = n * (m.returnPoolEpochs + m.marginRatioSum);
        uint256 commitmentDustBound =
            n * (m.returnPoolEpochs + m.commitmentRatioSum) + marginDustBound * m.commitmentRatioSum;
        assertLe(m.gapMargin, marginDustBound, "margin gap within suite bound");
        assertLe(m.gapCommitment, commitmentDustBound, "commitment gap within suite bound");
    }
}
