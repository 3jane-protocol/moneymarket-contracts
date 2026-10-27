// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {Vm} from "../../../lib/forge-std/src/Vm.sol";

/// @dev Recorded-log scanning shared by the LCC unit, helper, and fork suites.
abstract contract LCCLogCounter is Test {
    /// @dev Number of recorded logs from `emitter` whose first topic is `topic`; consumes the recorded logs.
    function _countLogs(address emitter, bytes32 topic) internal returns (uint256 count) {
        (count,) = _scanLogs(vm.getRecordedLogs(), emitter, topic);
    }

    /// @dev Data of the one recorded log from `emitter` whose first topic is `topic`; consumes the recorded logs.
    function _singleLogData(address emitter, bytes32 topic) internal returns (bytes memory) {
        return _singleLogData(vm.getRecordedLogs(), emitter, topic);
    }

    /// @dev Data of the one log in `logs` from `emitter` whose first topic is `topic`.
    function _singleLogData(Vm.Log[] memory logs, address emitter, bytes32 topic)
        internal
        pure
        returns (bytes memory data)
    {
        uint256 count;
        (count, data) = _scanLogs(logs, emitter, topic);
        assertEq(count, 1);
    }

    /// @dev Number of logs in `logs` from `emitter` whose first topic is `topic`, and the data of the last of them.
    function _scanLogs(Vm.Log[] memory logs, address emitter, bytes32 topic)
        internal
        pure
        returns (uint256 count, bytes memory data)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic) {
                data = logs[i].data;
                ++count;
            }
        }
    }
}
