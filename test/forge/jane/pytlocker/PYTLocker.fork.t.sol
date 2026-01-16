// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test, console2} from "forge-std/Test.sol";
import {PYTLocker} from "../../../../src/jane/PYTLocker.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Interface for Pendle YT token
interface IPendleYT {
    function redeemDueInterestAndRewards(address user, bool redeemInterest, bool redeemRewards)
        external
        returns (uint256 interestOut, uint256[] memory rewardsOut);

    function SY() external view returns (address);
    function isExpired() external view returns (bool);
    function expiry() external view returns (uint256);
    function balanceOf(address user) external view returns (uint256);
    function pyIndexCurrent() external returns (uint256);
    function pyIndexStored() external view returns (uint256);
}

/// @notice Interface for Pendle SY token
interface IPendleSY {
    function yieldToken() external view returns (address);
    function exchangeRate() external view returns (uint256);

    function redeem(
        address receiver,
        uint256 amountSharesToRedeem,
        address tokenOut,
        uint256 minTokenOut,
        bool burnFromInternalBalance
    ) external returns (uint256 amountTokenOut);
}

/// @notice Interface for Ethena sUSDE (ERC4626)
interface IStakedUSDe {
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function asset() external view returns (address);
}

/**
 * @title PYTLockerForkTest
 * @notice Fork test for PYTLocker using real Pendle YT-sUSDE-5FEB2026 on Ethereum mainnet
 * @dev Tests are skipped if ETH_RPC_URL environment variable is not set (CI-safe)
 *
 * YT Contract Details:
 * - YT Address: 0xe36c6c271779C080Ba2e68E1E68410291a1b3F7A (YT-sUSDE-5FEB2026)
 * - SY Address: 0x50CBf8837791aB3D8dcfB3cE3d1B0d128e1105d4
 * - Underlying Asset (sUSDE): 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497
 * - USDe: 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3
 * - Expiry: February 5, 2026
 *
 * Yield Simulation:
 * Since sUSDE's totalAssets() = USDe.balanceOf(sUSDE) - unvestedAmount,
 * we simulate yield by dealing USDe to sUSDE and calling pyIndexCurrent()
 * to force Pendle to read the new exchange rate.
 */
contract PYTLockerForkTest is Test {
    // Mainnet addresses for YT-sUSDE-5FEB2026
    address constant YT_SUSDE = 0xe36c6c271779C080Ba2e68E1E68410291a1b3F7A;
    address constant SY_SUSDE = 0x50CBf8837791aB3D8dcfB3cE3d1B0d128e1105d4;
    address constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;

    // Fork configuration - block with mature liquidity, before expiry (Feb 5, 2026)
    uint256 constant FORK_BLOCK = 24200000;

    // Real YT holder to impersonate (has ~1.72M YT with accrued interest)
    address constant YT_WHALE = 0x7FDe637d685A5486CCb1B0a8eF658Ad1a08e8337;

    // Test contracts
    PYTLocker public locker;

    // Test accounts
    address public owner = address(0xABCD);
    address public alice = YT_WHALE; // Use real holder for proper interest accounting
    address public bob = address(0x2222);

    // Fork state
    uint256 public mainnetFork;

    function setUp() public {
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string(""));

        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }

        mainnetFork = vm.createFork(rpcUrl, FORK_BLOCK);
        vm.selectFork(mainnetFork);

        // Label addresses for trace output
        vm.label(YT_SUSDE, "YT-sUSDE");
        vm.label(SY_SUSDE, "SY-sUSDE");
        vm.label(SUSDE, "sUSDE");
        vm.label(USDE, "USDe");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(owner, "Owner");

        // Deploy PYTLocker
        vm.prank(owner);
        locker = new PYTLocker(owner);
        vm.label(address(locker), "PYTLocker");

        // Add YT-sUSDE market
        vm.prank(owner);
        locker.addMarket(YT_SUSDE, SY_SUSDE, SUSDE);
    }

    // ============ Yield Simulation Helper ============

    /// @notice Simulates sUSDE yield by dealing USDe and refreshing Pendle's index
    /// @dev sUSDE's totalAssets() = USDe.balanceOf(sUSDE) - unvestedAmount
    ///      deal() increases balanceOf directly (no vesting), so yield is immediate
    ///      Pendle caches pyIndex per block, so we must advance block.number
    /// @param additionalUSDe Amount of USDe to add as simulated yield
    function _simulateSusdeYield(uint256 additionalUSDe) internal {
        // 1. Add USDe to sUSDE contract (increases totalAssets immediately)
        uint256 currentBalance = IERC20(USDE).balanceOf(SUSDE);
        deal(USDE, SUSDE, currentBalance + additionalUSDe);

        // 2. Advance block number - Pendle caches pyIndex per block, not timestamp
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12); // ~1 block time

        // 3. Force Pendle to refresh its pyIndex (reads new SY exchange rate)
        IPendleYT(YT_SUSDE).pyIndexCurrent();
    }

    // ============ Yield Accrual Tests ============

    /// @notice Debug test to verify yield simulation actually changes exchange rates
    function test_fork_debug_yieldSimulationWorks() public {
        // Get initial rates
        uint256 syRateBefore = IPendleSY(SY_SUSDE).exchangeRate();
        uint256 susdeTotalAssetsBefore = IStakedUSDe(SUSDE).totalAssets();
        uint256 pyIndexBefore = IPendleYT(YT_SUSDE).pyIndexStored();

        console2.log("SY rate before:", syRateBefore);
        console2.log("sUSDE totalAssets before:", susdeTotalAssetsBefore);
        console2.log("pyIndex before:", pyIndexBefore);

        // Simulate meaningful yield (1% of current assets)
        uint256 yieldAmount = susdeTotalAssetsBefore / 100;
        _simulateSusdeYield(yieldAmount);

        // Verify rates changed
        uint256 syRateAfter = IPendleSY(SY_SUSDE).exchangeRate();
        uint256 susdeTotalAssetsAfter = IStakedUSDe(SUSDE).totalAssets();
        uint256 pyIndexAfter = IPendleYT(YT_SUSDE).pyIndexStored();

        console2.log("SY rate after:", syRateAfter);
        console2.log("sUSDE totalAssets after:", susdeTotalAssetsAfter);
        console2.log("pyIndex after:", pyIndexAfter);

        assertGt(susdeTotalAssetsAfter, susdeTotalAssetsBefore, "sUSDE totalAssets should increase");
        assertGt(syRateAfter, syRateBefore, "SY exchange rate should increase");
        assertGt(pyIndexAfter, pyIndexBefore, "pyIndex should increase");
    }

    /// @notice Tests that a single depositor receives yield after harvest
    function test_fork_yieldAccrual_singleUser() public {
        uint256 depositAmount = 1000e18;

        // Alice deposits YT
        vm.startPrank(alice);
        IERC20(YT_SUSDE).approve(address(locker), depositAmount);
        locker.deposit(YT_SUSDE, depositAmount);
        vm.stopPrank();

        // Record initial state
        uint256 accYieldBefore = locker.accYieldPerToken(YT_SUSDE);
        uint256 lockerSusdeBefore = IERC20(SUSDE).balanceOf(address(locker));

        // Simulate yield (1% of sUSDE total assets)
        uint256 yieldAmount = IStakedUSDe(SUSDE).totalAssets() / 100;
        _simulateSusdeYield(yieldAmount);

        // Harvest
        locker.harvest(YT_SUSDE);

        // Verify yield was captured
        uint256 accYieldAfter = locker.accYieldPerToken(YT_SUSDE);
        uint256 lockerSusdeAfter = IERC20(SUSDE).balanceOf(address(locker));

        assertGt(accYieldAfter, accYieldBefore, "accYieldPerToken should increase");
        assertGt(lockerSusdeAfter, lockerSusdeBefore, "Locker should have received sUSDE");

        // Verify Alice can claim
        uint256 claimable = locker.claimable(YT_SUSDE, alice);
        assertGt(claimable, 0, "Alice should have claimable yield");

        // Alice claims
        uint256 aliceSusdeBefore = IERC20(SUSDE).balanceOf(alice);
        vm.prank(alice);
        locker.claim(YT_SUSDE);
        uint256 aliceSusdeAfter = IERC20(SUSDE).balanceOf(alice);

        assertEq(aliceSusdeAfter - aliceSusdeBefore, claimable, "Alice should receive claimable amount");
        assertEq(locker.claimable(YT_SUSDE, alice), 0, "Alice claimable should be zero after claim");
    }

    /// @notice Tests proportional yield distribution between two users
    function test_fork_yieldAccrual_multiUser_proportional() public {
        uint256 aliceDeposit = 300e18;
        uint256 bobDeposit = 700e18;

        // Transfer YT to Bob
        vm.prank(alice);
        IERC20(YT_SUSDE).transfer(bob, bobDeposit);

        // Both deposit (Alice 30%, Bob 70%)
        vm.startPrank(alice);
        IERC20(YT_SUSDE).approve(address(locker), aliceDeposit);
        locker.deposit(YT_SUSDE, aliceDeposit);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(YT_SUSDE).approve(address(locker), bobDeposit);
        locker.deposit(YT_SUSDE, bobDeposit);
        vm.stopPrank();

        // Simulate yield
        _simulateSusdeYield(IStakedUSDe(SUSDE).totalAssets() / 100);

        // Harvest
        locker.harvest(YT_SUSDE);

        // Check proportional distribution
        uint256 aliceClaimable = locker.claimable(YT_SUSDE, alice);
        uint256 bobClaimable = locker.claimable(YT_SUSDE, bob);
        uint256 totalClaimable = aliceClaimable + bobClaimable;

        assertGt(totalClaimable, 0, "Should have yield to distribute");

        // Alice should get ~30%, Bob ~70%
        assertApproxEqRel(
            aliceClaimable,
            (totalClaimable * aliceDeposit) / (aliceDeposit + bobDeposit),
            1e14, // 0.01% tolerance
            "Alice should get proportional share"
        );
        assertApproxEqRel(
            bobClaimable,
            (totalClaimable * bobDeposit) / (aliceDeposit + bobDeposit),
            1e14,
            "Bob should get proportional share"
        );
    }

    /// @notice Tests that new depositor doesn't dilute existing user's unclaimed yield
    function test_fork_yieldAccrual_noDilution() public {
        uint256 aliceDeposit = 500e18;
        uint256 bobDeposit = 500e18;

        // Transfer YT to Bob for later
        vm.prank(alice);
        IERC20(YT_SUSDE).transfer(bob, bobDeposit);

        // Alice deposits first
        vm.startPrank(alice);
        IERC20(YT_SUSDE).approve(address(locker), aliceDeposit);
        locker.deposit(YT_SUSDE, aliceDeposit);
        vm.stopPrank();

        // Simulate yield round 1 (Alice gets 100%)
        _simulateSusdeYield(IStakedUSDe(SUSDE).totalAssets() / 100);
        locker.harvest(YT_SUSDE);

        uint256 aliceClaimableRound1 = locker.claimable(YT_SUSDE, alice);
        assertGt(aliceClaimableRound1, 0, "Alice should have yield from round 1");

        // Bob deposits (should NOT dilute Alice's round 1 yield)
        vm.startPrank(bob);
        IERC20(YT_SUSDE).approve(address(locker), bobDeposit);
        locker.deposit(YT_SUSDE, bobDeposit);
        vm.stopPrank();

        // Alice's claimable should NOT decrease
        assertEq(locker.claimable(YT_SUSDE, alice), aliceClaimableRound1, "Alice's round 1 yield should not be diluted");

        // Bob should have zero claimable (no past yield)
        assertEq(locker.claimable(YT_SUSDE, bob), 0, "Bob should not receive past yield");

        // Simulate yield round 2 (split 50/50)
        _simulateSusdeYield(IStakedUSDe(SUSDE).totalAssets() / 100);
        locker.harvest(YT_SUSDE);

        // Verify both got round 2 equally
        uint256 aliceClaimableTotal = locker.claimable(YT_SUSDE, alice);
        uint256 bobClaimableTotal = locker.claimable(YT_SUSDE, bob);
        uint256 round2Yield = aliceClaimableTotal - aliceClaimableRound1;

        assertApproxEqRel(bobClaimableTotal, round2Yield, 1e14, "Bob should get half of round 2");
    }

    /// @notice Tests multiple harvest cycles with varying yield amounts
    function test_fork_yieldAccrual_variableRates() public {
        uint256 depositAmount = 1000e18;

        vm.startPrank(alice);
        IERC20(YT_SUSDE).approve(address(locker), depositAmount);
        locker.deposit(YT_SUSDE, depositAmount);
        vm.stopPrank();

        // Round 1: Small yield (0.1%)
        _simulateSusdeYield(IStakedUSDe(SUSDE).totalAssets() / 1000);
        locker.harvest(YT_SUSDE);
        uint256 claimable1 = locker.claimable(YT_SUSDE, alice);
        assertGt(claimable1, 0, "Round 1 should have yield");

        // Round 2: Large yield (2%)
        _simulateSusdeYield(IStakedUSDe(SUSDE).totalAssets() / 50);
        locker.harvest(YT_SUSDE);
        uint256 claimable2 = locker.claimable(YT_SUSDE, alice);
        assertGt(claimable2, claimable1, "Round 2 should accumulate more");

        // Round 3: Medium yield (0.5%)
        _simulateSusdeYield(IStakedUSDe(SUSDE).totalAssets() / 200);
        locker.harvest(YT_SUSDE);
        uint256 claimable3 = locker.claimable(YT_SUSDE, alice);
        assertGt(claimable3, claimable2, "Round 3 should accumulate more");

        // Claim all
        uint256 aliceBefore = IERC20(SUSDE).balanceOf(alice);
        vm.prank(alice);
        locker.claim(YT_SUSDE);
        uint256 aliceAfter = IERC20(SUSDE).balanceOf(alice);

        assertEq(aliceAfter - aliceBefore, claimable3, "Should receive all accumulated yield");
    }

    // ============ Setup Verification Tests ============

    function test_fork_ytNotExpired() public {
        IPendleYT yt = IPendleYT(YT_SUSDE);
        assertFalse(yt.isExpired(), "YT should not be expired at fork block");
        assertGt(yt.expiry(), block.timestamp, "YT expiry should be in the future");
    }

    function test_fork_marketConfigured() public {
        assertTrue(locker.isSupported(YT_SUSDE), "YT should be supported");
        (address sy, address asset, bool enabled) = locker.markets(YT_SUSDE);
        assertEq(sy, SY_SUSDE, "SY should match");
        assertEq(asset, SUSDE, "Asset should be sUSDE");
        assertTrue(enabled, "Market should be enabled");
    }

    function test_fork_syYieldToken() public {
        IPendleSY sy = IPendleSY(SY_SUSDE);
        assertEq(sy.yieldToken(), SUSDE, "SY yield token should be sUSDE");
    }

    // ============ Deposit Tests ============

    function test_fork_deposit() public {
        uint256 depositAmount = 100e18;
        uint256 aliceBalanceBefore = IERC20(YT_SUSDE).balanceOf(alice);

        vm.startPrank(alice);
        IERC20(YT_SUSDE).approve(address(locker), depositAmount);
        locker.deposit(YT_SUSDE, depositAmount);
        vm.stopPrank();

        assertEq(locker.balanceOf(YT_SUSDE, alice), depositAmount, "Alice balance should match deposit");
        assertEq(locker.totalSupply(YT_SUSDE), depositAmount, "Total supply should match deposit");
        assertEq(IERC20(YT_SUSDE).balanceOf(address(locker)), depositAmount, "Locker should hold YT");
        assertEq(IERC20(YT_SUSDE).balanceOf(alice), aliceBalanceBefore - depositAmount, "Alice YT reduced");
    }

    function test_fork_depositMultipleUsers() public {
        uint256 aliceDeposit = 100e18;
        uint256 bobDeposit = 200e18;

        // Transfer some YT from whale to bob for testing
        vm.prank(alice);
        IERC20(YT_SUSDE).transfer(bob, bobDeposit);

        vm.startPrank(alice);
        IERC20(YT_SUSDE).approve(address(locker), aliceDeposit);
        locker.deposit(YT_SUSDE, aliceDeposit);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(YT_SUSDE).approve(address(locker), bobDeposit);
        locker.deposit(YT_SUSDE, bobDeposit);
        vm.stopPrank();

        assertEq(locker.balanceOf(YT_SUSDE, alice), aliceDeposit);
        assertEq(locker.balanceOf(YT_SUSDE, bob), bobDeposit);
        assertEq(locker.totalSupply(YT_SUSDE), aliceDeposit + bobDeposit);
    }

    // ============ Edge Case Tests ============

    function test_fork_harvestWithZeroSupply() public {
        // Should not revert when harvesting with no depositors
        locker.harvest(YT_SUSDE);
        assertEq(locker.accYieldPerToken(YT_SUSDE), 0);
    }

    function test_fork_claimWithNoYield() public {
        uint256 depositAmount = 100e18;
        uint256 initialSUSDE = IERC20(SUSDE).balanceOf(alice);

        vm.startPrank(alice);
        IERC20(YT_SUSDE).approve(address(locker), depositAmount);
        locker.deposit(YT_SUSDE, depositAmount);
        locker.claim(YT_SUSDE); // Claim immediately after deposit (no time warp)
        vm.stopPrank();

        // Should not revert and sUSDE balance should remain same (no yield yet)
        assertEq(IERC20(SUSDE).balanceOf(alice), initialSUSDE);
    }

    function test_fork_depositNearExpiry() public {
        uint256 depositAmount = 100e18;

        IPendleYT yt = IPendleYT(YT_SUSDE);

        // Warp to 1 day before expiry
        uint256 expiry = yt.expiry();
        vm.warp(expiry - 1 days);

        // Should still allow deposit since not expired
        assertFalse(yt.isExpired(), "YT should not be expired yet");

        vm.startPrank(alice);
        IERC20(YT_SUSDE).approve(address(locker), depositAmount);
        locker.deposit(YT_SUSDE, depositAmount);
        vm.stopPrank();

        assertEq(locker.balanceOf(YT_SUSDE, alice), depositAmount);
    }

    function test_fork_revertDepositAfterExpiry() public {
        uint256 depositAmount = 100e18;

        IPendleYT yt = IPendleYT(YT_SUSDE);

        // Warp past expiry
        uint256 expiry = yt.expiry();
        vm.warp(expiry + 1);

        assertTrue(yt.isExpired(), "YT should be expired");

        vm.startPrank(alice);
        IERC20(YT_SUSDE).approve(address(locker), depositAmount);

        vm.expectRevert(PYTLocker.YTExpired.selector);
        locker.deposit(YT_SUSDE, depositAmount);
        vm.stopPrank();
    }

    // ============ Stress Tests ============

    function test_fork_manyDepositors() public {
        uint256 numDepositors = 10;
        uint256 depositAmount = 100e18;

        address[] memory depositors = new address[](numDepositors);

        // Transfer YT from whale to each depositor
        for (uint256 i = 0; i < numDepositors; i++) {
            depositors[i] = address(uint160(0x10000 + i));
            vm.prank(alice);
            IERC20(YT_SUSDE).transfer(depositors[i], depositAmount);

            vm.startPrank(depositors[i]);
            IERC20(YT_SUSDE).approve(address(locker), depositAmount);
            locker.deposit(YT_SUSDE, depositAmount);
            vm.stopPrank();
        }

        assertEq(locker.totalSupply(YT_SUSDE), depositAmount * numDepositors);

        // Harvest should work with many depositors
        locker.harvest(YT_SUSDE);

        // All depositors should have equal claimable (same deposit amount, same timing)
        uint256 firstClaimable = locker.claimable(YT_SUSDE, depositors[0]);
        for (uint256 i = 1; i < numDepositors; i++) {
            assertEq(
                locker.claimable(YT_SUSDE, depositors[i]),
                firstClaimable,
                "All depositors should have equal claimable with equal deposits"
            );
        }
    }

    // ============ View Function Tests ============

    function test_fork_claimableIsStaleBeforeHarvest() public {
        uint256 depositAmount = 100e18;

        vm.startPrank(alice);
        IERC20(YT_SUSDE).approve(address(locker), depositAmount);
        locker.deposit(YT_SUSDE, depositAmount);
        vm.stopPrank();

        // View function returns stale data before harvest
        uint256 claimableBefore = locker.claimable(YT_SUSDE, alice);

        // Even after time passes, claimable stays the same without harvest
        vm.warp(block.timestamp + 1 days);
        uint256 claimableAfterTime = locker.claimable(YT_SUSDE, alice);

        assertEq(claimableAfterTime, claimableBefore, "Claimable should be stale without harvest");
    }
}
