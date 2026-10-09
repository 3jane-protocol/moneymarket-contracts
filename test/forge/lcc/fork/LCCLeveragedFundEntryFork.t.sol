// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "../../../../lib/openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Permit} from "../../../../lib/openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Math} from "../../../../lib/openzeppelin/contracts/utils/math/Math.sol";

import {LCCMorphoForkFixture, ILCCForkTokenizedVault} from "./LCCMorphoForkFixture.sol";
import {LCCLeveragedFundSigUtils} from "../LCCLeveragedFundSigUtils.sol";
import {LCCLeveragedFundTestBase} from "../LCCLeveragedFundTestBase.sol";
import {ILCCVault} from "../../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCVaultFactory} from "../../../../src/lcc/LCCVaultFactory.sol";
import {LCCLeveragedFundHelper} from "../../../../src/lcc/LCCLeveragedFundHelper.sol";
import {ILCCLeveragedFundHelper} from "../../../../src/lcc/interfaces/ILCCLeveragedFundHelper.sol";
import {IMorphoBlue} from "../../../../src/lcc/interfaces/IMorphoBlue.sol";
import {IOracle} from "../../../../src/interfaces/IOracle.sol";
import {ILCCRedeemableVault} from "../../../../src/lcc/interfaces/ILCCNotificationVault.sol";
import {LCCAuctionLib} from "../../../../src/lcc/libraries/LCCAuctionLib.sol";
import {LCCEventsLib} from "../../../../src/lcc/libraries/LCCEventsLib.sol";
import {ORACLE_PRICE_SCALE} from "../../../../src/libraries/ConstantsLib.sol";
import {MathLib} from "../../../../src/libraries/MathLib.sol";
import {SharesMathLib} from "../../../../src/libraries/SharesMathLib.sol";

/// @dev The USD3 reads these tests need. `IUSD3` cannot be imported here because `src/usd3` compiles for Shanghai and
/// the helper for Cancun, which one compilation cannot satisfy.
interface ILCCForkUSD3 {
    function ringFencedLiquidity() external view returns (uint256);
    function ringFenceConduit(address conduit) external view returns (bool);
    function supplyCapExempt(address account) external view returns (bool);
}

contract LCCLeveragedFundEntryForkTest is LCCMorphoForkFixture, LCCLeveragedFundSigUtils, LCCLeveragedFundTestBase {
    using SafeERC20 for IERC20;
    using MathLib for uint256;
    using SharesMathLib for uint256;

    uint256 internal constant CALL_EPOCH = 2;
    uint256 internal constant CALL_AMOUNT = 1_234_567_891_011;
    uint256 internal constant ENTRY_LTV_BPS = 8_000;
    uint256 internal constant COLLATERAL_SLACK_BPS = 5;
    uint256 internal constant TAKE_FILL = 10_000e6;
    uint256 internal constant TAKE_BORROW = 8_000e6;
    uint256 internal constant LATE_STEP = 96;

    ILCCVault internal constant VAULT = ILCCVault(0x8350ba7c69aeADD74b891EFc53F52a0f592aD796);
    address internal constant FACTORY = 0x95431c2Fbfe3E0f17a61EF1d7601Eb34aE6cd6ba;
    address internal constant FACTORY_OWNER = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address internal constant LISTER = 0x485828f6373c5FB1aA1DD8A58D6A6E7803fC5b15;

    address[] internal funders;
    uint256[] internal funderKeys;
    address internal taker;

    function setUp() public override {
        super.setUp();
        if (!forkEnabled) return;

        marketParams = _createUsd3lMarket();
        marketId = keccak256(abi.encode(marketParams));
        helper = new LCCLeveragedFundHelper(address(MORPHO), FACTORY, address(USD3L));
        _setHelperBypass(true);

        string[3] memory names = ["levered-funder-small", "levered-funder-odd", "levered-funder-large"];
        for (uint256 i; i < names.length; ++i) {
            (address funder, uint256 key) = makeAddrAndKey(names[i]);
            funders.push(funder);
            funderKeys.push(key);
        }
        uint256[3] memory marginUsdc = [uint256(2_500e6), 9_876_543_211, 23_000e6];

        uint128[] memory caps = new uint128[](funders.length);
        for (uint256 i; i < funders.length; ++i) {
            caps[i] = type(uint128).max;
        }
        vm.prank(LISTER);
        LCCVaultFactory(FACTORY).setDepositorCaps(funders, caps);

        for (uint256 i; i < funders.length; ++i) {
            _depositMargin(funders[i], marginUsdc[i]);
        }

        vm.warp(VAULT.phaseEndsAt(CALL_EPOCH, ILCCVault.Phase.Normal));
        vm.prank(FACTORY_OWNER);
        VAULT.openEpochCall(CALL_EPOCH, CALL_AMOUNT);
        vm.warp(VAULT.phaseEndsAt(CALL_EPOCH, ILCCVault.Phase.PreCall));
    }

    function testFeedlessOraclePricesUSD3lAtTheUSD3ShareRate() public requiresFork {
        assertEq(USD3L.asset(), USD3);
        assertEq(USD3L.convertToAssets(1e6), 1e6);
        assertEq(USD3L.previewDeposit(1e6), 1e6);
        uint256 price = IOracle(USD3_USDC_ORACLE).price();
        assertEq(price, IERC4626(USD3).convertToAssets(1e6) * 1e30);
        assertGt(price, ORACLE_PRICE_SCALE);
    }

    function testHelperDerivesUSD3AndRejectsMarketWithWrongTokens() public requiresFork {
        assertEq(helper.usd3(), USD3);
        assertEq(helper.usdc(), USDC);

        address funder = funders[0];
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(funder);
        _approveAll(funder, params.maxContribution);

        params.market.loanToken = USDT;
        vm.expectRevert(ILCCLeveragedFundHelper.MarketTokenMismatch.selector);
        vm.prank(funder);
        helper.fund(params);

        params.market = marketParams;
        params.market.collateralToken = USD3;
        vm.expectRevert(ILCCLeveragedFundHelper.MarketTokenMismatch.selector);
        vm.prank(funder);
        helper.fund(params);
    }

    function testPreApprovedEntryMintsExactlyThePreviewedCollateral() public requiresFork {
        assertEq(uint256(VAULT.currentPhase()), uint256(ILCCVault.Phase.Funding));
        for (uint256 i; i < funders.length; ++i) {
            address funder = funders[i];
            ILCCLeveragedFundHelper.FundParams memory params = _fundParams(funder);
            uint256 marginBefore = IERC20(WA_ETH_USDC).balanceOf(funder);
            uint256 previewed = _previewCollateral(params.maxObligation);

            _approveAll(funder, params.maxContribution);
            vm.prank(funder);
            (uint256 funded, uint256 fundingAmount, uint256 collateral) = helper.fund(params);

            assertEq(funded, params.maxObligation);
            assertEq(fundingAmount, params.maxObligation);
            assertGt(IERC20(WA_ETH_USDC).balanceOf(funder), marginBefore, "margin not released");
            assertEq(collateral, previewed);
            _assertEntry(funder, params.borrowAssets, collateral);
        }
    }

    function testSignatureEntryAppliesRealPermitsAndAuthorization() public requiresFork {
        address funder = funders[1];
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(funder);
        uint256 previewed = _previewCollateral(params.maxObligation);
        deal(USDC, funder, params.maxContribution);

        Signed memory s = _sign(funderKeys[1], params.maxContribution, params.maxCollateral);
        assertFalse(MORPHO.isAuthorized(funder, address(helper)));

        vm.prank(funder);
        (,, uint256 collateral) =
            helper.fundWithSignatures(params, s.usdcPermit, s.usd3lPermit, s.marginPermit, s.authorization, s.signature);

        assertEq(collateral, previewed);
        assertTrue(MORPHO.isAuthorized(funder, address(helper)), "authorization stays enabled");
        assertEq(MORPHO.nonce(funder), s.authorization.nonce + 1);
        assertEq(IERC20(USDC).allowance(funder, address(helper)), 0);
        assertEq(USD3L.allowance(funder, address(helper)), params.maxCollateral - previewed);
        _assertEntry(funder, params.borrowAssets, collateral);
    }

    function testSignatureEntryToleratesThirdPartySubmittingEachSignatureFirst() public requiresFork {
        address funder = funders[2];
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(funder);
        deal(USDC, funder, params.maxContribution);

        uint256 previewed = _previewCollateral(params.maxObligation);
        Signed memory s = _sign(funderKeys[2], params.maxContribution, params.maxCollateral);

        vm.startPrank(makeAddr("front-runner"));
        _submitPermit(USDC, funder, address(helper), s.usdcPermit);
        _submitPermit(address(USD3L), funder, address(helper), s.usd3lPermit);
        MORPHO.setAuthorizationWithSig(s.authorization, s.signature);
        vm.stopPrank();

        vm.prank(funder);
        (,, uint256 collateral) =
            helper.fundWithSignatures(params, s.usdcPermit, s.usd3lPermit, s.marginPermit, s.authorization, s.signature);
        assertEq(collateral, previewed);
        _assertEntry(funder, params.borrowAssets, collateral);
    }

    function testLeveredMarginEntryWithStandingAllowances() public requiresFork {
        address funder = funders[2];
        (ILCCLeveragedFundHelper.FundParams memory params, uint256 released) = _marginFundParams(funder);
        uint256 previewed = _previewCollateral(params.maxObligation);
        uint256 burned = IERC4626(WA_ETH_USDC).previewWithdraw(params.marginAssets);
        uint256 marginBefore = IERC20(WA_ETH_USDC).balanceOf(funder);

        _approveAll(funder, params.maxContribution);
        vm.prank(funder);
        IERC20(WA_ETH_USDC).forceApprove(address(helper), params.maxMarginShares);
        uint256 usdcBefore = IERC20(USDC).balanceOf(funder);
        vm.prank(funder);
        (uint256 obligation, uint256 fundingAmount, uint256 collateral) = helper.fund(params);

        assertEq(obligation, params.maxObligation);
        assertEq(usdcBefore - IERC20(USDC).balanceOf(funder), fundingAmount - params.borrowAssets - params.marginAssets);
        _assertMarginEntry(funder, params, released, burned, marginBefore, previewed, collateral);
    }

    function testSignatureMarginEntryAppliesRealMarginPermit() public requiresFork {
        address funder = funders[1];
        uint256 key = funderKeys[1];
        (ILCCLeveragedFundHelper.FundParams memory params, uint256 released) = _marginFundParams(funder);
        uint256 previewed = _previewCollateral(params.maxObligation);
        uint256 burned = IERC4626(WA_ETH_USDC).previewWithdraw(params.marginAssets);
        uint256 marginBefore = IERC20(WA_ETH_USDC).balanceOf(funder);
        deal(USDC, funder, params.maxContribution);
        uint256 usdcBefore = IERC20(USDC).balanceOf(funder);

        Signed memory s = _sign(key, params.maxContribution, params.maxCollateral);
        s.marginPermit =
            _signPermit(WA_ETH_USDC, key, address(helper), params.maxMarginShares, block.timestamp + 1 hours);
        uint256 marginNonce = IERC20Permit(WA_ETH_USDC).nonces(funder);

        vm.prank(funder);
        (, uint256 fundingAmount, uint256 collateral) =
            helper.fundWithSignatures(params, s.usdcPermit, s.usd3lPermit, s.marginPermit, s.authorization, s.signature);

        assertEq(usdcBefore - IERC20(USDC).balanceOf(funder), fundingAmount - params.borrowAssets - params.marginAssets);
        assertEq(IERC20Permit(WA_ETH_USDC).nonces(funder), marginNonce + 1);
        assertEq(IERC20(WA_ETH_USDC).allowance(funder, address(helper)), params.maxMarginShares - burned);
        _assertMarginEntry(funder, params, released, burned, marginBefore, previewed, collateral);
    }

    function testMarginBeyondReleasedRevertsForSurplusHolder() public requiresFork {
        address funder = funders[0];
        (ILCCLeveragedFundHelper.FundParams memory params, uint256 released) = _marginFundParams(funder);
        deal(USDC, funder, 1_000e6);
        vm.startPrank(funder);
        IERC20(USDC).forceApprove(WA_ETH_USDC, 1_000e6);
        IERC4626(WA_ETH_USDC).deposit(1_000e6, funder);
        vm.stopPrank();

        params.marginAssets += 10;
        uint256 burned = IERC4626(WA_ETH_USDC).previewWithdraw(params.marginAssets);
        assertGt(burned, released);
        params.maxMarginShares = burned;
        params.maxContribution = params.maxObligation - params.borrowAssets - params.marginAssets;
        _approveAll(funder, params.maxContribution);
        vm.prank(funder);
        IERC20(WA_ETH_USDC).forceApprove(address(helper), burned);

        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.MarginExceedsReleased.selector, burned, released)
        );
        vm.prank(funder);
        helper.fund(params);
    }

    function testEntryWithoutMarginNeverCallsMarginAsset() public requiresFork {
        address funder = funders[0];
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(funder);
        _approveAll(funder, params.maxContribution);

        vm.expectCall(WA_ETH_USDC, abi.encodeWithSelector(IERC4626.asset.selector), 0);
        vm.expectCall(WA_ETH_USDC, abi.encodeWithSelector(IERC4626.withdraw.selector), 0);
        vm.prank(funder);
        helper.fund(params);
        assertTrue(VAULT.fundedEpoch(CALL_EPOCH, funder));
    }

    /* UNWIND */

    function testFullUnwindAfterCooldownClosesThePosition() public requiresFork {
        address funder = funders[2];
        (uint256 start, uint256 collateral) = _enterFunder(funder);
        vm.warp(start + _cooldown());

        uint256 expectedOut = _expectedUnwindOut(collateral, _debt(funder));
        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(collateral, true, 0);
        params.minOut = expectedOut;
        vm.prank(funder);
        (uint256 repaid, uint256 usdcOut) = helper.unwind(params);

        assertGt(repaid, 0);
        assertEq(usdcOut, expectedOut);
        assertGe(usdcOut, params.minOut);
        assertEq(IERC20(USDC).balanceOf(funder), usdcOut);
        (, uint128 borrowShares, uint128 positionCollateral) = MORPHO.position(marketId, funder);
        assertEq(borrowShares, 0);
        assertEq(positionCollateral, 0);
        assertEq(helper.cooldowns(funder, marketId).length, 0);
        _assertUnwindHelperClean();
    }

    function testFullUnwindWithUsd3OutDeliversUsd3() public requiresFork {
        address funder = funders[2];
        (uint256 start, uint256 collateral) = _enterFunder(funder);
        vm.warp(start + _cooldown());

        uint256 debt = _debt(funder);
        uint256 expectedUsd3 = collateral - IERC4626(USD3).previewWithdraw(debt);
        uint256 usd3Before = IERC20(USD3).balanceOf(funder);
        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(collateral, true, 0);
        params.usd3Out = true;
        params.minOut = expectedUsd3;
        vm.prank(funder);
        (uint256 repaid, uint256 amountOut) = helper.unwind(params);

        assertEq(repaid, debt);
        assertEq(amountOut, expectedUsd3);
        assertEq(IERC20(USD3).balanceOf(funder) - usd3Before, amountOut);
        assertEq(IERC20(USDC).balanceOf(funder), 0);
        (, uint128 borrowShares, uint128 positionCollateral) = MORPHO.position(marketId, funder);
        assertEq(borrowShares, 0);
        assertEq(positionCollateral, 0);
        _assertUnwindHelperClean();
    }

    function testZeroRepayUnwindWithUsd3OutDeliversAllRedeemedUsd3() public requiresFork {
        address funder = funders[1];
        ILCCLeveragedFundHelper.FundParams memory fundParams = _fundParams(funder);
        fundParams.borrowAssets = 0;
        fundParams.maxContribution = fundParams.maxObligation;
        _approveAll(funder, fundParams.maxContribution);
        vm.prank(funder);
        (,, uint256 collateral) = helper.fund(fundParams);
        vm.warp(block.timestamp + _cooldown());

        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(collateral, true, 0);
        params.usd3Out = true;
        vm.expectCall(USD3, abi.encodeWithSelector(ILCCRedeemableVault.withdraw.selector), 0);
        vm.prank(funder);
        (uint256 repaid, uint256 amountOut) = helper.unwind(params);

        assertEq(repaid, 0);
        assertEq(amountOut, collateral);
        assertEq(IERC20(USD3).balanceOf(funder), collateral);
        _assertUnwindHelperClean();
    }

    function testUsd3OutUnwindWithZeroUsd3WithdrawLimit() public requiresFork {
        address levered = funders[2];
        (uint256 leveredStart, uint256 leveredCollateral) = _enterFunder(levered);
        address unlevered = funders[1];
        ILCCLeveragedFundHelper.FundParams memory fundParams = _fundParams(unlevered);
        fundParams.borrowAssets = 0;
        fundParams.maxContribution = fundParams.maxObligation;
        _approveAll(unlevered, fundParams.maxContribution);
        vm.prank(unlevered);
        (,, uint256 unleveredCollateral) = helper.fund(fundParams);
        vm.warp(leveredStart + _cooldown());

        vm.mockCall(USD3, abi.encodeWithSignature("availableWithdrawLimit(address)"), abi.encode(uint256(0)));

        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(leveredCollateral, true, 0);
        params.usd3Out = true;
        vm.expectRevert(bytes("ERC4626: withdraw more than max"));
        vm.prank(levered);
        helper.unwind(params);

        params = _unwindParams(unleveredCollateral, true, 0);
        params.usd3Out = true;
        vm.prank(unlevered);
        (uint256 repaid, uint256 amountOut) = helper.unwind(params);
        assertEq(repaid, 0);
        assertEq(amountOut, unleveredCollateral);
        assertEq(IERC20(USD3).balanceOf(unlevered), unleveredCollateral);
        _assertUnwindHelperClean();
    }

    function testPartialUnwindAfterCooldown() public requiresFork {
        address funder = funders[2];
        (uint256 start, uint256 collateral) = _enterFunder(funder);
        vm.warp(start + _cooldown());

        uint256 repay = _debt(funder) / 2;
        uint256 shares = collateral / 2;
        uint256 expectedOut = _expectedUnwindOut(shares, repay);
        vm.prank(funder);
        (uint256 repaid, uint256 usdcOut) = helper.unwind(_unwindParams(shares, false, repay));

        assertEq(repaid, repay);
        assertEq(usdcOut, expectedOut);
        (,, uint128 positionCollateral) = MORPHO.position(marketId, funder);
        assertEq(positionCollateral, collateral - shares);
        assertEq(helper.cooldowns(funder, marketId)[0].shares, collateral - shares);
        _assertUnwindHelperClean();
    }

    function testUnwindOneSecondBeforeMaturityReverts() public requiresFork {
        address funder = funders[2];
        (uint256 start, uint256 collateral) = _enterFunder(funder);
        vm.warp(start + _cooldown() - 1);

        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.InsufficientMaturedShares.selector, collateral, 0)
        );
        vm.prank(funder);
        helper.unwind(_unwindParams(collateral, true, 0));
    }

    function testUnwindRevertsAtomicallyWhenBypassRevoked() public requiresFork {
        address funder = funders[2];
        (uint256 start, uint256 collateral) = _enterFunder(funder);
        vm.warp(start + _cooldown());
        _setHelperBypass(false);
        uint256 debt = _debt(funder);

        vm.expectRevert(bytes("ERC4626: redeem more than max"));
        vm.prank(funder);
        helper.unwind(_unwindParams(collateral, true, 0));

        assertEq(helper.cooldowns(funder, marketId)[0].shares, collateral);
        (,, uint128 positionCollateral) = MORPHO.position(marketId, funder);
        assertEq(positionCollateral, collateral);
        assertEq(_debt(funder), debt);
    }

    function testBorrowAboveMarketLiquidityReverts() public requiresFork {
        address funder = funders[2];
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(funder);
        vm.prank(lender);
        MORPHO.withdraw(marketParams, LENDER_LIQUIDITY - params.borrowAssets + 1, 0, lender, lender);

        _approveAll(funder, params.maxContribution);
        vm.expectRevert(bytes("insufficient liquidity"));
        vm.prank(funder);
        helper.fund(params);
    }

    function testEntryAboveLtvCapReverts() public requiresFork {
        address funder = funders[0];
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(funder);
        _approveAll(funder, params.maxContribution);

        uint256 snapshot = vm.snapshotState();
        vm.prank(funder);
        helper.fund(params);
        uint256 entryLtv = _positionLtv(funder);
        vm.revertToState(snapshot);
        assertGt(entryLtv, 0);

        params.maxEntryLtv = entryLtv - 1;
        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.EntryLtvExceeded.selector, entryLtv, entryLtv - 1)
        );
        vm.prank(funder);
        helper.fund(params);

        params.maxEntryLtv = entryLtv;
        vm.prank(funder);
        helper.fund(params);
        assertTrue(VAULT.fundedEpoch(CALL_EPOCH, funder));
        assertEq(_positionLtv(funder), entryLtv);
    }

    /* AUCTION TAKES */

    function testPartialLeveredTakeDeliversPreviewedCollateralAndRealAward() public requiresFork {
        _assertAuctionWiring();
        _openForkAuction(1);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(TAKE_FILL, TAKE_BORROW);
        deal(USDC, taker, TAKE_FILL - TAKE_BORROW);
        uint256 previewed = _previewCollateral(TAKE_FILL);
        uint256 award = _dryRunAward(TAKE_FILL);
        assertGt(award, 0);
        uint256 fenceBefore = ILCCForkUSD3(USD3).ringFencedLiquidity();

        vm.prank(taker);
        (uint256 filled, uint256 collateral) = helper.takeAuction(params);

        assertEq(filled, TAKE_FILL);
        assertEq(collateral, previewed);
        assertEq(ILCCForkUSD3(USD3).ringFencedLiquidity() - fenceBefore, filled);
        assertEq(IERC20(WA_ETH_USDC).balanceOf(taker), award);
        assertEq(IERC20(USDC).balanceOf(taker), 0);
        assertEq(USD3L.balanceOf(taker), 0);
        (, uint128 borrowShares, uint128 positionCollateral) = MORPHO.position(marketId, taker);
        assertEq(positionCollateral, collateral);
        assertApproxEqAbs(_borrowAssets(borrowShares), TAKE_BORROW, 1);
        assertEq(helper.cooldowns(taker, marketId)[0].shares, collateral);
        assertEq(VAULT.syncState().pendingAuctionEpochPlusOne, CALL_EPOCH + 1);
        assertEq(VAULT.getAuctionState(CALL_EPOCH).filledAmount, filled);
        _assertHelperClean(address(VAULT));
    }

    function testLateStepTakeSourcesContributionFromRealAwardWithdrawal() public requiresFork {
        _openForkAuction(LATE_STEP);
        uint256 award = _dryRunAward(TAKE_FILL);
        uint256 marginAssets = IERC4626(WA_ETH_USDC).previewRedeem(award) / 2;
        assertGt(marginAssets, 0);
        uint256 burned = IERC4626(WA_ETH_USDC).previewWithdraw(marginAssets);

        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(TAKE_FILL, TAKE_BORROW);
        params.marginAssets = marginAssets;
        deal(USDC, taker, TAKE_FILL - TAKE_BORROW - marginAssets);

        vm.prank(taker);
        (uint256 filled, uint256 collateral) = helper.takeAuction(params);

        assertEq(filled, TAKE_FILL);
        assertEq(collateral, _previewCollateral(TAKE_FILL));
        assertEq(IERC20(USDC).balanceOf(taker), 0);
        assertEq(IERC20(WA_ETH_USDC).balanceOf(taker), award - burned);
        (, uint128 borrowShares,) = MORPHO.position(marketId, taker);
        assertApproxEqAbs(_borrowAssets(borrowShares), TAKE_BORROW, 1);
        _assertHelperClean(address(VAULT));
    }

    function testCompletingTakeSettlesWithCallOpenPriceSnapshot() public requiresFork {
        _openForkAuction(1);
        VAULT.finalizeEpochSlash(CALL_EPOCH);
        LCCAuctionLib.AuctionState memory auction = VAULT.getAuctionState(CALL_EPOCH);
        uint256 remaining = uint256(auction.shortfallAmount) - auction.filledAmount;
        assertGt(remaining, 1_000_000e6);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(remaining, 0);
        deal(USDC, taker, remaining);

        vm.recordLogs();
        vm.prank(taker);
        (uint256 filled, uint256 collateral) = helper.takeAuction(params);

        assertEq(filled, remaining);
        assertEq(collateral, _previewCollateral(remaining));
        assertEq(_countLogs(address(VAULT), LCCEventsLib.AuctionSettled.selector), 1);
        assertEq(VAULT.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(VAULT.getAuctionState(CALL_EPOCH).filledAmount, auction.shortfallAmount);
        assertEq(helper.cooldowns(taker, marketId)[0].shares, collateral);
        _assertHelperClean(address(VAULT));
    }

    function testTakeBorrowAboveMarketLiquidityReverts() public requiresFork {
        _openForkAuction(1);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(TAKE_FILL, TAKE_BORROW);
        deal(USDC, taker, TAKE_FILL - TAKE_BORROW);
        vm.prank(lender);
        MORPHO.withdraw(marketParams, LENDER_LIQUIDITY - TAKE_BORROW + 1, 0, lender, lender);
        assertGt(IERC20(USDC).balanceOf(address(MORPHO)), 2 * TAKE_BORROW);

        vm.expectRevert(bytes("insufficient liquidity"));
        vm.prank(taker);
        helper.takeAuction(params);
    }

    function testMaturedUnwindOfTakeBookedCollateral() public requiresFork {
        (uint256 start, uint256 collateral) = _takeLevered();
        vm.warp(start + _cooldown() - 1);
        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.InsufficientMaturedShares.selector, collateral, 0)
        );
        vm.prank(taker);
        helper.unwind(_unwindParams(collateral, true, 0));

        vm.warp(start + _cooldown());
        uint256 expectedOut = _expectedUnwindOut(collateral, _debt(taker));
        vm.prank(taker);
        (uint256 repaid, uint256 usdcOut) = helper.unwind(_unwindParams(collateral, true, 0));

        assertGt(repaid, TAKE_BORROW);
        assertEq(usdcOut, expectedOut);
        assertEq(IERC20(USDC).balanceOf(taker), usdcOut);
        (, uint128 borrowShares, uint128 positionCollateral) = MORPHO.position(marketId, taker);
        assertEq(borrowShares, 0);
        assertEq(positionCollateral, 0);
        assertEq(helper.cooldowns(taker, marketId).length, 0);
        _assertUnwindHelperClean();
    }

    function testTakeBookedUnwindRevertsAtomicallyWhenBypassRevoked() public requiresFork {
        (uint256 start, uint256 collateral) = _takeLevered();
        vm.warp(start + _cooldown());
        _setHelperBypass(false);
        uint256 debt = _debt(taker);

        vm.expectRevert(bytes("ERC4626: redeem more than max"));
        vm.prank(taker);
        helper.unwind(_unwindParams(collateral, true, 0));

        assertEq(helper.cooldowns(taker, marketId)[0].shares, collateral);
        (,, uint128 positionCollateral) = MORPHO.position(marketId, taker);
        assertEq(positionCollateral, collateral);
        assertEq(_debt(taker), debt);
    }

    /// @dev The production facility's auction and USD3 wiring the take tests rely on.
    function _assertAuctionWiring() internal view {
        ILCCVault.AuctionConfig memory auctionConfig = VAULT.auctionConfig();
        assertEq(auctionConfig.auctionStepCount, 192);
        assertEq(auctionConfig.auctionStepDuration, 1_800);
        assertEq(auctionConfig.auctionStepDecayRateBps, 84);
        ILCCVault.RiskConfig memory riskConfig = VAULT.riskConfig();
        assertEq(riskConfig.maxAuctionAwardBps, 10_000);
        assertEq(riskConfig.slashFeeBps, 0);
        assertTrue(ILCCForkUSD3(USD3).ringFenceConduit(address(VAULT)));
        assertTrue(ILCCForkUSD3(USD3).supplyCapExempt(address(VAULT)));
        assertEq(VAULT.assetConfig().marginAsset, WA_ETH_USDC);
    }

    /// @dev The first two test funders fund the call; the third and the production depositors default. Warps `step`
    /// award steps past the funding deadline without touching the vault, and prepares a taker with a USDC allowance
    /// and Morpho authorization for the helper.
    function _openForkAuction(uint256 step) internal {
        for (uint256 i; i < 2; ++i) {
            address funder = funders[i];
            uint256 obligation = VAULT.obligationOf(CALL_EPOCH, funder);
            deal(USDC, funder, obligation + IERC4626(USD3).previewMint(1));
            vm.startPrank(funder);
            IERC20(USDC).forceApprove(address(VAULT), type(uint256).max);
            VAULT.fundCall(false);
            vm.stopPrank();
        }
        uint256 deadline = VAULT.phaseEndsAt(CALL_EPOCH, ILCCVault.Phase.Funding);
        vm.warp(deadline + step * VAULT.auctionConfig().auctionStepDuration);

        taker = makeAddr("auction-taker");
        _approveAll(taker, type(uint128).max);
    }

    function _takeParams(uint256 maxFill, uint256 borrowAssets)
        internal
        view
        returns (ILCCLeveragedFundHelper.TakeParams memory)
    {
        uint256 previewed = _previewCollateral(maxFill);
        return ILCCLeveragedFundHelper.TakeParams({
            vault: address(VAULT),
            market: marketParams,
            maxFill: maxFill,
            minFill: 0,
            borrowAssets: borrowAssets,
            marginAssets: 0,
            minMarginAward: 0,
            minCollateral: previewed - previewed * COLLATERAL_SLACK_BPS / 10_000,
            maxEntryLtv: LLTV,
            deadline: block.timestamp
        });
    }

    /// @dev Levered partial take at the first award step; returns the cooldown start and the collateral supplied.
    function _takeLevered() internal returns (uint256 start, uint256 collateral) {
        _openForkAuction(1);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(TAKE_FILL, TAKE_BORROW);
        deal(USDC, taker, TAKE_FILL - TAKE_BORROW);
        vm.prank(taker);
        (, collateral) = helper.takeAuction(params);
        start = vm.getBlockTimestamp();
        assertEq(helper.cooldowns(taker, marketId)[0].shares, collateral);
    }

    /// @dev The waEthUSDC award a direct `fill` would receive now, measured and rolled back.
    function _dryRunAward(uint256 fill) internal returns (uint256 award) {
        address filler = makeAddr("dry-run-filler");
        uint256 snapshot = vm.snapshotState();
        deal(USDC, filler, fill);
        vm.startPrank(filler);
        IERC20(USDC).forceApprove(address(VAULT), fill);
        (, award) = VAULT.takeAuction(fill, 0, block.timestamp);
        vm.stopPrank();
        assertEq(IERC20(WA_ETH_USDC).balanceOf(filler), award);
        vm.revertToState(snapshot);
    }

    /// @dev Adds released margin to `_fundParams`: the funder's released shares (the vault's own rounding), their
    /// redeemable USDC as `marginAssets`, and the released shares as the burn bound.
    function _marginFundParams(address funder)
        internal
        view
        returns (ILCCLeveragedFundHelper.FundParams memory params, uint256 released)
    {
        params = _fundParams(funder);
        ILCCVault.Account memory account = VAULT.getAccount(funder);
        released = Math.mulDiv(account.activeMargin, params.maxObligation, account.activeCommitment);
        assertGt(released, 0);
        params.marginAssets = IERC4626(WA_ETH_USDC).previewRedeem(released);
        params.maxMarginShares = released;
        params.maxContribution = params.maxObligation - params.borrowAssets - params.marginAssets;
    }

    function _previewCollateral(uint256 fundingAmount) internal view returns (uint256) {
        return USD3L.previewDeposit(IERC4626(USD3).previewDeposit(fundingAmount));
    }

    function _fundParams(address funder) internal view returns (ILCCLeveragedFundHelper.FundParams memory) {
        uint256 obligation = VAULT.obligationOf(CALL_EPOCH, funder);
        assertGt(obligation, 0);
        assertGt(obligation, IERC4626(USD3).previewMint(1));
        uint256 borrowAssets = obligation * ENTRY_LTV_BPS / 10_000;
        uint256 previewed = _previewCollateral(obligation);
        return ILCCLeveragedFundHelper.FundParams({
            vault: address(VAULT),
            market: marketParams,
            borrowAssets: borrowAssets,
            marginAssets: 0,
            maxMarginShares: 0,
            maxContribution: obligation - borrowAssets,
            minCollateral: previewed - previewed * COLLATERAL_SLACK_BPS / 10_000,
            maxCollateral: previewed + previewed * COLLATERAL_SLACK_BPS / 10_000,
            maxEntryLtv: LLTV,
            maxObligation: obligation,
            deadline: block.timestamp
        });
    }

    function _approveAll(address funder, uint256 contribution) internal {
        deal(USDC, funder, contribution);
        vm.startPrank(funder);
        IERC20(USDC).forceApprove(address(helper), contribution);
        IERC20(address(USD3L)).forceApprove(address(helper), type(uint256).max);
        MORPHO.setAuthorization(address(helper), true);
        vm.stopPrank();
    }

    function _sign(uint256 key, uint256 usdcValue, uint256 usd3lValue) internal view returns (Signed memory) {
        return _signAll(
            SignRequest({
                helper: address(helper),
                morpho: address(MORPHO),
                usdc: USDC,
                usd3l: address(USD3L),
                key: key,
                usdcValue: usdcValue,
                usd3lValue: usd3lValue,
                deadline: block.timestamp + 1 hours
            })
        );
    }

    function _setHelperBypass(bool allowed) internal {
        ILCCForkTokenizedVault vault = ILCCForkTokenizedVault(address(USD3L));
        vm.prank(vault.management());
        vault.setCooldownBypass(address(helper), allowed);
    }

    function _cooldown() internal view returns (uint256) {
        return ILCCForkTokenizedVault(address(USD3L)).cooldownDuration();
    }

    /// @dev Levered entry with standing allowances; returns the cooldown start and the collateral supplied.
    function _enterFunder(address funder) internal returns (uint256 start, uint256 collateral) {
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(funder);
        _approveAll(funder, params.maxContribution);
        vm.prank(funder);
        (,, collateral) = helper.fund(params);
        start = block.timestamp;
        assertEq(helper.cooldowns(funder, marketId)[0].shares, collateral);
    }

    function _debt(address funder) internal returns (uint256) {
        MORPHO.accrueInterest(marketParams);
        (, uint128 borrowShares,) = MORPHO.position(marketId, funder);
        return _borrowAssets(borrowShares);
    }

    function _expectedUnwindOut(uint256 shares, uint256 repay) internal view returns (uint256) {
        return IERC4626(USD3).previewRedeem(shares) - repay;
    }

    function _assertEntry(address funder, uint256 borrowAssets, uint256 collateral) internal view {
        assertTrue(VAULT.fundedEpoch(CALL_EPOCH, funder));
        assertEq(IERC20(USDC).balanceOf(funder), 0, "contribution not fully spent");
        assertEq(USD3L.balanceOf(funder), 0, "collateral left with funder");

        (, uint128 borrowShares, uint128 positionCollateral) = MORPHO.position(marketId, funder);
        assertEq(positionCollateral, collateral);
        assertApproxEqAbs(_borrowAssets(borrowShares), borrowAssets, 1);
        _assertHelperClean(address(VAULT));
    }

    function _assertMarginEntry(
        address funder,
        ILCCLeveragedFundHelper.FundParams memory params,
        uint256 released,
        uint256 burned,
        uint256 marginBefore,
        uint256 previewed,
        uint256 collateral
    ) internal view {
        assertEq(collateral, previewed);
        assertLe(burned, released);
        assertEq(IERC20(WA_ETH_USDC).balanceOf(funder), marginBefore + released - burned, "margin shares");
        _assertEntry(funder, params.borrowAssets, collateral);
    }

    function _positionLtv(address funder) internal view returns (uint256) {
        (, uint128 borrowShares, uint128 collateral) = MORPHO.position(marketId, funder);
        uint256 collateralValue =
            uint256(collateral).mulDivDown(IOracle(marketParams.oracle).price(), ORACLE_PRICE_SCALE);
        return _borrowAssets(borrowShares).wDivUp(collateralValue);
    }

    function _borrowAssets(uint256 borrowShares) internal view returns (uint256) {
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(marketId);
        return borrowShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
    }

    function _depositMargin(address funder, uint256 usdcAmount) internal {
        deal(USDC, funder, usdcAmount);
        vm.startPrank(funder);
        IERC20(USDC).forceApprove(WA_ETH_USDC, usdcAmount);
        uint256 margin = IERC4626(WA_ETH_USDC).deposit(usdcAmount, funder);
        IERC20(WA_ETH_USDC).forceApprove(address(VAULT), margin);
        VAULT.deposit(margin, funder, 1, type(uint256).max, true, block.timestamp);
        vm.stopPrank();
    }
}
