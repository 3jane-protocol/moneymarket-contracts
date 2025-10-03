// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IUSD3 as USD3} from "../../../../src/usd3/interfaces/IUSD3.sol";
import {ISUSD3 as sUSD3} from "../../../../src/usd3/interfaces/ISUSD3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title Debt Floor Handler
 * @notice Handler contract for invariant testing of debt floor mechanism
 */
contract DebtFloorHandler is Test {
    USD3 public immutable usd3Strategy;
    sUSD3 public immutable susd3Strategy;
    IERC20 public immutable underlyingAsset;

    address[] public actors;
    mapping(address => bool) public isActor;
    mapping(address => uint256) public lastSUSD3DepositTime; // Track when actors deposit to sUSD3

    constructor(address _usd3Strategy, address _susd3Strategy, address _underlyingAsset) {
        usd3Strategy = USD3(_usd3Strategy);
        susd3Strategy = sUSD3(_susd3Strategy);
        underlyingAsset = IERC20(_underlyingAsset);

        // Create some test actors
        for (uint256 i = 0; i < 3; i++) {
            address actor = address(uint160(uint256(keccak256(abi.encode("actor", i)))));
            actors.push(actor);
            isActor[actor] = true;
        }
    }

    // USD3 Operations
    function depositUSD3(uint256 actorSeed, uint256 amount) public {
        address currentActor = actors[actorSeed % actors.length];
        vm.startPrank(currentActor);

        amount = bound(amount, 1e6, 100_000e6); // 1 to 100K USDC

        // Give actor USDC if needed
        uint256 balance = underlyingAsset.balanceOf(currentActor);
        if (balance < amount) {
            deal(address(underlyingAsset), currentActor, amount);
        }

        underlyingAsset.approve(address(usd3Strategy), amount);
        usd3Strategy.deposit(amount, currentActor);

        vm.stopPrank();
    }

    function withdrawUSD3(uint256 actorSeed, uint256 amount) public {
        address currentActor = actors[actorSeed % actors.length];
        vm.startPrank(currentActor);

        uint256 balance = usd3Strategy.balanceOf(currentActor);
        if (balance == 0) {
            vm.stopPrank();
            return;
        }

        // Check max withdrawable amount (in assets, not shares)
        uint256 maxWithdrawable = usd3Strategy.maxWithdraw(currentActor);
        if (maxWithdrawable == 0) {
            vm.stopPrank();
            return;
        }

        amount = bound(amount, 0, maxWithdrawable);
        if (amount > 0) {
            usd3Strategy.withdraw(amount, currentActor, currentActor);
        }

        vm.stopPrank();
    }

    // sUSD3 Operations
    function depositSUSD3(uint256 actorSeed, uint256 amount) public {
        address currentActor = actors[actorSeed % actors.length];
        vm.startPrank(currentActor);

        uint256 usd3Balance = usd3Strategy.balanceOf(currentActor);
        if (usd3Balance == 0) {
            vm.stopPrank();
            return;
        }

        uint256 depositLimit = susd3Strategy.availableDepositLimit(currentActor);
        if (depositLimit == 0) {
            vm.stopPrank();
            return;
        }

        amount = bound(amount, 0, usd3Balance > depositLimit ? depositLimit : usd3Balance);
        if (amount > 0) {
            usd3Strategy.approve(address(susd3Strategy), amount);
            susd3Strategy.deposit(amount, currentActor);
            // Track deposit time for lock period
            lastSUSD3DepositTime[currentActor] = block.timestamp;
        }

        vm.stopPrank();
    }

    function startCooldown(uint256 actorSeed, uint256 amount) public {
        address currentActor = actors[actorSeed % actors.length];
        vm.startPrank(currentActor);

        uint256 balance = susd3Strategy.balanceOf(currentActor);
        if (balance == 0) {
            vm.stopPrank();
            return;
        }

        // Check if lock period has passed (90 days default)
        uint256 lockDuration = 90 days; // Default commitment time
        if (
            lastSUSD3DepositTime[currentActor] > 0
                && block.timestamp < lastSUSD3DepositTime[currentActor] + lockDuration
        ) {
            // Still in lock period, skip
            vm.stopPrank();
            return;
        }

        amount = bound(amount, 0, balance);
        if (amount > 0) {
            // Use try-catch to handle any reverts gracefully
            try susd3Strategy.startCooldown(amount) {
                // Success
            } catch {
                // Failed, likely due to lock period or other constraints
            }
        }

        vm.stopPrank();
    }

    function withdrawSUSD3(uint256 actorSeed, uint256 amount) public {
        address currentActor = actors[actorSeed % actors.length];
        vm.startPrank(currentActor);

        uint256 withdrawLimit = susd3Strategy.availableWithdrawLimit(currentActor);
        if (withdrawLimit == 0) {
            vm.stopPrank();
            return;
        }

        amount = bound(amount, 0, withdrawLimit);
        if (amount > 0) {
            susd3Strategy.withdraw(amount, currentActor, currentActor);
        }

        vm.stopPrank();
    }

    // Helper to advance time
    function skipTime(uint256 timeSeed) public {
        uint256 timeToSkip = bound(timeSeed, 1 days, 100 days);
        skip(timeToSkip);
    }
}
