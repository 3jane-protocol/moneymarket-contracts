// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

/// @title LCCBucketListLib
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Storage helpers for sparse epoch bucket lists with 1-based index maps.
library LCCBucketListLib {
    function track(uint256[] storage list, mapping(uint256 => uint256) storage indexPlusOne, uint256 key) internal {
        if (indexPlusOne[key] != 0) return;
        indexPlusOne[key] = list.length + 1;
        list.push(key);
    }

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
