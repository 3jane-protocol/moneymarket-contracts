// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "../utils/Setup.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {USD3} from "../../USD3.sol";
import {sUSD3} from "../../sUSD3.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {IMorpho, MarketParams} from "@3jane-morpho-blue/interfaces/IMorpho.sol";
import {IProtocolConfig} from "@3jane-morpho-blue/interfaces/IProtocolConfig.sol";
import {MorphoCredit} from "@3jane-morpho-blue/MorphoCredit.sol";

/**
 * @title Subordination Ratio Stress Test
 * @notice Tests for the 85/15 USD3/sUSD3 subordination ratio enforcement
 * @dev Critical tests for withdrawal restrictions and ratio boundary conditions
 */
contract SubordinationRatioStressTest is Setup {
    USD3 public usd3Strategy;
    address public mockSusd3;
    MockProtocolConfig public protocolConfig;

    // Test users
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public whale = makeAddr("whale");

    // Test amounts
    uint256 public constant LARGE_DEPOSIT = 1_000_000e6; // 1M USDC
    uint256 public constant MEDIUM_DEPOSIT = 100_000e6; // 100K USDC
    uint256 public constant SMALL_DEPOSIT = 10_000e6; // 10K USDC

    // Ratio constants
    uint256 public constant DEFAULT_SUB_RATIO = 1500; // 15%
    uint256 public constant MIN_USD3_RATIO = 8500; // 85%

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        // Get protocol config
        address morphoAddress = address(usd3Strategy.morphoCredit());
        protocolConfig = MockProtocolConfig(MorphoCredit(morphoAddress).protocolConfig());

        // Set default subordination ratio
        protocolConfig.setConfig(keccak256("TRANCHE_RATIO"), DEFAULT_SUB_RATIO);

        // Create a mock sUSD3 address (since real deployment is disabled)
        mockSusd3 = makeAddr("mockSusd3");

        // Fund test users using deal directly (not airdrop which doesn't work with USDC proxy)
        deal(address(underlyingAsset), alice, LARGE_DEPOSIT);
        deal(address(underlyingAsset), bob, MEDIUM_DEPOSIT);
        deal(address(underlyingAsset), charlie, SMALL_DEPOSIT);
        deal(address(underlyingAsset), whale, LARGE_DEPOSIT * 10);
    }

    /*//////////////////////////////////////////////////////////////
                    EXACT BOUNDARY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_subordinationRatio_exactBoundary() public {
        // Set sUSD3 strategy
        vm.prank(management);
        usd3Strategy.setSUSD3(mockSusd3);

        // Alice deposits to USD3
        vm.startPrank(alice);
        asset.approve(address(strategy), LARGE_DEPOSIT);
        strategy.deposit(LARGE_DEPOSIT, alice);
        vm.stopPrank();

        // Calculate exact amount for 15% subordination
        uint256 totalSupply = strategy.totalSupply();
        uint256 susd3Amount = (totalSupply * DEFAULT_SUB_RATIO) / MAX_BPS;

        // Mint sUSD3 holdings (simulate sUSD3 holding USD3)
        deal(address(strategy), mockSusd3, susd3Amount);

        // Alice should be at exact boundary - withdrawals restricted
        uint256 aliceLimit = strategy.availableWithdrawLimit(alice);
        assertEq(aliceLimit, 0, "At exact 85/15 boundary, no withdrawals allowed");

        // Small additional USD3 deposit should allow some withdrawal
        vm.startPrank(bob);
        asset.approve(address(strategy), 1000e6);
        strategy.deposit(1000e6, bob);
        vm.stopPrank();

        // Now Alice should be able to withdraw something
        uint256 newLimit = strategy.availableWithdrawLimit(alice);
        assertGt(newLimit, 0, "After additional USD3, some withdrawal allowed");
    }

    function test_subordinationRatio_multipleWithdrawals() public {
        // Set sUSD3 strategy
        vm.prank(management);
        usd3Strategy.setSUSD3(mockSusd3);

        // Multiple users deposit
        vm.startPrank(alice);
        asset.approve(address(strategy), LARGE_DEPOSIT);
        strategy.deposit(LARGE_DEPOSIT, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(strategy), MEDIUM_DEPOSIT);
        strategy.deposit(MEDIUM_DEPOSIT, bob);
        vm.stopPrank();

        vm.startPrank(charlie);
        asset.approve(address(strategy), SMALL_DEPOSIT);
        strategy.deposit(SMALL_DEPOSIT, charlie);
        vm.stopPrank();

        // Set sUSD3 holdings to 10% (within limit)
        uint256 totalSupply = strategy.totalSupply();
        uint256 susd3Amount = (totalSupply * 1000) / MAX_BPS; // 10%
        deal(address(strategy), mockSusd3, susd3Amount);

        // All users try to withdraw simultaneously
        uint256 aliceShares = strategy.balanceOf(alice);
        uint256 bobShares = strategy.balanceOf(bob);
        uint256 charlieShares = strategy.balanceOf(charlie);

        // Alice withdraws first - check available limit
        uint256 aliceLimit = strategy.availableWithdrawLimit(alice);
        if (aliceLimit > 0) {
            uint256 aliceSharesValue = strategy.convertToAssets(aliceShares / 2);
            uint256 aliceToWithdraw =
                aliceLimit < aliceSharesValue ? strategy.convertToShares(aliceLimit) : aliceShares / 2;

            if (aliceToWithdraw > 0) {
                vm.prank(alice);
                strategy.redeem(aliceToWithdraw, alice, alice);
            }
        }

        // Check if Bob can still withdraw
        uint256 bobLimit = strategy.availableWithdrawLimit(bob);
        if (bobLimit > 0) {
            uint256 bobSharesValue = strategy.convertToAssets(bobShares / 2);
            uint256 bobToWithdraw = bobLimit < bobSharesValue ? strategy.convertToShares(bobLimit) : bobShares / 2;

            if (bobToWithdraw > 0) {
                vm.prank(bob);
                strategy.redeem(bobToWithdraw, bob, bob);
            }
        }

        // Check Charlie's limit - might be restricted now
        uint256 charlieLimit = strategy.availableWithdrawLimit(charlie);

        // Verify ratio is still maintained
        uint256 newTotalSupply = strategy.totalSupply();
        if (newTotalSupply > 0) {
            uint256 susd3Holdings = strategy.balanceOf(mockSusd3);
            uint256 currentSubRatio = (susd3Holdings * MAX_BPS) / newTotalSupply;
            assertLe(currentSubRatio, DEFAULT_SUB_RATIO, "Subordination ratio should not exceed limit");
        }
    }

    /*//////////////////////////////////////////////////////////////
                    FLASH LOAN ATTACK TESTS
    //////////////////////////////////////////////////////////////*/

    function test_subordinationRatio_flashLoanResistance() public {
        // Set sUSD3 strategy
        vm.prank(management);
        usd3Strategy.setSUSD3(mockSusd3);

        // Setup initial state
        vm.startPrank(alice);
        asset.approve(address(strategy), LARGE_DEPOSIT);
        strategy.deposit(LARGE_DEPOSIT, alice);
        vm.stopPrank();

        // Set sUSD3 holdings near limit (14%)
        uint256 totalSupply = strategy.totalSupply();
        uint256 susd3Amount = (totalSupply * 1400) / MAX_BPS;
        deal(address(strategy), mockSusd3, susd3Amount);

        // Attacker tries flash loan attack
        // 1. Flash loan large amount of USDC
        uint256 flashLoanAmount = LARGE_DEPOSIT * 5;
        deal(address(underlyingAsset), whale, underlyingAsset.balanceOf(whale) + flashLoanAmount);

        // 2. Deposit to manipulate ratio
        vm.startPrank(whale);
        asset.approve(address(strategy), flashLoanAmount);
        strategy.deposit(flashLoanAmount, whale);

        // 3. Try to force Alice's withdrawal
        // This shouldn't allow Alice to break the ratio
        vm.stopPrank();
        vm.prank(alice);
        uint256 aliceShares = strategy.balanceOf(alice);

        // Even with flash loan dilution, ratio should be enforced
        uint256 withdrawLimit = strategy.availableWithdrawLimit(alice);

        // 4. Whale withdraws (simulating flash loan repayment)
        // Check whale's available limit first
        uint256 whaleShares = strategy.balanceOf(whale);
        uint256 whaleLimit = strategy.availableWithdrawLimit(whale);

        if (whaleLimit > 0 && whaleShares > 0) {
            uint256 whaleSharesValue = strategy.convertToAssets(whaleShares);
            uint256 whaleToWithdraw = whaleLimit < whaleSharesValue ? strategy.convertToShares(whaleLimit) : whaleShares;

            vm.prank(whale);
            strategy.redeem(whaleToWithdraw, whale, whale);
        }

        // Verify ratio wasn't broken during attack
        uint256 finalTotalSupply = strategy.totalSupply();
        uint256 finalSusd3Holdings = strategy.balanceOf(mockSusd3);

        if (finalTotalSupply > 0) {
            uint256 finalSubRatio = (finalSusd3Holdings * MAX_BPS) / finalTotalSupply;
            assertLe(finalSubRatio, DEFAULT_SUB_RATIO, "Ratio should be maintained after attack");
        }
    }

    /*//////////////////////////////////////////////////////////////
                    EMERGENCY SHUTDOWN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_subordinationRatio_emergencyShutdownBypass() public {
        // Set sUSD3 strategy
        vm.prank(management);
        usd3Strategy.setSUSD3(mockSusd3);

        // Setup positions
        vm.startPrank(alice);
        asset.approve(address(strategy), LARGE_DEPOSIT);
        strategy.deposit(LARGE_DEPOSIT, alice);
        vm.stopPrank();

        // Set sUSD3 at exact limit (15%)
        uint256 totalSupply = strategy.totalSupply();
        uint256 susd3Amount = (totalSupply * DEFAULT_SUB_RATIO) / MAX_BPS;
        deal(address(strategy), mockSusd3, susd3Amount);

        // Normally Alice can't withdraw
        uint256 normalLimit = strategy.availableWithdrawLimit(alice);
        assertEq(normalLimit, 0, "Should be restricted before shutdown");

        // Trigger emergency shutdown
        vm.prank(management);
        strategy.shutdownStrategy();

        // Now Alice should be able to withdraw everything
        uint256 shutdownLimit = strategy.availableWithdrawLimit(alice);
        assertGt(shutdownLimit, 0, "Should be able to withdraw during shutdown");

        // Alice withdraws - no approval needed for redeem since alice owns the shares
        uint256 aliceShares = strategy.balanceOf(alice);
        vm.prank(alice);
        uint256 withdrawn = strategy.redeem(aliceShares, alice, alice);
        assertGt(withdrawn, 0, "Should successfully withdraw during shutdown");
    }

    /*//////////////////////////////////////////////////////////////
                    ROUNDING ERROR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_subordinationRatio_roundingErrors() public {
        // Set sUSD3 strategy
        vm.prank(management);
        usd3Strategy.setSUSD3(mockSusd3);

        // Test with odd numbers that might cause rounding issues
        uint256 oddDeposit = 1234567; // Small odd number (1.23 USDC)

        // Multiple small deposits
        for (uint256 i = 0; i < 10; i++) {
            address user = address(uint160(0x1000 + i));
            deal(address(underlyingAsset), user, oddDeposit);

            vm.startPrank(user);
            asset.approve(address(strategy), oddDeposit);
            strategy.deposit(oddDeposit, user);
            vm.stopPrank();
        }

        // Set sUSD3 holdings with potential rounding
        uint256 totalSupply = strategy.totalSupply();
        uint256 susd3Amount = (totalSupply * 1499) / MAX_BPS; // Just under 15%
        deal(address(strategy), mockSusd3, susd3Amount);

        // Try withdrawals with rounding edge cases
        address firstUser = address(uint160(0x1000));
        uint256 firstUserShares = strategy.balanceOf(firstUser);

        // Withdraw 1 wei worth of shares
        if (firstUserShares > 1) {
            vm.prank(firstUser);
            strategy.redeem(1, firstUser, firstUser);

            // Verify ratio still maintained
            uint256 newTotalSupply = strategy.totalSupply();
            uint256 susd3Holdings = strategy.balanceOf(mockSusd3);

            if (newTotalSupply > 0) {
                uint256 currentRatio = (susd3Holdings * MAX_BPS) / newTotalSupply;
                assertLe(currentRatio, DEFAULT_SUB_RATIO + 1, "Ratio maintained with rounding tolerance");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                    DYNAMIC RATIO CHANGE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_subordinationRatio_dynamicConfigUpdate() public {
        // Set sUSD3 strategy
        vm.prank(management);
        usd3Strategy.setSUSD3(mockSusd3);

        // Initial deposits
        vm.startPrank(alice);
        asset.approve(address(strategy), LARGE_DEPOSIT);
        strategy.deposit(LARGE_DEPOSIT, alice);
        vm.stopPrank();

        // Set sUSD3 at 10%
        uint256 totalSupply = strategy.totalSupply();
        uint256 susd3Amount = (totalSupply * 1000) / MAX_BPS;
        deal(address(strategy), mockSusd3, susd3Amount);

        // Alice can withdraw with 10% subordination
        uint256 limitBefore = strategy.availableWithdrawLimit(alice);
        assertGt(limitBefore, 0, "Should allow withdrawal at 10%");

        // Update protocol config to stricter ratio (5% max subordination)
        protocolConfig.setConfig(keccak256("TRANCHE_RATIO"), 500);

        // Now Alice should be restricted (10% > 5%)
        uint256 limitAfter = strategy.availableWithdrawLimit(alice);
        assertEq(limitAfter, 0, "Should restrict withdrawal after ratio tightening");

        // Update to looser ratio (20% max subordination)
        protocolConfig.setConfig(keccak256("TRANCHE_RATIO"), 2000);

        // Alice can withdraw again
        uint256 limitLoose = strategy.availableWithdrawLimit(alice);
        assertGt(limitLoose, 0, "Should allow withdrawal with looser ratio");
    }

    /*//////////////////////////////////////////////////////////////
                    HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _calculateMaxWithdrawable(uint256 totalSupply, uint256 susd3Holdings, uint256 maxSubRatio)
        internal
        view
        returns (uint256)
    {
        if (totalSupply == 0) return 0;

        uint256 minUSD3Ratio = MAX_BPS - maxSubRatio;
        uint256 usd3Circulating = totalSupply - susd3Holdings;
        uint256 minUSD3Required = (totalSupply * minUSD3Ratio) / MAX_BPS;

        if (usd3Circulating <= minUSD3Required) {
            return 0;
        }
        return usd3Circulating - minUSD3Required;
    }
}
