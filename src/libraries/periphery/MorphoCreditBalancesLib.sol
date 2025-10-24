// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IMorpho, IMorphoCredit, Id, MarketParams, Market, BorrowerPremium} from "../../interfaces/IMorpho.sol";
import {IIrm} from "../../interfaces/IIrm.sol";
import {MorphoBalancesLib} from "./MorphoBalancesLib.sol";
import {MorphoCreditLib} from "./MorphoCreditLib.sol";
import {SharesMathLib} from "../SharesMathLib.sol";
import {MathLib, WAD} from "../MathLib.sol";
import {UtilsLib} from "../UtilsLib.sol";
import {MarketParamsLib} from "../MarketParamsLib.sol";

/// @title MorphoCreditBalancesLib
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice Helper library for balance calculations specific to MorphoCredit.
/// @dev This library extends MorphoBalancesLib functionality for MorphoCredit-specific calculations.
library MorphoCreditBalancesLib {
    using MorphoBalancesLib for IMorpho;
    using MorphoCreditLib for IMorphoCredit;
    using SharesMathLib for uint256;
    using MathLib for uint256;
    using MathLib for uint128;
    using UtilsLib for uint256;
    using MarketParamsLib for MarketParams;

    /// @dev Casts IMorphoCredit to IMorpho for accessing base functionality
    function _asIMorpho(IMorphoCredit morpho) private pure returns (IMorpho) {
        return IMorpho(address(morpho));
    }

    /// @notice Returns the expected borrow assets for a borrower including accrued premium
    /// @dev This accounts for base interest + risk premium but not penalty rates
    /// @param morpho The MorphoCredit instance
    /// @param id Market ID
    /// @param borrower Borrower address
    /// @return expectedAssets The expected borrow assets including premium
    function expectedBorrowAssetsWithPremium(IMorphoCredit morpho, Id id, address borrower)
        internal
        view
        returns (uint256 expectedAssets)
    {
        // Get base expected borrow assets (includes base interest)
        IMorpho morphoBase = _asIMorpho(morpho);
        MarketParams memory marketParams = morphoBase.idToMarketParams(id);
        expectedAssets = morphoBase.expectedBorrowAssets(marketParams, borrower);

        // Get premium details
        BorrowerPremium memory premium = morpho.getBorrowerPremium(id, borrower);

        if (premium.rate == 0 || premium.lastAccrualTime == 0) {
            return expectedAssets;
        }

        // Calculate elapsed time since last premium accrual
        uint256 elapsed = block.timestamp - premium.lastAccrualTime;
        if (elapsed == 0) {
            return expectedAssets;
        }

        // Calculate premium amount
        uint256 premiumAmount = expectedAssets.wMulDown(uint256(premium.rate).wTaylorCompounded(elapsed));

        return expectedAssets + premiumAmount;
    }

    /// @notice Returns the expected total supply assets for liquidity calculations
    /// @dev This adds markdown back since actual tokens remain in the contract
    /// @param morpho The MorphoCredit instance
    /// @param id Market ID
    /// @return effectiveSupply The expected supply assets plus total markdown for liquidity
    function expectedSupplyAssetsForLiquidity(IMorphoCredit morpho, Id id)
        internal
        view
        returns (uint256 effectiveSupply)
    {
        // Use optimized function that fetches market only once
        IMorpho morphoBase = _asIMorpho(morpho);
        MarketParams memory marketParams = morphoBase.idToMarketParams(id);
        (uint256 expectedSupply,,,, uint256 totalMarkdown) = expectedMarketBalances(morpho, marketParams);

        // Add markdown back for liquidity (actual tokens still present)
        return expectedSupply + totalMarkdown;
    }

    /// @notice Returns expected market balances including markdown as a separate value
    /// @dev Reimplements the full calculation to avoid external call overhead
    /// @param morpho The MorphoCredit instance
    /// @param marketParams The market parameters
    /// @return expectedSupplyAssets The expected total supply assets (already reduced by markdown)
    /// @return expectedSupplyShares The expected total supply shares
    /// @return expectedBorrowAssets The expected total borrow assets
    /// @return expectedBorrowShares The expected total borrow shares
    /// @return totalMarkdownAmount The total markdown amount across all borrowers
    function expectedMarketBalances(IMorphoCredit morpho, MarketParams memory marketParams)
        internal
        view
        returns (
            uint256 expectedSupplyAssets,
            uint256 expectedSupplyShares,
            uint256 expectedBorrowAssets,
            uint256 expectedBorrowShares,
            uint256 totalMarkdownAmount
        )
    {
        Id id = marketParams.id();
        Market memory market = _asIMorpho(morpho).market(id);

        // Get markdown amount as fifth return value
        totalMarkdownAmount = market.totalMarkdownAmount;

        // Calculate elapsed time since last update
        uint256 elapsed = block.timestamp - market.lastUpdate;

        // Calculate interest if needed
        if (elapsed != 0 && market.totalBorrowAssets != 0 && marketParams.irm != address(0)) {
            uint256 borrowRate = IIrm(marketParams.irm).borrowRateView(marketParams, market);
            uint256 interest = market.totalBorrowAssets.wMulDown(borrowRate.wTaylorCompounded(elapsed));
            market.totalBorrowAssets += interest.toUint128();
            market.totalSupplyAssets += interest.toUint128();

            // Calculate fee shares if applicable
            if (market.fee != 0) {
                uint256 feeAmount = interest.wMulDown(market.fee);
                // The fee amount is subtracted from the total supply in this calculation to compensate for the fact
                // that total supply is already updated.
                uint256 feeShares =
                    feeAmount.toSharesDown(market.totalSupplyAssets - feeAmount, market.totalSupplyShares);
                market.totalSupplyShares += feeShares.toUint128();
            }
        }

        // Return all values including markdown
        expectedSupplyAssets = market.totalSupplyAssets;
        expectedSupplyShares = market.totalSupplyShares;
        expectedBorrowAssets = market.totalBorrowAssets;
        expectedBorrowShares = market.totalBorrowShares;
    }

    /// @notice Returns expected market balances for liquidity calculations
    /// @dev Returns supply with markdown added back for accurate liquidity assessment
    /// @param morpho The MorphoCredit instance
    /// @param marketParams The market parameters
    /// @return expectedSupplyAssets The expected total supply assets for liquidity (with markdown added back)
    /// @return expectedSupplyShares The expected total supply shares
    /// @return expectedBorrowAssets The expected total borrow assets
    /// @return expectedBorrowShares The expected total borrow shares
    function expectedMarketBalancesForLiquidity(IMorphoCredit morpho, MarketParams memory marketParams)
        internal
        view
        returns (
            uint256 expectedSupplyAssets,
            uint256 expectedSupplyShares,
            uint256 expectedBorrowAssets,
            uint256 expectedBorrowShares
        )
    {
        // Use optimized function that fetches market only once
        uint256 totalMarkdown;
        (expectedSupplyAssets, expectedSupplyShares, expectedBorrowAssets, expectedBorrowShares, totalMarkdown) =
            expectedMarketBalances(morpho, marketParams);

        // Add markdown back since actual tokens remain in contract
        expectedSupplyAssets += totalMarkdown;
    }

    /// @notice Calculate expected shares for a withdrawal amount
    /// @dev Uses actual supply (without adding back markdown) for share calculation since shares represent claims on
    /// reduced supply @param morpho The MorphoCredit instance
    /// @param id Market ID
    /// @param assets The amount of assets to withdraw
    /// @return shares The shares needed to withdraw the specified assets
    function expectedWithdrawShares(IMorphoCredit morpho, Id id, uint256 assets)
        internal
        view
        returns (uint256 shares)
    {
        IMorpho morphoBase = _asIMorpho(morpho);
        MarketParams memory marketParams = morphoBase.idToMarketParams(id);
        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) = morphoBase.expectedMarketBalances(marketParams);

        if (totalSupplyAssets == 0) return 0;

        shares = assets.toSharesUp(totalSupplyAssets, totalSupplyShares);
    }

    /// @notice Returns the expected available liquidity in the market
    /// @dev Adds markdown back to supply since actual tokens remain in contract
    /// @param morpho The MorphoCredit instance
    /// @param id Market ID
    /// @return availableLiquidity The available liquidity for withdrawals/borrows
    function expectedAvailableLiquidity(IMorphoCredit morpho, Id id)
        internal
        view
        returns (uint256 availableLiquidity)
    {
        // Use optimized function that fetches market only once
        IMorpho morphoBase = _asIMorpho(morpho);
        MarketParams memory marketParams = morphoBase.idToMarketParams(id);
        (uint256 expectedSupply,, uint256 expectedBorrow,, uint256 totalMarkdown) =
            expectedMarketBalances(morpho, marketParams);

        // Add markdown back to get effective liquidity
        uint256 effectiveSupply = expectedSupply + totalMarkdown;

        return effectiveSupply > expectedBorrow ? effectiveSupply - expectedBorrow : 0;
    }
}
