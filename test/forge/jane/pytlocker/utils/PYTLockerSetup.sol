// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {PYTLocker, PYTLockerFactory} from "../../../../../src/jane/PYTLocker.sol";
import {MockPYT} from "../mocks/MockPYT.sol";
import {IERC20Metadata} from "../../../../../lib/openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract PYTLockerSetup is Test {
    PYTLockerFactory public factory;
    MockPYT public pyt1;
    MockPYT public pyt2;
    MockPYT public pyt3;

    address public alice;
    address public bob;
    address public charlie;
    address public dave;

    uint256 public constant INITIAL_BALANCE = 10_000e18;
    uint256 public constant DAY = 86400;
    uint256 public constant WEEK = 7 * DAY;
    uint256 public constant MONTH = 30 * DAY;
    uint256 public constant YEAR = 365 * DAY;

    // Events from PYTLocker
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // Events from PYTLockerFactory
    event LockerCreated(address indexed pytoken, address indexed locker);

    function setUp() public virtual {
        // Setup users
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        dave = makeAddr("dave");

        // Label addresses for better test output
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");
        vm.label(dave, "Dave");

        // Deploy factory
        factory = new PYTLockerFactory();
        vm.label(address(factory), "PYTLockerFactory");

        // Deploy mock PYT tokens with different expiries
        pyt1 = deployPYT("PYT-30D", "PYT30", 30 * DAY);
        pyt2 = deployPYT("PYT-90D", "PYT90", 90 * DAY);
        pyt3 = deployPYT("PYT-365D", "PYT365", 365 * DAY);

        // Fund test users with PYT tokens
        fundUsers();
    }

    /// @notice Deploys a new MockPYT token with specified expiry
    function deployPYT(string memory name, string memory symbol, uint256 expiryFromNow) internal returns (MockPYT) {
        MockPYT pyt = new MockPYT(name, symbol, block.timestamp + expiryFromNow);
        vm.label(address(pyt), name);
        return pyt;
    }

    /// @notice Deploys a PYTLocker for the given PYT token
    function deployLocker(MockPYT pyt) internal returns (PYTLocker) {
        address lockerAddr = factory.newPYTLocker(address(pyt));
        return PYTLocker(lockerAddr);
    }

    /// @notice Funds test users with PYT tokens
    function fundUsers() internal {
        address[4] memory users = [alice, bob, charlie, dave];
        MockPYT[3] memory pyts = [pyt1, pyt2, pyt3];

        for (uint256 i = 0; i < users.length; i++) {
            for (uint256 j = 0; j < pyts.length; j++) {
                pyts[j].mint(users[i], INITIAL_BALANCE);
            }
        }
    }

    /// @notice Helper to deposit PYT tokens into a locker
    function depositFor(PYTLocker locker, address user, uint256 amount) internal {
        MockPYT pyt = MockPYT(address(locker.underlying()));

        vm.startPrank(user);
        pyt.approve(address(locker), amount);
        locker.depositFor(user, amount);
        vm.stopPrank();
    }

    /// @notice Helper to withdraw PYT tokens from a locker
    function withdrawTo(PYTLocker locker, address user, uint256 amount) internal {
        vm.prank(user);
        locker.withdrawTo(user, amount);
    }

    /// @notice Helper to advance time
    function advanceTime(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
    }

    /// @notice Helper to advance time to exact timestamp
    function warpTo(uint256 timestamp) internal {
        vm.warp(timestamp);
    }

    /// @notice Helper to get current timestamp
    function currentTime() internal view returns (uint256) {
        return block.timestamp;
    }

    /// @notice Creates an expired PYT token for testing
    function createExpiredPYT() internal returns (MockPYT) {
        MockPYT expiredPYT = new MockPYT("Expired-PYT", "EPYT", block.timestamp - 1);
        vm.label(address(expiredPYT), "ExpiredPYT");
        return expiredPYT;
    }

    /// @notice Creates a PYT token expiring at exact current timestamp
    function createExpiringNowPYT() internal returns (MockPYT) {
        MockPYT nowPYT = new MockPYT("Now-PYT", "NPYT", block.timestamp);
        vm.label(address(nowPYT), "NowPYT");
        return nowPYT;
    }
}
