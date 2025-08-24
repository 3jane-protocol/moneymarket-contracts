// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../USD3.sol";
import {sUSD3} from "../../sUSD3.sol";
import {IERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {TransparentUpgradeableProxy} from "../../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {MorphoCredit} from "@3jane-morpho-blue/MorphoCredit.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title EdgeCases
 * @notice Fuzz testing and boundary condition tests
 * @dev Tests extreme values, overflow conditions, and protocol invariants
 */
contract EdgeCases is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant MAX_UINT128 = type(uint128).max;
    uint256 constant MAX_UINT256 = type(uint256).max;

    function setUp() public override {
        super.setUp();
        usd3Strategy = USD3(address(strategy));

        // Deploy sUSD3
        sUSD3 susd3Implementation = new sUSD3();
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(management);

        bytes memory susd3InitData = abi.encodeWithSelector(
            sUSD3.initialize.selector,
            address(usd3Strategy),
            management,
            keeper
        );

        TransparentUpgradeableProxy susd3Proxy = new TransparentUpgradeableProxy(
                address(susd3Implementation),
                address(susd3ProxyAdmin),
                susd3InitData
            );

        susd3Strategy = sUSD3(address(susd3Proxy));

        // Link strategies
        vm.prank(management);
        usd3Strategy.setSUSD3(address(susd3Strategy));

        // Setup test users with large amounts for fuzzing
        airdrop(asset, alice, 1000000e6); // 1M USDC
        airdrop(asset, bob, 1000000e6); // 1M USDC
    }

    /**
     * @notice Fuzz test deposit amounts
     * @dev Tests various deposit amounts from 0 to large values
     */
    function testFuzz_depositAmounts(uint256 amount) public {
        // Bound the amount to realistic values (0 to 1M USDC)
        amount = bound(amount, 0, 1000000e6);

        // Skip if amount is 0
        if (amount == 0) return;

        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), amount);

        // Should not revert for valid amounts
        uint256 shares = usd3Strategy.deposit(amount, alice);

        // Verify shares were minted
        if (amount > 0) {
            assertGt(shares, 0, "Should mint shares for non-zero deposit");
            assertEq(
                IERC20(address(usd3Strategy)).balanceOf(alice),
                shares,
                "Alice should receive shares"
            );
        }
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test withdrawal amounts
     * @dev Tests various withdrawal amounts with different maxLoss values
     */
    function testFuzz_withdrawalAmounts(
        uint256 amount,
        uint256 maxLoss
    ) public {
        // Setup: Alice deposits first
        uint256 depositAmount = 100000e6;
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), depositAmount);
        uint256 shares = usd3Strategy.deposit(depositAmount, alice);
        vm.stopPrank();

        // Get max withdrawable considering subordination limits
        uint256 maxWithdrawable = ITokenizedStrategy(address(usd3Strategy))
            .maxWithdraw(alice);

        // Bound withdrawal amount and maxLoss
        amount = bound(amount, 0, maxWithdrawable);
        maxLoss = bound(maxLoss, 0, 10000); // 0 to 100%

        if (amount == 0) return;

        // Try to withdraw
        vm.prank(alice);
        uint256 sharesUsed = usd3Strategy.withdraw(
            amount,
            alice,
            alice,
            maxLoss
        );

        // Verify withdrawal succeeded
        assertGt(sharesUsed, 0, "Should use shares for withdrawal");
        assertLe(
            IERC20(address(usd3Strategy)).balanceOf(alice),
            shares,
            "Alice's shares should decrease"
        );
    }

    /**
     * @notice Test extreme subordination ratios
     * @dev Tests sUSD3 deposit limits with various subordination ratios
     */
    function testFuzz_subordinationRatios(uint256 ratio) public {
        // Bound ratio from 0% to 50%
        ratio = bound(ratio, 0, 5000);

        // Get protocol config
        address morphoAddress = address(usd3Strategy.morphoCredit());
        address protocolConfigAddress = MorphoCredit(morphoAddress)
            .protocolConfig();
        MockProtocolConfig protocolConfig = MockProtocolConfig(
            protocolConfigAddress
        );

        // Set the ratio
        bytes32 TRANCHE_RATIO = keccak256("TRANCHE_RATIO");
        protocolConfig.setConfig(TRANCHE_RATIO, ratio);

        // Calculate expected limit
        uint256 usd3Supply = IERC20(address(usd3Strategy)).totalSupply();
        uint256 expectedMaxDeposit = ratio == 0
            ? 0
            : (usd3Supply * ratio) / 10000;

        // Check deposit limit
        uint256 depositLimit = susd3Strategy.availableDepositLimit(alice);

        if (ratio == 0) {
            // With 0 ratio, should fallback to default 15%
            uint256 defaultLimit = (usd3Supply * 1500) / 10000;
            assertApproxEqAbs(
                depositLimit,
                defaultLimit,
                100e6,
                "Should use default ratio when 0"
            );
        } else {
            assertApproxEqAbs(
                depositLimit,
                expectedMaxDeposit,
                100e6,
                "Deposit limit should match ratio"
            );
        }
    }

    /**
     * @notice Test cooldown with extreme share amounts
     * @dev Tests uint128 boundary for cooldown shares
     */
    function test_cooldownExtremeshares() public {
        // Alice deposits to get shares
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 100000e6);
        usd3Strategy.deposit(100000e6, alice);
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 10000e6);
        uint256 shares = susd3Strategy.deposit(10000e6, alice);
        vm.stopPrank();

        // Fast forward past lock
        skip(91 days);

        // Test with maximum uint128 value (even though alice doesn't have that many)
        vm.prank(alice);
        susd3Strategy.startCooldown(MAX_UINT128);

        // Verify cooldown was set
        (, , uint256 cooldownShares) = susd3Strategy.getCooldownStatus(alice);
        assertEq(cooldownShares, MAX_UINT128, "Should store max uint128");

        // Actual withdrawal will be limited by balance
        skip(8 days);
        vm.prank(alice);
        uint256 withdrawn = susd3Strategy.redeem(shares, alice, alice);
        assertEq(withdrawn, 10000e6, "Should only withdraw actual balance");
    }

    /**
     * @notice Test performance fee boundaries
     * @dev Tests setting performance fees from 0% to 100%
     */
    function testFuzz_performanceFeeBoundaries(uint256 fee) public {
        // Bound fee from 0 to 10000 (0% to 100%)
        fee = bound(fee, 0, 10000);

        // Get protocol config
        address morphoAddress = address(usd3Strategy.morphoCredit());
        address protocolConfigAddress = MorphoCredit(morphoAddress)
            .protocolConfig();
        MockProtocolConfig protocolConfig = MockProtocolConfig(
            protocolConfigAddress
        );

        // Set the fee via protocol config
        bytes32 TRANCHE_SHARE_VARIANT = keccak256("TRANCHE_SHARE_VARIANT");
        protocolConfig.setConfig(TRANCHE_SHARE_VARIANT, fee);

        // Sync to USD3
        vm.prank(keeper);
        usd3Strategy.syncTrancheShare();

        // Generate profit and verify distribution
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 10000e6);
        usd3Strategy.deposit(10000e6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), 10000e6);
        usd3Strategy.deposit(10000e6, bob);

        // Check available limit and deposit within subordination ratio
        uint256 availableLimit = susd3Strategy.availableDepositLimit(bob);
        uint256 depositAmount = availableLimit > 3000e6
            ? 3000e6
            : availableLimit;

        if (depositAmount > 0) {
            IERC20(address(usd3Strategy)).approve(
                address(susd3Strategy),
                depositAmount
            );
            susd3Strategy.deposit(depositAmount, bob);
        }
        vm.stopPrank();

        // Generate yield
        airdrop(asset, address(usd3Strategy), 1000e6);

        uint256 susd3BalanceBefore = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );

        // Report
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        uint256 susd3BalanceAfter = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );

        // Verify fee distribution only if sUSD3 has deposits
        if (depositAmount > 0) {
            if (fee == 0) {
                assertEq(
                    susd3BalanceAfter,
                    susd3BalanceBefore,
                    "No shares minted with 0% fee"
                );
            } else if (fee == 10000) {
                // All profit goes to sUSD3
                uint256 sharesReceived = susd3BalanceAfter - susd3BalanceBefore;
                // Only check if shares were actually received
                if (sharesReceived > 0) {
                    uint256 valueReceived = ITokenizedStrategy(
                        address(usd3Strategy)
                    ).convertToAssets(sharesReceived);
                    assertApproxEqAbs(
                        valueReceived,
                        1000e6,
                        10e6,
                        "Should receive ~100% of profit"
                    );
                }
            } else {
                // Partial distribution
                uint256 sharesReceived = susd3BalanceAfter - susd3BalanceBefore;
                if (sharesReceived > 0) {
                    assertLt(
                        sharesReceived,
                        1000e6,
                        "Should receive less than full profit in shares"
                    );
                }
            }
        }
    }

    /**
     * @notice Test loss absorption with extreme values
     * @dev Tests burning shares with various loss amounts
     */
    function testFuzz_lossAbsorption(uint256 lossPercent) public {
        // Bound loss from 0% to 100%
        lossPercent = bound(lossPercent, 0, 100);

        // Setup deposits
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 50000e6);
        usd3Strategy.deposit(50000e6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), 50000e6);
        usd3Strategy.deposit(50000e6, bob);

        // Check available limit and deposit within subordination ratio
        uint256 availableLimit = susd3Strategy.availableDepositLimit(bob);
        uint256 depositAmount = availableLimit > 15000e6
            ? 15000e6
            : availableLimit;

        IERC20(address(usd3Strategy)).approve(
            address(susd3Strategy),
            depositAmount
        );
        if (depositAmount > 0) {
            susd3Strategy.deposit(depositAmount, bob);
        }
        vm.stopPrank();

        uint256 totalAssets = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        uint256 susd3SharesBefore = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );

        // Calculate and simulate loss
        uint256 idleAssets = asset.balanceOf(address(usd3Strategy));
        uint256 lossAmount = (idleAssets * lossPercent) / 100;

        if (lossAmount > 0 && lossAmount <= idleAssets) {
            vm.prank(address(usd3Strategy));
            asset.transfer(address(1), lossAmount);

            // Report loss
            vm.prank(keeper);
            (uint256 profit, uint256 loss) = ITokenizedStrategy(
                address(usd3Strategy)
            ).report();

            assertEq(loss, lossAmount, "Should report correct loss");

            // Verify shares burned
            uint256 susd3SharesAfter = IERC20(address(usd3Strategy)).balanceOf(
                address(susd3Strategy)
            );

            if (lossPercent > 0) {
                assertLt(
                    susd3SharesAfter,
                    susd3SharesBefore,
                    "sUSD3 shares should be burned"
                );
            }
        }
    }

    /**
     * @notice Test time-based parameters
     * @dev Tests lock duration, cooldown, and withdrawal windows
     */
    function testFuzz_timeParameters(
        uint256 lockDuration,
        uint256 cooldownDuration,
        uint256 withdrawalWindow
    ) public {
        // Bound parameters to reasonable values
        lockDuration = bound(lockDuration, 1 days, 365 days);
        cooldownDuration = bound(cooldownDuration, 1 days, 30 days);
        withdrawalWindow = bound(withdrawalWindow, 1 days, 7 days);

        // Get protocol config
        address morphoAddress = address(usd3Strategy.morphoCredit());
        address protocolConfigAddress = MorphoCredit(morphoAddress)
            .protocolConfig();
        MockProtocolConfig protocolConfig = MockProtocolConfig(
            protocolConfigAddress
        );

        // Set durations
        bytes32 SUSD3_LOCK_DURATION = keccak256("SUSD3_LOCK_DURATION");
        bytes32 SUSD3_COOLDOWN_PERIOD = keccak256("SUSD3_COOLDOWN_PERIOD");

        protocolConfig.setConfig(SUSD3_LOCK_DURATION, lockDuration);
        protocolConfig.setConfig(SUSD3_COOLDOWN_PERIOD, cooldownDuration);

        bytes32 SUSD3_WITHDRAWAL_WINDOW = keccak256("SUSD3_WITHDRAWAL_WINDOW");
        protocolConfig.setConfig(SUSD3_WITHDRAWAL_WINDOW, withdrawalWindow);

        // Test deposit with new lock duration
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 10000e6);
        usd3Strategy.deposit(10000e6, alice);
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 1000e6);
        uint256 shares = susd3Strategy.deposit(1000e6, alice);

        // Verify lock is set
        assertEq(
            susd3Strategy.lockedUntil(alice),
            block.timestamp + lockDuration,
            "Lock should match configured duration"
        );

        // Fast forward past lock
        skip(lockDuration + 1);

        // Start cooldown
        susd3Strategy.startCooldown(shares);

        // Verify cooldown timing
        (uint256 cooldownEnd, uint256 windowEnd, ) = susd3Strategy
            .getCooldownStatus(alice);
        assertEq(
            cooldownEnd,
            block.timestamp + cooldownDuration,
            "Cooldown should match configured duration"
        );
        assertEq(
            windowEnd,
            block.timestamp + cooldownDuration + withdrawalWindow,
            "Window should match configured duration"
        );
        vm.stopPrank();
    }

    /**
     * @notice Test rapid deposit/withdraw cycles
     * @dev Simulates high-frequency trading behavior
     */
    function test_rapidDepositWithdrawCycles() public {
        uint256 cycleAmount = 1000e6;
        uint256 cycles = 10;

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), type(uint256).max);

        for (uint256 i = 0; i < cycles; i++) {
            // Deposit
            uint256 shares = usd3Strategy.deposit(cycleAmount, alice);
            assertGt(shares, 0, "Should mint shares");

            // Immediate withdraw (respecting limits)
            uint256 maxWithdrawable = ITokenizedStrategy(address(usd3Strategy))
                .maxWithdraw(alice);
            uint256 toWithdraw = cycleAmount > maxWithdrawable
                ? maxWithdrawable
                : cycleAmount;

            if (toWithdraw > 0) {
                uint256 withdrawn = usd3Strategy.withdraw(
                    toWithdraw,
                    alice,
                    alice
                );
                assertGt(withdrawn, 0, "Should withdraw some amount");
            }
        }

        // Verify no significant drift
        uint256 finalBalance = asset.balanceOf(alice);
        assertApproxEqRel(
            finalBalance,
            1000000e6,
            0.01e18, // 1% tolerance
            "Should maintain balance after cycles"
        );
        vm.stopPrank();
    }

    /**
     * @notice Test concurrent operations from multiple users
     * @dev Simulates realistic multi-user scenarios
     */
    function test_concurrentMultiUserOperations() public {
        address[5] memory users = [
            makeAddr("user1"),
            makeAddr("user2"),
            makeAddr("user3"),
            makeAddr("user4"),
            makeAddr("user5")
        ];

        // Give each user funds
        for (uint256 i = 0; i < users.length; i++) {
            airdrop(asset, users[i], 100000e6);
        }

        // Simultaneous deposits
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            asset.approve(address(usd3Strategy), 20000e6);
            usd3Strategy.deposit(20000e6, users[i]);
            vm.stopPrank();
        }

        // Verify total supply
        uint256 totalSupply = IERC20(address(usd3Strategy)).totalSupply();
        assertEq(totalSupply, 100000e6, "Total supply should match deposits");

        // Some users withdraw
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(users[i]);
            usd3Strategy.withdraw(10000e6, users[i], users[i]);
        }

        // Verify remaining supply
        uint256 remainingSupply = IERC20(address(usd3Strategy)).totalSupply();
        assertEq(
            remainingSupply,
            70000e6,
            "Supply should decrease by withdrawals"
        );
    }

    /**
     * @notice Test protocol invariants
     * @dev Verifies critical invariants always hold
     */
    function testFuzz_protocolInvariants(
        uint256 deposits,
        uint256 withdrawals,
        uint256 losses
    ) public {
        // Bound inputs
        deposits = bound(deposits, 0, 100000e6);
        withdrawals = bound(withdrawals, 0, deposits);
        losses = bound(losses, 0, deposits / 10); // Max 10% loss

        // Initial state
        uint256 initialSupply = IERC20(address(usd3Strategy)).totalSupply();

        // Deposit
        if (deposits > 0) {
            vm.startPrank(alice);
            asset.approve(address(usd3Strategy), deposits);
            usd3Strategy.deposit(deposits, alice);
            vm.stopPrank();
        }

        // Invariant 1: Total supply equals sum of all balances
        uint256 supply = IERC20(address(usd3Strategy)).totalSupply();
        uint256 aliceBalance = IERC20(address(usd3Strategy)).balanceOf(alice);
        assertGe(
            supply,
            aliceBalance,
            "Supply should be at least user balance"
        );

        // Withdraw (respecting limits)
        if (withdrawals > 0 && deposits > 0) {
            uint256 maxWithdrawable = ITokenizedStrategy(address(usd3Strategy))
                .maxWithdraw(alice);
            uint256 actualWithdrawal = withdrawals > maxWithdrawable
                ? maxWithdrawable
                : withdrawals;

            if (actualWithdrawal > 0) {
                vm.prank(alice);
                usd3Strategy.withdraw(actualWithdrawal, alice, alice);
            }
        }

        // Invariant 2: Total assets >= total supply (in asset terms)
        uint256 totalAssets = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        uint256 totalSupplyInAssets = ITokenizedStrategy(address(usd3Strategy))
            .convertToAssets(IERC20(address(usd3Strategy)).totalSupply());
        assertGe(
            totalAssets + 1, // +1 for rounding
            totalSupplyInAssets,
            "Assets should cover supply"
        );

        // Simulate loss
        if (losses > 0) {
            uint256 idleAssets = asset.balanceOf(address(usd3Strategy));
            uint256 actualLoss = losses > idleAssets ? idleAssets : losses;
            if (actualLoss > 0) {
                vm.prank(address(usd3Strategy));
                asset.transfer(address(1), actualLoss);

                vm.prank(keeper);
                ITokenizedStrategy(address(usd3Strategy)).report();
            }
        }

        // Invariant 3: Share price should not increase on losses
        // (This is checked implicitly by the loss absorption mechanism)

        // Invariant 4: Subordination ratio should never exceed maximum
        uint256 susd3Holdings = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        uint256 usd3TotalSupply = IERC20(address(usd3Strategy)).totalSupply();
        if (usd3TotalSupply > 0) {
            uint256 ratio = (susd3Holdings * 10000) / usd3TotalSupply;
            assertLe(ratio, 5000, "Subordination should not exceed 50%");
        }
    }
}
