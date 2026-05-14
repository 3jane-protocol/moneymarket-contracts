// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "../../lib/openzeppelin/contracts/access/Ownable.sol";
import {PYTLocker} from "./PYTLocker.sol";

/// @title PYTLockerFactory
/// @author 3Jane
/// @notice Deploys and records one PYTLocker per Pendle YT
contract PYTLockerFactory is Ownable {
    /// @notice YT => deployed locker
    mapping(address => address) public locker;

    /// @notice Lockers deployed by this factory
    address[] public lockers;

    event LockerCreated(address indexed yt, address indexed locker, address sy, address asset, address owner);

    error LockerExists();
    error ZeroAddress();

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Deploy a new locker for a YT
    /// @param yt The Pendle YT to bind to the new locker
    /// @return locker_ The deployed locker address
    function createLocker(address yt) external onlyOwner returns (address locker_) {
        if (yt == address(0)) revert ZeroAddress();
        if (locker[yt] != address(0)) revert LockerExists();

        PYTLocker created = new PYTLocker(owner(), yt);
        locker_ = address(created);

        locker[yt] = locker_;
        lockers.push(locker_);

        emit LockerCreated(yt, locker_, created.sy(), created.asset(), owner());
    }

    /// @notice Number of lockers deployed by this factory
    function numLockers() external view returns (uint256) {
        return lockers.length;
    }

    /// @notice All lockers deployed by this factory
    function allLockers() external view returns (address[] memory) {
        return lockers;
    }
}
