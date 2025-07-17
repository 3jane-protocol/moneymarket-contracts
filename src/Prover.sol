// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IProver} from "./interfaces/IProver.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";

/// @title Prover
/// @author Morpho Labs
/// @custom:contact security@morpho.org
contract Prover is IProver {
    /// @inheritdoc IProver
    address public owner;

    /// @inheritdoc IProver
    mapping(address => uint256) public tvv;

    /* CONSTRUCTOR */

    constructor(address newOwner) {
        require(newOwner != address(0), ErrorsLib.ZERO_ADDRESS);
        owner = newOwner;
        emit EventsLib.SetOwner(newOwner);
    }

    /// @dev Reverts if the caller is not the owner.
    modifier onlyOwner() {
        require(msg.sender == owner, ErrorsLib.NOT_OWNER);
        _;
    }

    /// @inheritdoc IProver
    function isSafeTVV(address borrower, uint256 credit) external view returns (bool) {
        return credit < tvv[borrower];
    }

    /* ONLY OWNER FUNCTIONS */

    /// @inheritdoc IProver
    function setTVV(address borrower, uint256 newTvv) external onlyOwner {
        tvv[borrower] = newTvv;
    }
}
