// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LCCLogCounter} from "./LCCLogCounter.sol";
import {LCCLeveragedFundHelper} from "../../../src/lcc/LCCLeveragedFundHelper.sol";
import {ILCCLeveragedFundHelper} from "../../../src/lcc/interfaces/ILCCLeveragedFundHelper.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {IMorphoBlue} from "../../../src/lcc/interfaces/IMorphoBlue.sol";

/// @dev State, request builders, and clean-state assertions shared by the leveraged-helper unit and fork suites.
abstract contract LCCLeveragedFundTestBase is LCCLogCounter {
    LCCLeveragedFundHelper internal helper;
    IMorphoBlue.MarketParams internal marketParams;
    bytes32 internal marketId;

    function _unwindParams(uint256 shares, bool full, uint256 repayAssets)
        internal
        view
        returns (ILCCLeveragedFundHelper.UnwindParams memory)
    {
        return ILCCLeveragedFundHelper.UnwindParams({
            market: marketParams,
            shares: shares,
            full: full,
            repayAssets: repayAssets,
            maxRepayAssets: type(uint256).max,
            usd3Out: false,
            minOut: 0,
            deadline: block.timestamp
        });
    }

    /// @dev After an entry into `vault`: the helper holds no USDC, USD3l, or margin asset, its exact per-vault USDC
    /// approval is spent, and its standing Morpho allowances are untouched.
    function _assertHelperClean(address vault) internal view {
        assertEq(IERC20(helper.usdc()).balanceOf(address(helper)), 0);
        assertEq(IERC20(helper.usd3l()).balanceOf(address(helper)), 0);
        assertEq(IERC20(ILCCVault(vault).assetConfig().marginAsset).balanceOf(address(helper)), 0);
        assertEq(IERC20(helper.usdc()).allowance(address(helper), vault), 0);
        _assertStandingMorphoAllowances();
    }

    /// @dev After an unwind: the helper holds no USDC, USD3l, or USD3, and its standing Morpho allowances are
    /// untouched.
    function _assertUnwindHelperClean() internal view {
        assertEq(IERC20(helper.usdc()).balanceOf(address(helper)), 0);
        assertEq(IERC20(helper.usd3l()).balanceOf(address(helper)), 0);
        assertEq(IERC20(helper.usd3()).balanceOf(address(helper)), 0);
        _assertStandingMorphoAllowances();
    }

    /// @dev Mainnet USDC decrements even a maximal allowance by every pull, so the standing USDC allowance is only
    /// required to stay effectively unbounded; USD3l leaves a maximal allowance untouched.
    function _assertStandingMorphoAllowances() internal view {
        uint256 usdcAllowance = IERC20(helper.usdc()).allowance(address(helper), helper.morpho());
        assertGe(usdcAllowance, type(uint256).max - type(uint128).max);
        assertEq(IERC20(helper.usd3l()).allowance(address(helper), helper.morpho()), type(uint256).max);
    }
}
