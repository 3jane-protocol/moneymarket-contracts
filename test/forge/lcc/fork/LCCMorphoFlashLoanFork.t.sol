// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LCCMainnetForkBase} from "./LCCMainnetForkBase.sol";
import {IMorphoBlueTest} from "../IMorphoBlueTest.sol";
import {IMorphoBlue, IMorphoBlueFlashLoanCallback} from "../../../../src/lcc/interfaces/IMorphoBlue.sol";

/// @dev Calls the canonical singleton's `flashLoan` and records what it observes inside the callback.
contract LCCMorphoFlashLoanProbe is IMorphoBlueFlashLoanCallback {
    using SafeERC20 for IERC20;

    IMorphoBlueTest internal immutable morpho;
    IERC20 internal immutable usdc;

    uint256 public balanceBefore;
    uint256 public balanceInCallback;
    uint256 public callbackAssets;
    uint256 public callbackCount;
    bytes public callbackData;
    uint256 public borrowedInCallback;

    constructor(IMorphoBlueTest morpho_, IERC20 usdc_) {
        morpho = morpho_;
        usdc = usdc_;
    }

    function run(uint256 assets, bytes calldata data) external {
        balanceBefore = usdc.balanceOf(address(this));
        morpho.flashLoan(address(usdc), assets, data);
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == address(morpho), "not morpho");
        ++callbackCount;
        callbackAssets = assets;
        callbackData = data;
        balanceInCallback = usdc.balanceOf(address(this));

        if (data.length > 32) {
            (IMorphoBlue.MarketParams memory market, uint256 collateral, uint256 borrowAssets) =
                abi.decode(data, (IMorphoBlue.MarketParams, uint256, uint256));
            IERC20(market.collateralToken).forceApprove(address(morpho), collateral);
            morpho.supplyCollateral(market, collateral, address(this), "");
            uint256 before = usdc.balanceOf(address(this));
            morpho.borrow(market, borrowAssets, 0, address(this), address(this));
            borrowedInCallback = usdc.balanceOf(address(this)) - before;
        }

        usdc.forceApprove(address(morpho), assets);
    }
}

contract LCCMorphoFlashLoanForkTest is LCCMainnetForkBase {
    using SafeERC20 for IERC20;

    uint256 internal constant ENTRY_FORK_BLOCK = 26_129_000;
    uint256 internal constant LENDER_LIQUIDITY = 5_000_000e6;
    IMorphoBlueTest internal constant MORPHO = IMorphoBlueTest(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    address internal constant ADAPTIVE_CURVE_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    address internal constant USD3L = 0xDF697c55f0D696CA9E3E624cD52d8186C6745904;

    IMorphoBlue.MarketParams internal marketParams;
    LCCMorphoFlashLoanProbe internal probe;

    function _forkBlock() internal pure override returns (uint256) {
        return ENTRY_FORK_BLOCK;
    }

    function setUp() public override {
        super.setUp();
        if (!forkEnabled) return;

        marketParams = IMorphoBlue.MarketParams({
            loanToken: USDC, collateralToken: USD3L, oracle: USD3_USDC_ORACLE, irm: ADAPTIVE_CURVE_IRM, lltv: 0.86e18
        });
        MORPHO.createMarket(marketParams);
        address lender = makeAddr("lender");
        deal(USDC, lender, LENDER_LIQUIDITY);
        vm.startPrank(lender);
        IERC20(USDC).forceApprove(address(MORPHO), LENDER_LIQUIDITY);
        MORPHO.supply(marketParams, LENDER_LIQUIDITY, 0, lender, "");
        vm.stopPrank();

        probe = new LCCMorphoFlashLoanProbe(MORPHO, IERC20(USDC));
    }

    function testFlashLoanTransfersBeforeCallbackAndPullsBackSameAmountWithoutFee() public requiresFork {
        uint256 assets = 1_234_567e6;
        uint256 morphoBefore = IERC20(USDC).balanceOf(address(MORPHO));

        probe.run(assets, hex"");

        assertEq(probe.callbackCount(), 1);
        assertEq(probe.callbackAssets(), assets);
        assertEq(probe.balanceInCallback(), probe.balanceBefore() + assets, "USDC arrives before the callback");
        assertEq(IERC20(USDC).balanceOf(address(probe)), probe.balanceBefore(), "same amount pulled back, no fee");
        assertEq(IERC20(USDC).balanceOf(address(MORPHO)), morphoBefore);
    }

    function testFlashLoanPassesDataThrough() public requiresFork {
        probe.run(1e6, hex"c0ffee");
        assertEq(probe.callbackData(), hex"c0ffee");
    }

    function testZeroAmountFlashLoanReverts() public requiresFork {
        vm.expectRevert(bytes("zero assets"));
        probe.run(0, hex"");
        assertEq(probe.callbackCount(), 0);
    }

    function testUnrepaidFlashLoanReverts() public requiresFork {
        vm.mockCall(USDC, abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));
        vm.expectRevert();
        probe.run(1e6, hex"");
    }

    function testNestedSupplyCollateralAndBorrowSucceedInsideCallback() public requiresFork {
        uint256 collateral = 1_000_000e6;
        uint256 borrowAssets = 500_000e6;
        deal(USD3L, address(probe), collateral);
        uint256 assets = 2_000_000e6;

        probe.run(assets, abi.encode(marketParams, collateral, borrowAssets));

        bytes32 id = keccak256(abi.encode(marketParams));
        (, uint128 borrowShares, uint128 positionCollateral) = MORPHO.position(id, address(probe));
        assertEq(positionCollateral, collateral);
        assertGt(borrowShares, 0);
        assertEq(probe.borrowedInCallback(), borrowAssets);
        assertEq(IERC20(USDC).balanceOf(address(probe)), borrowAssets, "flash repaid, borrow retained");
    }
}
