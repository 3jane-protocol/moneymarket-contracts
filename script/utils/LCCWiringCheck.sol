// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

import {ILCCVault} from "../../src/lcc/interfaces/ILCCVault.sol";

/// @notice Shared validation for the protocol-wide wiring exposed by an LCC vault implementation or proxy.
abstract contract LCCWiringCheck {
    function _requireLCCWiring(address vault, address expectedUsd3)
        internal
        view
        returns (ILCCVault.AssetConfig memory config)
    {
        (bool ok, bytes memory data) = vault.staticcall(abi.encodeCall(ILCCVault.assetConfig, ()));
        require(ok && data.length == 6 * 32, "LCC assetConfig read failed");

        config = abi.decode(data, (ILCCVault.AssetConfig));
        require(config.usd3 == expectedUsd3, "LCC USD3 mismatch");
        require(config.notificationVault != address(0), "LCC NotificationVault not set");
    }
}
