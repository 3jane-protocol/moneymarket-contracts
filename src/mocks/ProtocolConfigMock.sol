// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

contract ProtocolConfigMock {
    address public owner;
    uint256 public isPaused;

    constructor() {
        owner = msg.sender;
        isPaused = 0;
    }

    function getIsPaused() external view returns (uint256) {
        return isPaused;
    }

    function setPaused(uint256 _paused) external {
        isPaused = _paused;
    }

    function setOwner(address newOwner) external {
        owner = newOwner;
    }
}
