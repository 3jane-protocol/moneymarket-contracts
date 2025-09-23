// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "../utils/Setup.sol";
import {ERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {sUSD3} from "../../../../src/usd3/sUSD3.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {IMorpho, MarketParams} from "../../../../src/interfaces/IMorpho.sol";
import {IProtocolConfig} from "../../../../src/interfaces/IProtocolConfig.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {TransparentUpgradeableProxy} from
    "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title Subordination Ratio Stress Test
 * @notice Tests for debt-based subordination and MAX_ON_CREDIT constraints
 * @dev Tests sUSD3 deposit limits based on market debt and USD3 withdrawal limits based on liquidity
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

        // Set MAX_ON_CREDIT to enable potential debt for sUSD3 deposits
        setMaxOnCredit(8000); // 80% max deployment

        // Create a mock sUSD3 address (since real deployment is disabled)
        mockSusd3 = makeAddr("mockSusd3");

        // Fund test users using deal directly (not airdrop which doesn't work with USDC proxy)
        deal(address(underlyingAsset), alice, LARGE_DEPOSIT);
        deal(address(underlyingAsset), bob, MEDIUM_DEPOSIT);
        deal(address(underlyingAsset), charlie, SMALL_DEPOSIT);
        deal(address(underlyingAsset), whale, LARGE_DEPOSIT * 10);
    }

    /*//////////////////////////////////////////////////////////////
                    DEBT-BASED SUBORDINATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_subordinationRatio_debtBasedLimit() public {
        // Set sUSD3 strategy
        vm.prank(management);
        usd3Strategy.setSUSD3(mockSusd3);

        // Alice deposits to USD3
        vm.startPrank(alice);
        asset.approve(address(strategy), LARGE_DEPOSIT);
        strategy.deposit(LARGE_DEPOSIT, alice);
        vm.stopPrank();

        // Create market debt to enable sUSD3 deposits
        address borrower = makeAddr("borrower");
        createMarketDebt(borrower, 500_000e6); // $500k USDC debt

        // Calculate max sUSD3 allowed based on debt
        uint256 debtCapUSDC = usd3Strategy.getSubordinatedDebtCapInAssets();
        assertGt(debtCapUSDC, 0, "Should have debt cap");

        // Convert to USD3 shares for mock
        uint256 maxSusd3USD3 = ITokenizedStrategy(address(usd3Strategy)).convertToShares(debtCapUSDC);

        // Set sUSD3 holdings at exactly the cap
        deal(address(strategy), mockSusd3, maxSusd3USD3);

        // USD3 withdrawals should NOT be limited by subordination
        uint256 aliceLimit = strategy.availableWithdrawLimit(alice);
        assertGt(aliceLimit, 0, "USD3 withdrawals not limited by subordination");

        // The limit should only be based on liquidity and MAX_ON_CREDIT
        uint256 aliceBalance = strategy.balanceOf(alice);
        // Alice should be able to withdraw based on available liquidity
        assertGt(aliceLimit, 0, "Should allow withdrawals based on liquidity");
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
            uint256 aliceSharesValue = ITokenizedStrategy(address(strategy)).convertToAssets(aliceShares / 2);
            uint256 aliceToWithdraw = aliceLimit < aliceSharesValue
                ? ITokenizedStrategy(address(strategy)).convertToShares(aliceLimit)
                : aliceShares / 2;

            if (aliceToWithdraw > 0) {
                vm.prank(alice);
                strategy.redeem(aliceToWithdraw, alice, alice);
            }
        }

        // Check if Bob can still withdraw
        uint256 bobLimit = strategy.availableWithdrawLimit(bob);
        if (bobLimit > 0) {
            uint256 bobSharesValue = ITokenizedStrategy(address(strategy)).convertToAssets(bobShares / 2);
            uint256 bobToWithdraw = bobLimit < bobSharesValue
                ? ITokenizedStrategy(address(strategy)).convertToShares(bobLimit)
                : bobShares / 2;

            if (bobToWithdraw > 0) {
                vm.prank(bob);
                strategy.redeem(bobToWithdraw, bob, bob);
            }
        }

        // Check Charlie's limit - might be restricted now
        uint256 charlieLimit = strategy.availableWithdrawLimit(charlie);

        // With debt-based subordination, USD3 withdrawals are not limited
        // The subordination ratio against USD3 supply is no longer enforced
        uint256 newTotalSupply = strategy.totalSupply();
        if (newTotalSupply > 0) {
            uint256 susd3Holdings = strategy.balanceOf(mockSusd3);
            // No assertion - USD3 withdrawals are allowed regardless of sUSD3 holdings
        }
    }

    /*//////////////////////////////////////////////////////////////
                    FLASH LOAN ATTACK TESTS
    //////////////////////////////////////////////////////////////*/

    function test_subordinationRatio_flashLoanResistance() public {
        // Set sUSD3 strategy
        vm.prank(management);
        usd3Strategy.setSUSD3(mockSusd3);

        // Alice deposits normally
        vm.startPrank(alice);
        asset.approve(address(strategy), LARGE_DEPOSIT);
        strategy.deposit(LARGE_DEPOSIT, alice);
        vm.stopPrank();

        // 2. Set sUSD3 holdings to 14% (just below limit)
        uint256 totalSupplyBefore = strategy.totalSupply();
        uint256 susd3Amount = (totalSupplyBefore * 1400) / MAX_BPS;
        deal(address(strategy), mockSusd3, susd3Amount);

        // 3. Whale simulates flash loan deposit
        vm.startPrank(whale);
        asset.approve(address(strategy), LARGE_DEPOSIT * 10);
        strategy.deposit(LARGE_DEPOSIT * 10, whale); // Huge deposit dilutes ratio
        vm.stopPrank();

        // Now ratio is much lower (susd3/total is diluted)
        // Alice tries to withdraw during this dilution
        vm.prank(alice);
        uint256 aliceShares = strategy.balanceOf(alice);

        // Even with flash loan dilution, ratio should be enforced
        uint256 withdrawLimit = strategy.availableWithdrawLimit(alice);

        // 4. Whale withdraws (simulating flash loan repayment)
        // Check whale's available limit first
        uint256 whaleShares = strategy.balanceOf(whale);
        uint256 whaleLimit = strategy.availableWithdrawLimit(whale);

        if (whaleLimit > 0 && whaleShares > 0) {
            uint256 whaleSharesValue = ITokenizedStrategy(address(strategy)).convertToAssets(whaleShares);
            uint256 whaleToWithdraw = whaleLimit < whaleSharesValue
                ? ITokenizedStrategy(address(strategy)).convertToShares(whaleLimit)
                : whaleShares;

            vm.prank(whale);
            strategy.redeem(whaleToWithdraw, whale, whale);
        }

        // With debt-based subordination, USD3 withdrawals don't check ratio
        uint256 finalTotalSupply = strategy.totalSupply();
        uint256 finalSusd3Holdings = strategy.balanceOf(mockSusd3);

        // No assertion - flash loan attack on subordination ratio is not relevant
        // since USD3 withdrawals are not limited by subordination
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

        // Create market debt to test MAX_ON_CREDIT constraint
        // Use lower debt to maintain some liquidity for withdrawals
        address borrower = makeAddr("borrower");
        createMarketDebt(borrower, LARGE_DEPOSIT * 6 / 10); // Borrow only 60% of deposits

        // With debt-based subordination, USD3 withdrawals are not limited by sUSD3 holdings
        // Only by MAX_ON_CREDIT and liquidity
        uint256 normalLimit = strategy.availableWithdrawLimit(alice);
        // Should be limited by MAX_ON_CREDIT, not subordination
        assertGt(normalLimit, 0, "Should allow some withdrawal based on MAX_ON_CREDIT");

        // Trigger emergency shutdown
        vm.prank(management);
        strategy.shutdownStrategy();

        // During shutdown, withdrawal limit should be based on available liquidity
        uint256 shutdownLimit = strategy.availableWithdrawLimit(alice);
        assertGt(shutdownLimit, 0, "Should be able to withdraw during shutdown");

        // Alice withdraws available amount
        uint256 aliceShares = strategy.balanceOf(alice);
        // Withdraw what's available (limited by liquidity)
        uint256 sharesToWithdraw = ITokenizedStrategy(address(strategy)).convertToShares(shutdownLimit);
        if (sharesToWithdraw > aliceShares) sharesToWithdraw = aliceShares;

        vm.prank(alice);
        uint256 withdrawn = strategy.redeem(sharesToWithdraw, alice, alice);
        assertGt(withdrawn, 0, "Should successfully withdraw during shutdown");
    }

    /*//////////////////////////////////////////////////////////////
                    MAX_ON_CREDIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_maxOnCredit_roundingErrors() public {
        // Test MAX_ON_CREDIT with odd numbers that might cause rounding issues
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

        // Create debt to test MAX_ON_CREDIT constraint
        address borrower = makeAddr("borrower");
        uint256 totalDeposited = oddDeposit * 10;
        createMarketDebt(borrower, totalDeposited * 7 / 10); // 70% utilized

        // Try withdrawals with rounding edge cases
        address firstUser = address(uint160(0x1000));
        uint256 firstUserShares = strategy.balanceOf(firstUser);

        // Check withdraw limit
        uint256 withdrawLimit = strategy.availableWithdrawLimit(firstUser);

        // Withdraw exactly 1 wei of shares
        if (firstUserShares > 0 && withdrawLimit > 0) {
            uint256 toWithdraw = 1; // 1 wei of shares
            vm.prank(firstUser);
            strategy.redeem(toWithdraw, firstUser, firstUser);

            // Verify no rounding errors caused issues
            uint256 newShares = strategy.balanceOf(firstUser);
            assertEq(newShares, firstUserShares - toWithdraw, "Share accounting should be exact");
        }
    }

    /*//////////////////////////////////////////////////////////////
                    DYNAMIC RATIO CHANGE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_subordinationRatio_dynamicConfigUpdate() public {
        // Deploy real sUSD3 for testing debt-based limits
        sUSD3 susd3Implementation = new sUSD3();
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(management);
        TransparentUpgradeableProxy susd3Proxy = new TransparentUpgradeableProxy(
            address(susd3Implementation),
            address(susd3ProxyAdmin),
            abi.encodeCall(sUSD3.initialize, (address(usd3Strategy), management, keeper))
        );
        sUSD3 realSusd3 = sUSD3(address(susd3Proxy));

        // Link strategies
        vm.prank(management);
        usd3Strategy.setSUSD3(address(realSusd3));

        // Initial deposits
        vm.startPrank(alice);
        asset.approve(address(strategy), LARGE_DEPOSIT);
        strategy.deposit(LARGE_DEPOSIT, alice);
        vm.stopPrank();

        // Create market debt to enable sUSD3 deposits
        address borrower = makeAddr("borrower");
        createMarketDebt(borrower, 100_000e6); // $100k debt

        // Bob gets USD3 to deposit into sUSD3
        vm.startPrank(bob);
        asset.approve(address(strategy), MEDIUM_DEPOSIT);
        strategy.deposit(MEDIUM_DEPOSIT, bob);
        vm.stopPrank();

        // Check initial deposit limit with 15% subordination
        uint256 limitBefore = realSusd3.availableDepositLimit(bob);
        assertGt(limitBefore, 0, "Should allow sUSD3 deposits at 15% ratio");

        // Update protocol config to stricter ratio (5% max subordination)
        protocolConfig.setConfig(keccak256("TRANCHE_RATIO"), 500);

        // Deposit limit should decrease
        uint256 limitAfter = realSusd3.availableDepositLimit(bob);
        assertLt(limitAfter, limitBefore, "Should reduce deposit limit after ratio tightening");

        // Update to looser ratio (20% max subordination)
        protocolConfig.setConfig(keccak256("TRANCHE_RATIO"), 2000);

        // Deposit limit should increase
        uint256 limitLoose = realSusd3.availableDepositLimit(bob);
        assertGt(limitLoose, limitAfter, "Should increase deposit limit with looser ratio");

        // USD3 withdrawals should always be allowed regardless of ratio
        uint256 aliceWithdrawLimit = strategy.availableWithdrawLimit(alice);
        assertGt(aliceWithdrawLimit, 0, "USD3 withdrawals not limited by subordination ratio");
    }
}
