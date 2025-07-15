// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseHealthCheck, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
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

    /// @notice Address for the Morpho contract, the same on ETH and Base.
    IMorpho public constant MORPHO_BLUE =
        IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    // these internal immutable vars can be accessed externally via marketParams()
    address internal immutable loanToken;
    address internal immutable collateralToken;
    address internal immutable oracle;
    address internal immutable irm;
    uint256 internal immutable lltv;
    address internal immutable creditLine;

    constructor(
        address _asset,
        string memory _name,
        MarketParams memory _marketParams
    ) BaseHealthCheck(_asset, _name) {
        require(_asset == _marketParams.loanToken, "!loantoken");

        loanToken = _marketParams.loanToken;
        collateralToken = _marketParams.collateralToken;
        oracle = _marketParams.oracle;
        irm = _marketParams.irm;
        lltv = _marketParams.lltv;
        creditLine = _marketParams.creditLine;

        asset.forceApprove(address(MORPHO_BLUE), type(uint256).max);
    }

    function marketId() external view returns (Id) {
        return marketParams_().id();
    }

    function marketParams() external view returns (MarketParams memory) {
        return marketParams_();
    }

    function marketParams_() internal view returns (MarketParams memory) {
        return
            MarketParams({
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
        returns (
            uint256 totalSupplyAssets,
            uint256 totalShares,
            uint256 totalBorrowAssets,
            uint256 liquidity
        )
    {
        (totalSupplyAssets, totalShares, totalBorrowAssets, ) = MORPHO_BLUE
            .expectedMarketBalances(marketParams_());
        liquidity = totalSupplyAssets - totalBorrowAssets;
    }

    function getPosition()
        internal
        view
        returns (uint256 shares, uint256 assetsMax, uint256 liquidity)
    {
        Id id = marketParams_().id();
        shares = MORPHO_BLUE.position(id, address(this)).supplyShares;
        uint256 totalSupplyAssets;
        uint256 totalShares;
        (totalSupplyAssets, totalShares, , liquidity) = getMarketLiquidity();
        assetsMax = shares.toAssetsDown(totalSupplyAssets, totalShares);
    }

    /**
     * @dev Should deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy should attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        MORPHO_BLUE.supply(marketParams_(), _amount, 0, address(this), hex"");
    }

    /**
     * @dev Will attempt to free the '_amount' of 'asset'.
     *
     * The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 amount) internal override {
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

        MORPHO_BLUE.withdraw(
            marketParams_(),
            amount,
            shares,
            address(this),
            address(this)
        );
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        if (TokenizedStrategy.isShutdown()) {
            // If strategy is shutdown, just withdraw all you can
            _freeFunds(type(uint256).max);
            // NOTE: take into account that some assets might not have been released
            return
                asset.balanceOf(address(this)) +
                MORPHO_BLUE.expectedSupplyAssets(
                    marketParams_(),
                    address(this)
                );
        }

        // An airdrop might have cause asset to be available, deposit!
        uint256 looseAsset = asset.balanceOf(address(this));
        if (looseAsset > 0) {
            _deployFunds(looseAsset);
        }

        return MORPHO_BLUE.expectedSupplyAssets(marketParams_(), address(this));
    }

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies. It should never be lower than `totalIdle`.
     *
     *   EX:
     *       return TokenIzedStrategy.totalIdle();
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The available amount that can be withdrawn in terms of `asset`
     */
    function availableWithdrawLimit(
        address
    ) public view override returns (uint256) {
        (, , , uint256 liquidity) = getMarketLiquidity();
        return asset.balanceOf(address(this)) + liquidity;
    }
}
