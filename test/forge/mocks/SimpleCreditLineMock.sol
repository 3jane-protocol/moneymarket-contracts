// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

contract SimpleCreditLineMock {
    address public mm;

    constructor() {
        mm = address(0);
    }

    function setMm(address _mm) external {
        mm = _mm;
    }
}
