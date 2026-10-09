// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "../../../../lib/openzeppelin/contracts/interfaces/IERC4626.sol";

import {LCCMainnetForkBase} from "./LCCMainnetForkBase.sol";
import {IMorphoBlueTest} from "../IMorphoBlueTest.sol";
import {IMorphoBlue} from "../../../../src/lcc/interfaces/IMorphoBlue.sol";

/// @dev The USD3l NotificationVault and USD3 TokenizedStrategy surface the helper fork suites read or drive.
interface ILCCForkTokenizedVault {
    function management() external view returns (address);
    function cooldownDuration() external view returns (uint64);
    function setCooldownBypass(address account, bool allowed) external;
    function availableWithdrawLimit(address owner) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function redeem(uint256 shares, address receiver, address owner, uint256 maxLoss) external returns (uint256);
}

/// @dev Canonical Morpho Blue and USD3l fixture for the leveraged-helper fork suites, pinned to its own block.
abstract contract LCCMorphoForkFixture is LCCMainnetForkBase {
    using SafeERC20 for IERC20;

    uint256 internal constant HELPER_FORK_BLOCK = 26_129_000;
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant LENDER_LIQUIDITY = 5_000_000e6;
    IMorphoBlueTest internal constant MORPHO = IMorphoBlueTest(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    address internal constant ADAPTIVE_CURVE_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    IERC4626 internal constant USD3L = IERC4626(0xDF697c55f0D696CA9E3E624cD52d8186C6745904);

    address internal lender;

    function _forkBlock() internal pure override returns (uint256) {
        return HELPER_FORK_BLOCK;
    }

    /// @dev Creates the USDC-against-USD3l market at the feedless USD3 share-rate oracle and supplies
    /// `LENDER_LIQUIDITY` from `lender`.
    function _createUsd3lMarket() internal returns (IMorphoBlue.MarketParams memory market) {
        market = IMorphoBlue.MarketParams({
            loanToken: USDC,
            collateralToken: address(USD3L),
            oracle: USD3_USDC_ORACLE,
            irm: ADAPTIVE_CURVE_IRM,
            lltv: LLTV
        });
        MORPHO.createMarket(market);

        lender = makeAddr("curator-vault");
        deal(USDC, lender, LENDER_LIQUIDITY);
        vm.startPrank(lender);
        IERC20(USDC).forceApprove(address(MORPHO), LENDER_LIQUIDITY);
        MORPHO.supply(market, LENDER_LIQUIDITY, 0, lender, "");
        vm.stopPrank();
    }
}
