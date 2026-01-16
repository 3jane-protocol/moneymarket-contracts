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
}

/// @notice Interface for Pendle SY token
interface IPendleSY {
    function yieldToken() external view returns (address);

    function redeem(
        address receiver,
        uint256 amountSharesToRedeem,
        address tokenOut,
        uint256 minTokenOut,
        bool burnFromInternalBalance
    ) external returns (uint256 amountTokenOut);
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
 * - Expiry: February 5, 2026
 *
 * NOTE: These tests verify interface compatibility with real Pendle contracts.
 * Yield distribution logic is tested in unit tests with mocks (PYTLocker.t.sol).
 * Simulating yield on a fork requires complex state manipulation of Pendle internals.
 */
contract PYTLockerForkTest is Test {
    // Mainnet addresses for YT-sUSDE-5FEB2026
    address constant YT_SUSDE = 0xe36c6c271779C080Ba2e68E1E68410291a1b3F7A;
    address constant SY_SUSDE = 0x50CBf8837791aB3D8dcfB3cE3d1B0d128e1105d4;
    address constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;

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

    // ============ Full Flow Tests ============

    /// @notice Tests the complete deposit -> harvest -> claim flow
    /// @dev Verifies interface compatibility - yield distribution tested in unit tests
    function test_fork_fullFlow_depositHarvestClaim() public {
        uint256 depositAmount = 1000e18;

        // Alice deposits (using real whale balance)
        vm.startPrank(alice);
        IERC20(YT_SUSDE).approve(address(locker), depositAmount);
        locker.deposit(YT_SUSDE, depositAmount);
        vm.stopPrank();

        assertEq(locker.balanceOf(YT_SUSDE, alice), depositAmount);
        assertEq(locker.totalSupply(YT_SUSDE), depositAmount);

        // Harvest should not revert (verifies interface compatibility)
        locker.harvest(YT_SUSDE);

        // Claim should not revert
        vm.prank(alice);
        locker.claim(YT_SUSDE);

        // State should remain consistent
        assertEq(locker.balanceOf(YT_SUSDE, alice), depositAmount);
        assertEq(locker.claimable(YT_SUSDE, alice), 0);
    }

    /// @notice Tests multiple harvests don't break state
    function test_fork_multipleHarvests() public {
        uint256 depositAmount = 500e18;

        vm.startPrank(alice);
        IERC20(YT_SUSDE).approve(address(locker), depositAmount);
        locker.deposit(YT_SUSDE, depositAmount);
        vm.stopPrank();

        // Multiple harvests should not revert
        for (uint256 i = 0; i < 4; i++) {
            locker.harvest(YT_SUSDE);
        }

        // State should be consistent
        assertEq(locker.balanceOf(YT_SUSDE, alice), depositAmount);
        assertEq(locker.totalSupply(YT_SUSDE), depositAmount);
    }

    // ============ Multi-User Tests ============

    /// @notice Tests multiple users can deposit and the accounting is correct
    function test_fork_multiUserDeposits() public {
        uint256 aliceDeposit = 300e18;
        uint256 bobDeposit = 700e18;

        // Transfer some YT from whale to bob
        vm.prank(alice);
        IERC20(YT_SUSDE).transfer(bob, bobDeposit);

        // Both deposit
        vm.startPrank(alice);
        IERC20(YT_SUSDE).approve(address(locker), aliceDeposit);
        locker.deposit(YT_SUSDE, aliceDeposit);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(YT_SUSDE).approve(address(locker), bobDeposit);
        locker.deposit(YT_SUSDE, bobDeposit);
        vm.stopPrank();

        // Verify accounting
        assertEq(locker.balanceOf(YT_SUSDE, alice), aliceDeposit);
        assertEq(locker.balanceOf(YT_SUSDE, bob), bobDeposit);
        assertEq(locker.totalSupply(YT_SUSDE), aliceDeposit + bobDeposit);

        // Harvest and claim should work for both
        locker.harvest(YT_SUSDE);

        vm.prank(alice);
        locker.claim(YT_SUSDE);
        vm.prank(bob);
        locker.claim(YT_SUSDE);

        // State should remain consistent
        assertEq(locker.balanceOf(YT_SUSDE, alice), aliceDeposit);
        assertEq(locker.balanceOf(YT_SUSDE, bob), bobDeposit);
    }

    /// @notice Tests new depositors start with zero claimable (no past yield)
    function test_fork_noDilutionForNewDepositors() public {
        uint256 aliceDeposit = 500e18;
        uint256 bobDeposit = 500e18;

        // Transfer some YT from whale to bob
        vm.prank(alice);
        IERC20(YT_SUSDE).transfer(bob, bobDeposit);

        // Alice deposits first
        vm.startPrank(alice);
        IERC20(YT_SUSDE).approve(address(locker), aliceDeposit);
        locker.deposit(YT_SUSDE, aliceDeposit);
        vm.stopPrank();

        // Harvest (even with 0 yield, this updates accYieldPerToken)
        locker.harvest(YT_SUSDE);
        uint256 aliceClaimableBefore = locker.claimable(YT_SUSDE, alice);

        // Bob deposits (harvest is called internally)
        vm.startPrank(bob);
        IERC20(YT_SUSDE).approve(address(locker), bobDeposit);
        locker.deposit(YT_SUSDE, bobDeposit);
        vm.stopPrank();

        // Bob should have zero claimable (new depositor doesn't get past yield)
        assertEq(locker.claimable(YT_SUSDE, bob), 0, "Bob should not receive past yield");

        // Alice's claimable should not decrease
        assertGe(
            locker.claimable(YT_SUSDE, alice),
            aliceClaimableBefore,
            "Alice's claimable should not decrease when Bob deposits"
        );
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
