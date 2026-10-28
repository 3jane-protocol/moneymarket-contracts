// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {BPS} from "../../../src/libraries/ConstantsLib.sol";
import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";

contract LCCExitLifecycleRegressionTest is LCCBase {
    uint256 internal constant MAX_EXIT_MATURITY_BUCKETS = 128;
    uint256 internal constant MAX_EXIT_DELAY_EPOCHS = 64;
    uint256 internal constant MAX_MATERIALIZE_STEPS = 64;
    uint256 internal constant FLOOR_EXIT_CAP_BPS = 313;
    uint256 internal constant FRAGMENTATION_PROTOCOL_CAP = 1_000_000e18;
    uint256 internal constant ACCOUNTS_SLOT = 14;
    uint256 internal constant EXIT_MATURITY_LIST_SLOT = 21;

    struct FallbackMetrics {
        uint256 earliestMaturity;
        uint256 remainingCommitted;
        uint256 aggregateUnusedCapacity;
        uint256 eligibleBucketCount;
        uint256 selectedMaturity;
        uint256 eligibleScheduledBefore;
        uint256 aggregateCeiling;
    }

    function test_BoundedExitRejectsDirectMaturityAtSunset() public {
        _deployVaultWithParams(_termParams(4));
        _deposit(alice, 100e18);

        vm.warp(START + 3 * EPOCH);
        vm.expectRevert(LCCErrorsLib.VaultTerminal.selector);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);
    }

    function test_BoundedExitHonoursLastNormalPhaseBoundary() public {
        _deployVaultWithParams(_termParams(4));
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);

        vm.warp(START + 2 * EPOCH);
        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 3);

        vm.warp(START + 2 * EPOCH + NORMAL);
        vm.expectRevert(LCCErrorsLib.VaultTerminal.selector);
        vm.prank(bob);
        vault.requestExit(type(uint256).max, type(uint256).max);

        vm.warp(START + 3 * EPOCH);
        uint256 balanceBefore = margin.balanceOf(alice);
        vm.prank(alice);
        assertEq(vault.claimExitedMargin(alice), 100e18);
        assertEq(margin.balanceOf(alice), balanceBefore + 100e18);
        assertEq(vault.currentEpoch(), 3);
    }

    function test_BoundedExitRejectsFirstFitWalkPastSunset() public {
        ILCCVault.VaultParams memory params = _termParams(4);
        params.protocolCommitmentCap = 400e18;
        params.userCommitmentCap = 400e18;
        params.exitCapBps = 2_500;
        _deployVaultWithParams(params);

        assertEq(_deposit(alice, 30e18), 60e18);
        assertEq(_deposit(bob, 25e18), 50e18);

        vm.warp(START + 2 * EPOCH);
        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 3);
        assertEq(vault.exitBucketCommitmentByMaturity(3), 60e18);

        vm.expectRevert(LCCErrorsLib.VaultTerminal.selector);
        vm.prank(bob);
        vault.requestExit(type(uint256).max, type(uint256).max);
    }

    function test_PerpetualExitAssignmentRemainsUnboundedByTenor() public {
        _deposit(alice, 100e18);

        vm.warp(START + 3 * EPOCH);
        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 4);
    }

    function test_ExitAdmissionWithFullMaturityListAndFragmentedCapacity() public {
        ILCCVault.VaultParams memory params =
            _params(address(oracle), FRAGMENTATION_PROTOCOL_CAP, FRAGMENTATION_PROTOCOL_CAP, FLOOR_EXIT_CAP_BPS);
        params.marginRatioBps = BPS;
        params.exitDelayEpochs = MAX_EXIT_DELAY_EPOCHS;
        _deployVaultWithParams(params);

        uint256 bucketCapacity = Math.mulDiv(FRAGMENTATION_PROTOCOL_CAP, FLOOR_EXIT_CAP_BPS, BPS);
        address[] memory participants = new address[](MAX_EXIT_MATURITY_BUCKETS);
        uint256 participantCount;
        uint256 callCount;
        margin.mint(address(this), FRAGMENTATION_PROTOCOL_CAP);

        // Each call amortizes 15/16 of every live position. The released protocol-cap headroom admits another
        // wave of exact-capacity exits, while the prior buckets retain nonzero commitment and stay tracked.
        while (participantCount < MAX_EXIT_MATURITY_BUCKETS) {
            uint256 epoch = callCount;
            vm.warp(START + epoch * EPOCH);

            uint256 headroom = FRAGMENTATION_PROTOCOL_CAP - vault.totals().activeCommitment;
            while (participantCount < MAX_EXIT_MATURITY_BUCKETS && headroom >= bucketCapacity) {
                address participant = _fragmentationActor(participantCount);
                participants[participantCount] = participant;
                assertTrue(margin.transfer(participant, bucketCapacity));
                _mintAndApprove(participant, 0, bucketCapacity);
                assertEq(_deposit(participant, bucketCapacity), bucketCapacity);

                vm.prank(participant);
                vault.requestExit(type(uint256).max, type(uint256).max);

                unchecked {
                    ++participantCount;
                }
                headroom -= bucketCapacity;
            }

            uint256 activeCommitment = vault.totals().activeCommitment;
            _openCallAtEpoch(epoch, Math.mulDiv(activeCommitment, 15, 16));
            for (uint256 i = 0; i < participantCount; ++i) {
                _fundAtEpoch(participants[i], epoch);
                uint256 releasedMargin = margin.balanceOf(participants[i]);
                if (releasedMargin != 0) {
                    vm.prank(participants[i]);
                    assertTrue(margin.transfer(address(this), releasedMargin));
                }
            }

            unchecked {
                ++callCount;
            }
        }

        assertEq(participantCount, MAX_EXIT_MATURITY_BUCKETS);
        assertEq(callCount, 5);

        // Move to the next Normal phase. The synchronized victim deposit finalizes the fifth call without folding
        // any exit maturity, because the first maturity is still 59 epochs away.
        vm.warp(START + callCount * EPOCH);
        address victim = _fragmentationActor(MAX_EXIT_MATURITY_BUCKETS);
        _mintAndApprove(victim, bucketCapacity, 0);
        assertEq(_deposit(victim, bucketCapacity), bucketCapacity);
        _assertExitBucketCount(MAX_EXIT_MATURITY_BUCKETS);

        uint256 assignedMaturity = _admitFragmentedVictim(victim, bucketCapacity, callCount);
        _assertOverbookedLifecycleConservation(victim, bucketCapacity, callCount, assignedMaturity);
    }

    function _admitFragmentedVictim(address victim, uint256 bucketCapacity, uint256 callCount)
        internal
        returns (uint256 assignedMaturity)
    {
        FallbackMetrics memory metrics;
        metrics.earliestMaturity = callCount + MAX_EXIT_DELAY_EPOCHS;
        uint256 selectedCommitment = type(uint256).max;
        for (uint256 i = 0; i < MAX_EXIT_MATURITY_BUCKETS; ++i) {
            uint256 bucketMaturity = MAX_EXIT_DELAY_EPOCHS + i;
            uint256 residual = vault.exitBucketCommitmentByMaturity(bucketMaturity);
            assertGt(residual, 0, "bucket was pruned");
            assertLt(residual, bucketCapacity, "bucket was not partially amortized");
            metrics.remainingCommitted += residual;
            if (bucketMaturity >= metrics.earliestMaturity) {
                metrics.aggregateUnusedCapacity += bucketCapacity - residual;
                ++metrics.eligibleBucketCount;
                if (residual < selectedCommitment) {
                    selectedCommitment = residual;
                    metrics.selectedMaturity = bucketMaturity;
                }
            }
        }
        assertGt(metrics.aggregateUnusedCapacity, bucketCapacity);
        assertEq(vault.totals().activeCommitment, metrics.remainingCommitted + bucketCapacity);
        assertEq(margin.balanceOf(address(this)) + metrics.remainingCommitted, FRAGMENTATION_PROTOCOL_CAP);
        emit log_named_uint("commitment remaining across 128 buckets", metrics.remainingCommitted);
        emit log_named_uint("aggregate usable unused exit capacity", metrics.aggregateUnusedCapacity);

        metrics.aggregateCeiling = Math.min(FRAGMENTATION_PROTOCOL_CAP, metrics.eligibleBucketCount * bucketCapacity);
        metrics.eligibleScheduledBefore =
            _eligibleScheduledCommitment(metrics.earliestMaturity, MAX_EXIT_DELAY_EPOCHS + MAX_EXIT_MATURITY_BUCKETS);
        assertLe(metrics.eligibleScheduledBefore + bucketCapacity, metrics.aggregateCeiling);

        uint256 gasBefore = gasleft();
        vm.prank(victim);
        assignedMaturity = vault.requestExit(MAX_EXIT_MATURITY_BUCKETS - 1, type(uint256).max);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("fragmented full-list requestExit gas", gasUsed);
        assertEq(assignedMaturity, metrics.selectedMaturity);
        assertGt(vault.exitBucketCommitmentByMaturity(assignedMaturity), bucketCapacity);
        assertTrue(vault.getAccount(victim).exitRequested);
        _assertExitBucketCount(MAX_EXIT_MATURITY_BUCKETS);
        assertEq(
            metrics.eligibleScheduledBefore + bucketCapacity,
            _eligibleScheduledCommitment(metrics.earliestMaturity, MAX_EXIT_DELAY_EPOCHS + MAX_EXIT_MATURITY_BUCKETS)
        );
        assertLe(metrics.eligibleScheduledBefore + bucketCapacity, metrics.aggregateCeiling);
        assertLt(gasUsed, 25_000_000);
    }

    function _assertOverbookedLifecycleConservation(
        address victim,
        uint256 bucketCapacity,
        uint256 callCount,
        uint256 assignedMaturity
    ) internal {
        // The soft-cap assignment remains fully conserved through all downstream paths: the victim amortizes,
        // every other position is slashed, and the victim's surviving exit margin folds at its existing maturity.
        _mintAndApprove(victim, 0, bucketCapacity);
        uint256 vaultMarginBefore = margin.balanceOf(address(vault));
        uint256 treasuryBefore = vault.pendingTreasuryMargin();
        _openCallAtEpoch(callCount, vault.totals().activeCommitment / 2);
        assertGt(_fundAtEpoch(victim, callCount), 0);
        _finishFundingAtEpoch(callCount);
        vault.finalizeEpochSlash(callCount);

        ILCCVault.EpochState memory state = vault.getEpochState(callCount);
        uint256 slashAccrued = vault.pendingTreasuryMargin() - treasuryBefore;
        assertEq(
            state.marginReleased + state.fundedUsersRemainingMargin + slashAccrued + state.returnPool,
            state.marginAtCallOpen
        );

        vm.warp(START + assignedMaturity * EPOCH);
        vault.materializeAccount(victim);
        ILCCVault.Account memory folded = vault.getAccount(victim);
        assertTrue(folded.exitMatured);
        assertEq(folded.claimableExitMargin, state.fundedUsersRemainingMargin);
        assertEq(vault.totals().activeMargin, state.returnPool);
        assertEq(
            margin.balanceOf(address(vault)),
            folded.claimableExitMargin + vault.totals().activeMargin + vault.pendingTreasuryMargin()
        );
        assertEq(
            vaultMarginBefore,
            state.marginReleased + folded.claimableExitMargin + state.returnPool + slashAccrued + treasuryBefore
        );
    }

    function test_MaturedExitClaimAfterManyFinalizedCalls() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 1);

        vm.warp(START + EPOCH);
        vault.materializeAccount(alice);
        ILCCVault.Account memory matured = vault.getAccount(alice);
        assertEq(matured.activeMargin, 0);
        assertEq(matured.activeCommitment, 0);
        assertEq(matured.claimableExitMargin, 100e18);
        assertTrue(matured.exitMatured);
        uint256 maturityEpoch = matured.exitMaturityEpoch;
        uint256 commitmentStartEpoch = matured.commitmentStartEpoch;

        _deposit(bob, 100e18);
        for (uint256 i = 0; i < 2 * MAX_MATERIALIZE_STEPS + 1; ++i) {
            uint256 epoch = i + 1;
            _openCallAtEpoch(epoch, 1e18);
            assertEq(_fundAtEpoch(bob, epoch), 1e18);
            _finishFundingAtEpoch(epoch);
            vault.finalizeEpochSlash(epoch);
        }
        assertEq(vault.syncState().finalizedCallPrefix, 2 * MAX_MATERIALIZE_STEPS + 1);

        vault.materializeAccount(alice);
        ILCCVault.Account memory skipped = vault.getAccount(alice);
        assertEq(skipped.claimableExitMargin, matured.claimableExitMargin);
        assertEq(skipped.exitMaturityEpoch, maturityEpoch);
        assertEq(skipped.commitmentStartEpoch, commitmentStartEpoch);
        assertTrue(skipped.exitRequested);
        assertTrue(skipped.exitMatured);

        uint256 beforeBalance = margin.balanceOf(alice);
        vm.prank(alice);
        assertEq(vault.claimExitedMargin(alice), 100e18);
        assertEq(_storedCalledEpochCursor(alice), 2 * MAX_MATERIALIZE_STEPS + 1);
        assertEq(margin.balanceOf(alice), beforeBalance + 100e18);
    }

    function _storedCalledEpochCursor(address account) internal view returns (uint256) {
        _assertLayoutSlot("accounts", ACCOUNTS_SLOT);
        uint256 accountSlot = uint256(keccak256(abi.encode(account, ACCOUNTS_SLOT)));
        return uint256(vm.load(address(vault), bytes32(accountSlot + 3))) >> 192;
    }

    function _assertExitBucketCount(uint256 expected) internal view {
        _assertLayoutSlot("exitMaturityList", EXIT_MATURITY_LIST_SLOT);
        assertEq(uint256(vm.load(address(vault), bytes32(EXIT_MATURITY_LIST_SLOT))), expected);
    }

    function _eligibleScheduledCommitment(uint256 startMaturity, uint256 endMaturity)
        internal
        view
        returns (uint256 scheduled)
    {
        for (uint256 maturity = startMaturity; maturity < endMaturity; ++maturity) {
            scheduled += vault.exitBucketCommitmentByMaturity(maturity);
        }
    }

    function _fragmentationActor(uint256 index) internal view returns (address) {
        return vm.addr(index + 20_000);
    }
}
