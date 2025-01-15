// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {MarketParams} from "../interfaces/IMorpho.sol";

contract CreditLineMock {
    address public owner;
    address public morpho;

    mapping(address account => uint256) public creditLines;

    function setCreditLine(MarketParams memory marketParams, address borrower, uint256 credit) external {
        creditLines[borrower] = credit;
    }

    function setOwner(address newOwner) external {}
}
