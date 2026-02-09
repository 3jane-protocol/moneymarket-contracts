// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test, console2} from "forge-std/Test.sol";
import {PYTLocker} from "../../../../src/jane/PYTLocker.sol";
import {MockAsset, MockSY, MockYT} from "./mocks/MockPendle.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PYTLockerTest is Test {
    PYTLocker public locker;
    MockAsset public asset;
    MockSY public sy;
    MockYT public yt;

    address public owner = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);
    address public charlie = address(0x4);

    uint256 public constant INITIAL_YT_BALANCE = 1000e18;
    uint256 public constant YT_EXPIRY = 365 days;

    function setUp() public {
        asset = new MockAsset();
        sy = new MockSY(address(asset));
        yt = new MockYT(address(sy), block.timestamp + YT_EXPIRY);

        vm.prank(owner);
        locker = new PYTLocker(owner);

        vm.prank(owner);
        locker.addMarket(address(yt));

        yt.mint(alice, INITIAL_YT_BALANCE);
        yt.mint(bob, INITIAL_YT_BALANCE);
        yt.mint(charlie, INITIAL_YT_BALANCE);

        vm.prank(alice);
        yt.approve(address(locker), type(uint256).max);
        vm.prank(bob);
        yt.approve(address(locker), type(uint256).max);
        vm.prank(charlie);
        yt.approve(address(locker), type(uint256).max);
    }

    function _accrueYield(uint256 amount) internal {
        sy.mint(address(yt), amount);
        sy.fundAsset(amount);
        yt.accrueInterest(address(locker), amount);
    }

    // ============ Admin Tests ============

    function test_addMarket() public {
        MockAsset asset2 = new MockAsset();
        MockSY sy2 = new MockSY(address(asset2));
        MockYT yt2 = new MockYT(address(sy2), block.timestamp + YT_EXPIRY);

        vm.prank(owner);
        locker.addMarket(address(yt2));

        (address configSy, address configAsset, bool enabled) = locker.markets(address(yt2));
        assertEq(configSy, address(sy2));
        assertEq(configAsset, address(asset2));
        assertTrue(enabled);
    }

    function test_addMarket_revertIfNotOwner() public {
        MockYT yt2 = new MockYT(address(sy), block.timestamp + YT_EXPIRY);

        vm.prank(alice);
        vm.expectRevert();
        locker.addMarket(address(yt2));
    }

    function test_addMarket_revertIfAlreadyExists() public {
        vm.prank(owner);
        vm.expectRevert(PYTLocker.MarketExists.selector);
        locker.addMarket(address(yt));
    }

    // ============ Deposit Tests ============

    function test_deposit() public {
        uint256 depositAmount = 100e18;

        vm.prank(alice);
        locker.deposit(address(yt), depositAmount);

        assertEq(locker.balanceOf(address(yt), alice), depositAmount);
        assertEq(locker.totalSupply(address(yt)), depositAmount);
        assertEq(yt.balanceOf(alice), INITIAL_YT_BALANCE - depositAmount);
        assertEq(yt.balanceOf(address(locker)), depositAmount);
    }

    function test_deposit_receiver_thirdPartyPays_receiverCredited() public {
        uint256 depositAmount = 100e18;

        uint256 bobBalanceBefore = yt.balanceOf(bob);
        uint256 aliceBalanceBefore = yt.balanceOf(alice);

        vm.prank(bob);
        locker.deposit(address(yt), depositAmount, alice);

        assertEq(locker.balanceOf(address(yt), alice), depositAmount);
        assertEq(locker.balanceOf(address(yt), bob), 0);
        assertEq(locker.totalSupply(address(yt)), depositAmount);
        assertEq(yt.balanceOf(bob), bobBalanceBefore - depositAmount);
        assertEq(yt.balanceOf(alice), aliceBalanceBefore);
        assertEq(yt.balanceOf(address(locker)), depositAmount);
    }

    function test_deposit_revertIfNotSupported() public {
        MockYT yt2 = new MockYT(address(sy), block.timestamp + YT_EXPIRY);

        vm.prank(alice);
        vm.expectRevert(PYTLocker.UnsupportedYT.selector);
        locker.deposit(address(yt2), 100e18);
    }

    function test_deposit_receiver_revertIfNotSupported() public {
        MockYT yt2 = new MockYT(address(sy), block.timestamp + YT_EXPIRY);

        vm.prank(bob);
        vm.expectRevert(PYTLocker.UnsupportedYT.selector);
        locker.deposit(address(yt2), 100e18, alice);
    }

    function test_deposit_revertIfZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(PYTLocker.ZeroAmount.selector);
        locker.deposit(address(yt), 0);
    }

    function test_deposit_receiver_revertIfZeroAmount() public {
        vm.prank(bob);
        vm.expectRevert(PYTLocker.ZeroAmount.selector);
        locker.deposit(address(yt), 0, alice);
    }

    function test_deposit_receiver_revertIfZeroAddress() public {
        vm.prank(bob);
        vm.expectRevert(PYTLocker.ZeroAddress.selector);
        locker.deposit(address(yt), 100e18, address(0));
    }

    function test_deposit_revertIfExpired() public {
        vm.warp(block.timestamp + YT_EXPIRY + 1);

        vm.prank(alice);
        vm.expectRevert(PYTLocker.YTExpired.selector);
        locker.deposit(address(yt), 100e18);
    }

    function test_deposit_receiver_revertIfExpired() public {
        vm.warp(block.timestamp + YT_EXPIRY + 1);

        vm.prank(bob);
        vm.expectRevert(PYTLocker.YTExpired.selector);
        locker.deposit(address(yt), 100e18, alice);
    }

    function test_deposit_multipleUsers() public {
        vm.prank(alice);
        locker.deposit(address(yt), 100e18);

        vm.prank(bob);
        locker.deposit(address(yt), 200e18);

        assertEq(locker.balanceOf(address(yt), alice), 100e18);
        assertEq(locker.balanceOf(address(yt), bob), 200e18);
        assertEq(locker.totalSupply(address(yt)), 300e18);
    }

    // ============ Harvest Tests ============

    function test_harvest_distributesYield() public {
        vm.prank(alice);
        locker.deposit(address(yt), 100e18);

        uint256 yieldAmount = 10e18;
        _accrueYield(yieldAmount);

        locker.harvest(address(yt));

        assertEq(locker.accYieldPerToken(address(yt)), (yieldAmount * 1e18) / 100e18);
        assertEq(locker.claimable(address(yt), alice), yieldAmount);
    }

    function test_harvest_noYieldIfNoDepositors() public {
        locker.harvest(address(yt));
        assertEq(locker.accYieldPerToken(address(yt)), 0);
    }

    function test_harvest_anyoneCanCall() public {
        vm.prank(alice);
        locker.deposit(address(yt), 100e18);

        uint256 yieldAmount = 10e18;
        _accrueYield(yieldAmount);

        address random = address(0xDEAD);
        vm.prank(random);
        locker.harvest(address(yt));

        assertEq(locker.claimable(address(yt), alice), yieldAmount);
    }

    // ============ Claim Tests ============

    function test_claim() public {
        vm.prank(alice);
        locker.deposit(address(yt), 100e18);

        uint256 yieldAmount = 10e18;
        _accrueYield(yieldAmount);
        locker.harvest(address(yt));

        uint256 balanceBefore = asset.balanceOf(alice);

        vm.prank(alice);
        locker.claim(address(yt));

        assertEq(asset.balanceOf(alice), balanceBefore + yieldAmount);
        assertEq(locker.claimable(address(yt), alice), 0);
    }

    function test_claim_noOpIfNoRewards() public {
        vm.prank(alice);
        locker.deposit(address(yt), 100e18);

        vm.prank(alice);
        locker.claim(address(yt));

        assertEq(asset.balanceOf(alice), 0);
    }

    function test_claim_partialClaim() public {
        vm.prank(alice);
        locker.deposit(address(yt), 100e18);

        uint256 yield1 = 10e18;
        _accrueYield(yield1);
        locker.harvest(address(yt));

        vm.prank(alice);
        locker.claim(address(yt));
        assertEq(asset.balanceOf(alice), yield1);

        uint256 yield2 = 5e18;
        _accrueYield(yield2);
        locker.harvest(address(yt));

        vm.prank(alice);
        locker.claim(address(yt));
        assertEq(asset.balanceOf(alice), yield1 + yield2);
    }

    function test_claim_onBehalf() public {
        vm.prank(alice);
        locker.deposit(address(yt), 100e18);

        uint256 yieldAmount = 10e18;
        _accrueYield(yieldAmount);
        locker.harvest(address(yt));

        uint256 bobBalanceBefore = asset.balanceOf(bob);

        vm.prank(bob);
        locker.claim(address(yt), alice);

        assertEq(asset.balanceOf(alice), yieldAmount);
        assertEq(asset.balanceOf(bob), bobBalanceBefore);
        assertEq(locker.claimable(address(yt), alice), 0);
    }

    // ============ No Dilution Tests (Critical) ============

    function test_noDilution_newDepositorDoesNotGetPastYield() public {
        vm.prank(alice);
        locker.deposit(address(yt), 100e18);

        uint256 yieldAmount = 10e18;
        _accrueYield(yieldAmount);

        vm.prank(bob);
        locker.deposit(address(yt), 100e18);

        assertEq(locker.claimable(address(yt), bob), 0);
        assertEq(locker.claimable(address(yt), alice), yieldAmount);
    }

    function test_noDilution_multipleDepositsAndYields() public {
        vm.prank(alice);
        locker.deposit(address(yt), 100e18);

        uint256 yield1 = 10e18;
        _accrueYield(yield1);
        locker.harvest(address(yt));

        vm.prank(bob);
        locker.deposit(address(yt), 100e18);

        uint256 yield2 = 20e18;
        _accrueYield(yield2);
        locker.harvest(address(yt));

        assertEq(locker.claimable(address(yt), alice), yield1 + yield2 / 2);
        assertEq(locker.claimable(address(yt), bob), yield2 / 2);
    }

    function test_noDilution_proportionalDistribution() public {
        vm.prank(alice);
        locker.deposit(address(yt), 100e18);

        vm.prank(bob);
        locker.deposit(address(yt), 300e18);

        uint256 yieldAmount = 40e18;
        _accrueYield(yieldAmount);
        locker.harvest(address(yt));

        assertEq(locker.claimable(address(yt), alice), 10e18);
        assertEq(locker.claimable(address(yt), bob), 30e18);
    }

    // ============ Auto-Claim on Deposit Tests ============

    function test_deposit_autoClaimsPendingYield() public {
        vm.prank(alice);
        locker.deposit(address(yt), 100e18);

        uint256 yield1 = 10e18;
        _accrueYield(yield1);
        locker.harvest(address(yt));

        assertEq(locker.claimable(address(yt), alice), yield1);

        vm.prank(alice);
        locker.deposit(address(yt), 50e18);

        assertEq(asset.balanceOf(alice), yield1);
        assertEq(locker.claimable(address(yt), alice), 0);
        assertEq(locker.balanceOf(address(yt), alice), 150e18);
    }

    function test_deposit_receiver_autoClaimsPendingYield() public {
        vm.prank(alice);
        locker.deposit(address(yt), 100e18);

        uint256 yield1 = 10e18;
        _accrueYield(yield1);
        locker.harvest(address(yt));

        assertEq(locker.claimable(address(yt), alice), yield1);

        vm.prank(bob);
        locker.deposit(address(yt), 50e18, alice);

        assertEq(asset.balanceOf(alice), yield1);
        assertEq(asset.balanceOf(bob), 0);
        assertEq(locker.claimable(address(yt), alice), 0);
        assertEq(locker.balanceOf(address(yt), alice), 150e18);
        assertEq(locker.balanceOf(address(yt), bob), 0);
    }

    // ============ Edge Cases ============

    function test_depositAfterClaim() public {
        vm.prank(alice);
        locker.deposit(address(yt), 100e18);

        uint256 yield1 = 10e18;
        _accrueYield(yield1);
        locker.harvest(address(yt));

        vm.prank(alice);
        locker.claim(address(yt));

        vm.prank(alice);
        locker.deposit(address(yt), 50e18);

        uint256 yield2 = 15e18;
        _accrueYield(yield2);
        locker.harvest(address(yt));

        assertEq(locker.claimable(address(yt), alice), yield2);
    }

    function test_multipleMarkets() public {
        MockAsset asset2 = new MockAsset();
        MockSY sy2 = new MockSY(address(asset2));
        MockYT yt2 = new MockYT(address(sy2), block.timestamp + YT_EXPIRY);

        vm.prank(owner);
        locker.addMarket(address(yt2));

        yt2.mint(alice, 500e18);
        vm.prank(alice);
        yt2.approve(address(locker), type(uint256).max);

        vm.prank(alice);
        locker.deposit(address(yt), 100e18);

        vm.prank(alice);
        locker.deposit(address(yt2), 200e18);

        uint256 yield1 = 10e18;
        sy.mint(address(yt), yield1);
        sy.fundAsset(yield1);
        yt.accrueInterest(address(locker), yield1);

        uint256 yield2 = 20e18;
        sy2.mint(address(yt2), yield2);
        sy2.fundAsset(yield2);
        yt2.accrueInterest(address(locker), yield2);

        locker.harvest(address(yt));
        locker.harvest(address(yt2));

        assertEq(locker.claimable(address(yt), alice), yield1);
        assertEq(locker.claimable(address(yt2), alice), yield2);
    }

    // ============ Sweep Tests ============

    function test_sweep_allowsUnprotectedTokens() public {
        MockAsset rewardToken = new MockAsset();
        rewardToken.mint(address(locker), 100e18);

        vm.prank(owner);
        locker.sweep(address(rewardToken), owner, 100e18);

        assertEq(rewardToken.balanceOf(owner), 100e18);
    }

    function test_sweep_revertsForYT() public {
        vm.prank(owner);
        vm.expectRevert(PYTLocker.CannotSweepMarketToken.selector);
        locker.sweep(address(yt), owner, 1e18);
    }

    function test_sweep_revertsForSY() public {
        vm.prank(owner);
        vm.expectRevert(PYTLocker.CannotSweepMarketToken.selector);
        locker.sweep(address(sy), owner, 1e18);
    }

    function test_sweep_revertsForAsset() public {
        vm.prank(owner);
        vm.expectRevert(PYTLocker.CannotSweepMarketToken.selector);
        locker.sweep(address(asset), owner, 1e18);
    }

    function test_sweep_revertsForNonOwner() public {
        MockAsset rewardToken = new MockAsset();
        rewardToken.mint(address(locker), 100e18);

        vm.prank(alice);
        vm.expectRevert();
        locker.sweep(address(rewardToken), alice, 100e18);
    }

    // ============ Fuzz Tests ============

    function testFuzz_depositAndClaim(uint256 depositAmount, uint256 yieldAmount) public {
        depositAmount = bound(depositAmount, 1e18, 1000e18);
        yieldAmount = bound(yieldAmount, 1e18, 1000e18);

        vm.prank(alice);
        locker.deposit(address(yt), depositAmount);

        _accrueYield(yieldAmount);
        locker.harvest(address(yt));

        uint256 claimableAmount = locker.claimable(address(yt), alice);
        assertApproxEqRel(claimableAmount, yieldAmount, 1e11);

        vm.prank(alice);
        locker.claim(address(yt));

        assertApproxEqRel(asset.balanceOf(alice), yieldAmount, 1e11);
    }

    function testFuzz_noDilution(uint256 aliceDeposit, uint256 bobDeposit, uint256 yield1, uint256 yield2) public {
        aliceDeposit = bound(aliceDeposit, 1e18, 500e18);
        bobDeposit = bound(bobDeposit, 1e18, 500e18);
        yield1 = bound(yield1, 1e18, 100e18);
        yield2 = bound(yield2, 1e18, 100e18);

        vm.prank(alice);
        locker.deposit(address(yt), aliceDeposit);

        _accrueYield(yield1);
        locker.harvest(address(yt));

        uint256 aliceClaimableAfterYield1 = locker.claimable(address(yt), alice);
        assertApproxEqRel(aliceClaimableAfterYield1, yield1, 1e11);

        vm.prank(bob);
        locker.deposit(address(yt), bobDeposit);

        assertEq(locker.claimable(address(yt), bob), 0);
        assertApproxEqRel(locker.claimable(address(yt), alice), yield1, 1e11);

        _accrueYield(yield2);
        locker.harvest(address(yt));

        uint256 totalLocked = aliceDeposit + bobDeposit;
        uint256 aliceShare2 = (yield2 * aliceDeposit) / totalLocked;
        uint256 bobShare2 = (yield2 * bobDeposit) / totalLocked;

        assertApproxEqRel(locker.claimable(address(yt), alice), yield1 + aliceShare2, 1e11);
        assertApproxEqRel(locker.claimable(address(yt), bob), bobShare2, 1e11);
    }
}
