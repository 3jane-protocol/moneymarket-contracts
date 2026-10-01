// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test, console2} from "forge-std/Test.sol";
import {PYTLocker} from "../../../../src/jane/PYTLocker.sol";
import {MockAsset, MockSY, MockYT} from "./mocks/MockPendle.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "../../../../lib/openzeppelin/contracts/access/Ownable.sol";

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

    event MaxSupplyUpdated(uint256 oldMaxSupply, uint256 newMaxSupply);

    function setUp() public {
        asset = new MockAsset();
        sy = new MockSY(address(asset));
        yt = new MockYT(address(sy), block.timestamp + YT_EXPIRY);

        vm.prank(owner);
        locker = new PYTLocker(owner, address(yt));

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

    function _setMaxSupply(uint256 maxSupply) internal {
        vm.prank(owner);
        locker.setMaxSupply(maxSupply);
    }

    // ============ Admin Tests ============

    function test_constructor_bindsYTAndDerivesTokens() public view {
        assertEq(locker.yt(), address(yt));
        assertEq(locker.sy(), address(sy));
        assertEq(locker.asset(), address(asset));
    }

    function test_constructor_initializesUnlimitedCap() public view {
        assertEq(locker.maxSupply(), type(uint256).max);
        assertEq(locker.maxDeposit(), type(uint256).max);
    }

    function test_constructor_revertsForZeroYT() public {
        vm.expectRevert(PYTLocker.ZeroAddress.selector);
        new PYTLocker(owner, address(0));
    }

    function test_setMaxSupply_owner_emitsUpdate() public {
        uint256 newCap = 500e18;

        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(locker));
        emit MaxSupplyUpdated(type(uint256).max, newCap);
        locker.setMaxSupply(newCap);

        assertEq(locker.maxSupply(), newCap);
    }

    function test_setMaxSupply_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        locker.setMaxSupply(500e18);
    }

    function test_maxDeposit_expired() public {
        vm.warp(block.timestamp + YT_EXPIRY + 1);

        assertEq(locker.maxDeposit(), 0);
    }

    function test_maxDeposit_returnsRemainingCapacity() public {
        uint256 cap = 250e18;
        _setMaxSupply(cap);

        vm.prank(alice);
        locker.deposit(100e18);

        assertEq(locker.maxDeposit(), cap - 100e18);
    }

    function test_maxDeposit_returnsZeroWhenAtCap() public {
        uint256 cap = 100e18;
        _setMaxSupply(cap);

        vm.prank(alice);
        locker.deposit(cap);

        assertEq(locker.maxDeposit(), 0);
    }

    function test_maxDeposit_returnsZeroWhenOverCap() public {
        vm.prank(alice);
        locker.deposit(100e18);

        _setMaxSupply(50e18);

        assertEq(locker.maxDeposit(), 0);
    }

    // ============ Deposit Tests ============

    function test_deposit() public {
        uint256 depositAmount = 100e18;

        vm.prank(alice);
        locker.deposit(depositAmount);

        assertEq(locker.balanceOf(alice), depositAmount);
        assertEq(locker.totalSupply(), depositAmount);
        assertEq(yt.balanceOf(alice), INITIAL_YT_BALANCE - depositAmount);
        assertEq(yt.balanceOf(address(locker)), depositAmount);
    }

    function test_deposit_receiver_thirdPartyPays_receiverCredited() public {
        uint256 depositAmount = 100e18;

        uint256 bobBalanceBefore = yt.balanceOf(bob);
        uint256 aliceBalanceBefore = yt.balanceOf(alice);

        vm.prank(bob);
        locker.deposit(depositAmount, alice);

        assertEq(locker.balanceOf(alice), depositAmount);
        assertEq(locker.balanceOf(bob), 0);
        assertEq(locker.totalSupply(), depositAmount);
        assertEq(yt.balanceOf(bob), bobBalanceBefore - depositAmount);
        assertEq(yt.balanceOf(alice), aliceBalanceBefore);
        assertEq(yt.balanceOf(address(locker)), depositAmount);
    }

    function test_deposit_revertIfZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(PYTLocker.ZeroAmount.selector);
        locker.deposit(0);
    }

    function test_deposit_receiver_revertIfZeroAmount() public {
        vm.prank(bob);
        vm.expectRevert(PYTLocker.ZeroAmount.selector);
        locker.deposit(0, alice);
    }

    function test_deposit_receiver_revertIfZeroAddress() public {
        vm.prank(bob);
        vm.expectRevert(PYTLocker.ZeroAddress.selector);
        locker.deposit(100e18, address(0));
    }

    function test_deposit_revertIfExpired() public {
        vm.warp(block.timestamp + YT_EXPIRY + 1);

        vm.prank(alice);
        vm.expectRevert(PYTLocker.YTExpired.selector);
        locker.deposit(100e18);
    }

    function test_deposit_receiver_revertIfExpired() public {
        vm.warp(block.timestamp + YT_EXPIRY + 1);

        vm.prank(bob);
        vm.expectRevert(PYTLocker.YTExpired.selector);
        locker.deposit(100e18, alice);
    }

    function test_deposit_multipleUsers() public {
        vm.prank(alice);
        locker.deposit(100e18);

        vm.prank(bob);
        locker.deposit(200e18);

        assertEq(locker.balanceOf(alice), 100e18);
        assertEq(locker.balanceOf(bob), 200e18);
        assertEq(locker.totalSupply(), 300e18);
    }

    function test_deposit_succeedsAtExactCap() public {
        uint256 cap = 150e18;
        _setMaxSupply(cap);

        vm.prank(alice);
        locker.deposit(100e18);

        vm.prank(bob);
        locker.deposit(50e18);

        assertEq(locker.totalSupply(), cap);
        assertEq(locker.maxDeposit(), 0);
    }

    function test_deposit_revertsWhenExceedingCap() public {
        uint256 cap = 150e18;
        _setMaxSupply(cap);

        vm.prank(alice);
        locker.deposit(100e18);

        vm.prank(bob);
        vm.expectRevert(PYTLocker.MaxSupplyExceeded.selector);
        locker.deposit(50e18 + 1);
    }

    function test_deposit_atCapThenAnyMoreReverts() public {
        uint256 cap = 100e18;
        _setMaxSupply(cap);

        vm.prank(alice);
        locker.deposit(cap);

        vm.prank(bob);
        vm.expectRevert(PYTLocker.MaxSupplyExceeded.selector);
        locker.deposit(1);
    }

    function test_deposit_revertsWhenCapBelowSupply() public {
        vm.prank(alice);
        locker.deposit(100e18);

        _setMaxSupply(50e18);

        vm.prank(bob);
        vm.expectRevert(PYTLocker.MaxSupplyExceeded.selector);
        locker.deposit(1);
    }

    function test_deposit_succeedsAfterCapRaisedFromZero() public {
        vm.prank(alice);
        locker.deposit(100e18);

        _setMaxSupply(0);

        assertEq(locker.maxDeposit(), 0);

        vm.prank(bob);
        vm.expectRevert(PYTLocker.MaxSupplyExceeded.selector);
        locker.deposit(1);

        _setMaxSupply(150e18);

        assertEq(locker.maxDeposit(), 50e18);

        vm.prank(bob);
        locker.deposit(50e18);

        assertEq(locker.totalSupply(), 150e18);
        assertEq(locker.maxDeposit(), 0);
    }

    function test_deposit_receiverForm_honorsCap() public {
        uint256 cap = 125e18;
        _setMaxSupply(cap);

        vm.prank(bob);
        locker.deposit(100e18, alice);

        vm.prank(charlie);
        vm.expectRevert(PYTLocker.MaxSupplyExceeded.selector);
        locker.deposit(25e18 + 1, alice);

        vm.prank(charlie);
        locker.deposit(25e18, alice);

        assertEq(locker.balanceOf(alice), cap);
        assertEq(locker.totalSupply(), cap);
    }

    function test_deposit_capRevertSkipsHarvest() public {
        uint256 cap = 100e18;
        _setMaxSupply(cap);

        vm.prank(alice);
        locker.deposit(cap);

        _accrueYield(10e18);

        vm.prank(bob);
        vm.expectRevert(PYTLocker.MaxSupplyExceeded.selector);
        locker.deposit(1);

        assertEq(locker.accYieldPerToken(), 0);
        assertEq(locker.claimable(alice), 0);
        assertEq(asset.balanceOf(address(locker)), 0);
    }

    // ============ Harvest Tests ============

    function test_harvest_distributesYield() public {
        vm.prank(alice);
        locker.deposit(100e18);

        uint256 yieldAmount = 10e18;
        _accrueYield(yieldAmount);

        locker.harvest();

        assertEq(locker.accYieldPerToken(), (yieldAmount * 1e18) / 100e18);
        assertEq(locker.claimable(alice), yieldAmount);
    }

    function test_harvest_carriesRoundingRemainderAcrossHarvests() public {
        uint256 depositAmount = 1_000_000e18;
        uint256 smallYield = 500_000;

        yt.mint(alice, depositAmount);

        vm.prank(alice);
        locker.deposit(depositAmount);

        _accrueYield(smallYield);
        locker.harvest();

        assertEq(locker.accYieldPerToken(), 0);
        assertEq(locker.claimable(alice), 0);

        _accrueYield(smallYield);
        locker.harvest();

        assertEq(locker.accYieldPerToken(), 1);
        assertEq(locker.claimable(alice), smallYield * 2);

        vm.prank(alice);
        locker.claim();

        assertEq(asset.balanceOf(alice), smallYield * 2);
        assertEq(asset.balanceOf(address(locker)), 0);
    }

    function test_harvest_manySubThresholdHarvestsCumulateToIncrement() public {
        uint256 depositAmount = 1_000_000e18;
        uint256 smallYield = 250_000;

        yt.mint(alice, depositAmount);

        vm.prank(alice);
        locker.deposit(depositAmount);

        for (uint256 i = 0; i < 4; i++) {
            _accrueYield(smallYield);
            locker.harvest();

            assertLt(locker.yieldRemainder(), locker.totalSupply());
            if (i < 3) {
                assertEq(locker.accYieldPerToken(), 0);
            }
        }

        assertEq(locker.accYieldPerToken(), 1);
        assertEq(locker.yieldRemainder(), 0);
        assertEq(locker.claimable(alice), smallYield * 4);
    }

    function test_harvest_remainderNeverExceedsSupply() public {
        uint256 depositAmount = 1_000_000e18;
        uint256 smallYield = 333_333;

        yt.mint(alice, depositAmount);

        vm.prank(alice);
        locker.deposit(depositAmount);

        for (uint256 i = 0; i < 20; i++) {
            _accrueYield(smallYield);
            locker.harvest();

            assertLt(locker.yieldRemainder(), locker.totalSupply());
        }
    }

    function test_harvest_carriesRemainderAcrossDepositBoundary() public {
        uint256 aliceDeposit = 1_000_000e18;
        uint256 bobDeposit = 1_000_000e18;
        uint256 firstYield = 500_000;
        uint256 secondYield = 1_500_000;

        yt.mint(alice, aliceDeposit);
        yt.mint(bob, bobDeposit);

        vm.prank(alice);
        locker.deposit(aliceDeposit);

        _accrueYield(firstYield);
        locker.harvest();

        uint256 firstRemainder = locker.yieldRemainder();
        assertEq(locker.accYieldPerToken(), 0);
        assertEq(firstRemainder, firstYield * 1e18);

        vm.prank(bob);
        locker.deposit(bobDeposit);

        assertEq(locker.accYieldPerToken(), 0);
        assertEq(locker.yieldRemainder(), firstRemainder);

        _accrueYield(secondYield);
        locker.harvest();

        // Carry intentionally shares sub-precision dust across the updated supply.
        assertEq(locker.accYieldPerToken(), 1);
        assertEq(locker.yieldRemainder(), 0);
        assertEq(locker.claimable(alice), 1_000_000);
        assertEq(locker.claimable(bob), 1_000_000);

        vm.prank(alice);
        locker.claim();
        vm.prank(bob);
        locker.claim();

        assertEq(asset.balanceOf(alice), 1_000_000);
        assertEq(asset.balanceOf(bob), 1_000_000);
        assertEq(asset.balanceOf(address(locker)), 0);
    }

    function test_harvest_zeroGainDoesNotFlushRemainder() public {
        uint256 depositAmount = 1_000_000e18;
        uint256 smallYield = 500_000;

        yt.mint(alice, depositAmount);

        vm.prank(alice);
        locker.deposit(depositAmount);

        _accrueYield(smallYield);
        locker.harvest();

        uint256 remainder = locker.yieldRemainder();
        assertEq(locker.accYieldPerToken(), 0);
        assertGt(remainder, 0);

        locker.harvest();

        assertEq(locker.accYieldPerToken(), 0);
        assertEq(locker.yieldRemainder(), remainder);
        assertEq(asset.balanceOf(address(locker)), smallYield);
    }

    function test_harvest_noYieldIfNoDepositors() public {
        locker.harvest();
        assertEq(locker.accYieldPerToken(), 0);
    }

    function test_harvest_anyoneCanCall() public {
        vm.prank(alice);
        locker.deposit(100e18);

        uint256 yieldAmount = 10e18;
        _accrueYield(yieldAmount);

        address random = address(0xDEAD);
        vm.prank(random);
        locker.harvest();

        assertEq(locker.claimable(alice), yieldAmount);
    }

    // ============ Claim Tests ============

    function test_claim() public {
        vm.prank(alice);
        locker.deposit(100e18);

        uint256 yieldAmount = 10e18;
        _accrueYield(yieldAmount);
        locker.harvest();

        uint256 balanceBefore = asset.balanceOf(alice);

        vm.prank(alice);
        locker.claim();

        assertEq(asset.balanceOf(alice), balanceBefore + yieldAmount);
        assertEq(locker.claimable(alice), 0);
    }

    function test_claim_noOpIfNoRewards() public {
        vm.prank(alice);
        locker.deposit(100e18);

        vm.prank(alice);
        locker.claim();

        assertEq(asset.balanceOf(alice), 0);
    }

    function test_claim_partialClaim() public {
        vm.prank(alice);
        locker.deposit(100e18);

        uint256 yield1 = 10e18;
        _accrueYield(yield1);
        locker.harvest();

        vm.prank(alice);
        locker.claim();
        assertEq(asset.balanceOf(alice), yield1);

        uint256 yield2 = 5e18;
        _accrueYield(yield2);
        locker.harvest();

        vm.prank(alice);
        locker.claim();
        assertEq(asset.balanceOf(alice), yield1 + yield2);
    }

    function test_claim_onBehalf() public {
        vm.prank(alice);
        locker.deposit(100e18);

        uint256 yieldAmount = 10e18;
        _accrueYield(yieldAmount);
        locker.harvest();

        uint256 bobBalanceBefore = asset.balanceOf(bob);

        vm.prank(bob);
        locker.claim(alice);

        assertEq(asset.balanceOf(alice), yieldAmount);
        assertEq(asset.balanceOf(bob), bobBalanceBefore);
        assertEq(locker.claimable(alice), 0);
    }

    // ============ No Dilution Tests (Critical) ============

    function test_noDilution_newDepositorDoesNotGetPastYield() public {
        vm.prank(alice);
        locker.deposit(100e18);

        uint256 yieldAmount = 10e18;
        _accrueYield(yieldAmount);

        vm.prank(bob);
        locker.deposit(100e18);

        assertEq(locker.claimable(bob), 0);
        assertEq(locker.claimable(alice), yieldAmount);
    }

    function test_noDilution_multipleDepositsAndYields() public {
        vm.prank(alice);
        locker.deposit(100e18);

        uint256 yield1 = 10e18;
        _accrueYield(yield1);
        locker.harvest();

        vm.prank(bob);
        locker.deposit(100e18);

        uint256 yield2 = 20e18;
        _accrueYield(yield2);
        locker.harvest();

        assertEq(locker.claimable(alice), yield1 + yield2 / 2);
        assertEq(locker.claimable(bob), yield2 / 2);
    }

    function test_noDilution_proportionalDistribution() public {
        vm.prank(alice);
        locker.deposit(100e18);

        vm.prank(bob);
        locker.deposit(300e18);

        uint256 yieldAmount = 40e18;
        _accrueYield(yieldAmount);
        locker.harvest();

        assertEq(locker.claimable(alice), 10e18);
        assertEq(locker.claimable(bob), 30e18);
    }

    // ============ Auto-Claim on Deposit Tests ============

    function test_deposit_autoClaimsPendingYield() public {
        vm.prank(alice);
        locker.deposit(100e18);

        uint256 yield1 = 10e18;
        _accrueYield(yield1);
        locker.harvest();

        assertEq(locker.claimable(alice), yield1);

        vm.prank(alice);
        locker.deposit(50e18);

        assertEq(asset.balanceOf(alice), yield1);
        assertEq(locker.claimable(alice), 0);
        assertEq(locker.balanceOf(alice), 150e18);
    }

    function test_deposit_receiver_autoClaimsPendingYield() public {
        vm.prank(alice);
        locker.deposit(100e18);

        uint256 yield1 = 10e18;
        _accrueYield(yield1);
        locker.harvest();

        assertEq(locker.claimable(alice), yield1);

        vm.prank(bob);
        locker.deposit(50e18, alice);

        assertEq(asset.balanceOf(alice), yield1);
        assertEq(asset.balanceOf(bob), 0);
        assertEq(locker.claimable(alice), 0);
        assertEq(locker.balanceOf(alice), 150e18);
        assertEq(locker.balanceOf(bob), 0);
    }

    // ============ Edge Cases ============

    function test_depositAfterClaim() public {
        vm.prank(alice);
        locker.deposit(100e18);

        uint256 yield1 = 10e18;
        _accrueYield(yield1);
        locker.harvest();

        vm.prank(alice);
        locker.claim();

        vm.prank(alice);
        locker.deposit(50e18);

        uint256 yield2 = 15e18;
        _accrueYield(yield2);
        locker.harvest();

        assertEq(locker.claimable(alice), yield2);
    }

    function test_twoIndependentLockers_separateYield() public {
        MockAsset asset2 = new MockAsset();
        MockSY sy2 = new MockSY(address(asset2));
        MockYT yt2 = new MockYT(address(sy2), block.timestamp + YT_EXPIRY);
        PYTLocker locker2 = new PYTLocker(owner, address(yt2));

        yt2.mint(alice, 500e18);
        vm.prank(alice);
        yt2.approve(address(locker2), type(uint256).max);

        vm.prank(alice);
        locker.deposit(100e18);

        vm.prank(alice);
        locker2.deposit(200e18);

        uint256 yield1 = 10e18;
        sy.mint(address(yt), yield1);
        sy.fundAsset(yield1);
        yt.accrueInterest(address(locker), yield1);

        uint256 yield2 = 20e18;
        sy2.mint(address(yt2), yield2);
        sy2.fundAsset(yield2);
        yt2.accrueInterest(address(locker2), yield2);

        locker.harvest();
        locker2.harvest();

        assertEq(locker.claimable(alice), yield1);
        assertEq(locker2.claimable(alice), yield2);
    }

    function test_twoIndependentLockers_separateCaps() public {
        MockAsset asset2 = new MockAsset();
        MockSY sy2 = new MockSY(address(asset2));
        MockYT yt2 = new MockYT(address(sy2), block.timestamp + YT_EXPIRY);
        PYTLocker locker2 = new PYTLocker(owner, address(yt2));

        yt2.mint(alice, 500e18);
        vm.prank(alice);
        yt2.approve(address(locker2), type(uint256).max);

        vm.startPrank(owner);
        locker.setMaxSupply(100e18);
        locker2.setMaxSupply(200e18);
        vm.stopPrank();

        vm.prank(alice);
        locker.deposit(100e18);

        vm.prank(alice);
        locker2.deposit(150e18);

        vm.prank(bob);
        vm.expectRevert(PYTLocker.MaxSupplyExceeded.selector);
        locker.deposit(1);

        vm.prank(alice);
        locker2.deposit(50e18);

        assertEq(locker.totalSupply(), 100e18);
        assertEq(locker.maxDeposit(), 0);
        assertEq(locker2.totalSupply(), 200e18);
        assertEq(locker2.maxDeposit(), 0);
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
        vm.expectRevert(PYTLocker.CannotSweepProtectedToken.selector);
        locker.sweep(address(yt), owner, 1e18);
    }

    function test_sweep_revertsForSY() public {
        vm.prank(owner);
        vm.expectRevert(PYTLocker.CannotSweepProtectedToken.selector);
        locker.sweep(address(sy), owner, 1e18);
    }

    function test_sweep_revertsForAsset() public {
        vm.prank(owner);
        vm.expectRevert(PYTLocker.CannotSweepProtectedToken.selector);
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
        locker.deposit(depositAmount);

        _accrueYield(yieldAmount);
        locker.harvest();

        uint256 claimableAmount = locker.claimable(alice);
        assertApproxEqRel(claimableAmount, yieldAmount, 1e11);

        vm.prank(alice);
        locker.claim();

        assertApproxEqRel(asset.balanceOf(alice), yieldAmount, 1e11);
    }

    function testFuzz_noDilution(uint256 aliceDeposit, uint256 bobDeposit, uint256 yield1, uint256 yield2) public {
        aliceDeposit = bound(aliceDeposit, 1e18, 500e18);
        bobDeposit = bound(bobDeposit, 1e18, 500e18);
        yield1 = bound(yield1, 1e18, 100e18);
        yield2 = bound(yield2, 1e18, 100e18);

        vm.prank(alice);
        locker.deposit(aliceDeposit);

        _accrueYield(yield1);
        locker.harvest();

        uint256 aliceClaimableAfterYield1 = locker.claimable(alice);
        assertApproxEqRel(aliceClaimableAfterYield1, yield1, 1e11);

        vm.prank(bob);
        locker.deposit(bobDeposit);

        assertEq(locker.claimable(bob), 0);
        assertApproxEqRel(locker.claimable(alice), yield1, 1e11);

        _accrueYield(yield2);
        locker.harvest();

        uint256 totalLocked = aliceDeposit + bobDeposit;
        uint256 aliceShare2 = (yield2 * aliceDeposit) / totalLocked;
        uint256 bobShare2 = (yield2 * bobDeposit) / totalLocked;

        assertApproxEqRel(locker.claimable(alice), yield1 + aliceShare2, 1e11);
        assertApproxEqRel(locker.claimable(bob), bobShare2, 1e11);
    }
}
