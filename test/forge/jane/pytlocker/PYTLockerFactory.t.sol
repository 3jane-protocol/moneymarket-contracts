// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "../../../../lib/openzeppelin/contracts/access/Ownable.sol";
import {PYTLocker} from "../../../../src/jane/PYTLocker.sol";
import {PYTLockerFactory} from "../../../../src/jane/PYTLockerFactory.sol";
import {MockAsset, MockSY, MockYT} from "./mocks/MockPendle.sol";

contract PYTLockerFactoryTest is Test {
    PYTLockerFactory public factory;
    MockAsset public asset;
    MockSY public sy;
    MockYT public yt;

    address public owner = address(0x1);
    address public newOwner = address(0x2);
    address public alice = address(0x3);

    uint256 public constant YT_EXPIRY = 365 days;

    event LockerCreated(address indexed yt, address indexed locker, address sy, address asset, address owner);

    function setUp() public {
        asset = new MockAsset();
        sy = new MockSY(address(asset));
        yt = new MockYT(address(sy), block.timestamp + YT_EXPIRY);

        factory = new PYTLockerFactory(owner);
    }

    function test_createLocker_recordsAndEmits() public {
        address expectedLocker = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));

        vm.prank(owner);
        vm.expectEmit(true, true, false, true, address(factory));
        emit LockerCreated(address(yt), expectedLocker, address(sy), address(asset), owner);
        address locker = factory.createLocker(address(yt));

        assertEq(locker, expectedLocker);
        assertEq(factory.locker(address(yt)), locker);
        assertEq(factory.lockers(0), locker);
        assertEq(factory.numLockers(), 1);
        address[] memory allLockers = factory.allLockers();
        assertEq(allLockers.length, 1);
        assertEq(allLockers[0], locker);

        PYTLocker created = PYTLocker(locker);
        assertEq(created.owner(), owner);
        assertEq(created.yt(), address(yt));
        assertEq(created.sy(), address(sy));
        assertEq(created.asset(), address(asset));
        assertEq(created.maxSupply(), type(uint256).max);
    }

    function test_createLocker_revertsOnDuplicate() public {
        vm.startPrank(owner);
        factory.createLocker(address(yt));

        vm.expectRevert(PYTLockerFactory.LockerExists.selector);
        factory.createLocker(address(yt));
        vm.stopPrank();
    }

    function test_createLocker_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(PYTLockerFactory.ZeroAddress.selector);
        factory.createLocker(address(0));
    }

    function test_createLocker_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.createLocker(address(yt));
    }

    function test_createLocker_lockerOwnerFrozenAtCreation() public {
        vm.prank(owner);
        address firstLocker = factory.createLocker(address(yt));

        vm.prank(owner);
        factory.transferOwnership(newOwner);

        MockYT yt2 = new MockYT(address(sy), block.timestamp + YT_EXPIRY);

        vm.prank(newOwner);
        address secondLocker = factory.createLocker(address(yt2));

        assertEq(PYTLocker(firstLocker).owner(), owner);
        assertEq(PYTLocker(secondLocker).owner(), newOwner);
    }

    function test_createLocker_twoYTsSameSY_bothSucceed() public {
        MockYT yt2 = new MockYT(address(sy), block.timestamp + YT_EXPIRY);

        vm.startPrank(owner);
        address locker1 = factory.createLocker(address(yt));
        address locker2 = factory.createLocker(address(yt2));
        vm.stopPrank();

        assertEq(factory.numLockers(), 2);
        assertEq(factory.locker(address(yt)), locker1);
        assertEq(factory.locker(address(yt2)), locker2);
        assertEq(PYTLocker(locker1).sy(), address(sy));
        assertEq(PYTLocker(locker2).sy(), address(sy));
    }

    function test_numLockers_tracksLength() public {
        MockYT yt2 = new MockYT(address(sy), block.timestamp + YT_EXPIRY);

        assertEq(factory.numLockers(), 0);

        vm.prank(owner);
        factory.createLocker(address(yt));
        assertEq(factory.numLockers(), 1);

        vm.prank(owner);
        factory.createLocker(address(yt2));
        assertEq(factory.numLockers(), 2);
    }
}
