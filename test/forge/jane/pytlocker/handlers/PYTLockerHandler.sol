// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {PYTLocker} from "../../../../../src/jane/PYTLocker.sol";
import {MockAsset, MockSY, MockYT} from "../mocks/MockPendle.sol";
import {IERC20} from "../../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PYTLockerHandler is CommonBase, StdUtils, StdCheats {
    PYTLocker public locker;
    MockYT public yt;
    MockSY public sy;
    MockAsset public asset;

    // Ghost variables for invariant checking
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalYieldHarvested;
    uint256 public ghost_totalClaimed;
    uint256 public ghost_lastAccYieldPerToken;

    // Track per-user state for proportional distribution checks
    mapping(address => uint256) public ghost_userDeposits;
    mapping(address => uint256) public ghost_userClaimed;
    mapping(address => uint256) public ghost_userYieldAtDeposit;
    mapping(address => bool) public ghost_userHasDeposited;

    // Actor pool for multi-user testing
    address[] public actors;
    mapping(address => bool) public isActor;

    // Call counters for debugging
    uint256 public depositCalls;
    uint256 public harvestCalls;
    uint256 public claimCalls;

    constructor(PYTLocker _locker, MockYT _yt, MockSY _sy, MockAsset _asset) {
        locker = _locker;
        yt = _yt;
        sy = _sy;
        asset = _asset;

        // Initialize actor pool
        actors.push(address(0x1001));
        actors.push(address(0x1002));
        actors.push(address(0x1003));
        actors.push(address(0x1004));
        actors.push(address(0x1005));

        for (uint256 i = 0; i < actors.length; i++) {
            isActor[actors[i]] = true;
        }
    }

    function _getActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = _getActor(actorSeed);
        amount = bound(amount, 1e18, 100e18);

        // Track if this is user's first deposit
        bool isFirstDeposit = !ghost_userHasDeposited[actor];

        // Mint YT to actor and approve
        yt.mint(actor, amount);

        vm.startPrank(actor);
        yt.approve(address(locker), amount);
        locker.deposit(address(yt), amount);
        vm.stopPrank();

        // Update ghost state
        ghost_totalDeposited += amount;
        ghost_userDeposits[actor] += amount;
        ghost_userHasDeposited[actor] = true;

        // Track yield at time of first deposit (for no-dilution check)
        if (isFirstDeposit) {
            ghost_userYieldAtDeposit[actor] = ghost_totalYieldHarvested;
        }

        depositCalls++;
    }

    function harvest(uint256 yieldAmount) external {
        // Variable yield rates: 0 to 10e18 per harvest
        yieldAmount = bound(yieldAmount, 0, 10e18);

        // Skip if no depositors or zero yield
        if (locker.totalSupply(address(yt)) == 0 || yieldAmount == 0) return;

        // Store previous accYieldPerToken for monotonicity check
        ghost_lastAccYieldPerToken = locker.accYieldPerToken(address(yt));

        // Simulate yield accrual
        sy.mint(address(yt), yieldAmount);
        sy.fundAsset(yieldAmount);
        yt.accrueInterest(address(locker), yieldAmount);

        locker.harvest(address(yt));

        ghost_totalYieldHarvested += yieldAmount;
        harvestCalls++;
    }

    function claim(uint256 actorSeed) external {
        address actor = _getActor(actorSeed);

        // Skip if actor has no deposits
        if (locker.balanceOf(address(yt), actor) == 0) return;

        uint256 beforeBal = asset.balanceOf(actor);

        vm.prank(actor);
        locker.claim(address(yt));

        uint256 claimed = asset.balanceOf(actor) - beforeBal;
        ghost_totalClaimed += claimed;
        ghost_userClaimed[actor] += claimed;

        claimCalls++;
    }

    // View functions for invariant checks

    function getActorCount() external view returns (uint256) {
        return actors.length;
    }

    function getActor(uint256 index) external view returns (address) {
        return actors[index];
    }

    function getSumOfBalances() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += locker.balanceOf(address(yt), actors[i]);
        }
    }

    function getSumOfClaimable() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += locker.claimable(address(yt), actors[i]);
        }
    }

    function getTotalClaimedByUsers() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += ghost_userClaimed[actors[i]];
        }
    }
}
