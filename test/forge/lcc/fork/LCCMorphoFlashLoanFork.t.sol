// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "../../../../lib/openzeppelin/contracts/interfaces/IERC4626.sol";

import {LCCMainnetForkBase} from "./LCCMainnetForkBase.sol";
import {IMorphoBlueTest} from "../IMorphoBlueTest.sol";
import {IMorphoBlue, IMorphoBlueFlashLoanCallback} from "../../../../src/lcc/interfaces/IMorphoBlue.sol";
import {SharesMathLib} from "../../../../src/libraries/SharesMathLib.sol";

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
    using SharesMathLib for uint256;

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

    /* UNWIND PRIMITIVES */

    function _openBorrow(address borrower, uint256 collateral, uint256 borrowAssets) internal {
        deal(USD3L, borrower, collateral);
        vm.startPrank(borrower);
        IERC20(USD3L).forceApprove(address(MORPHO), collateral);
        MORPHO.supplyCollateral(marketParams, collateral, borrower, "");
        MORPHO.borrow(marketParams, borrowAssets, 0, borrower, borrower);
        vm.stopPrank();
    }

    function testAccrueInterestIsPublicAndShareRepayClearsDebtExactly() public requiresFork {
        address borrower = makeAddr("borrower");
        _openBorrow(borrower, 1_000_000e6, 500_000e6);
        vm.warp(block.timestamp + 30 days);

        MORPHO.accrueInterest(marketParams);
        bytes32 id = keccak256(abi.encode(marketParams));
        (, uint128 borrowShares,) = MORPHO.position(id, borrower);
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(id);
        uint256 owed = uint256(borrowShares).toAssetsUp(totalBorrowAssets, totalBorrowShares);
        assertGt(owed, 500_000e6, "interest accrued");

        address payer = makeAddr("payer");
        deal(USDC, payer, owed);
        vm.startPrank(payer);
        IERC20(USDC).forceApprove(address(MORPHO), owed);
        (uint256 repaid, uint256 sharesRepaid) = MORPHO.repay(marketParams, 0, borrowShares, borrower, "");
        vm.stopPrank();

        assertEq(repaid, owed);
        assertEq(sharesRepaid, borrowShares);
        (, uint128 borrowSharesAfter,) = MORPHO.position(id, borrower);
        assertEq(borrowSharesAfter, 0);
        assertEq(IERC20(USDC).balanceOf(payer), 0);
    }

    function testWithdrawCollateralNeedsAuthorizationAndSkipsOracleAtZeroDebt() public requiresFork {
        address borrower = makeAddr("borrower");
        address operator = makeAddr("operator");
        _openBorrow(borrower, 1_000_000e6, 500_000e6);
        bytes32 id = keccak256(abi.encode(marketParams));
        (, uint128 borrowShares,) = MORPHO.position(id, borrower);
        deal(USDC, address(this), 600_000e6);
        IERC20(USDC).forceApprove(address(MORPHO), 600_000e6);
        MORPHO.repay(marketParams, 0, borrowShares, borrower, "");

        vm.expectRevert(bytes("unauthorized"));
        vm.prank(operator);
        MORPHO.withdrawCollateral(marketParams, 1_000_000e6, borrower, operator);

        vm.prank(borrower);
        MORPHO.setAuthorization(operator, true);
        vm.mockCallRevert(USD3_USDC_ORACLE, abi.encodeWithSignature("price()"), "ORACLE_DOWN");
        vm.prank(operator);
        MORPHO.withdrawCollateral(marketParams, 1_000_000e6, borrower, operator);

        (,, uint128 collateral) = MORPHO.position(id, borrower);
        assertEq(collateral, 0);
        assertEq(IERC20(USD3L).balanceOf(operator), 1_000_000e6);
    }

    function testWithdrawCollateralWithDebtReadsOracle() public requiresFork {
        address borrower = makeAddr("borrower");
        _openBorrow(borrower, 1_000_000e6, 100_000e6);
        vm.mockCallRevert(USD3_USDC_ORACLE, abi.encodeWithSignature("price()"), "ORACLE_DOWN");
        vm.expectRevert(bytes("ORACLE_DOWN"));
        vm.prank(borrower);
        MORPHO.withdrawCollateral(marketParams, 1e6, borrower, borrower);
    }

    function testBypassedOwnerRedeemsUsd3lOneToOneAndUsd3WithZeroLoss() public requiresFork {
        address holder = makeAddr("bypassed-holder");
        ITokenizedStrategyLike usd3l = ITokenizedStrategyLike(USD3L);
        vm.prank(usd3l.management());
        INotificationVaultLike(USD3L).setCooldownBypass(holder, true);

        uint256 assets = 250_000e6;
        deal(USD3, holder, assets);
        vm.startPrank(holder);
        IERC20(USD3).forceApprove(USD3L, assets);
        uint256 shares = IERC4626(USD3L).deposit(assets, holder);
        vm.stopPrank();
        assertEq(shares, assets);
        uint256 usd3Before = IERC20(USD3).balanceOf(holder);
        vm.prank(holder);
        uint256 usd3Out = usd3l.redeem(shares, holder, holder, 0);
        assertEq(usd3Out, shares, "USD3l redeems 1:1");
        assertEq(IERC20(USD3).balanceOf(holder) - usd3Before, shares);

        uint256 previewUsdc = ITokenizedStrategyLike(USD3).previewRedeem(usd3Out);
        assertLe(previewUsdc, ITokenizedStrategyLike(USD3).availableWithdrawLimit(holder));
        vm.prank(holder);
        uint256 usdcOut = ITokenizedStrategyLike(USD3).redeem(usd3Out, holder, holder, 0);
        assertEq(usdcOut, previewUsdc, "USD3 redeems at preview with zero loss");
        assertEq(IERC20(USDC).balanceOf(holder), usdcOut);
    }
}

interface ITokenizedStrategyLike {
    function management() external view returns (address);
    function redeem(uint256 shares, address receiver, address owner, uint256 maxLoss) external returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function availableWithdrawLimit(address owner) external view returns (uint256);
}

interface INotificationVaultLike {
    function setCooldownBypass(address account, bool allowed) external;
}
