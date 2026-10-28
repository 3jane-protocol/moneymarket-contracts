// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test} from "../../../lib/forge-std/src/Test.sol";

import {LCCBucketListLib} from "../../../src/lcc/libraries/LCCBucketListLib.sol";

contract LCCBucketListHarness {
    using LCCBucketListLib for uint256[];

    uint256[] internal list;
    mapping(uint256 => uint256) internal indexPlusOne;

    function track(uint256 key) external {
        list.track(indexPlusOne, key);
    }

    function pruneIfEmpty(uint256 key, bool empty) external {
        list.pruneIfEmpty(indexPlusOne, key, empty);
    }

    function keys() external view returns (uint256[] memory) {
        return list;
    }

    function indexOf(uint256 key) external view returns (uint256) {
        return indexPlusOne[key];
    }
}

contract LCCBucketListLibTest is Test {
    uint256 internal constant KEY_SPACE = 16;

    LCCBucketListHarness internal buckets;

    function setUp() public {
        buckets = new LCCBucketListHarness();
    }

    function testFuzzTrackAndPruneMatchReferenceSet(uint256[48] memory keySeeds, uint256 opBitmap, uint256 emptyBitmap)
        public
    {
        bool[KEY_SPACE] memory present;
        uint256 expectedLength;

        for (uint256 i = 0; i < keySeeds.length; ++i) {
            uint256 key = bound(keySeeds[i], 0, KEY_SPACE - 1);
            bool trackOp = (opBitmap & (uint256(1) << (i % 256))) == 0;
            bool empty = (emptyBitmap & (uint256(1) << (i % 256))) != 0;

            uint256[] memory beforeList = buckets.keys();
            uint256 beforeIndex = buckets.indexOf(key);
            uint256 beforeLast = beforeList.length == 0 ? 0 : beforeList[beforeList.length - 1];

            if (trackOp) {
                buckets.track(key);
                if (!present[key]) {
                    present[key] = true;
                    ++expectedLength;
                }
            } else {
                buckets.pruneIfEmpty(key, empty);
                if (empty && present[key]) {
                    present[key] = false;
                    --expectedLength;
                    _assertSwapRemove(beforeIndex, beforeLast, key);
                }
            }

            _assertMatchesReferenceSet(present, expectedLength);
        }
    }

    function _assertSwapRemove(uint256 beforeIndex, uint256 beforeLast, uint256 removedKey) internal view {
        assertEq(buckets.indexOf(removedKey), 0);
        if (beforeLast != removedKey) assertEq(buckets.indexOf(beforeLast), beforeIndex);
    }

    function _assertMatchesReferenceSet(bool[KEY_SPACE] memory present, uint256 expectedLength) internal view {
        uint256[] memory list = buckets.keys();
        assertEq(list.length, expectedLength);

        bool[KEY_SPACE] memory seen;
        for (uint256 i = 0; i < list.length; ++i) {
            uint256 key = list[i];
            assertLt(key, KEY_SPACE);
            assertTrue(present[key]);
            assertFalse(seen[key]);
            seen[key] = true;
            assertEq(buckets.indexOf(key), i + 1);
        }

        for (uint256 key = 0; key < KEY_SPACE; ++key) {
            uint256 indexPlusOne = buckets.indexOf(key);
            assertEq(indexPlusOne != 0, present[key]);
            if (indexPlusOne != 0) assertEq(list[indexPlusOne - 1], key);
        }
    }
}
