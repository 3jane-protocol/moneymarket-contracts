// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ICreditLine} from "../interfaces/ICreditLine.sol";

contract CreditLineMock is ICreditLine {
    uint256 public price;

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }
}
