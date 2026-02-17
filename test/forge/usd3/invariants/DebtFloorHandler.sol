// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IUSD3 as USD3} from "../../../../src/usd3/interfaces/IUSD3.sol";
import {ISUSD3 as sUSD3} from "../../../../src/usd3/interfaces/ISUSD3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

/**
 * @title DebtFloorHandler
 * @notice Handler for debt-floor focused invariant testing
 */
contract DebtFloorHandler is Test {
    USD3 public immutable usd3Strategy;
    sUSD3 public immutable susd3Strategy;
    IERC20 public immutable underlyingAsset;
    address public immutable keeper;

    address[] public actors;

    uint256 public attemptedDepositUSD3;
    uint256 public successfulDepositUSD3;
    uint256 public attemptedWithdrawUSD3;
    uint256 public successfulWithdrawUSD3;
    uint256 public attemptedDepositSUSD3;
    uint256 public successfulDepositSUSD3;
    uint256 public attemptedStartCooldown;
    uint256 public successfulStartCooldown;
    uint256 public attemptedCancelCooldown;
    uint256 public successfulCancelCooldown;
    uint256 public attemptedWithdrawSUSD3;
    uint256 public successfulWithdrawSUSD3;
    uint256 public attemptedReport;
    uint256 public successfulReport;
    uint256 public attemptedSkipTime;
    uint256 public successfulSkipTime;

    constructor(
        address _usd3Strategy,
        address _susd3Strategy,
        address _underlyingAsset,
        address _keeper,
        address[] memory _actors
    ) {
        usd3Strategy = USD3(_usd3Strategy);
        susd3Strategy = sUSD3(_susd3Strategy);
        underlyingAsset = IERC20(_underlyingAsset);
        keeper = _keeper;
        actors = _actors;
    }

    function depositUSD3(uint256 actorSeed, uint256 amountSeed) public {
        ++attemptedDepositUSD3;
        address actor = actors[actorSeed % actors.length];

        uint256 maxDeposit = usd3Strategy.availableDepositLimit(actor);
        if (maxDeposit == 0) return;

        uint256 maxAssets = maxDeposit;
        uint256 minAssets = maxAssets < 1e6 ? maxAssets : 1e6;
        uint256 assets = bound(amountSeed, minAssets, maxAssets);

        uint256 balance = underlyingAsset.balanceOf(actor);
        if (balance < assets) deal(address(underlyingAsset), actor, assets);

        vm.startPrank(actor);
        underlyingAsset.approve(address(usd3Strategy), assets);
        try usd3Strategy.deposit(assets, actor) returns (uint256 sharesOut) {
            if (sharesOut > 0) ++successfulDepositUSD3;
        } catch {}
        vm.stopPrank();
    }

    function withdrawUSD3(uint256 actorSeed, uint256 sharesSeed) public {
        ++attemptedWithdrawUSD3;
        address actor = actors[actorSeed % actors.length];

        uint256 sharesBalance = IERC20(address(usd3Strategy)).balanceOf(actor);
        if (sharesBalance == 0) return;

        uint256 maxWithdraw = usd3Strategy.availableWithdrawLimit(actor);
        if (maxWithdraw == 0) return;
        uint256 maxRedeemShares = ITokenizedStrategy(address(usd3Strategy)).convertToShares(maxWithdraw);
        uint256 maxShares = sharesBalance < maxRedeemShares ? sharesBalance : maxRedeemShares;
        if (maxShares == 0) return;

        uint256 shares = bound(sharesSeed, 1, maxShares);
        vm.prank(actor);
        try usd3Strategy.redeem(shares, actor, actor) returns (uint256 assetsOut) {
            if (assetsOut > 0) ++successfulWithdrawUSD3;
        } catch {}
    }

    function depositSUSD3(uint256 actorSeed, uint256 amountSeed) public {
        ++attemptedDepositSUSD3;
        address actor = actors[actorSeed % actors.length];

        uint256 usd3Balance = IERC20(address(usd3Strategy)).balanceOf(actor);
        uint256 depositLimit = susd3Strategy.availableDepositLimit(actor);
        uint256 maxAssets = usd3Balance < depositLimit ? usd3Balance : depositLimit;
        if (maxAssets == 0) return;

        uint256 assets = bound(amountSeed, 1, maxAssets);
        vm.startPrank(actor);
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), assets);
        try susd3Strategy.deposit(assets, actor) returns (uint256 sharesOut) {
            if (sharesOut > 0) ++successfulDepositSUSD3;
        } catch {}
        vm.stopPrank();
    }

    function startCooldown(uint256 actorSeed, uint256 sharesSeed) public {
        ++attemptedStartCooldown;
        address actor = actors[actorSeed % actors.length];

        uint256 sharesBalance = IERC20(address(susd3Strategy)).balanceOf(actor);
        if (sharesBalance == 0) return;
        if (block.timestamp < susd3Strategy.lockedUntil(actor)) return;

        uint256 shares = bound(sharesSeed, 1, sharesBalance);
        vm.prank(actor);
        try susd3Strategy.startCooldown(shares) {
            ++successfulStartCooldown;
        } catch {}
    }

    function cancelCooldown(uint256 actorSeed) public {
        ++attemptedCancelCooldown;
        address actor = actors[actorSeed % actors.length];

        (,, uint256 cooldownShares) = susd3Strategy.getCooldownStatus(actor);
        if (cooldownShares == 0) return;

        vm.prank(actor);
        try susd3Strategy.cancelCooldown() {
            ++successfulCancelCooldown;
        } catch {}
    }

    function withdrawSUSD3(uint256 actorSeed, uint256 amountSeed) public {
        ++attemptedWithdrawSUSD3;
        address actor = actors[actorSeed % actors.length];

        uint256 withdrawLimit = susd3Strategy.availableWithdrawLimit(actor);
        if (withdrawLimit == 0) return;

        uint256 assets = bound(amountSeed, 1, withdrawLimit);
        vm.prank(actor);
        try susd3Strategy.withdraw(assets, actor, actor) returns (uint256 sharesBurned) {
            if (sharesBurned > 0) ++successfulWithdrawSUSD3;
        } catch {}
    }

    function reportUSD3() public {
        ++attemptedReport;
        vm.prank(keeper);
        try usd3Strategy.report() returns (uint256, uint256) {
            ++successfulReport;
        } catch {}
    }

    function skipTime(uint256 timeSeed) public {
        ++attemptedSkipTime;
        // Bias half the warps to shorter jumps so cooldown windows are exercised.
        uint256 timeToSkip = timeSeed % 2 == 0 ? bound(timeSeed, 1 hours, 14 days) : bound(timeSeed, 1 days, 120 days);
        skip(timeToSkip);
        ++successfulSkipTime;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        if (actors.length == 0) return address(0);
        return actors[index % actors.length];
    }
}
