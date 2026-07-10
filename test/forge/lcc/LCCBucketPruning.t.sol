// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";

contract LCCBucketPruningTest is LCCBase {
    // These slots intentionally mirror the upgrade-frozen LCCVault storage-layout snapshot. Reading the internal
    // sparse-list bookkeeping directly lets the tests prove both list contents and every 1-based index mapping.
    uint256 internal constant TOTALS_SLOT = 11;
    uint256 internal constant PENDING_MARGIN_SLOT = 19;
    uint256 internal constant PENDING_COMMITMENT_SLOT = 20;
    uint256 internal constant ACTIVATION_LIST_SLOT = 21;
    uint256 internal constant ACTIVATION_INDEX_SLOT = 22;
    uint256 internal constant EXIT_MARGIN_SLOT = 23;
    uint256 internal constant EXIT_COMMITMENT_SLOT = 24;
    uint256 internal constant MATURITY_LIST_SLOT = 25;
    uint256 internal constant MATURITY_INDEX_SLOT = 26;

    struct BucketSlots {
        uint256 marginMapping;
        uint256 commitmentMapping;
        uint256 list;
        uint256 indexMapping;
        uint256 packedTotals;
    }

    function testActivationPruningRetainsMixedFutureBucketsAndRepairsIndices() public {
        _seedBuckets(
            BucketSlots({
                marginMapping: PENDING_MARGIN_SLOT,
                commitmentMapping: PENDING_COMMITMENT_SLOT,
                list: ACTIVATION_LIST_SLOT,
                indexMapping: ACTIVATION_INDEX_SLOT,
                packedTotals: TOTALS_SLOT + 1
            })
        );

        vm.warp(START + 3 * EPOCH);
        vault.materializeAccount(alice);

        _assertPrunedList(ACTIVATION_LIST_SLOT, ACTIVATION_INDEX_SLOT);
        _assertBucketValues(PENDING_MARGIN_SLOT, PENDING_COMMITMENT_SLOT);

        ILCCVault.Totals memory totals = vault.totals();
        assertEq(totals.activeMargin, 6e18);
        assertEq(totals.activeCommitment, 12e18);
        assertEq(totals.pendingMargin, 17e18);
        assertEq(totals.pendingCommitment, 34e18);
    }

    function testMaturityPruningRetainsMixedFutureBucketsAndRepairsIndices() public {
        _seedBuckets(
            BucketSlots({
                marginMapping: EXIT_MARGIN_SLOT,
                commitmentMapping: EXIT_COMMITMENT_SLOT,
                list: MATURITY_LIST_SLOT,
                indexMapping: MATURITY_INDEX_SLOT,
                packedTotals: TOTALS_SLOT
            })
        );

        vm.warp(START + 3 * EPOCH);
        vault.materializeAccount(alice);

        _assertPrunedList(MATURITY_LIST_SLOT, MATURITY_INDEX_SLOT);
        _assertBucketValues(EXIT_MARGIN_SLOT, EXIT_COMMITMENT_SLOT);

        ILCCVault.Totals memory totals = vault.totals();
        assertEq(totals.activeMargin, 17e18);
        assertEq(totals.activeCommitment, 34e18);
        assertEq(totals.pendingMargin, 0);
        assertEq(totals.pendingCommitment, 0);
    }

    function _seedBuckets(BucketSlots memory slots) internal {
        // Epochs 1, 2, and 3 are due. Epoch 3 is a due middle element whose removal moves the future tail (9) into
        // its slot; epochs 8 and 9 must both survive even though that moved tail has already been examined.
        uint256[5] memory epochs = [uint256(1), 8, 2, 3, 9];

        vm.store(address(vault), bytes32(slots.list), bytes32(epochs.length));
        uint256 listDataSlot = uint256(keccak256(abi.encode(slots.list)));
        for (uint256 i = 0; i < epochs.length; ++i) {
            _seedBucket(slots, listDataSlot, i, epochs[i]);
        }

        vm.store(address(vault), bytes32(slots.packedTotals), bytes32(uint256(23e18) | (uint256(46e18) << 128)));
    }

    function _seedBucket(BucketSlots memory slots, uint256 listDataSlot, uint256 index, uint256 epoch) internal {
        vm.store(address(vault), bytes32(listDataSlot + index), bytes32(epoch));
        vm.store(address(vault), _mappingSlot(epoch, slots.indexMapping), bytes32(index + 1));
        vm.store(address(vault), _mappingSlot(epoch, slots.marginMapping), bytes32(epoch * 1e18));
        vm.store(address(vault), _mappingSlot(epoch, slots.commitmentMapping), bytes32(epoch * 2e18));
    }

    function _assertPrunedList(uint256 listSlot, uint256 indexMappingSlot) internal view {
        assertEq(uint256(vm.load(address(vault), bytes32(listSlot))), 2);

        uint256 listDataSlot = uint256(keccak256(abi.encode(listSlot)));
        assertEq(uint256(vm.load(address(vault), bytes32(listDataSlot))), 9);
        assertEq(uint256(vm.load(address(vault), bytes32(listDataSlot + 1))), 8);

        assertEq(_indexPlusOne(1, indexMappingSlot), 0);
        assertEq(_indexPlusOne(2, indexMappingSlot), 0);
        assertEq(_indexPlusOne(3, indexMappingSlot), 0);
        assertEq(_indexPlusOne(9, indexMappingSlot), 1);
        assertEq(_indexPlusOne(8, indexMappingSlot), 2);
    }

    function _assertBucketValues(uint256 marginMappingSlot, uint256 commitmentMappingSlot) internal view {
        for (uint256 epoch = 1; epoch <= 3; ++epoch) {
            assertEq(uint256(vm.load(address(vault), _mappingSlot(epoch, marginMappingSlot))), 0);
            assertEq(uint256(vm.load(address(vault), _mappingSlot(epoch, commitmentMappingSlot))), 0);
        }

        assertEq(uint256(vm.load(address(vault), _mappingSlot(8, marginMappingSlot))), 8e18);
        assertEq(uint256(vm.load(address(vault), _mappingSlot(8, commitmentMappingSlot))), 16e18);
        assertEq(uint256(vm.load(address(vault), _mappingSlot(9, marginMappingSlot))), 9e18);
        assertEq(uint256(vm.load(address(vault), _mappingSlot(9, commitmentMappingSlot))), 18e18);
    }

    function _indexPlusOne(uint256 epoch, uint256 indexMappingSlot) internal view returns (uint256) {
        return uint256(vm.load(address(vault), _mappingSlot(epoch, indexMappingSlot)));
    }

    function _mappingSlot(uint256 key, uint256 slot) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, slot));
    }
}
