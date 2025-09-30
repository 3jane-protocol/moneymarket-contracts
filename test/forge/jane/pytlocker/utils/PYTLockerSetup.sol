// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {PYTLocker, IPYieldToken} from "../../../../../src/jane/PYTLocker.sol";
import {MockPYT} from "../mocks/MockPYT.sol";
import {IERC20} from "../../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PYTLockerSetup is Test {
    PYTLocker public locker;

    MockPYT public pyt1;
    MockPYT public pyt2;
    MockPYT public pyt3;
    MockPYT public expiredPyt;

    address public owner;
    address public alice;
    address public bob;
    address public charlie;

    uint256 public futureExpiry1;
    uint256 public futureExpiry2;
    uint256 public futureExpiry3;
    uint256 public pastExpiry;

    uint256 public constant INITIAL_BALANCE = 1000e18;
    uint256 public constant ONE_DAY = 86400;
    uint256 public constant ONE_WEEK = 604800;
    uint256 public constant ONE_MONTH = 2592000;

    // Events
    event TokenAdded(address indexed pytToken, uint256 expiry);
    event Deposited(address indexed user, address indexed pytToken, uint256 amount);
    event Withdrawn(address indexed user, address indexed pytToken, uint256 amount);

    function setUp() public virtual {
        // Set up users
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // Warp to a reasonable timestamp to avoid underflow
        vm.warp(365 days);

        // Set up expiry times
        futureExpiry1 = block.timestamp + ONE_WEEK;
        futureExpiry2 = block.timestamp + ONE_MONTH;
        futureExpiry3 = block.timestamp + ONE_MONTH * 2;
        pastExpiry = block.timestamp - ONE_DAY;

        // Deploy mock PYT tokens
        pyt1 = new MockPYT("PYT Token 1", "PYT1", futureExpiry1);
        pyt2 = new MockPYT("PYT Token 2", "PYT2", futureExpiry2);
        pyt3 = new MockPYT("PYT Token 3", "PYT3", futureExpiry3);
        expiredPyt = new MockPYT("Expired PYT", "EPYT", pastExpiry);

        // Deploy multi-token locker
        locker = new PYTLocker(owner);

        // Mint tokens to test users
        pyt1.mint(alice, INITIAL_BALANCE);
        pyt1.mint(bob, INITIAL_BALANCE);
        pyt1.mint(charlie, INITIAL_BALANCE);

        pyt2.mint(alice, INITIAL_BALANCE);
        pyt2.mint(bob, INITIAL_BALANCE);
        pyt2.mint(charlie, INITIAL_BALANCE);

        pyt3.mint(alice, INITIAL_BALANCE);
        pyt3.mint(bob, INITIAL_BALANCE);
        pyt3.mint(charlie, INITIAL_BALANCE);

        expiredPyt.mint(alice, INITIAL_BALANCE);

        // Set up labels
        vm.label(address(locker), "PYTLocker");
        vm.label(address(pyt1), "PYT1");
        vm.label(address(pyt2), "PYT2");
        vm.label(address(pyt3), "PYT3");
        vm.label(address(expiredPyt), "ExpiredPYT");
        vm.label(owner, "Owner");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");
    }

    /**
     * @notice Helper function to add a supported token as owner
     */
    function addSupportedToken(address pytToken) internal {
        vm.prank(owner);
        locker.addSupportedToken(pytToken);
    }

    /**
     * @notice Helper function to add multiple supported tokens
     */
    function addMultipleTokens() internal {
        vm.startPrank(owner);
        locker.addSupportedToken(address(pyt1));
        locker.addSupportedToken(address(pyt2));
        locker.addSupportedToken(address(pyt3));
        vm.stopPrank();
    }

    /**
     * @notice Helper function to approve tokens for locker
     */
    function approveToken(address user, address pytToken, uint256 amount) internal {
        vm.prank(user);
        IERC20(pytToken).approve(address(locker), amount);
    }

    /**
     * @notice Helper function to deposit tokens
     */
    function deposit(address user, address pytToken, uint256 amount) internal {
        approveToken(user, pytToken, amount);
        vm.prank(user);
        locker.deposit(pytToken, amount);
    }

    /**
     * @notice Helper function to withdraw tokens
     */
    function withdraw(address user, address pytToken, uint256 amount) internal {
        vm.prank(user);
        locker.withdraw(pytToken, amount);
    }

    /**
     * @notice Helper to advance time
     */
    function advanceTime(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
    }

    /**
     * @notice Helper to advance time to token expiry
     */
    function advanceToExpiry(address pytToken) internal {
        uint256 expiry = IPYieldToken(pytToken).expiry();
        vm.warp(expiry + 1);
    }

    /**
     * @notice Helper to check token balance
     */
    function getTokenBalance(address user, address pytToken) internal view returns (uint256) {
        return IERC20(pytToken).balanceOf(user);
    }

    /**
     * @notice Helper to check locked balance
     */
    function getLockedBalance(address user, address pytToken) internal view returns (uint256) {
        return locker.balanceOf(user, pytToken);
    }
}
