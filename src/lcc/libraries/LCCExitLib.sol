// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

import {SafeCast} from "../../../lib/openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";

import {BPS} from "../../libraries/ConstantsLib.sol";
import {LCCBucketListLib} from "./LCCBucketListLib.sol";
import {LCCConfigLib} from "./LCCConfigLib.sol";
import {LCCErrorsLib} from "./LCCErrorsLib.sol";
import {LCCTypesLib} from "./LCCTypesLib.sol";

/// @title LCCExitLib
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Externally linked storage operations for per-call exit exposure and exit-maturity reconciliation.
/// @dev The vault retains its own bucket increment/decrement and pruning helpers because pending-bucket accounting,
/// maturity folding, and account closeout also use them. Routing those vault-side callers through this library would
/// add delegatecalls outside the extracted subsystem and cost more bytecode and gas than duplicating the small private
/// helpers here. The public functions take `exitBucketByMaturity` as the typed storage anchor and derive the four
/// immediately following exit-storage roots. Their adjacency is part of LCCVault's reviewer-controlled, upgrade-frozen
/// storage layout; deriving them here avoids encoding five independent storage slots at every delegatecall site.
library LCCExitLib {
    using SafeCast for uint256;
    using Math for uint256;

    uint256 private constant MAX_EXIT_MATURITY_BUCKETS = 2 * LCCConfigLib.MAX_EXIT_DELAY_EPOCHS;

    /// @dev Storage view over LCCVault's five consecutive exit-accounting roots. This type is never declared as
    /// vault state and therefore does not alter the vault's storage layout.
    struct ExitStorage {
        mapping(uint256 => LCCTypesLib.Bucket) bucketByMaturity;
        uint256[] maturityList;
        mapping(uint256 => uint256) maturityIndexPlusOne;
        mapping(uint256 => mapping(uint256 => LCCTypesLib.ExitExposure)) exposureByCallAndMaturity;
        mapping(uint256 => uint256[]) maturitiesByCall;
    }

    /// @dev Assignment is first-fit by request time, not strict FIFO. Capacity is recomputed from live active
    /// commitment for every request, so it is never below the configured-cap value at that request but is
    /// path-dependent across requests. It can decline as active commitment declines through amortization or
    /// slashing. Aggregate active commitment may conservatively include unattributed return commitment, which only
    /// widens capacity. Funded or slashed amounts can free bucket room retroactively, and a request larger than the
    /// whole per-epoch capacity takes the first bucket with any remaining room. Cap-raise sequences can still reach
    /// the 128-bucket limit.
    ///
    /// Termination invariant: the `Math.max(1, ...)` clamp below is load-bearing and must not be removed. Capacity of
    /// at least one makes any empty bucket terminate the scan; only nonzero-commitment buckets are skipped. The vault's
    /// maturity tracking and pruning keep those buckets in the 128-entry maturity list, so the scan takes at most 129
    /// iterations. `packedCaps` stores the validated uint128 protocol/active commitments in its low/high halves;
    /// `packedTiming` stores the phase-aware earliest maturity (uint64) and exitCapBps (uint16). Packing changes only
    /// the delegatecall ABI, not the arithmetic widths used below.
    function assignExitMaturity(
        mapping(uint256 => LCCTypesLib.Bucket) storage exitBucketByMaturity,
        uint256 accountCommitment,
        uint256 maxDeferralEpochs,
        uint256 packedCaps,
        uint256 packedTiming
    ) public view returns (uint256 maturityEpoch) {
        ExitStorage storage exitStorage = _exitStorage(exitBucketByMaturity);
        uint256 earliestMaturity = uint64(packedTiming);
        uint256 capacity = Math.max(
            1, Math.max(uint128(packedCaps), uint128(packedCaps >> 128)).mulDiv(uint16(packedTiming >> 64), BPS)
        );

        maturityEpoch = earliestMaturity;
        uint256 remainingDeferralEpochs = maxDeferralEpochs;
        while (true) {
            uint256 assigned = exitStorage.bucketByMaturity[maturityEpoch].commitment;
            if (assigned < capacity) {
                if (accountCommitment <= capacity - assigned || accountCommitment > capacity) {
                    if (
                        exitStorage.maturityIndexPlusOne[maturityEpoch] != 0
                            || exitStorage.maturityList.length < MAX_EXIT_MATURITY_BUCKETS
                    ) return maturityEpoch;

                    return
                        _assignAtFullList(exitStorage, accountCommitment, earliestMaturity, maxDeferralEpochs, capacity);
                }
            }
            if (remainingDeferralEpochs == 0) revert LCCErrorsLib.ExitDeferralExceeded();
            unchecked {
                --remainingDeferralEpochs;
                ++maturityEpoch;
            }
        }
    }

    /// @dev When all 128 maturity keys are occupied, admit against aggregate capacity within the caller's deferral
    /// window and choose the least-loaded eligible bucket, breaking ties by earliest maturity. For eligible load S,
    /// bucket count N, capacity C, and account commitment A, admission requires S + A <= N * C. The selected bucket's
    /// post-assignment load is therefore at most S / N + A <= C + A * (1 - 1 / N), so overshoot is strictly below A.
    function _assignAtFullList(
        ExitStorage storage exitStorage,
        uint256 accountCommitment,
        uint256 earliestMaturity,
        uint256 maxDeferralEpochs,
        uint256 capacity
    ) private view returns (uint256 selectedMaturity) {
        uint256 eligibleCount;
        uint256 scheduledCommitment;
        uint256 selectedCommitment = type(uint256).max;

        for (uint256 i = 0; i < exitStorage.maturityList.length; ++i) {
            uint256 maturity = exitStorage.maturityList[i];
            if (maturity < earliestMaturity || maturity - earliestMaturity > maxDeferralEpochs) continue;

            uint256 commitment = exitStorage.bucketByMaturity[maturity].commitment;
            scheduledCommitment += commitment;
            ++eligibleCount;
            if (commitment < selectedCommitment || (commitment == selectedCommitment && maturity < selectedMaturity)) {
                selectedCommitment = commitment;
                selectedMaturity = maturity;
            }
        }

        if (scheduledCommitment + accountCommitment > eligibleCount * capacity) {
            revert LCCErrorsLib.ExitCapacityReached();
        }
    }

    /// @notice Adds a newly requested exit to its maturity bucket and exact-once maturity list.
    /// @dev `packedExposure` stores margin/commitment in its low/high uint128 halves. When
    /// `currentCallEpochPlusOne != 0`, the current call exposure is appended only after the bucket and list writes,
    /// preserving the vault's original write order.
    function recordExitRequest(
        mapping(uint256 => LCCTypesLib.Bucket) storage exitBucketByMaturity,
        uint256 maturity,
        uint256 packedExposure,
        uint256 currentCallEpochPlusOne
    ) public {
        ExitStorage storage exitStorage = _exitStorage(exitBucketByMaturity);
        uint256 margin = uint128(packedExposure);
        uint256 commitment = uint128(packedExposure >> 128);
        LCCTypesLib.Bucket storage bucket = exitStorage.bucketByMaturity[maturity];
        bucket.margin = (uint256(bucket.margin) + margin).toUint128();
        bucket.commitment = (uint256(bucket.commitment) + commitment).toUint128();
        LCCBucketListLib.track(exitStorage.maturityList, exitStorage.maturityIndexPlusOne, maturity);
        if (currentCallEpochPlusOne != 0) {
            _addCallExitExposure(
                exitStorage.exposureByCallAndMaturity,
                exitStorage.maturitiesByCall,
                currentCallEpochPlusOne - 1,
                maturity,
                margin,
                commitment
            );
        }
    }

    /// @notice Snapshots every still-exposed exit-maturity bucket when a call opens.
    function snapshotExitBucketsForCall(
        mapping(uint256 => LCCTypesLib.Bucket) storage exitBucketByMaturity,
        uint256 epoch
    ) public {
        ExitStorage storage exitStorage = _exitStorage(exitBucketByMaturity);

        for (uint256 i = 0; i < exitStorage.maturityList.length; ++i) {
            uint256 maturity = exitStorage.maturityList[i];
            if (maturity <= epoch) continue;

            LCCTypesLib.Bucket storage bucket = exitStorage.bucketByMaturity[maturity];
            uint256 margin = bucket.margin;
            uint256 commitment = bucket.commitment;
            if (margin == 0 && commitment == 0) continue;

            _addCallExitExposure(
                exitStorage.exposureByCallAndMaturity, exitStorage.maturitiesByCall, epoch, maturity, margin, commitment
            );
        }
    }

    /// @notice Reconciles a funding exiter's maturity bucket and records its funded call exposure.
    /// @dev Called only after the vault has established that the account has a live, unmatured exit. The caller updates
    /// the account's in-memory bucket mirror immediately after this storage operation and persists it later in the same
    /// transaction, preserving the existing `synced`-entrypoint coupling. `packedFunded` stores released margin in its
    /// low uint128 half and obligation in its high half; `packedRemaining` stores remaining commitment low and margin
    /// high. All four values originate in the vault's uint128-bounded account state.
    function recordExitingFund(
        mapping(uint256 => LCCTypesLib.Bucket) storage exitBucketByMaturity,
        uint256 epoch,
        uint256 maturity,
        uint256 packedFunded,
        uint256 packedRemaining
    ) public {
        ExitStorage storage exitStorage = _exitStorage(exitBucketByMaturity);
        uint256 obligationAmount = uint128(packedFunded >> 128);
        uint256 releasedMargin = uint128(packedFunded);
        uint256 remainingMargin = uint128(packedRemaining >> 128);
        uint256 remainingCommitment = uint128(packedRemaining);

        LCCTypesLib.Bucket storage bucket = exitStorage.bucketByMaturity[maturity];
        _decreaseBucket(bucket, releasedMargin, obligationAmount);
        _pruneExitMaturityIfEmpty(exitStorage, maturity);

        LCCTypesLib.ExitExposure storage exposure = exitStorage.exposureByCallAndMaturity[epoch][maturity];
        if (!exposure.listed) return;

        exposure.fundedAmount = (uint256(exposure.fundedAmount) + obligationAmount).toUint128();
        exposure.marginReleased = (uint256(exposure.marginReleased) + releasedMargin).toUint128();
        exposure.fundedUsersRemainingMargin =
            (uint256(exposure.fundedUsersRemainingMargin) + remainingMargin).toUint128();
        exposure.fundedUsersRemainingCommitment =
            (uint256(exposure.fundedUsersRemainingCommitment) + remainingCommitment).toUint128();
    }

    /// @notice Removes defaulted exiting exposure from every maturity bucket snapshotted for a call.
    function reduceExitBucketsForSlash(
        mapping(uint256 => LCCTypesLib.Bucket) storage exitBucketByMaturity,
        uint256 epoch
    ) public {
        ExitStorage storage exitStorage = _exitStorage(exitBucketByMaturity);

        uint256[] storage maturities = exitStorage.maturitiesByCall[epoch];
        for (uint256 i = 0; i < maturities.length; ++i) {
            uint256 maturity = maturities[i];
            LCCTypesLib.ExitExposure storage exposure = exitStorage.exposureByCallAndMaturity[epoch][maturity];

            uint256 slashedMargin = exposure.margin - exposure.marginReleased - exposure.fundedUsersRemainingMargin;
            uint256 slashedCommitment =
                exposure.commitment - exposure.fundedAmount - exposure.fundedUsersRemainingCommitment;
            if (slashedMargin == 0 && slashedCommitment == 0) continue;

            LCCTypesLib.Bucket storage bucket = exitStorage.bucketByMaturity[maturity];
            _decreaseBucket(bucket, slashedMargin, slashedCommitment);
            _pruneExitMaturityIfEmpty(exitStorage, maturity);
        }
    }

    function _addCallExitExposure(
        mapping(uint256 => mapping(uint256 => LCCTypesLib.ExitExposure)) storage exitExposureByCallAndMaturity,
        mapping(uint256 => uint256[]) storage exitMaturitiesByCall,
        uint256 epoch,
        uint256 maturity,
        uint256 margin,
        uint256 commitment
    ) private {
        LCCTypesLib.ExitExposure storage exposure = exitExposureByCallAndMaturity[epoch][maturity];
        if (!exposure.listed) {
            exposure.listed = true;
            exitMaturitiesByCall[epoch].push(maturity);
        }
        exposure.margin = (uint256(exposure.margin) + margin).toUint128();
        exposure.commitment = (uint256(exposure.commitment) + commitment).toUint128();
    }

    function _decreaseBucket(LCCTypesLib.Bucket storage bucket, uint256 margin, uint256 commitment) private {
        bucket.margin = (uint256(bucket.margin) - margin).toUint128();
        bucket.commitment = (uint256(bucket.commitment) - commitment).toUint128();
    }

    function _pruneExitMaturityIfEmpty(ExitStorage storage exitStorage, uint256 maturity) private {
        LCCTypesLib.Bucket storage bucket = exitStorage.bucketByMaturity[maturity];
        bool empty = bucket.margin == 0 && bucket.commitment == 0;
        LCCBucketListLib.pruneIfEmpty(exitStorage.maturityList, exitStorage.maturityIndexPlusOne, maturity, empty);
    }

    function _exitStorage(mapping(uint256 => LCCTypesLib.Bucket) storage exitBucketByMaturity)
        private
        pure
        returns (ExitStorage storage exitStorage)
    {
        assembly ("memory-safe") {
            exitStorage.slot := exitBucketByMaturity.slot
        }
    }
}
