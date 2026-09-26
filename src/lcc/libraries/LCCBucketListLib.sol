// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

/// @title LCCBucketListLib
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Storage helpers for sparse epoch bucket lists with 1-based index maps.
/// @dev Mirrors OpenZeppelin EnumerableSet's position-map pattern: `indexPlusOne` stores `array index + 1` so the
/// mapping's zero default unambiguously means "not tracked", making membership a single read with no sentinel
/// slot. Kept as owned code rather than `EnumerableSet.UintSet` because callers rely on a property this library
/// states as a contract: removal only ever moves the LAST element into the vacated index. A caller iterating the
/// list by descending index may therefore prune the current key mid-loop without skipping or revisiting any
/// entry — every moved element comes from an index the loop has already examined. The vault's due-bucket fold
/// loops are built on exactly this guarantee.
library LCCBucketListLib {
    /// @notice Appends `key` to the list if it is not already tracked; no-op otherwise.
    /// @dev After `push`, the element's 1-based position equals the new `list.length`, so the encoding falls out
    /// of the append with no extra arithmetic.
    function track(uint256[] storage list, mapping(uint256 => uint256) storage indexPlusOne, uint256 key) internal {
        if (indexPlusOne[key] != 0) return;
        indexPlusOne[key] = list.length + 1;
        list.push(key);
    }

    /// @notice Swap-removes `key` from the list when `empty` says its bucket no longer holds value; no-op when the
    /// bucket is still live or the key is not tracked.
    /// @dev O(1) swap-and-pop: the tail element (and only the tail element) moves into the removed index and has
    /// its position remapped; the removed key's position resets to zero, reclaiming the slot. `empty` is computed
    /// by the caller from the bucket storage the list indexes, keeping this library agnostic of bucket shape.
    function pruneIfEmpty(
        uint256[] storage list,
        mapping(uint256 => uint256) storage indexPlusOne,
        uint256 key,
        bool empty
    ) internal {
        if (!empty || indexPlusOne[key] == 0) return;

        uint256 index = indexPlusOne[key] - 1;
        uint256 lastIndex = list.length - 1;
        if (index != lastIndex) {
            uint256 moved = list[lastIndex];
            list[index] = moved;
            indexPlusOne[moved] = index + 1;
        }
        list.pop();
        indexPlusOne[key] = 0;
    }
}
