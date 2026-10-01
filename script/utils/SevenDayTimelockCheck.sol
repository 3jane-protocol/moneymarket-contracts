// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

import {ITimelockController} from "../../src/interfaces/ITimelockController.sol";

/// @notice Shared validation for deployment addresses expected to be the protocol's 7-day timelock.
abstract contract SevenDayTimelockCheck {
    uint256 internal constant SEVEN_DAY_DELAY = 7 days;

    function _requireSevenDayTimelock(address timelock) internal view {
        (bool ok, bytes memory data) = timelock.staticcall(abi.encodeCall(ITimelockController.getMinDelay, ()));
        require(ok && data.length == 32, "SEVEN_DAY_TIMELOCK delay read failed");
        require(abi.decode(data, (uint256)) == SEVEN_DAY_DELAY, "SEVEN_DAY_TIMELOCK delay mismatch");
    }
}
