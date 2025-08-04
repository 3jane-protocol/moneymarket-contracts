// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {InsuranceFund} from "../../../src/InsuranceFund.sol";
import {IInsuranceFund} from "../../../src/interfaces/IInsuranceFund.sol";
import {IERC20} from "../../../src/interfaces/IERC20.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";

// Mock ERC20 token for testing
contract MockERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address _owner) {
        // Give initial balance to the deployer
        balanceOf[_owner] = 1000000e18;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    // Required IERC20 functions (stubs)
    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function name() external pure returns (string memory) {
        return "Mock Token";
    }

    function symbol() external pure returns (string memory) {
        return "MOCK";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract InsuranceFundTest is Test {
    InsuranceFund internal insuranceFund;
    MockERC20 internal mockToken;

    address internal owner;
    address internal nonCreditLine;
    address internal creditLine;

    function setUp() public {
        owner = makeAddr("Owner");
        nonCreditLine = makeAddr("NonCreditLine");
        creditLine = makeAddr("CreditLine");

        // Deploy mock token
        mockToken = new MockERC20(owner);

        // Deploy insurance fund
        insuranceFund = new InsuranceFund(creditLine);

        // Give some tokens to the insurance fund
        vm.prank(owner);
        mockToken.transfer(address(insuranceFund), 10000e18);
    }

    // Constructor tests
    function test_Constructor_ValidAddress() public {
        InsuranceFund newInsuranceFund = new InsuranceFund(creditLine);
        assertEq(newInsuranceFund.CREDIT_LINE(), creditLine);
    }

    function test_Constructor_ZeroAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new InsuranceFund(address(0));
    }

    // CREDIT_LINE getter test
    function test_CreditLine_Getter() public {
        assertEq(insuranceFund.CREDIT_LINE(), creditLine);
    }

    // bring function tests
    function test_Bring_Success() public {
        uint256 amount = 1000e18;
        uint256 initialBalance = mockToken.balanceOf(address(insuranceFund));
        uint256 initialCreditLineBalance = mockToken.balanceOf(creditLine);

        vm.prank(creditLine);
        insuranceFund.bring(address(mockToken), amount);

        assertEq(mockToken.balanceOf(address(insuranceFund)), initialBalance - amount);
        assertEq(mockToken.balanceOf(creditLine), initialCreditLineBalance + amount);
    }

    function test_Bring_NotCreditLine() public {
        vm.prank(nonCreditLine);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        insuranceFund.bring(address(mockToken), 1000e18);
    }
}
