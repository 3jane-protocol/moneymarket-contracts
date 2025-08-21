// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {USD3} from "../../USD3.sol";
import {sUSD3} from "../../sUSD3.sol";
import {ERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/**
 * @title InvariantHandler
 * @notice Handler contract for invariant testing
 * @dev Wraps strategy calls to enable proper fuzzing
 */
contract InvariantHandler is Test {
    USD3 public immutable usd3Strategy;
    sUSD3 public immutable susd3Strategy;
    ERC20 public immutable underlyingAsset;

    address[] public actors;

    constructor(
        address _usd3Strategy,
        address _susd3Strategy,
        address _underlyingAsset,
        address[] memory _actors
    ) {
        usd3Strategy = USD3(_usd3Strategy);
        susd3Strategy = sUSD3(_susd3Strategy);
        underlyingAsset = ERC20(_underlyingAsset);
        actors = _actors;
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        if (actors.length == 0) return;

        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1e6, 1000e6); // 1 to 1000 USDC

        uint256 balance = underlyingAsset.balanceOf(actor);
        if (balance < amount) return;

        // Simulate actor depositing
        vm.prank(actor);
        try usd3Strategy.deposit(amount, actor) {
            // Success
        } catch {
            // Ignore failures (may hit limits)
        }
    }

    function withdraw(uint256 actorSeed, uint256 shares) external {
        if (actors.length == 0) return;

        address actor = actors[actorSeed % actors.length];
        uint256 balance = ERC20(address(usd3Strategy)).balanceOf(actor);

        if (balance == 0) return;
        shares = bound(shares, 0, balance);

        vm.prank(actor);
        try usd3Strategy.redeem(shares, actor, actor) {
            // Success
        } catch {
            // Ignore failures
        }
    }

    function depositSUSD3(uint256 actorSeed, uint256 amount) external {
        if (actors.length == 0) return;

        address actor = actors[actorSeed % actors.length];
        uint256 usd3Balance = ERC20(address(usd3Strategy)).balanceOf(actor);

        if (usd3Balance == 0) return;
        amount = bound(amount, 0, usd3Balance / 10); // Max 10% to respect subordination

        vm.prank(actor);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), amount);

        vm.prank(actor);
        try susd3Strategy.deposit(amount, actor) {
            // Success
        } catch {
            // Ignore failures
        }
    }
}
