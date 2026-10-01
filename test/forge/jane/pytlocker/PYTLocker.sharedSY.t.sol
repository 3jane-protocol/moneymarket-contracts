// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {PYTLocker} from "../../../../src/jane/PYTLocker.sol";
import {PYTLockerFactory} from "../../../../src/jane/PYTLockerFactory.sol";
import {MockAsset, MockSY, MockYT} from "./mocks/MockPendle.sol";

contract PYTLockerSharedSYTest is Test {
    PYTLockerFactory public factory;
    MockAsset public asset;
    MockSY public sharedSy;
    MockYT public ytA;
    MockYT public ytB;
    PYTLocker public lockerA;
    PYTLocker public lockerB;

    address public owner = address(0x1);
    address public victim = address(0x2);
    address public attacker = address(0x3);

    uint256 public constant YT_EXPIRY = 365 days;

    function setUp() public {
        asset = new MockAsset();
        sharedSy = new MockSY(address(asset));
        ytA = new MockYT(address(sharedSy), block.timestamp + YT_EXPIRY);
        ytB = new MockYT(address(sharedSy), block.timestamp + YT_EXPIRY);
        factory = new PYTLockerFactory(owner);

        vm.startPrank(owner);
        lockerA = PYTLocker(factory.createLocker(address(ytA)));
        lockerB = PYTLocker(factory.createLocker(address(ytB)));
        vm.stopPrank();

        ytA.mint(victim, 100e18);
        ytB.mint(attacker, 100e18);

        vm.startPrank(victim);
        ytA.approve(address(lockerA), 100e18);
        lockerA.deposit(100e18);
        vm.stopPrank();

        vm.startPrank(attacker);
        ytB.approve(address(lockerB), 100e18);
        lockerB.deposit(100e18);
        vm.stopPrank();
    }

    function test_sharedSYYieldCannotBeCreditedToWrongLocker() public {
        uint256 yieldAmount = 100e18;

        sharedSy.mint(address(ytA), yieldAmount);
        sharedSy.fundAsset(yieldAmount);
        ytA.accrueInterest(address(lockerA), yieldAmount);

        assertEq(sharedSy.balanceOf(address(lockerA)), 0);
        assertEq(sharedSy.balanceOf(address(lockerB)), 0);

        lockerB.harvest();

        assertEq(lockerB.accYieldPerToken(), 0);
        assertEq(lockerB.claimable(attacker), 0);
        assertEq(asset.balanceOf(attacker), 0);

        lockerA.harvest();

        assertEq(lockerA.claimable(victim), yieldAmount);

        vm.prank(victim);
        lockerA.claim();

        assertEq(asset.balanceOf(victim), yieldAmount);
        assertEq(asset.balanceOf(attacker), 0);
    }

    function test_directRedeemYTAToLockerBProducesNoCredit() public {
        uint256 yieldAmount = 100e18;

        sharedSy.mint(address(ytA), yieldAmount);
        sharedSy.fundAsset(yieldAmount);
        ytA.accrueInterest(address(lockerA), yieldAmount);

        (uint256 interestOut,) = ytA.redeemDueInterestAndRewards(address(lockerB), true, true);

        assertEq(interestOut, 0);
        assertEq(sharedSy.balanceOf(address(lockerB)), 0);

        lockerB.harvest();

        assertEq(lockerB.accYieldPerToken(), 0);
        assertEq(lockerB.claimable(attacker), 0);
    }
}
