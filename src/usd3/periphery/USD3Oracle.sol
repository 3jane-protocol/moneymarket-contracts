// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.22;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {IOracle} from "../../interfaces/IOracle.sol";

/// @title USD3Oracle
/// @notice Morpho oracle for USD3 collateral in USDC-quoted markets.
/// @dev Returns ERC4626 share-accounting value, not current redeemable liquidity.
contract USD3Oracle is IOracle {
    /// @notice Mainnet USD3 proxy.
    address public constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;

    /// @dev USD3 and USDC are 6-decimal tokens.
    uint256 internal constant SAMPLE = 1e6;

    /// @dev Morpho scale factor for 6-decimal collateral: 1e36 / 1e6.
    uint256 internal constant SCALE_FACTOR = 1e30;

    /// @notice Returns the USD3 share price in USDC, scaled by 1e36.
    /// @dev This intentionally ignores USD3 commitment restrictions and withdrawal liquidity.
    function price() external view returns (uint256) {
        return IStrategy(USD3).convertToAssets(SAMPLE) * SCALE_FACTOR;
    }
}
