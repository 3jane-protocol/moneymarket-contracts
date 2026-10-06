// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IMorphoBlue} from "../../../src/lcc/interfaces/IMorphoBlue.sol";

/// @dev Canonical Morpho Blue entrypoints the test suites use beyond the helper's own surface.
interface IMorphoBlueTest is IMorphoBlue {
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function createMarket(MarketParams calldata marketParams) external;

    function supply(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);

    function withdraw(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);

    function setAuthorization(address authorized, bool newIsAuthorized) external;

    function nonce(address authorizer) external view returns (uint256);
}
