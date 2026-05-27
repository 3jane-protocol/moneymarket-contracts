// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.22;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {IOracle} from "../../interfaces/IOracle.sol";

/// @title sUSD3Oracle
/// @notice Morpho oracle for sUSD3 collateral in USDC-quoted markets.
/// @dev Returns ERC4626 share-accounting value, not current redeemable liquidity.
contract sUSD3Oracle is IOracle {
    /// @notice Mainnet USD3 proxy.
    address public constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;

    /// @notice Mainnet sUSD3 proxy.
    address public constant SUSD3 = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;

    /// @dev sUSD3, USD3, and USDC are 6-decimal tokens.
    uint256 internal constant SAMPLE = 1e6;

    /// @dev Morpho scale factor for 6-decimal collateral: 1e36 / 1e6.
    uint256 internal constant SCALE_FACTOR = 1e30;

    /// @notice Returns the sUSD3 share price in USDC, scaled by 1e36.
    /// @dev This intentionally ignores sUSD3 lock/cooldown limits, withdrawal windows, and liquidity.
    function price() external view returns (uint256) {
        uint256 usd3Assets = IStrategy(SUSD3).convertToAssets(SAMPLE);
        uint256 usdcAssets = IStrategy(USD3).convertToAssets(usd3Assets);

        return usdcAssets * SCALE_FACTOR;
    }
}
