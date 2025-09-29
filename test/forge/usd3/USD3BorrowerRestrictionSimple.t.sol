// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {USD3} from "../../../src/usd3/USD3.sol";
import {Helper} from "../../../src/Helper.sol";
import {IERC20} from "../../../src/interfaces/IERC20.sol";
import {IMorpho, MarketParams, Id} from "../../../src/interfaces/IMorpho.sol";

/**
 * @title USD3BorrowerRestrictionSimpleTest
 * @notice Simplified test to verify borrower restriction works
 */
contract USD3BorrowerRestrictionSimpleTest is Test {
    // Mock morpho that returns borrow shares
    MockMorphoForTest public mockMorpho;

    // Test addresses
    address constant USD3_ADDRESS = 0x66093bAC596dFA1Bd909B7F6025eD893A091Ba95;
    address constant HELPER_ADDRESS = 0xAa48B96C3c2E77C98E5Fff5e8e7C7bcA19d45e03;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address public alice = makeAddr("alice");
    address public borrower = makeAddr("borrower");

    function setUp() public {
        // Fork mainnet
        vm.createSelectFork(vm.envString("RPC_MAINNET"), 21451893);

        // Deploy mock morpho
        mockMorpho = new MockMorphoForTest();

        // Replace morphoCredit in USD3 with our mock
        // This requires accessing the storage slot
        bytes32 morphoSlot = bytes32(uint256(152)); // Slot for morphoCredit in USD3
        vm.store(USD3_ADDRESS, morphoSlot, bytes32(uint256(uint160(address(mockMorpho)))));

        // Fund test users with USDC
        deal(USDC, alice, 10_000_000e6);
        deal(USDC, borrower, 10_000_000e6);

        // Approve USD3 and Helper
        vm.prank(alice);
        IERC20(USDC).approve(USD3_ADDRESS, type(uint256).max);
        vm.prank(alice);
        IERC20(USDC).approve(HELPER_ADDRESS, type(uint256).max);

        vm.prank(borrower);
        IERC20(USDC).approve(USD3_ADDRESS, type(uint256).max);
        vm.prank(borrower);
        IERC20(USDC).approve(HELPER_ADDRESS, type(uint256).max);
    }

    function test_borrowerRestrictionDirect() public {
        // Get market ID from USD3
        USD3 usd3 = USD3(USD3_ADDRESS);
        Id marketId = usd3.marketId();

        // Set borrower to have borrow shares in our mock
        mockMorpho.setBorrowShares(marketId, borrower, 1000e18);

        // Check that availableDepositLimit returns 0 for borrower
        uint256 limit = usd3.availableDepositLimit(borrower);
        assertEq(limit, 0, "Borrower should have 0 deposit limit");

        // Non-borrower should have positive limit
        uint256 aliceLimit = usd3.availableDepositLimit(alice);
        assertGt(aliceLimit, 0, "Non-borrower should have positive limit");

        // Try to deposit as borrower - should fail
        vm.prank(borrower);
        vm.expectRevert();
        usd3.deposit(1000e6, borrower);

        // Alice should be able to deposit
        vm.prank(alice);
        uint256 shares = usd3.deposit(1000e6, alice);
        assertGt(shares, 0, "Alice should receive shares");
    }

    function test_borrowerRestrictionThroughHelper() public {
        // Get market ID from USD3
        USD3 usd3 = USD3(USD3_ADDRESS);
        Id marketId = usd3.marketId();

        // Set borrower to have borrow shares in our mock
        mockMorpho.setBorrowShares(marketId, borrower, 1000e18);

        Helper helper = Helper(HELPER_ADDRESS);

        // Try to deposit through helper as borrower - should fail
        vm.prank(borrower);
        vm.expectRevert("Deposit exceeds limit");
        helper.deposit(1000e6, borrower, false);

        // Alice should be able to deposit through helper
        vm.prank(alice);
        uint256 shares = helper.deposit(1000e6, alice, false);
        assertGt(shares, 0, "Alice should receive shares through helper");
    }
}

// Simple mock for testing
contract MockMorphoForTest {
    mapping(Id => mapping(address => uint256)) public borrowShares;

    function setBorrowShares(Id id, address user, uint256 shares) external {
        borrowShares[id][user] = shares;
    }

    // Mock the position function to return borrow shares
    function position(Id id, address user) external view returns (uint256, uint256, uint256) {
        return (0, borrowShares[id][user], 0); // (supplyShares, borrowShares, collateral)
    }
}
