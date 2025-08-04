// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMorpho} from "../interfaces/IMorpho.sol";
import {MarketParams} from "../interfaces/IMorpho.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";

contract USD3Mock {
    using SafeTransferLib for IERC20;

    IMorpho public immutable morpho;

    constructor(address _morpho) {
        morpho = IMorpho(_morpho);
    }

    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256, uint256) {
        // Transfer tokens from sender to this contract first
        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        // Approve morpho to spend tokens
        IERC20(marketParams.loanToken).approve(address(morpho), assets);
        // Supply through morpho
        return morpho.supply(marketParams, assets, shares, onBehalf, data);
    }

    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        // Withdraw from morpho (tokens will go to receiver directly)
        return morpho.withdraw(marketParams, assets, shares, onBehalf, receiver);
    }
}
