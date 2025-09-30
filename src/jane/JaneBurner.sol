// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Jane} from "./Jane.sol";

contract JaneBurner {
    error NotOwner();
    error Unauthorized();

    event AuthorizationUpdated(address indexed account, bool status);

    Jane public immutable JANE;

    mapping(address => bool) public authorized;

    constructor(address jane) {
        JANE = Jane(jane);
    }

    function owner() public view returns (address) {
        return JANE.owner();
    }

    modifier isOwner() {
        _checkOwner();
        _;
    }

    function _checkOwner() internal view {
        if (msg.sender != owner()) revert NotOwner();
    }

    function setAuthorized(address account, bool status) external isOwner {
        authorized[account] = status;
        emit AuthorizationUpdated(account, status);
    }

    function burn(address to, uint256 amount) public {
        if (msg.sender != owner() && !authorized[msg.sender]) {
            revert Unauthorized();
        }
        JANE.burn(to, amount);
    }
}
