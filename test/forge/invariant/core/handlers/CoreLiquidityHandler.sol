// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {ERC20Mock} from "../../../../../src/mocks/ERC20Mock.sol";
import {IMorpho, Id, MarketParams} from "../../../../../src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../../../../src/libraries/MarketParamsLib.sol";
import {MorphoLib} from "../../../../../src/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "../../../../../src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "../../../../../src/libraries/SharesMathLib.sol";

contract CoreLiquidityHandler is Test {
    bytes4 internal constant SUPPLY_SELECTOR =
        bytes4(keccak256("supply((address,address,address,address,uint256,address),uint256,uint256,address,bytes)"));
    bytes4 internal constant WITHDRAW_SELECTOR = bytes4(
        keccak256("withdraw((address,address,address,address,uint256,address),uint256,uint256,address,address)")
    );
    bytes4 internal constant ACCRUE_INTEREST_SELECTOR =
        bytes4(keccak256("accrueInterest((address,address,address,address,uint256,address))"));

    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;

    uint256 internal constant MAX_TEST_ASSETS = 1e24;
    uint256 internal constant MAX_TEST_SHARES = MAX_TEST_ASSETS * SharesMathLib.VIRTUAL_SHARES;

    IMorpho public immutable morpho;
    ERC20Mock public immutable loanToken;

    Id[] public marketIds;
    address[] public actors;
    uint256 public successfulSupplyAssets;
    uint256 public successfulSupplyShares;
    uint256 public successfulWithdrawAssets;
    uint256 public successfulWithdrawShares;
    uint256 public successfulAccrueInterest;
    uint256 public attemptedSupplyAssets;
    uint256 public attemptedSupplyShares;

    constructor(address _morpho, address _loanToken, Id[] memory _marketIds, address[] memory _actors) {
        morpho = IMorpho(_morpho);
        loanToken = ERC20Mock(_loanToken);

        for (uint256 i; i < _marketIds.length; ++i) {
            marketIds.push(_marketIds[i]);
        }
        for (uint256 i; i < _actors.length; ++i) {
            actors.push(_actors[i]);
        }
    }

    function supplyAssets(uint256 marketSeed, uint256 callerSeed, uint256 onBehalfSeed, uint256 assetsSeed) external {
        attemptedSupplyAssets++;
        Id id = _marketId(marketSeed);
        MarketParams memory marketParams = morpho.idToMarketParams(id);
        address caller = _actor(callerSeed);
        address onBehalf = _actor(onBehalfSeed);

        uint256 currentAssets = morpho.expectedSupplyAssets(marketParams, onBehalf);
        if (currentAssets >= MAX_TEST_ASSETS) return;

        uint256 assets = bound(assetsSeed, 1, MAX_TEST_ASSETS - currentAssets);
        loanToken.setBalance(caller, assets);

        vm.startPrank(caller);
        loanToken.approve(address(morpho), type(uint256).max);
        (bool ok,) = address(morpho)
            .call(abi.encodeWithSelector(SUPPLY_SELECTOR, marketParams, assets, uint256(0), onBehalf, ""));
        vm.stopPrank();
        if (ok) successfulSupplyAssets++;
    }

    function supplyShares(uint256 marketSeed, uint256 callerSeed, uint256 onBehalfSeed, uint256 sharesSeed) external {
        attemptedSupplyShares++;
        Id id = _marketId(marketSeed);
        MarketParams memory marketParams = morpho.idToMarketParams(id);
        address caller = _actor(callerSeed);
        address onBehalf = _actor(onBehalfSeed);

        uint256 currentShares = morpho.supplyShares(id, onBehalf);
        if (currentShares >= MAX_TEST_SHARES) return;

        uint256 shares = bound(sharesSeed, 1, MAX_TEST_SHARES - currentShares);
        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) = morpho.expectedMarketBalances(marketParams);
        uint256 assetsNeeded = shares.toAssetsUp(totalSupplyAssets, totalSupplyShares);
        if (assetsNeeded == 0) return;

        loanToken.setBalance(caller, assetsNeeded);

        vm.startPrank(caller);
        loanToken.approve(address(morpho), type(uint256).max);
        (bool ok,) = address(morpho)
            .call(abi.encodeWithSelector(SUPPLY_SELECTOR, marketParams, uint256(0), shares, onBehalf, ""));
        vm.stopPrank();
        if (ok) successfulSupplyShares++;
    }

    function withdrawAssets(
        uint256 marketSeed,
        uint256 callerSeed,
        uint256 onBehalfSeed,
        uint256 receiverSeed,
        uint256 assetsSeed
    ) external {
        Id id = _marketId(marketSeed);
        MarketParams memory marketParams = morpho.idToMarketParams(id);
        address caller = _actor(callerSeed);
        address onBehalf = _actor(onBehalfSeed);
        address receiver = _actor(receiverSeed);

        uint256 supplyBalance = morpho.expectedSupplyAssets(marketParams, onBehalf);
        uint256 totalSupplyAssets = morpho.totalSupplyAssets(id);
        uint256 totalBorrowAssets = morpho.totalBorrowAssets(id);
        uint256 liquidity = totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;
        uint256 maxAssets = supplyBalance < liquidity ? supplyBalance : liquidity;
        if (maxAssets == 0) return;

        uint256 assets = bound(assetsSeed, 1, maxAssets);

        vm.prank(caller);
        (bool ok,) = address(morpho)
            .call(abi.encodeWithSelector(WITHDRAW_SELECTOR, marketParams, assets, uint256(0), onBehalf, receiver));
        if (ok) successfulWithdrawAssets++;
    }

    function withdrawShares(
        uint256 marketSeed,
        uint256 callerSeed,
        uint256 onBehalfSeed,
        uint256 receiverSeed,
        uint256 sharesSeed
    ) external {
        Id id = _marketId(marketSeed);
        MarketParams memory marketParams = morpho.idToMarketParams(id);
        address caller = _actor(callerSeed);
        address onBehalf = _actor(onBehalfSeed);
        address receiver = _actor(receiverSeed);

        uint256 userSupplyShares = morpho.supplyShares(id, onBehalf);
        if (userSupplyShares == 0) return;

        uint256 totalSupplyAssets = morpho.totalSupplyAssets(id);
        uint256 totalBorrowAssets = morpho.totalBorrowAssets(id);
        uint256 totalSupplyShares = morpho.totalSupplyShares(id);

        uint256 liquidity = totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;
        uint256 liquidityShares = liquidity.toSharesDown(totalSupplyAssets, totalSupplyShares);
        uint256 maxShares = userSupplyShares < liquidityShares ? userSupplyShares : liquidityShares;
        if (maxShares == 0) return;

        uint256 shares = bound(sharesSeed, 1, maxShares);

        vm.prank(caller);
        (bool ok,) = address(morpho)
            .call(abi.encodeWithSelector(WITHDRAW_SELECTOR, marketParams, uint256(0), shares, onBehalf, receiver));
        if (ok) successfulWithdrawShares++;
    }

    function accrueInterest(uint256 marketSeed) external {
        Id id = _marketId(marketSeed);
        (bool ok,) = address(morpho).call(abi.encodeWithSelector(ACCRUE_INTEREST_SELECTOR, morpho.idToMarketParams(id)));
        if (ok) successfulAccrueInterest++;
    }

    function _marketId(uint256 seed) internal view returns (Id) {
        return marketIds[seed % marketIds.length];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
}
