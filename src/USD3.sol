// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseHealthCheck, BaseStrategy, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho, MarketParams, Id} from "@3jane-morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@3jane-morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoLib} from "@3jane-morpho-blue/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "@3jane-morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@3jane-morpho-blue/libraries/SharesMathLib.sol";

contract USD3 is BaseHealthCheck {
    using SafeERC20 for ERC20;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    /// @notice Address for the Morpho contract.
    IMorpho public immutable morphoBlue;

    // these internal immutable vars can be accessed externally via marketParams()
    address internal immutable loanToken;
    address internal immutable collateralToken;
    address internal immutable oracle;
    address internal immutable irm;
    uint256 internal immutable lltv;
    address internal immutable creditLine;

    constructor(address _asset, address _morphoBlue, MarketParams memory _params) BaseHealthCheck(_asset, "USD3") {
        require(_morphoBlue != address(0), "!morpho");
        require(_asset == _params.loanToken, "!loantoken");

        morphoBlue = IMorpho(_morphoBlue);
        loanToken = _params.loanToken;
        collateralToken = _params.collateralToken;
        oracle = _params.oracle;
        irm = _params.irm;
        lltv = _params.lltv;
        creditLine = _params.creditLine;

        ERC20(_params.loanToken).forceApprove(_morphoBlue, type(uint256).max);
    }

    function symbol() external view returns (string memory) {
        return "USD3";
    }

    function marketId() external view returns (Id) {
        return _marketParams().id();
    }

    function marketParams() external view returns (MarketParams memory) {
        return _marketParams();
    }

    function _marketParams() internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: loanToken,
            collateralToken: collateralToken,
            oracle: oracle,
            irm: irm,
            lltv: lltv,
            creditLine: creditLine
        });
    }

    function getMarketLiquidity()
        internal
        view
        returns (uint256 totalSupplyAssets, uint256 totalShares, uint256 totalBorrowAssets, uint256 liquidity)
    {
        (totalSupplyAssets, totalShares, totalBorrowAssets,) = morphoBlue.expectedMarketBalances(_marketParams());
        liquidity = totalSupplyAssets - totalBorrowAssets;
    }

    function getPosition() internal view returns (uint256 shares, uint256 assetsMax, uint256 liquidity) {
        Id id = _marketParams().id();
        shares = morphoBlue.position(id, address(this)).supplyShares;
        uint256 totalSupplyAssets;
        uint256 totalShares;
        (totalSupplyAssets, totalShares,, liquidity) = getMarketLiquidity();
        assetsMax = shares.toAssetsDown(totalSupplyAssets, totalShares);
    }

    /// @inheritdoc BaseStrategy
    function _deployFunds(uint256 _amount) internal override {
        morphoBlue.supply(_marketParams(), _amount, 0, address(this), hex"");
    }

    /// @inheritdoc BaseStrategy
    function _freeFunds(uint256 amount) internal override {
        morphoBlue.accrueInterest(_marketParams());
        (uint256 shares, uint256 assetsMax, uint256 liquidity) = getPosition();

        if (amount >= assetsMax && assetsMax <= liquidity) {
            // We use shares instead of amount
            amount = 0;
        } else {
            // We will use amount to indicate how much we want to withdraw
            shares = 0;
            // cap amount to withdraw if liquidity is low
            amount = amount > liquidity ? liquidity : amount;
        }

        morphoBlue.withdraw(_marketParams(), amount, shares, address(this), address(this));
    }

    /// @inheritdoc BaseStrategy
    function _harvestAndReport() internal override returns (uint256) {
        MarketParams memory params = _marketParams();

        morphoBlue.accrueInterest(params);

        // An airdrop might have cause asset to be available, deposit!
        uint256 _totalIdle = asset.balanceOf(address(this));
        if (_totalIdle > 0) {
            _tend(_totalIdle);
        }

        return morphoBlue.expectedSupplyAssets(params, address(this));
    }

    /// @inheritdoc BaseStrategy
    function _tend(uint256 _totalIdle) internal virtual override {
        _deployFunds(_totalIdle);
    }

    /// @inheritdoc BaseStrategy
    function availableWithdrawLimit(address) public view override returns (uint256) {
        (,,, uint256 liquidity) = getMarketLiquidity();
        return asset.balanceOf(address(this)) + liquidity;
    }
}
