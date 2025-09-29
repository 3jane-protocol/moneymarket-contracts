// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IUSD3} from "./utils/Setup.sol";
import {USD3} from "../../../src/usd3/USD3.sol";
import {MockProtocolConfig} from "./mocks/MockProtocolConfig.sol";
import {IMorpho, IMorphoCredit, MarketParams} from "../../../src/interfaces/IMorpho.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {HelperMock} from "../../../src/mocks/HelperMock.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {IHelper} from "../../../src/interfaces/IHelper.sol";
import {Helper} from "../../../src/Helper.sol";
import {MockWaUSDC} from "./mocks/MockWaUSDC.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {MorphoBalancesLib} from "../../../src/libraries/periphery/MorphoBalancesLib.sol";

/**
 * @title USD3BorrowerRestrictionTest
 * @notice Test suite for USD3 borrower restriction functionality
 * @dev Tests that borrowers cannot deposit to USD3 directly or through Helper
 */
contract USD3BorrowerRestrictionTest is Setup {
    using MorphoBalancesLib for IMorpho;

    USD3 public usd3Strategy;
    MockProtocolConfig public protocolConfig;
    IMorpho public morpho;
    MarketParams public marketParams;
    Helper public helperContract;
    address public sUSD3;

    // Test users
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public borrower = makeAddr("borrower");
    address public lender = makeAddr("lender");

    // Constants
    uint256 constant INITIAL_DEPOSIT = 10_000_000e6; // 10M USDC
    uint256 constant BORROW_AMOUNT = 1_000_000e6; // 1M USDC
    uint256 constant TEST_AMOUNT = 100_000e6; // 100K USDC

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        // Get the protocol config and morpho instance
        morpho = IMorpho(address(usd3Strategy.morphoCredit()));
        protocolConfig = MockProtocolConfig(IMorphoCredit(address(morpho)).protocolConfig());
        marketParams = usd3Strategy.marketParams();

        // Deploy sUSD3 mock for testing hop functionality
        sUSD3 = makeAddr("sUSD3");
        vm.mockCall(
            sUSD3, abi.encodeWithSignature("deposit(uint256,address)", TEST_AMOUNT, borrower), abi.encode(TEST_AMOUNT)
        );

        // Deploy Helper contract with correct addresses
        helperContract = new Helper(
            address(morpho),
            address(usd3Strategy),
            sUSD3,
            address(underlyingAsset), // USDC
            address(waUSDC)
        );

        // Fund test users
        _fundUsers();

        // Setup initial market liquidity
        _setupMarketLiquidity();
    }

    function _fundUsers() internal {
        deal(address(underlyingAsset), alice, 10_000_000e6);
        deal(address(underlyingAsset), bob, 10_000_000e6);
        deal(address(underlyingAsset), borrower, 10_000_000e6);
        deal(address(underlyingAsset), lender, 100_000_000e6);

        // Approve USD3 for all users
        vm.prank(alice);
        underlyingAsset.approve(address(usd3Strategy), type(uint256).max);

        vm.prank(bob);
        underlyingAsset.approve(address(usd3Strategy), type(uint256).max);

        vm.prank(borrower);
        underlyingAsset.approve(address(usd3Strategy), type(uint256).max);

        vm.prank(lender);
        underlyingAsset.approve(address(usd3Strategy), type(uint256).max);

        // Also approve Helper for all users
        vm.prank(alice);
        underlyingAsset.approve(address(helperContract), type(uint256).max);

        vm.prank(bob);
        underlyingAsset.approve(address(helperContract), type(uint256).max);

        vm.prank(borrower);
        underlyingAsset.approve(address(helperContract), type(uint256).max);

        vm.prank(lender);
        underlyingAsset.approve(address(helperContract), type(uint256).max);
    }

    function _setupMarketLiquidity() internal {
        // Lender deposits to create liquidity
        vm.prank(lender);
        ITokenizedStrategy(address(usd3Strategy)).deposit(INITIAL_DEPOSIT, lender);
    }

    function _setupBorrowerWithLoan(address _borrower, uint256 _borrowAmount) internal {
        // First need to close a payment cycle to unfreeze the market
        vm.prank(marketParams.creditLine);
        MorphoCredit(address(morpho)).closeCycleAndPostObligations(
            usd3Strategy.marketId(),
            block.timestamp, // End date is current time
            new address[](0), // No borrowers yet
            new uint256[](0), // No repayment bps
            new uint256[](0) // No ending balances
        );

        // First wrap the waUSDC amount needed for the credit line
        uint256 waUSDCAmount = waUSDC.previewDeposit(_borrowAmount);

        // Get the credit line mock from the market params
        CreditLineMock creditLine = CreditLineMock(marketParams.creditLine);

        // Setup credit line by calling setCreditLine on the credit line contract
        // which will then call setCreditLine on morpho
        creditLine.setCreditLine(
            usd3Strategy.marketId(),
            _borrower,
            waUSDCAmount * 2, // Credit limit in waUSDC terms
            0 // Premium rate
        );

        // Execute borrow through helper (which is authorized)
        // helper.borrow expects USDC amount and converts internally
        vm.prank(_borrower);
        helper.borrow(marketParams, _borrowAmount, 0, _borrower, _borrower);

        // Verify borrow was successful
        uint256 borrowShares = morpho.position(usd3Strategy.marketId(), _borrower).borrowShares;
        assertGt(borrowShares, 0, "Borrow should have succeeded");
    }

    /*//////////////////////////////////////////////////////////////
                        DIRECT DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_borrowerCannotDepositDirectly() public {
        // Setup borrower with active loan
        _setupBorrowerWithLoan(borrower, BORROW_AMOUNT);

        // Verify borrower has active loan
        uint256 borrowShares = morpho.position(usd3Strategy.marketId(), borrower).borrowShares;
        assertGt(borrowShares, 0, "Borrower should have active loan");

        // Check availableDepositLimit returns 0 for borrower
        uint256 depositLimit = usd3Strategy.availableDepositLimit(borrower);
        assertEq(depositLimit, 0, "Deposit limit should be 0 for borrower");

        // Try to deposit - should fail
        vm.prank(borrower);
        vm.expectRevert();
        ITokenizedStrategy(address(usd3Strategy)).deposit(TEST_AMOUNT, borrower);
    }

    function test_nonBorrowerCanDepositNormally() public {
        // Alice has no loans
        uint256 borrowShares = morpho.position(usd3Strategy.marketId(), alice).borrowShares;
        assertEq(borrowShares, 0, "Alice should have no loans");

        // Check deposit limit is non-zero
        uint256 depositLimit = usd3Strategy.availableDepositLimit(alice);
        assertGt(depositLimit, 0, "Deposit limit should be positive for non-borrower");

        // Deposit should succeed
        vm.prank(alice);
        uint256 shares = ITokenizedStrategy(address(usd3Strategy)).deposit(TEST_AMOUNT, alice);
        assertGt(shares, 0, "Should receive shares");

        // Verify deposit succeeded
        uint256 balance = ITokenizedStrategy(address(usd3Strategy)).balanceOf(alice);
        assertEq(balance, shares, "Should have received shares");
    }

    /*//////////////////////////////////////////////////////////////
                        HELPER DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_borrowerCannotUseHelperWithHopFalse() public {
        // Setup borrower with active loan
        _setupBorrowerWithLoan(borrower, BORROW_AMOUNT);

        // Try to deposit through Helper without hop - should fail
        vm.prank(borrower);
        vm.expectRevert("Deposit exceeds limit");
        helperContract.deposit(TEST_AMOUNT, borrower, false);
    }

    function test_borrowerCannotUseHelperWithHopTrue() public {
        // Setup borrower with active loan
        _setupBorrowerWithLoan(borrower, BORROW_AMOUNT);

        // Whitelist borrower for USD3 (required for hop)
        vm.prank(management);
        usd3Strategy.setWhitelist(borrower, true);

        // Try to deposit through Helper with hop - should fail
        vm.prank(borrower);
        vm.expectRevert("Deposit exceeds limit");
        helperContract.deposit(TEST_AMOUNT, borrower, true);
    }

    function test_nonBorrowerCanUseHelperNormally() public {
        // Alice has no loans
        uint256 borrowShares = morpho.position(usd3Strategy.marketId(), alice).borrowShares;
        assertEq(borrowShares, 0, "Alice should have no loans");

        // Deposit through Helper without hop should succeed
        vm.prank(alice);
        uint256 shares = helperContract.deposit(TEST_AMOUNT, alice, false);
        assertGt(shares, 0, "Should receive shares");
    }

    /*//////////////////////////////////////////////////////////////
                        REPAYMENT AND RE-DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_exBorrowerCanDepositAfterFullRepayment() public {
        // Setup borrower with active loan
        _setupBorrowerWithLoan(borrower, BORROW_AMOUNT);

        // Verify cannot deposit while having loan
        uint256 depositLimit = usd3Strategy.availableDepositLimit(borrower);
        assertEq(depositLimit, 0, "Should not be able to deposit with active loan");

        // Repay the full loan (pass shares as second parameter)
        uint256 borrowShares = morpho.position(usd3Strategy.marketId(), borrower).borrowShares;

        // Get required waUSDC for repayment and deal it to borrower
        uint256 repayAmount = morpho.expectedBorrowAssets(marketParams, borrower);
        deal(address(waUSDC), borrower, repayAmount);
        vm.prank(borrower);
        waUSDC.approve(address(morpho), repayAmount);

        // Repay directly through morpho
        vm.prank(borrower);
        morpho.repay(marketParams, 0, borrowShares, borrower, "");

        // Verify loan is fully repaid
        uint256 remainingBorrowShares = morpho.position(usd3Strategy.marketId(), borrower).borrowShares;
        assertEq(remainingBorrowShares, 0, "Loan should be fully repaid");

        // Now should be able to deposit
        depositLimit = usd3Strategy.availableDepositLimit(borrower);
        assertGt(depositLimit, 0, "Should be able to deposit after repayment");

        // Deposit should succeed
        vm.prank(borrower);
        uint256 shares = ITokenizedStrategy(address(usd3Strategy)).deposit(TEST_AMOUNT, borrower);
        assertGt(shares, 0, "Should receive shares after repayment");
    }

    function test_partialRepaymentStillBlocksDeposit() public {
        // Setup borrower with active loan
        _setupBorrowerWithLoan(borrower, BORROW_AMOUNT);

        // Repay only half the loan
        uint256 borrowShares = morpho.position(usd3Strategy.marketId(), borrower).borrowShares;
        uint256 halfShares = borrowShares / 2;

        // Get required waUSDC for half repayment and deal it to borrower
        uint256 halfRepayAmount = morpho.expectedBorrowAssets(marketParams, borrower) / 2;
        deal(address(waUSDC), borrower, halfRepayAmount);
        vm.prank(borrower);
        waUSDC.approve(address(morpho), halfRepayAmount);

        // Repay directly through morpho
        vm.prank(borrower);
        morpho.repay(marketParams, 0, halfShares, borrower, "");

        // Verify still has outstanding loan
        uint256 remainingBorrowShares = morpho.position(usd3Strategy.marketId(), borrower).borrowShares;
        assertGt(remainingBorrowShares, 0, "Should still have outstanding loan");

        // Should still not be able to deposit
        uint256 depositLimit = usd3Strategy.availableDepositLimit(borrower);
        assertEq(depositLimit, 0, "Should not be able to deposit with partial loan");

        // Deposit should fail
        vm.prank(borrower);
        vm.expectRevert();
        ITokenizedStrategy(address(usd3Strategy)).deposit(TEST_AMOUNT, borrower);

        // Helper deposit should also fail
        vm.prank(borrower);
        vm.expectRevert("Deposit exceeds limit");
        helperContract.deposit(TEST_AMOUNT, borrower, false);
    }

    /*//////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_depositThenBorrowIsAllowed() public {
        // Alice deposits first
        vm.prank(alice);
        uint256 shares = ITokenizedStrategy(address(usd3Strategy)).deposit(TEST_AMOUNT, alice);
        assertGt(shares, 0, "Should receive shares");

        // Then Alice borrows - this should be allowed
        _setupBorrowerWithLoan(alice, BORROW_AMOUNT);

        // Verify Alice now has both deposit and loan
        uint256 balance = ITokenizedStrategy(address(usd3Strategy)).balanceOf(alice);
        assertEq(balance, shares, "Should still have deposit shares");

        uint256 borrowShares = morpho.position(usd3Strategy.marketId(), alice).borrowShares;
        assertGt(borrowShares, 0, "Should have active loan");

        // But Alice cannot deposit more while having the loan
        uint256 depositLimit = usd3Strategy.availableDepositLimit(alice);
        assertEq(depositLimit, 0, "Should not be able to deposit more with active loan");
    }

    function test_multipleUsersWithDifferentStates() public {
        // Setup: Alice is a lender, Bob is a borrower, Charlie is neither
        address charlie = makeAddr("charlie");
        deal(address(underlyingAsset), charlie, 10_000_000e6);
        vm.prank(charlie);
        underlyingAsset.approve(address(usd3Strategy), type(uint256).max);

        // Alice deposits (lender)
        vm.prank(alice);
        ITokenizedStrategy(address(usd3Strategy)).deposit(TEST_AMOUNT, alice);

        // Bob borrows
        _setupBorrowerWithLoan(bob, BORROW_AMOUNT);

        // Check deposit limits for each
        uint256 aliceLimit = usd3Strategy.availableDepositLimit(alice);
        uint256 bobLimit = usd3Strategy.availableDepositLimit(bob);
        uint256 charlieLimit = usd3Strategy.availableDepositLimit(charlie);

        assertGt(aliceLimit, 0, "Alice (lender) should be able to deposit more");
        assertEq(bobLimit, 0, "Bob (borrower) should not be able to deposit");
        assertGt(charlieLimit, 0, "Charlie (neither) should be able to deposit");

        // Verify actual deposits
        vm.prank(alice);
        uint256 aliceShares2 = ITokenizedStrategy(address(usd3Strategy)).deposit(50_000e6, alice);
        assertGt(aliceShares2, 0, "Alice should be able to deposit more");

        vm.prank(bob);
        vm.expectRevert();
        ITokenizedStrategy(address(usd3Strategy)).deposit(50_000e6, bob);

        vm.prank(charlie);
        uint256 charlieShares = ITokenizedStrategy(address(usd3Strategy)).deposit(50_000e6, charlie);
        assertGt(charlieShares, 0, "Charlie should be able to deposit");
    }
}
