// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {Vm} from "../../../lib/forge-std/src/Vm.sol";

/// @dev Recorded-log counting shared by the LCC unit, helper, and fork suites.
abstract contract LCCLogCounter is Test {
    /// @dev Number of recorded logs from `emitter` whose first topic is `topic`; consumes the recorded logs.
    function _countLogs(address emitter, bytes32 topic) internal returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic) ++count;
        }
    }
}
