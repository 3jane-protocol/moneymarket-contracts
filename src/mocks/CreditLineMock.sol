// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Id} from "../interfaces/IMorpho.sol";
import {IMorphoCredit} from "../interfaces/IMorpho.sol";

contract CreditLineMock {
    address public owner;
    address public morpho;
    address public mm;

    mapping(address account => uint256) public creditLines;
    mapping(Id => mapping(address => uint128)) public borrowerRates;

    constructor(address _morpho) {
        morpho = _morpho;
        owner = msg.sender;
    }

    function setCreditLine(Id id, address borrower, uint256 credit, uint128 premiumRate) external {
        creditLines[borrower] = credit;
        borrowerRates[id][borrower] = premiumRate;

        // Call MorphoCredit to set the actual credit line and premium rate
        IMorphoCredit(morpho).setCreditLine(id, borrower, credit, premiumRate);
    }

    function setMm(address newMm) external {
        require(msg.sender == owner, "NOT_OWNER");
        mm = newMm;
    }

    function setOwner(address newOwner) external {
        require(msg.sender == owner, "NOT_OWNER");
        owner = newOwner;
    }
}
