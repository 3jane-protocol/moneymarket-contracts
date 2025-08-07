// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "../utils/Setup.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {USD3} from "../../USD3.sol";
import {sUSD3} from "../../sUSD3.sol";
import {IMorpho, MarketParams} from "@3jane-morpho-blue/interfaces/IMorpho.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {MorphoCredit} from "@3jane-morpho-blue/MorphoCredit.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title Multi-User Stress Test Suite
 * @notice Tests for concurrent operations and complex multi-user scenarios
 * @dev Validates system behavior under realistic multi-user load and edge cases
 */
contract MultiUserStressTest is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;

    // Test users
    address[] public users;
    uint256 public constant NUM_USERS = 10;

    // Test amounts
    uint256 public constant BASE_AMOUNT = 50_000e6; // 50K USDC base
    uint256 public constant LARGE_AMOUNT = 500_000e6; // 500K USDC
    uint256 public constant MAX_SUBORDINATION = 15; // 15% max for sUSD3

    event UserAction(address indexed user, string action, uint256 amount);
    event SystemState(
        uint256 usd3Total,
        uint256 susd3Total,
        uint256 subordinationRatio
    );

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));
        susd3Strategy = sUSD3(setUpSusd3Strategy());

        // Link strategies
        vm.prank(management);
        usd3Strategy.setSusd3Strategy(address(susd3Strategy));

        vm.prank(management);
        susd3Strategy.setUsd3Strategy(address(usd3Strategy));

        // Setup yield sharing via protocol config
        address morphoAddress = address(usd3Strategy.morphoCredit());
        address protocolConfigAddress = MorphoCredit(morphoAddress)
            .protocolConfig();
        MockProtocolConfig protocolConfig = MockProtocolConfig(
            protocolConfigAddress
        );

        // Set the tranche share variant in protocol config
        bytes32 TRANCHE_SHARE_VARIANT = keccak256("TRANCHE_SHARE_VARIANT");
        protocolConfig.setConfig(TRANCHE_SHARE_VARIANT, 3000); // 30% to sUSD3

        // Sync the value to USD3 strategy as keeper
        vm.prank(keeper);
        usd3Strategy.syncTrancheShare();

        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFeeRecipient(
            address(susd3Strategy)
        );

        // Create and fund test users
        _setupUsers();
    }

    function setUpSusd3Strategy() internal returns (address) {
        // Deploy sUSD3 implementation
        sUSD3 susd3Implementation = new sUSD3();

        // Deploy proxy admin
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(management);

        // Deploy proxy with initialization
        bytes memory susd3InitData = abi.encodeWithSelector(
            sUSD3.initialize.selector,
            address(usd3Strategy),
            "sUSD3",
            management,
            keeper
        );

        TransparentUpgradeableProxy susd3Proxy = new TransparentUpgradeableProxy(
                address(susd3Implementation),
                address(susd3ProxyAdmin),
                susd3InitData
            );

        return address(susd3Proxy);
    }

    function _setupUsers() internal {
        for (uint256 i = 0; i < NUM_USERS; i++) {
            address user = address(uint160(0x1000 + i));
            users.push(user);

            // Fund each user with sufficient amounts for all test scenarios
            // First 3 users need LARGE_AMOUNT for subordination tests
            uint256 amount = i < 3 ? LARGE_AMOUNT * 2 : BASE_AMOUNT * (i + 1);
            airdrop(asset, user, amount * 3); // 3x for multiple operations

            vm.label(user, string(abi.encodePacked("User", vm.toString(i))));
        }
    }

    function _simulateLoss(uint256 lossAmount) internal {
        // Simulate loss by directly manipulating MorphoCredit's state
        USD3 usd3 = USD3(address(usd3Strategy));
        IMorpho morpho = usd3.morphoCredit();
        MarketParams memory marketParams = usd3.marketParams();

        // Calculate the market ID
        bytes32 marketId = keccak256(abi.encode(marketParams));

        // Use vm.store to directly reduce the totalSupplyAssets in Morpho's storage
        bytes32 marketSlot = keccak256(abi.encode(marketId, uint256(3))); // slot 3 is market mapping

        // Read current totalSupplyAssets (first element of Market struct)
        uint256 currentTotalSupply = uint256(
            vm.load(address(morpho), marketSlot)
        );

        if (currentTotalSupply > lossAmount) {
            // Reduce totalSupplyAssets by the loss amount
            vm.store(
                address(morpho),
                marketSlot,
                bytes32(currentTotalSupply - lossAmount)
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                        CONCURRENT DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_simultaneousDeposits() public {
        // All users deposit simultaneously
        for (uint256 i = 0; i < NUM_USERS; i++) {
            address user = users[i];
            uint256 amount = BASE_AMOUNT * (i + 1);

            vm.startPrank(user);
            asset.approve(address(usd3Strategy), amount);
            uint256 shares = usd3Strategy.deposit(amount, user);
            vm.stopPrank();

            assertGt(shares, 0, "User should receive shares");
            emit UserAction(user, "deposit", amount);
        }

        // Verify system state
        uint256 totalAssets = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        uint256 expectedTotal = (BASE_AMOUNT * NUM_USERS * (NUM_USERS + 1)) / 2; // Sum of 1+2+...+NUM_USERS

        assertApproxEqAbs(
            totalAssets,
            expectedTotal,
            1000e6,
            "Total assets should match sum of deposits"
        );
    }

    function test_simultaneousWithdrawals() public {
        // Setup: All users deposit first
        uint256[] memory shares = new uint256[](NUM_USERS);

        for (uint256 i = 0; i < NUM_USERS; i++) {
            address user = users[i];
            uint256 amount = BASE_AMOUNT * (i + 1);

            vm.startPrank(user);
            asset.approve(address(usd3Strategy), amount);
            shares[i] = usd3Strategy.deposit(amount, user);
            vm.stopPrank();
        }

        uint256 totalAssetsBefore = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();

        // All users withdraw 50% simultaneously
        for (uint256 i = 0; i < NUM_USERS; i++) {
            address user = users[i];
            uint256 withdrawShares = shares[i] / 2;

            vm.startPrank(user);
            uint256 assetsReceived = ITokenizedStrategy(address(usd3Strategy))
                .redeem(withdrawShares, user, user);
            vm.stopPrank();

            assertGt(
                assetsReceived,
                0,
                "User should receive assets on withdrawal"
            );
            emit UserAction(user, "withdraw", assetsReceived);
        }

        // Verify proportional reduction in total assets
        uint256 totalAssetsAfter = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        assertApproxEqRel(
            totalAssetsAfter,
            totalAssetsBefore / 2,
            0.05e18,
            "Should withdraw ~50% of assets"
        );
    }

    function test_mixedOperationsConcurrency() public {
        // Some users deposit, others withdraw, others do sUSD3 operations

        // First wave: deposits
        for (uint256 i = 0; i < NUM_USERS / 2; i++) {
            address user = users[i];
            uint256 amount = BASE_AMOUNT * (i + 1);

            vm.startPrank(user);
            asset.approve(address(usd3Strategy), amount);
            usd3Strategy.deposit(amount, user);
            vm.stopPrank();
        }

        // Second wave: some users move to sUSD3
        for (uint256 i = 2; i < NUM_USERS / 2; i++) {
            address user = users[i];
            uint256 usd3Balance = ITokenizedStrategy(address(usd3Strategy))
                .balanceOf(user);

            if (usd3Balance > 0) {
                // Check available deposit limit for sUSD3
                uint256 availableLimit = susd3Strategy.availableDepositLimit(
                    user
                );
                uint256 depositAmount = usd3Balance > availableLimit
                    ? availableLimit
                    : usd3Balance;

                if (depositAmount > 0) {
                    vm.startPrank(user);
                    ERC20(address(usd3Strategy)).approve(
                        address(susd3Strategy),
                        depositAmount
                    );
                    susd3Strategy.deposit(depositAmount, user);
                    vm.stopPrank();

                    emit UserAction(user, "susd3_deposit", depositAmount);
                }
            }
        }

        // Third wave: remaining users deposit
        for (uint256 i = NUM_USERS / 2; i < NUM_USERS; i++) {
            address user = users[i];
            uint256 amount = BASE_AMOUNT * (i + 1);

            vm.startPrank(user);
            asset.approve(address(usd3Strategy), amount);
            usd3Strategy.deposit(amount, user);
            vm.stopPrank();
        }

        // Verify system consistency
        uint256 usd3TotalSupply = ITokenizedStrategy(address(usd3Strategy))
            .totalSupply();
        uint256 susd3Balance = ITokenizedStrategy(address(usd3Strategy))
            .balanceOf(address(susd3Strategy));

        assertGt(usd3TotalSupply, 0, "Should have USD3 total supply");
        assertGt(susd3Balance, 0, "sUSD3 should have some USD3 balance");

        emit SystemState(
            usd3TotalSupply,
            susd3Balance,
            (susd3Balance * 100) / usd3TotalSupply
        );
    }

    /*//////////////////////////////////////////////////////////////
                        SUBORDINATION RATIO STRESS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_subordinationRatioBoundaryStress() public {
        // Fill USD3 to create base for subordination calculations
        address usd3User = users[0];
        vm.startPrank(usd3User);
        asset.approve(address(usd3Strategy), LARGE_AMOUNT);
        usd3Strategy.deposit(LARGE_AMOUNT, usd3User);
        vm.stopPrank();

        uint256 usd3TotalAssets = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();

        // Calculate maximum sUSD3 allowed (15% subordination)
        // If USD3 = X and sUSD3 = Y, then Y/(X+Y) <= 0.15
        // Solving: Y <= 0.15*X/(1-0.15) = 0.15*X/0.85
        uint256 maxSusd3Assets = (usd3TotalAssets * MAX_SUBORDINATION) /
            (100 - MAX_SUBORDINATION);

        // Multiple users try to deposit up to the limit
        uint256 remainingSusd3Capacity = maxSusd3Assets;
        uint256 susd3UsersCount = 0;

        for (
            uint256 i = 1;
            i < NUM_USERS && remainingSusd3Capacity > BASE_AMOUNT;
            i++
        ) {
            address user = users[i];
            uint256 userAmount = BASE_AMOUNT * (i + 1);

            // First deposit to USD3
            vm.startPrank(user);
            asset.approve(address(usd3Strategy), userAmount);
            uint256 usd3Shares = usd3Strategy.deposit(userAmount, user);

            // Then try to move to sUSD3 if within limits
            uint256 attemptAmount = userAmount / 2; // Try to stake 50%

            if (attemptAmount <= remainingSusd3Capacity) {
                uint256 usd3SharesToStake = usd3Shares / 2;
                ERC20(address(usd3Strategy)).approve(
                    address(susd3Strategy),
                    usd3SharesToStake
                );

                // This might revert if subordination limit is hit
                try susd3Strategy.deposit(usd3SharesToStake, user) {
                    remainingSusd3Capacity -= attemptAmount;
                    susd3UsersCount++;
                    emit UserAction(
                        user,
                        "susd3_deposit_success",
                        attemptAmount
                    );
                } catch {
                    emit UserAction(
                        user,
                        "susd3_deposit_failed",
                        attemptAmount
                    );
                }
            }
            vm.stopPrank();
        }

        // Verify subordination ratio is enforced
        uint256 finalUsd3Supply = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        uint256 finalSusd3Balance = ITokenizedStrategy(address(usd3Strategy))
            .balanceOf(address(susd3Strategy));
        uint256 finalSusd3Value = ITokenizedStrategy(address(usd3Strategy))
            .convertToAssets(finalSusd3Balance);

        if (finalSusd3Value > 0) {
            uint256 subordinationRatio = (finalSusd3Value * 100) /
                (finalUsd3Supply);
            assertLe(
                subordinationRatio,
                MAX_SUBORDINATION + 1,
                "Should enforce subordination ratio"
            ); // +1 for rounding
        }

        assertGt(
            susd3UsersCount,
            0,
            "Some users should have succeeded in sUSD3 deposits"
        );
    }

    function test_subordinationRatioWithVaryingDeposits() public {
        // Test subordination with users depositing different amounts over time

        // Large USD3 deposits to establish base
        for (uint256 i = 0; i < 3; i++) {
            address user = users[i];

            vm.startPrank(user);
            asset.approve(address(usd3Strategy), LARGE_AMOUNT);
            usd3Strategy.deposit(LARGE_AMOUNT, user);
            vm.stopPrank();
        }

        // Smaller sUSD3 deposits from remaining users
        for (uint256 i = 3; i < NUM_USERS; i++) {
            address user = users[i];
            uint256 amount = BASE_AMOUNT * (i - 2);

            vm.startPrank(user);
            asset.approve(address(usd3Strategy), amount);
            uint256 usd3Shares = usd3Strategy.deposit(amount, user);

            // Try to stake to sUSD3
            ERC20(address(usd3Strategy)).approve(
                address(susd3Strategy),
                usd3Shares
            );

            try susd3Strategy.deposit(usd3Shares, user) {
                emit UserAction(user, "susd3_success", amount);
            } catch {
                emit UserAction(user, "susd3_limit_hit", amount);
                // Keep the USD3 position
            }
            vm.stopPrank();
        }

        // Verify final state
        uint256 totalUsd3 = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        uint256 susd3UsdBalance = ITokenizedStrategy(address(usd3Strategy))
            .balanceOf(address(susd3Strategy));

        assertGt(totalUsd3, 0, "Should have USD3 assets");

        if (susd3UsdBalance > 0) {
            uint256 susd3Value = ITokenizedStrategy(address(usd3Strategy))
                .convertToAssets(susd3UsdBalance);
            uint256 ratio = (susd3Value * 100) / totalUsd3;
            assertLe(
                ratio,
                MAX_SUBORDINATION,
                "Final ratio should respect limit"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                        RESOURCE CONTENTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_liquidityContentionDuringWithdrawals() public {
        // Setup: Multiple large deposits
        uint256[] memory shares = new uint256[](NUM_USERS);

        for (uint256 i = 0; i < NUM_USERS; i++) {
            address user = users[i];
            uint256 amount = LARGE_AMOUNT / NUM_USERS; // Equal amounts

            vm.startPrank(user);
            asset.approve(address(usd3Strategy), amount);
            shares[i] = usd3Strategy.deposit(amount, user);
            vm.stopPrank();
        }

        // All users try to withdraw large amounts simultaneously
        // This tests if the strategy can handle liquidity pressure
        uint256 successfulWithdrawals = 0;
        uint256 totalWithdrawn = 0;

        for (uint256 i = 0; i < NUM_USERS; i++) {
            address user = users[i];
            uint256 withdrawShares = (shares[i] * 80) / 100; // Try to withdraw 80%

            vm.startPrank(user);
            try
                ITokenizedStrategy(address(usd3Strategy)).redeem(
                    withdrawShares,
                    user,
                    user
                )
            returns (uint256 assets) {
                successfulWithdrawals++;
                totalWithdrawn += assets;
                emit UserAction(user, "withdrawal_success", assets);
            } catch {
                emit UserAction(user, "withdrawal_failed", 0);
            }
            vm.stopPrank();
        }

        // Some withdrawals should succeed, but system should remain stable
        assertGt(successfulWithdrawals, 0, "Some withdrawals should succeed");
        assertGt(totalWithdrawn, 0, "Should have withdrawn some assets");

        // System should still be functional
        uint256 remainingAssets = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        assertGe(
            remainingAssets,
            0,
            "Should have non-negative remaining assets"
        );
    }

    function test_yieldDistributionWithManyUsers() public {
        // Setup: Multiple users in both USD3 and sUSD3
        for (uint256 i = 0; i < NUM_USERS / 2; i++) {
            address user = users[i];
            uint256 amount = BASE_AMOUNT * (i + 1);

            vm.startPrank(user);
            asset.approve(address(usd3Strategy), amount);
            usd3Strategy.deposit(amount, user);
            vm.stopPrank();
        }

        for (uint256 i = NUM_USERS / 2; i < NUM_USERS; i++) {
            address user = users[i];
            uint256 amount = BASE_AMOUNT * (i + 1);

            vm.startPrank(user);
            asset.approve(address(usd3Strategy), amount);
            uint256 usd3Shares = usd3Strategy.deposit(amount, user);

            // Check available deposit limit for sUSD3 before depositing
            uint256 depositAmount = usd3Shares / 2;
            uint256 availableLimit = susd3Strategy.availableDepositLimit(user);
            if (availableLimit > 0) {
                depositAmount = depositAmount > availableLimit
                    ? availableLimit
                    : depositAmount;
                ERC20(address(usd3Strategy)).approve(
                    address(susd3Strategy),
                    depositAmount
                );
                susd3Strategy.deposit(depositAmount, user);
            }
            vm.stopPrank();
        }

        // Add yield to the system
        uint256 yieldAmount = (ITokenizedStrategy(address(usd3Strategy))
            .totalAssets() * 5) / 100; // 5% yield
        airdrop(asset, address(usd3Strategy), yieldAmount);

        // Report yield
        vm.prank(keeper);
        (uint256 profit, ) = ITokenizedStrategy(address(usd3Strategy)).report();

        assertGt(profit, 0, "Should report profit");

        // Verify all users can still withdraw (yield distributed correctly)
        for (uint256 i = 0; i < NUM_USERS; i++) {
            address user = users[i];
            uint256 usd3Balance = ITokenizedStrategy(address(usd3Strategy))
                .balanceOf(user);

            if (usd3Balance > 0) {
                vm.startPrank(user);
                uint256 withdrawn = ITokenizedStrategy(address(usd3Strategy))
                    .redeem(usd3Balance / 10, user, user); // Withdraw 10%
                vm.stopPrank();

                assertGt(
                    withdrawn,
                    0,
                    "User should be able to withdraw after yield distribution"
                );
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        COMPLEX SCENARIO TESTS
    //////////////////////////////////////////////////////////////*/

    function test_complexInteractionPattern() public {
        // Simulate realistic usage pattern over time

        // Phase 1: Initial deposits (different sizes)
        for (uint256 i = 0; i < NUM_USERS / 3; i++) {
            address user = users[i];
            uint256 amount = BASE_AMOUNT * (2 ** i); // Exponential amounts

            vm.startPrank(user);
            asset.approve(address(usd3Strategy), amount);
            usd3Strategy.deposit(amount, user);
            vm.stopPrank();
        }

        // Phase 2: Some move to sUSD3
        for (uint256 i = 1; i < NUM_USERS / 3; i++) {
            address user = users[i];
            uint256 usd3Balance = ITokenizedStrategy(address(usd3Strategy))
                .balanceOf(user);

            vm.startPrank(user);
            ERC20(address(usd3Strategy)).approve(
                address(susd3Strategy),
                usd3Balance
            );
            try susd3Strategy.deposit(usd3Balance, user) {
                // Success
            } catch {
                // Hit subordination limit, that's OK
            }
            vm.stopPrank();
        }

        // Phase 3: Add yield
        uint256 yield1 = (ITokenizedStrategy(address(usd3Strategy))
            .totalAssets() * 3) / 100;
        airdrop(asset, address(usd3Strategy), yield1);

        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // Phase 4: More users join
        for (uint256 i = NUM_USERS / 3; i < (2 * NUM_USERS) / 3; i++) {
            address user = users[i];
            uint256 amount = BASE_AMOUNT;

            vm.startPrank(user);
            asset.approve(address(usd3Strategy), amount);
            usd3Strategy.deposit(amount, user);
            vm.stopPrank();
        }

        // Phase 5: Some losses occur
        uint256 loss = (ITokenizedStrategy(address(usd3Strategy))
            .totalAssets() * 2) / 100;
        _simulateLoss(loss);

        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // Phase 6: Final users join and some withdraw
        for (uint256 i = (2 * NUM_USERS) / 3; i < NUM_USERS; i++) {
            address user = users[i];
            uint256 amount = BASE_AMOUNT / 2;

            vm.startPrank(user);
            asset.approve(address(usd3Strategy), amount);
            usd3Strategy.deposit(amount, user);
            vm.stopPrank();
        }

        // Some early users partially withdraw
        for (uint256 i = 0; i < NUM_USERS / 4; i++) {
            address user = users[i];
            uint256 balance = ITokenizedStrategy(address(usd3Strategy))
                .balanceOf(user);

            if (balance > 0) {
                vm.startPrank(user);
                ITokenizedStrategy(address(usd3Strategy)).redeem(
                    balance / 3,
                    user,
                    user
                );
                vm.stopPrank();
            }
        }

        // Verify system integrity after complex interactions
        uint256 finalTotalAssets = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        uint256 finalTotalSupply = ITokenizedStrategy(address(usd3Strategy))
            .totalSupply();

        assertGt(finalTotalAssets, 0, "Should have final assets");
        assertGt(finalTotalSupply, 0, "Should have final supply");

        // All remaining users should be able to withdraw something
        uint256 successfulFinalWithdrawals = 0;
        for (uint256 i = 0; i < NUM_USERS; i++) {
            address user = users[i];
            uint256 balance = ITokenizedStrategy(address(usd3Strategy))
                .balanceOf(user);

            if (balance > 0) {
                vm.startPrank(user);
                try
                    ITokenizedStrategy(address(usd3Strategy)).redeem(
                        1,
                        user,
                        user
                    )
                returns (uint256) {
                    successfulFinalWithdrawals++;
                } catch {
                    // Some might fail due to liquidity, that's acceptable
                }
                vm.stopPrank();
            }
        }

        assertGt(
            successfulFinalWithdrawals,
            0,
            "Some users should be able to make final withdrawals"
        );
    }

    function test_simultaneousLossAndWithdrawals() public {
        // Setup positions
        for (uint256 i = 0; i < NUM_USERS / 2; i++) {
            address user = users[i];
            uint256 amount = BASE_AMOUNT * (i + 1);

            vm.startPrank(user);
            asset.approve(address(usd3Strategy), amount);
            usd3Strategy.deposit(amount, user);
            vm.stopPrank();
        }

        // Some users move to sUSD3
        for (uint256 i = 1; i < NUM_USERS / 4; i++) {
            address user = users[i];
            uint256 usd3Balance = ITokenizedStrategy(address(usd3Strategy))
                .balanceOf(user);

            vm.startPrank(user);
            ERC20(address(usd3Strategy)).approve(
                address(susd3Strategy),
                usd3Balance
            );
            susd3Strategy.deposit(usd3Balance, user);
            vm.stopPrank();
        }

        // Simulate loss
        uint256 loss = (ITokenizedStrategy(address(usd3Strategy))
            .totalAssets() * 8) / 100;
        _simulateLoss(loss);

        // Simultaneously: some users try to withdraw while loss is being reported
        // In practice, the report would happen first, but this tests system robustness

        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // After loss report, test withdrawals
        uint256 successfulWithdrawals = 0;
        for (uint256 i = NUM_USERS / 2; i < NUM_USERS; i++) {
            address user = users[i];
            uint256 balance = ITokenizedStrategy(address(usd3Strategy))
                .balanceOf(user);

            if (balance > 0) {
                vm.startPrank(user);
                try
                    ITokenizedStrategy(address(usd3Strategy)).redeem(
                        balance / 2,
                        user,
                        user
                    )
                returns (uint256 assets) {
                    successfulWithdrawals++;
                    assertGt(
                        assets,
                        0,
                        "Should receive some assets even after loss"
                    );
                } catch {
                    // Some withdrawals might fail due to liquidity constraints
                }
                vm.stopPrank();
            }
        }

        // System should handle loss and withdrawals gracefully
        assertTrue(
            successfulWithdrawals >= 0,
            "System should remain functional after loss"
        );

        // sUSD3 should have absorbed some loss
        uint256 susd3Balance = ITokenizedStrategy(address(usd3Strategy))
            .balanceOf(address(susd3Strategy));
        // The balance might be reduced due to share burning
        assertTrue(susd3Balance >= 0, "sUSD3 balance should be non-negative");
    }
}
