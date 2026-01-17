// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test, console2} from "forge-std/Test.sol";
import {PYTLocker} from "../../../../src/jane/PYTLocker.sol";
import {MockAsset, MockSY, MockYT} from "./mocks/MockPendle.sol";
import {PYTLockerHandler} from "./handlers/PYTLockerHandler.sol";

contract PYTLockerInvariantTest is Test {
    PYTLocker public locker;
    MockAsset public asset;
    MockSY public sy;
    MockYT public yt;
    PYTLockerHandler public handler;

    address public owner = address(0xABCD);
    uint256 public constant YT_EXPIRY = 365 days;

    function setUp() public {
        // Deploy mocks
        asset = new MockAsset();
        sy = new MockSY(address(asset));
        yt = new MockYT(address(sy), block.timestamp + YT_EXPIRY);

        // Deploy locker
        vm.prank(owner);
        locker = new PYTLocker(owner);

        vm.prank(owner);
        locker.addMarket(address(yt), address(sy), address(asset));

        // Deploy handler
        handler = new PYTLockerHandler(locker, yt, sy, asset);

        // Target only the handler for fuzzing
        targetContract(address(handler));

        // Only target the main actions
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = PYTLockerHandler.deposit.selector;
        selectors[1] = PYTLockerHandler.harvest.selector;
        selectors[2] = PYTLockerHandler.claim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice totalSupply must equal sum of all user balances
    function invariant_supplyConservation() public view {
        uint256 totalSupply = locker.totalSupply(address(yt));
        uint256 sumOfBalances = handler.getSumOfBalances();

        assertEq(totalSupply, sumOfBalances, "Supply conservation violated");
    }

    /// @notice Sum of claimable + claimed must not exceed total yield harvested
    function invariant_yieldConservation() public view {
        uint256 sumClaimable = handler.getSumOfClaimable();
        uint256 sumClaimed = handler.getTotalClaimedByUsers();
        uint256 totalYield = handler.ghost_totalYieldHarvested();

        assertLe(
            sumClaimable + sumClaimed,
            totalYield + 1, // +1 for rounding tolerance
            "Yield conservation violated: distributed more than harvested"
        );
    }

    /// @notice accYieldPerToken should only increase (never decrease)
    function invariant_accYieldPerTokenMonotonic() public view {
        uint256 current = locker.accYieldPerToken(address(yt));
        uint256 previous = handler.ghost_lastAccYieldPerToken();

        // Only check if there was a previous value recorded
        if (handler.harvestCalls() > 0) {
            assertGe(current, previous, "accYieldPerToken decreased");
        }
    }

    /// @notice Total deposited in handler should match totalSupply in locker
    function invariant_depositTracking() public view {
        uint256 totalSupply = locker.totalSupply(address(yt));
        uint256 ghostDeposited = handler.ghost_totalDeposited();

        assertEq(totalSupply, ghostDeposited, "Deposit tracking mismatch");
    }

    /// @notice YT balance of locker should equal totalSupply
    function invariant_lockerHoldsAllYT() public view {
        uint256 lockerYTBalance = yt.balanceOf(address(locker));
        uint256 totalSupply = locker.totalSupply(address(yt));

        assertEq(lockerYTBalance, totalSupply, "Locker YT balance != totalSupply");
    }

    /// @notice Asset balance of locker should be >= sum of all claimable
    function invariant_lockerSolvent() public view {
        uint256 lockerAssetBalance = asset.balanceOf(address(locker));
        uint256 sumClaimable = handler.getSumOfClaimable();

        assertGe(lockerAssetBalance, sumClaimable, "Locker insolvent: can't pay all claims");
    }

    /// @notice Debug helper - called after each invariant run
    function invariant_callSummary() public view {
        console2.log("--- Call Summary ---");
        console2.log("Deposits:", handler.depositCalls());
        console2.log("Harvests:", handler.harvestCalls());
        console2.log("Claims:", handler.claimCalls());
        console2.log("Total Yield:", handler.ghost_totalYieldHarvested());
        console2.log("Total Claimed:", handler.ghost_totalClaimed());
        console2.log("accYieldPerToken:", locker.accYieldPerToken(address(yt)));
    }
}
