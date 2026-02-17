// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {sUSD3} from "../../../../src/usd3/sUSD3.sol";
import {ERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

/**
 * @title InvariantHandler
 * @notice Handler contract for USD3/sUSD3 invariant testing
 * @dev Tracks attempted/successful calls to surface no-op fuzz campaigns
 */
contract InvariantHandler is Test {
    USD3 public immutable usd3Strategy;
    sUSD3 public immutable susd3Strategy;
    ERC20 public immutable underlyingAsset;
    address public immutable keeper;

    address[] public actors;

    uint256 public attemptedDepositUSD3;
    uint256 public successfulDepositUSD3;
    uint256 public attemptedRedeemUSD3;
    uint256 public successfulRedeemUSD3;
    uint256 public attemptedDepositSUSD3;
    uint256 public successfulDepositSUSD3;
    uint256 public attemptedStartCooldownSUSD3;
    uint256 public successfulStartCooldownSUSD3;
    uint256 public attemptedCancelCooldownSUSD3;
    uint256 public successfulCancelCooldownSUSD3;
    uint256 public attemptedWithdrawSUSD3;
    uint256 public successfulWithdrawSUSD3;
    uint256 public attemptedTransferUSD3;
    uint256 public successfulTransferUSD3;
    uint256 public attemptedTransferSUSD3;
    uint256 public successfulTransferSUSD3;
    uint256 public attemptedReportUSD3;
    uint256 public successfulReportUSD3;
    uint256 public attemptedWarpTime;
    uint256 public successfulWarpTime;
    uint256 public attemptedProfitReports;
    uint256 public successfulProfitReports;
    uint256 public attemptedLossReports;
    uint256 public successfulLossReports;
    uint256 public observedLossReportsWithLocked;
    uint256 public maxPpsIncreaseOnLossWithLocked;

    constructor(
        address _usd3Strategy,
        address _susd3Strategy,
        address _underlyingAsset,
        address _keeper,
        address[] memory _actors
    ) {
        usd3Strategy = USD3(_usd3Strategy);
        susd3Strategy = sUSD3(_susd3Strategy);
        underlyingAsset = ERC20(_underlyingAsset);
        keeper = _keeper;
        actors = _actors;
    }

    function depositUSD3(uint256 actorSeed, uint256 amountSeed) external {
        ++attemptedDepositUSD3;
        if (actors.length == 0) return;

        address actor = actors[actorSeed % actors.length];
        uint256 maxDeposit = usd3Strategy.availableDepositLimit(actor);
        uint256 balance = underlyingAsset.balanceOf(actor);
        uint256 maxAssets = balance < maxDeposit ? balance : maxDeposit;
        if (maxAssets == 0) return;
        uint256 minAssets = maxAssets < 1e6 ? maxAssets : 1e6;
        uint256 assets = bound(amountSeed, minAssets, maxAssets);

        vm.prank(actor);
        try usd3Strategy.deposit(assets, actor) returns (uint256 mintedShares) {
            if (mintedShares > 0) ++successfulDepositUSD3;
        } catch {}
    }

    function redeemUSD3(uint256 actorSeed, uint256 sharesSeed) external {
        ++attemptedRedeemUSD3;
        if (actors.length == 0) return;

        address actor = actors[actorSeed % actors.length];
        uint256 sharesBalance = ERC20(address(usd3Strategy)).balanceOf(actor);
        if (sharesBalance == 0) return;

        uint256 maxWithdraw = usd3Strategy.availableWithdrawLimit(actor);
        if (maxWithdraw == 0) return;

        uint256 maxRedeemShares = ITokenizedStrategy(address(usd3Strategy)).convertToShares(maxWithdraw);
        if (maxRedeemShares == 0) return;
        uint256 maxShares = sharesBalance < maxRedeemShares ? sharesBalance : maxRedeemShares;
        if (maxShares == 0) return;

        uint256 shares = bound(sharesSeed, 1, maxShares);
        vm.prank(actor);
        try usd3Strategy.redeem(shares, actor, actor) returns (uint256 assetsOut) {
            if (assetsOut > 0) ++successfulRedeemUSD3;
        } catch {}
    }

    function depositSUSD3(uint256 actorSeed, uint256 amountSeed) external {
        ++attemptedDepositSUSD3;
        if (actors.length == 0) return;

        address actor = actors[actorSeed % actors.length];
        uint256 usd3Balance = ERC20(address(usd3Strategy)).balanceOf(actor);
        if (usd3Balance == 0) return;

        uint256 depositLimit = susd3Strategy.availableDepositLimit(actor);
        if (depositLimit == 0) return;
        uint256 maxAssets = usd3Balance < depositLimit ? usd3Balance : depositLimit;
        if (maxAssets == 0) return;

        uint256 assets = bound(amountSeed, 1, maxAssets);
        vm.startPrank(actor);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), assets);
        try susd3Strategy.deposit(assets, actor) returns (uint256 mintedShares) {
            if (mintedShares > 0) ++successfulDepositSUSD3;
        } catch {}
        vm.stopPrank();
    }

    function startCooldownSUSD3(uint256 actorSeed, uint256 sharesSeed) external {
        ++attemptedStartCooldownSUSD3;
        if (actors.length == 0) return;

        address actor = actors[actorSeed % actors.length];
        uint256 sharesBalance = ERC20(address(susd3Strategy)).balanceOf(actor);
        if (sharesBalance == 0) return;
        if (block.timestamp < susd3Strategy.lockedUntil(actor)) return;

        uint256 shares = bound(sharesSeed, 1, sharesBalance);
        vm.prank(actor);
        try susd3Strategy.startCooldown(shares) {
            ++successfulStartCooldownSUSD3;
        } catch {}
    }

    function cancelCooldownSUSD3(uint256 actorSeed) external {
        ++attemptedCancelCooldownSUSD3;
        if (actors.length == 0) return;

        address actor = actors[actorSeed % actors.length];
        (,, uint256 cooldownShares) = susd3Strategy.getCooldownStatus(actor);
        if (cooldownShares == 0) return;

        vm.prank(actor);
        try susd3Strategy.cancelCooldown() {
            ++successfulCancelCooldownSUSD3;
        } catch {}
    }

    function withdrawSUSD3(uint256 actorSeed, uint256 assetsSeed) external {
        ++attemptedWithdrawSUSD3;
        if (actors.length == 0) return;

        address actor = actors[actorSeed % actors.length];
        uint256 maxWithdraw = susd3Strategy.availableWithdrawLimit(actor);
        if (maxWithdraw == 0) return;

        uint256 assets = bound(assetsSeed, 1, maxWithdraw);
        vm.prank(actor);
        try susd3Strategy.withdraw(assets, actor, actor) returns (uint256 burnedShares) {
            if (burnedShares > 0) ++successfulWithdrawSUSD3;
        } catch {}
    }

    function transferUSD3(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        ++attemptedTransferUSD3;
        if (actors.length == 0) return;

        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        if (from == to) return;

        uint256 balance = ERC20(address(usd3Strategy)).balanceOf(from);
        if (balance == 0) return;

        uint256 amount = bound(amountSeed, 1, balance);
        vm.prank(from);
        try usd3Strategy.transfer(to, amount) returns (bool ok) {
            if (ok) ++successfulTransferUSD3;
        } catch {}
    }

    function transferSUSD3(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        ++attemptedTransferSUSD3;
        if (actors.length == 0) return;

        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        if (from == to) return;

        uint256 balance = ERC20(address(susd3Strategy)).balanceOf(from);
        if (balance == 0) return;

        uint256 amount = bound(amountSeed, 1, balance);
        vm.prank(from);
        try susd3Strategy.transfer(to, amount) returns (bool ok) {
            if (ok) ++successfulTransferSUSD3;
        } catch {}
    }

    function reportUSD3() external {
        ++attemptedReportUSD3;
        vm.prank(keeper);
        try usd3Strategy.report() returns (uint256, uint256) {
            ++successfulReportUSD3;
        } catch {}
    }

    function warpTime(uint256 secondsSeed) external {
        ++attemptedWarpTime;
        uint256 delta = bound(secondsSeed, 1 hours, 120 days);
        vm.warp(block.timestamp + delta);
        vm.roll(block.number + 1);
        ++successfulWarpTime;
    }

    function simulateProfitAndReport(uint256 profitSeed) external {
        ++attemptedProfitReports;

        (uint256 totalSupplyAssets, uint256 upperSlotBits) = _marketSupplyAssetsAndUpper();
        if (totalSupplyAssets == 0) return;

        uint256 maxProfit = totalSupplyAssets / 5;
        if (maxProfit < 1e6) maxProfit = 1e6;
        uint256 profit = bound(profitSeed, 1e6, maxProfit);
        uint256 newTotalSupplyAssets = totalSupplyAssets + profit;

        _writeMarketSupplyAssets(upperSlotBits, newTotalSupplyAssets);
        vm.prank(keeper);
        try usd3Strategy.report() returns (uint256, uint256) {
            ++successfulProfitReports;
        } catch {}
    }

    function simulateLossAndReport(uint256 lossSeed) external {
        ++attemptedLossReports;

        (uint256 totalSupplyAssets, uint256 upperSlotBits) = _marketSupplyAssetsAndUpper();
        if (totalSupplyAssets <= 1e6) return;

        uint256 maxLoss = totalSupplyAssets / 5;
        if (maxLoss < 1e6) maxLoss = 1e6;
        if (maxLoss >= totalSupplyAssets) maxLoss = totalSupplyAssets - 1;
        uint256 loss = bound(lossSeed, 1e6, maxLoss);

        uint256 ppsBefore = _pricePerShare();
        uint256 lockedSharesBefore = ERC20(address(usd3Strategy)).balanceOf(address(usd3Strategy));
        uint256 susd3SharesBefore = ERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy));

        _writeMarketSupplyAssets(upperSlotBits, totalSupplyAssets - loss);
        vm.prank(keeper);
        try usd3Strategy.report() returns (uint256, uint256 reportedLoss) {
            ++successfulLossReports;
            if (reportedLoss > 0 && lockedSharesBefore > 0 && susd3SharesBefore > 0) {
                ++observedLossReportsWithLocked;
                uint256 ppsAfter = _pricePerShare();
                if (ppsAfter > ppsBefore) {
                    uint256 increase = ppsAfter - ppsBefore;
                    if (increase > maxPpsIncreaseOnLossWithLocked) maxPpsIncreaseOnLossWithLocked = increase;
                }
            }
        } catch {}
    }

    // Backwards-compatible entrypoints retained for old selector names.
    function deposit(uint256 actorSeed, uint256 amount) external {
        this.depositUSD3(actorSeed, amount);
    }

    function withdraw(uint256 actorSeed, uint256 shares) external {
        this.redeemUSD3(actorSeed, shares);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        if (actors.length == 0) return address(0);
        return actors[index % actors.length];
    }

    function _marketSupplySlot() internal view returns (bytes32 marketSlot) {
        bytes32 marketId = keccak256(abi.encode(usd3Strategy.marketParams()));
        marketSlot = keccak256(abi.encode(marketId, uint256(3)));
    }

    function _marketSupplyAssetsAndUpper() internal view returns (uint256 totalSupplyAssets, uint256 upperSlotBits) {
        uint256 slotValue = uint256(vm.load(address(usd3Strategy.morphoCredit()), _marketSupplySlot()));
        totalSupplyAssets = uint256(uint128(slotValue));
        upperSlotBits = slotValue & (~uint256(type(uint128).max));
    }

    function _writeMarketSupplyAssets(uint256 upperSlotBits, uint256 totalSupplyAssets) internal {
        vm.store(
            address(usd3Strategy.morphoCredit()),
            _marketSupplySlot(),
            bytes32(upperSlotBits | uint256(uint128(totalSupplyAssets)))
        );
    }

    function _pricePerShare() internal view returns (uint256) {
        uint256 supply = ITokenizedStrategy(address(usd3Strategy)).totalSupply();
        if (supply == 0) return 0;
        return ITokenizedStrategy(address(usd3Strategy)).totalAssets() * 1e18 / supply;
    }
}
