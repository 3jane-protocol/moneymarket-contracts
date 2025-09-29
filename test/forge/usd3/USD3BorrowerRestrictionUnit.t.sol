// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Helper} from "../../../src/Helper.sol";

/**
 * @title USD3BorrowerRestrictionUnitTest
 * @notice Unit test to verify the Helper check works
 */
contract USD3BorrowerRestrictionUnitTest is Test {
    // Mock contracts
    MockUSD3 public mockUSD3;
    MockERC20 public mockUSDC;
    MockERC20 public mockSUSD3;
    MockERC20 public mockWaUSDC;
    address public mockMorpho;

    Helper public helper;

    address public alice = makeAddr("alice");
    address public borrower = makeAddr("borrower");

    function setUp() public {
        // Create mock address first to avoid zero addresses
        mockMorpho = makeAddr("morpho");

        // Deploy mocks
        mockUSD3 = new MockUSD3();
        mockUSDC = new MockERC20();
        mockSUSD3 = new MockERC20();
        mockWaUSDC = new MockERC20();

        // Deploy helper with mock addresses
        helper = new Helper(mockMorpho, address(mockUSD3), address(mockSUSD3), address(mockUSDC), address(mockWaUSDC));

        // Fund test users
        mockUSDC.mint(alice, 10_000_000e6);
        mockUSDC.mint(borrower, 10_000_000e6);

        // Approve helper
        vm.prank(alice);
        mockUSDC.approve(address(helper), type(uint256).max);

        vm.prank(borrower);
        mockUSDC.approve(address(helper), type(uint256).max);
    }

    function test_helperBlocksBorrower() public {
        // Set borrower's deposit limit to 0 (simulating they have a loan)
        mockUSD3.setAvailableDepositLimit(borrower, 0);

        // Set alice's deposit limit to max
        mockUSD3.setAvailableDepositLimit(alice, type(uint256).max);

        // Borrower should fail to deposit (USD3 will reject it)
        vm.prank(borrower);
        vm.expectRevert("ERC4626 deposit exceeds max");
        helper.deposit(1000e6, borrower, false);

        // Alice should succeed
        vm.prank(alice);
        uint256 shares = helper.deposit(1000e6, alice, false);
        assertEq(shares, 1000e6, "Alice should receive shares");
    }

    function test_helperBlocksBorrowerWithHop() public {
        // Set borrower's deposit limit to 0
        mockUSD3.setAvailableDepositLimit(borrower, 0);

        // Set alice's deposit limit to max
        mockUSD3.setAvailableDepositLimit(alice, type(uint256).max);

        // Set helper's limit to max (since it's the one depositing to USD3 in hop)
        mockUSD3.setAvailableDepositLimit(address(helper), type(uint256).max);

        // Whitelist both for hop test
        mockUSD3.setWhitelist(alice, true);
        mockUSD3.setWhitelist(borrower, true);

        // Borrower as receiver should fail to deposit with hop
        vm.prank(alice); // Alice sends funds but borrower is receiver
        vm.expectRevert("Deposit exceeds limit");
        helper.deposit(1000e6, borrower, true);

        // Alice as receiver should succeed with hop
        vm.prank(alice);
        uint256 shares = helper.deposit(1000e6, alice, true);
        assertEq(shares, 1000e6, "Alice should receive shares through hop");
    }

    function test_helperRespectsExactAmount() public {
        // Set borrower's deposit limit to 500e6 (partial)
        mockUSD3.setAvailableDepositLimit(borrower, 500e6);

        // Should fail when trying to deposit more than limit (USD3 will reject it)
        vm.prank(borrower);
        vm.expectRevert("ERC4626 deposit exceeds max");
        helper.deposit(1000e6, borrower, false);

        // Should succeed when depositing within limit
        vm.prank(borrower);
        uint256 shares = helper.deposit(500e6, borrower, false);
        assertEq(shares, 500e6, "Should deposit within limit");
    }
}

// Mock USD3 contract
contract MockUSD3 {
    mapping(address => uint256) public availableDepositLimit;
    mapping(address => bool) public whitelist;
    mapping(address => mapping(address => uint256)) public allowance;

    function setAvailableDepositLimit(address user, uint256 limit) external {
        availableDepositLimit[user] = limit;
    }

    function setWhitelist(address user, bool status) external {
        whitelist[user] = status;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        // Mock the USD3 deposit behavior - check receiver's limit
        require(this.availableDepositLimit(receiver) >= assets, "ERC4626 deposit exceeds max");
        // Mock deposit - just return the assets as shares
        return assets;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// Simple mock ERC20
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        require(balanceOf[from] >= amount, "Insufficient balance");

        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;

        return true;
    }

    // Mock for sUSD3 deposit
    function deposit(uint256, address) external returns (uint256) {
        return 1000e6; // Just return a fixed amount
    }
}
