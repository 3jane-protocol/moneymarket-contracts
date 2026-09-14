// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {IOracle} from "../../src/interfaces/IOracle.sol";

interface ILCCMarginOracleView is IOracle {
    function BASE_VAULT() external view returns (address);
}

abstract contract LCCMarginOracleValidation {
    function _requireMarginOracleBinding(address marginAsset, address marginOracle) internal view {
        require(marginOracle != address(0), "Margin oracle not set");
        require(marginOracle.code.length > 0, "Margin oracle has no code");
        require(ILCCMarginOracleView(marginOracle).BASE_VAULT() == marginAsset, "Margin oracle base vault mismatch");
    }

    function _requireMarginOracle(
        address marginAsset,
        address marginOracle,
        uint256 minMarginOraclePrice,
        uint256 maxMarginOraclePrice
    ) internal view {
        require(
            minMarginOraclePrice != 0 && minMarginOraclePrice <= maxMarginOraclePrice,
            "Invalid margin oracle price range"
        );
        _requireMarginOracleBinding(marginAsset, marginOracle);

        uint256 marginOraclePrice = IOracle(marginOracle).price();
        require(marginOraclePrice != 0, "Margin oracle price is zero");
        require(marginOraclePrice >= minMarginOraclePrice, "Margin oracle price below minimum");
        require(marginOraclePrice <= maxMarginOraclePrice, "Margin oracle price above maximum");
    }
}
