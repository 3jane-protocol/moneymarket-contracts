// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IMorpho, IMorphoCredit, Id, MarketParams, Market, BorrowerPremium} from "../../interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "./MorphoBalancesLib.sol";
import {MorphoCreditLib} from "./MorphoCreditLib.sol";
import {SharesMathLib} from "../SharesMathLib.sol";
import {MathLib, WAD} from "../MathLib.sol";
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

    /// @notice Returns the expected total supply assets accounting for markdowns
    /// @dev This returns the effective supply after subtracting total markdown
    /// @param morpho The MorphoCredit instance
    /// @param id Market ID
    /// @return effectiveSupply The expected supply assets minus total markdown
    function expectedSupplyAssetsWithMarkdown(IMorphoCredit morpho, Id id)
        internal
        view
        returns (uint256 effectiveSupply)
    {
        // Get expected supply (with accrued interest)
        IMorpho morphoBase = _asIMorpho(morpho);
        (uint256 expectedSupply,,,) = morphoBase.expectedMarketBalances(morphoBase.idToMarketParams(id));

        // Get total markdown
        uint256 totalMarkdown = morpho.getMarketMarkdownInfo(id);

        // Return effective supply
        return expectedSupply > totalMarkdown ? expectedSupply - totalMarkdown : 0;
    }

    /// @notice Returns expected market balances including markdown effects
    /// @dev Returns supply adjusted for markdown, while borrow values remain unchanged
    /// @param morpho The MorphoCredit instance
    /// @param marketParams The market parameters
    /// @return expectedSupplyAssets The expected total supply assets (reduced by markdown)
    /// @return expectedSupplyShares The expected total supply shares
    /// @return expectedBorrowAssets The expected total borrow assets
    /// @return expectedBorrowShares The expected total borrow shares
    function expectedMarketBalancesWithMarkdown(IMorphoCredit morpho, MarketParams memory marketParams)
        internal
        view
        returns (
            uint256 expectedSupplyAssets,
            uint256 expectedSupplyShares,
            uint256 expectedBorrowAssets,
            uint256 expectedBorrowShares
        )
    {
        // Get base expected balances
        (expectedSupplyAssets, expectedSupplyShares, expectedBorrowAssets, expectedBorrowShares) =
            _asIMorpho(morpho).expectedMarketBalances(marketParams);

        // Adjust supply for markdown
        Id id = marketParams.id();
        uint256 totalMarkdown = morpho.getMarketMarkdownInfo(id);

        if (totalMarkdown > 0 && expectedSupplyAssets > totalMarkdown) {
            expectedSupplyAssets -= totalMarkdown;
        } else if (totalMarkdown >= expectedSupplyAssets) {
            expectedSupplyAssets = 0;
        }
    }

    /// @notice Calculate expected shares for a withdrawal amount accounting for markdown
    /// @dev Uses effective supply (reduced by markdown) for share calculation
    /// @param morpho The MorphoCredit instance
    /// @param id Market ID
    /// @param assets The amount of assets to withdraw
    /// @return shares The shares needed to withdraw the specified assets
    function expectedWithdrawSharesWithMarkdown(IMorphoCredit morpho, Id id, uint256 assets)
        internal
        view
        returns (uint256 shares)
    {
        IMorpho morphoBase = _asIMorpho(morpho);
        MarketParams memory marketParams = morphoBase.idToMarketParams(id);
        (, uint256 totalSupplyShares,,) = morphoBase.expectedMarketBalances(marketParams);
        uint256 effectiveSupplyAssets = expectedSupplyAssetsWithMarkdown(morpho, id);

        if (effectiveSupplyAssets == 0) return 0;

        shares = assets.toSharesUp(effectiveSupplyAssets, totalSupplyShares);
    }
}
