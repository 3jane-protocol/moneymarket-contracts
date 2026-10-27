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
import {IMorphoCredit} from "../../../../src/interfaces/IMorpho.sol";
import {IOracle} from "../../../../src/interfaces/IOracle.sol";
import {IProtocolConfig} from "../../../../src/interfaces/IProtocolConfig.sol";
import {ILCCRedeemableVault} from "../../../../src/lcc/interfaces/ILCCNotificationVault.sol";
import {LCCAuctionLib} from "../../../../src/lcc/libraries/LCCAuctionLib.sol";
import {LCCErrorsLib} from "../../../../src/lcc/libraries/LCCErrorsLib.sol";
import {LCCEventsLib} from "../../../../src/lcc/libraries/LCCEventsLib.sol";
import {ORACLE_PRICE_SCALE} from "../../../../src/libraries/ConstantsLib.sol";
import {MathLib} from "../../../../src/libraries/MathLib.sol";
import {ProtocolConfigLib} from "../../../../src/libraries/ProtocolConfigLib.sol";
import {SharesMathLib} from "../../../../src/libraries/SharesMathLib.sol";

/// @dev The USD3 reads these tests need. `IUSD3` cannot be imported here because `src/usd3` compiles for Shanghai and
/// the helper for Cancun, which one compilation cannot satisfy.
interface ILCCForkUSD3 {
    function ringFencedLiquidity() external view returns (uint256);
    function ringFenceConduit(address conduit) external view returns (bool);
    function supplyCapExempt(address account) external view returns (bool);
    function nav() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function balanceOfWaUSDC() external view returns (uint256);
    function morphoCredit() external view returns (address);
    function maxOnCredit() external view returns (uint256);
    function keeper() external view returns (address);
    function tend() external;
}

/// @dev The ProtocolConfig owner read, which `IProtocolConfig` does not declare.
interface ILCCForkOwnable {
    function owner() external view returns (address);
}

/// @dev Canonical Morpho Blue's liquidation entrypoint.
interface ILCCForkMorphoLiquidation {
    function liquidate(
        IMorphoBlue.MarketParams memory marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes memory data
    ) external returns (uint256 seized, uint256 repaidAssets);
}

/// @dev Fixture shared by the helper's fork suites: three test funders deposit margin into the production facility,
/// and setUp opens `CALL_EPOCH`'s call at `_callAmount()` and warps to its Funding phase.
abstract contract LCCLeveragedFundForkBase is LCCMorphoForkFixture, LCCLeveragedFundSigUtils, LCCLeveragedFundTestBase {
    using SafeERC20 for IERC20;
    using MathLib for uint256;

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
        _openCall(CALL_EPOCH, _callAmount());
    }

    /// @dev The amount setUp calls in `CALL_EPOCH`.
    function _callAmount() internal pure virtual returns (uint256) {
        return CALL_AMOUNT;
    }

    /// @dev Opens the call for `epoch`, which must be in its PreCall phase, at `callAmount` and warps to the start of
    /// its Funding phase.
    function _openCall(uint256 epoch, uint256 callAmount) internal {
        vm.prank(FACTORY_OWNER);
        VAULT.openEpochCall(epoch, callAmount);
        vm.warp(VAULT.phaseEndsAt(epoch, ILCCVault.Phase.PreCall));
    }

    /// @dev Warps to `epoch`'s PreCall phase, syncs the vault so earlier calls are settled and its totals current,
    /// and opens `epoch`'s call for a quarter of the active commitment.
    function _openLaterCall(uint256 epoch) internal {
        vm.warp(VAULT.phaseEndsAt(epoch, ILCCVault.Phase.Normal));
        uint256[] memory called = VAULT.calledEpochs();
        VAULT.finalizeEpochSlash(called[called.length - 1]);
        _openCall(epoch, VAULT.totals().activeCommitment / 4);
    }

    /* ENTRIES */

    function _fundParams(address funder) internal view returns (ILCCLeveragedFundHelper.FundParams memory) {
        uint256 obligation = VAULT.obligationOf(VAULT.currentEpoch(), funder);
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

    /// @dev Adds released margin to `_fundParams`: the funder's released shares, their redeemable USDC as
    /// `marginAssets`, and the released shares as the burn bound.
    function _marginFundParams(address funder)
        internal
        view
        returns (ILCCLeveragedFundHelper.FundParams memory params, uint256 released)
    {
        params = _fundParams(funder);
        released = _releasedMargin(funder, params.maxObligation);
        assertGt(released, 0);
        params.marginAssets = IERC4626(WA_ETH_USDC).previewRedeem(released);
        params.maxMarginShares = released;
        params.maxContribution = params.maxObligation - params.borrowAssets - params.marginAssets;
    }

    /// @dev The margin shares amortizing `obligation` releases to `funder`, rounded down as the vault does, from the
    /// vault's view replay of the account.
    function _releasedMargin(address funder, uint256 obligation) internal view returns (uint256) {
        ILCCVault.Account memory account = VAULT.getAccount(funder);
        return Math.mulDiv(account.activeMargin, obligation, account.activeCommitment);
    }

    /// @dev Levered (`levered`) or unlevered entry with standing allowances; returns the cooldown start and the
    /// collateral supplied. An unlevered entry grants no Morpho authorization.
    function _enterFunder(address funder, bool levered) internal returns (uint256 start, uint256 collateral) {
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(funder);
        if (levered) {
            _approveAll(funder, params.maxContribution);
        } else {
            params.borrowAssets = 0;
            params.maxContribution = params.maxObligation;
            _approveTokens(funder, params.maxContribution);
        }
        vm.prank(funder);
        (,, collateral) = helper.fund(params);
        start = block.timestamp;
        ILCCLeveragedFundHelper.Cooldown[] memory book = helper.cooldowns(funder, marketId);
        assertEq(book[book.length - 1].shares, collateral);
    }

    /// @dev `funder` funds its current-epoch obligation directly on the vault, amortizing.
    function _fundDirectly(address funder) internal {
        deal(USDC, funder, VAULT.obligationOf(VAULT.currentEpoch(), funder) + IERC4626(USD3).previewMint(1));
        vm.startPrank(funder);
        IERC20(USDC).forceApprove(address(VAULT), type(uint256).max);
        VAULT.fundCall(false);
        vm.stopPrank();
    }

    /// @dev Warps `step` award steps past `CALL_EPOCH`'s funding deadline without touching the vault.
    function _warpToAuctionStep(uint256 step) internal {
        uint256 deadline = VAULT.phaseEndsAt(CALL_EPOCH, ILCCVault.Phase.Funding);
        vm.warp(deadline + step * VAULT.auctionConfig().auctionStepDuration);
    }

    /// @dev The first two test funders fund the call directly; the third and the production depositors default.
    /// Warps `step` award steps past the funding deadline without touching the vault, and prepares a taker with a USDC
    /// allowance and Morpho authorization for the helper.
    function _openForkAuction(uint256 step) internal {
        _fundDirectly(funders[0]);
        _fundDirectly(funders[1]);
        _warpToAuctionStep(step);

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

    /// @dev `user` takes `fill` of the live auction borrowing `borrowAssets`, with the contribution approved; returns
    /// the cooldown start and the collateral supplied.
    function _take(address user, uint256 fill, uint256 borrowAssets)
        internal
        returns (uint256 start, uint256 collateral)
    {
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(fill, borrowAssets);
        _approveAll(user, fill - borrowAssets);
        vm.prank(user);
        (, collateral) = helper.takeAuction(params);
        start = block.timestamp;
    }

    /// @dev Levered partial take at the first award step; returns the cooldown start and the collateral supplied.
    function _takeLevered() internal returns (uint256 start, uint256 collateral) {
        _openForkAuction(1);
        (start, collateral) = _take(taker, TAKE_FILL, TAKE_BORROW);
        assertEq(helper.cooldowns(taker, marketId)[0].shares, collateral);
    }

    /// @dev funders[0] funds levered through the helper and funders[1] funds directly, receiving its USD3l in its
    /// wallet; funders[2] and the production depositors default. Then warps one award step past the funding deadline
    /// without touching the vault or the market, so interest accrues untouched until the next entry. `fill` is an odd
    /// amount near half of funders[0]'s funded obligation.
    function _leveredFundIntoAuction()
        internal
        returns (address user, uint256 fundStart, uint256 fundCollateral, uint256 fill)
    {
        user = funders[0];
        fill = VAULT.obligationOf(CALL_EPOCH, user) / 2 | 1;
        (fundStart, fundCollateral) = _enterFunder(user, true);
        _fundDirectly(funders[1]);
        _warpToAuctionStep(1);
    }

    /// @dev Measures the whole-position LTV `params` leaves `funder` at in a rolled-back run, requires the entry to
    /// revert `EntryLtvExceeded` one unit below it, and returns `params` bounded at exactly that LTV.
    function _boundAtMeasuredLtv(address funder, ILCCLeveragedFundHelper.FundParams memory params)
        internal
        returns (ILCCLeveragedFundHelper.FundParams memory)
    {
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
        return params;
    }

    function _previewCollateral(uint256 fundingAmount) internal view returns (uint256) {
        return USD3L.previewDeposit(IERC4626(USD3).previewDeposit(fundingAmount));
    }

    /// @dev Deals `contribution` USDC to `funder` and approves the helper for it and for unlimited USD3l.
    function _approveTokens(address funder, uint256 contribution) internal {
        deal(USDC, funder, contribution);
        vm.startPrank(funder);
        IERC20(USDC).forceApprove(address(helper), contribution);
        IERC20(address(USD3L)).forceApprove(address(helper), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev `_approveTokens` plus the funder's Morpho authorization of the helper.
    function _approveAll(address funder, uint256 contribution) internal {
        _approveTokens(funder, contribution);
        if (!MORPHO.isAuthorized(funder, address(helper))) {
            vm.prank(funder);
            MORPHO.setAuthorization(address(helper), true);
        }
    }

    function _sign(uint256 key, uint256 usdcValue, uint256 usd3lValue) internal view returns (Signed memory) {
        return _signAll(
            SignRequest({
                helper: helper,
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

    function _debt(address funder) internal returns (uint256) {
        MORPHO.accrueInterest(marketParams);
        return _borrowAssetsOf(marketId, funder);
    }

    /// @dev USDC from redeeming `shares` of USD3l to USD3 and that USD3 to USDC, minus `repay`.
    function _expectedUnwindOut(uint256 shares, uint256 repay) internal view returns (uint256) {
        return IERC4626(USD3).previewRedeem(USD3L.previewRedeem(shares)) - repay;
    }

    /* ASSERTIONS */

    function _assertEntry(address funder, uint256 borrowAssets, uint256 collateral) internal view {
        assertTrue(VAULT.fundedEpoch(VAULT.currentEpoch(), funder));
        assertEq(IERC20(USDC).balanceOf(funder), 0, "contribution not fully spent");
        assertEq(USD3L.balanceOf(funder), 0, "collateral left with funder");

        (,, uint128 positionCollateral) = MORPHO.position(marketId, funder);
        assertEq(positionCollateral, collateral);
        assertApproxEqAbs(_borrowAssetsOf(marketId, funder), borrowAssets, 1);
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

    /// @dev `user` holds no borrow shares or collateral in the market and the helper is clean after the unwind.
    function _assertPositionClosed(address user) internal view {
        (, uint128 borrowShares, uint128 collateral) = MORPHO.position(marketId, user);
        assertEq(borrowShares, 0);
        assertEq(collateral, 0);
        _assertUnwindHelperClean();
    }

    /// @dev The unwind sent `user` exactly `expectedOut` of `outToken`, which is `user`'s whole balance of it, and
    /// closed the position, emptying its cooldown book.
    function _assertFullyUnwound(address user, address outToken, uint256 amountOut, uint256 expectedOut) internal view {
        assertEq(amountOut, expectedOut);
        assertEq(IERC20(outToken).balanceOf(user), amountOut);
        _assertPositionClosed(user);
        assertEq(helper.cooldowns(user, marketId).length, 0);
    }

    /// @dev `user`'s whole-position LTV at the market oracle price with `debt`, rounding up as the helper does.
    function _ltv(address user, uint256 debt) internal view returns (uint256) {
        (,, uint128 collateral) = MORPHO.position(marketId, user);
        uint256 collateralValue =
            uint256(collateral).mulDivDown(IOracle(marketParams.oracle).price(), ORACLE_PRICE_SCALE);
        return debt.wDivUp(collateralValue);
    }

    function _positionLtv(address user) internal view returns (uint256) {
        return _ltv(user, _borrowAssetsOf(marketId, user));
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

contract LCCLeveragedFundEntryForkTest is LCCLeveragedFundForkBase {
    using SafeERC20 for IERC20;
    using SharesMathLib for uint256;

    function testFeedlessOraclePricesUSD3lAtTheUSD3ShareRate() public requiresFork {
        assertEq(USD3L.asset(), USD3);
        assertEq(USD3L.convertToAssets(1e6), 1e6);
        assertEq(USD3L.previewDeposit(1e6), 1e6);
        uint256 price = IOracle(USD3_USDC_ORACLE).price();
        assertEq(price, IERC4626(USD3).convertToAssets(1e6) * 1e30);
        assertGt(price, ORACLE_PRICE_SCALE);
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

    /* FUNDING TOP-UP */

    /// @dev Mocks only USD3's `previewMint(1)`, the one read from which both the helper and the live vault's `_fund`
    /// size the top-up, because no reachable USD3 share price puts the one-share minimum 1,000 base units above an
    /// obligation. At 1,001 units over the obligation the helper and the vault both reject the funding; at the
    /// 1,000-unit bound the levered entry pays the vault the topped-up amount while the vault records the obligation.
    function testFundingTopUpBoundMirrorsTheLiveVault() public requiresFork {
        address funder = funders[1];
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(funder);
        uint256 obligation = params.maxObligation;
        bytes memory previewMintOne = abi.encodeCall(IERC4626.previewMint, (1));

        vm.mockCall(USD3, previewMintOne, abi.encode(obligation + 1_001));
        params.maxContribution = obligation + 1_001 - params.borrowAssets;
        _approveAll(funder, params.maxContribution);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILCCLeveragedFundHelper.FundingTopUpExceeded.selector, obligation + 1_001, obligation
            )
        );
        vm.prank(funder);
        helper.fund(params);
        vm.startPrank(funder);
        IERC20(USDC).forceApprove(address(VAULT), obligation + 1_001);
        vm.expectRevert(LCCErrorsLib.FundingTopUpExcessive.selector);
        VAULT.fundCall(false);
        IERC20(USDC).forceApprove(address(VAULT), 0);
        vm.stopPrank();

        uint256 fundingAmount = obligation + 1_000;
        vm.mockCall(USD3, previewMintOne, abi.encode(fundingAmount));
        uint256 previewed = _previewCollateral(fundingAmount);
        params.maxContribution = fundingAmount - params.borrowAssets;
        params.minCollateral = previewed;
        params.maxCollateral = previewed;
        _approveAll(funder, params.maxContribution);
        uint256 fundedBefore = VAULT.getEpochState(CALL_EPOCH).fundedAmount;

        vm.expectEmit(true, true, true, true, address(VAULT));
        emit LCCEventsLib.CallFunded(address(helper), funder, CALL_EPOCH, obligation, fundingAmount);
        vm.prank(funder);
        (uint256 funded, uint256 funding, uint256 collateral) = helper.fund(params);

        assertEq(funded, obligation);
        assertEq(funding, fundingAmount);
        assertEq(collateral, previewed);
        assertEq(VAULT.getEpochState(CALL_EPOCH).fundedAmount - fundedBefore, obligation);
        assertEq(VAULT.obligationOf(CALL_EPOCH, funder), 0);
        _assertEntry(funder, params.borrowAssets, collateral);
    }

    /* MULTI-EPOCH LIFECYCLE */

    /// @dev One funder funds levered through the helper in `CALL_EPOCH` and again in the next epoch's call, against
    /// the deployed vault. The second funding runs on an account with history (an amortized funding, then the other
    /// accounts' default, slash, and auction settlement), so it pins the helper's sizing reads (`currentPhase`,
    /// `obligationOf`, the view replay behind `getAccount`) against what the vault's own replay inside `fundCall`
    /// charges and releases. Each entry is bounded at its exact whole-position LTV. The first cooldown is then unwound
    /// at its maturity with its collateral's pro-rata share of the debt, and the funder re-enters in a third epoch's
    /// call, opening a new cooldown behind the open one.
    function testLeveredFundingAcrossEpochsMatchesTheVaultsAccountReplay() public requiresFork {
        address user = funders[0];
        (uint256 firstStart, uint256 firstCollateral) = _fundLeveredAgainstTheVault(user);

        _openLaterCall(CALL_EPOCH + 1);
        assertEq(VAULT.syncState().pendingAuctionEpochPlusOne, 0);
        assertTrue(VAULT.getEpochState(CALL_EPOCH).slashFinalized);
        (uint256 secondStart, uint256 secondCollateral) = _fundLeveredAgainstTheVault(user);
        _assertTwoCooldowns(user, firstCollateral, firstStart, secondCollateral, secondStart);

        vm.warp(firstStart + _cooldown());
        assertLt(block.timestamp, secondStart + _cooldown());
        _unwindFirstCooldown(user, firstCollateral, secondCollateral, secondStart);

        _openLaterCall(CALL_EPOCH + 2);
        (uint256 thirdStart, uint256 thirdCollateral) = _fundLeveredAgainstTheVault(user);
        _assertTwoCooldowns(user, secondCollateral, secondStart, thirdCollateral, thirdStart);
        assertEq(helper.maxUnwindable(user, marketId), 0);
    }

    /// @dev At the first of `user`'s two cooldowns' maturity, unwinds exactly its `firstCollateral`, repaying that
    /// collateral's pro-rata share of the whole debt, which leaves the second entry's collateral, cooldown, and the
    /// rest of the debt.
    function _unwindFirstCooldown(address user, uint256 firstCollateral, uint256 secondCollateral, uint256 secondStart)
        internal
    {
        assertEq(helper.maxUnwindable(user, marketId), firstCollateral);
        uint256 debt = _debt(user);
        uint256 repay = debt * firstCollateral / (firstCollateral + secondCollateral);
        uint256 expectedRepaid = _repaidFor(repay);
        uint256 expectedOut = _expectedUnwindOut(firstCollateral, expectedRepaid);
        vm.prank(user);
        (uint256 repaid, uint256 usdcOut) = helper.unwind(_unwindParams(firstCollateral, false, repay));

        assertEq(repaid, expectedRepaid);
        assertEq(usdcOut, expectedOut);
        assertEq(IERC20(USDC).balanceOf(user), usdcOut);
        assertApproxEqAbs(_borrowAssetsOf(marketId, user), debt - repaid, 1);
        assertEq(_collateralOf(user), secondCollateral);
        assertLt(_positionLtv(user), LLTV);
        ILCCLeveragedFundHelper.Cooldown[] memory book = helper.cooldowns(user, marketId);
        assertEq(book.length, 1);
        _assertCooldown(book[0], secondCollateral, secondStart, _cooldown());
        _assertUnwindHelperClean();
    }

    function _assertTwoCooldowns(
        address user,
        uint256 firstShares,
        uint256 firstStart,
        uint256 secondShares,
        uint256 secondStart
    ) internal view {
        ILCCLeveragedFundHelper.Cooldown[] memory book = helper.cooldowns(user, marketId);
        assertEq(book.length, 2);
        _assertCooldown(book[0], firstShares, firstStart, _cooldown());
        _assertCooldown(book[1], secondShares, secondStart, _cooldown());
    }

    /// @dev `funder`'s levered entry into the current epoch's call, bounded at its exact whole-position LTV; requires
    /// the obligation the helper funded to be what the vault's `fundCall` charged (its `CallFunded` event and the
    /// epoch's `fundedAmount`) and the margin the vault released to equal the view replay's prediction.
    function _fundLeveredAgainstTheVault(address funder) internal returns (uint256 start, uint256 collateral) {
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(funder);
        uint256 epoch = VAULT.currentEpoch();
        FundBaseline memory before = FundBaseline({
            obligation: params.maxObligation,
            released: _releasedMargin(funder, params.maxObligation),
            margin: IERC20(WA_ETH_USDC).balanceOf(funder),
            collateral: _collateralOf(funder),
            funded: VAULT.getEpochState(epoch).fundedAmount
        });
        assertGt(before.released, 0);
        _approveAll(funder, params.maxContribution);
        params = _boundAtMeasuredLtv(funder, params);

        vm.expectEmit(true, true, true, true, address(VAULT));
        emit LCCEventsLib.CallFunded(address(helper), funder, epoch, before.obligation, before.obligation);
        vm.prank(funder);
        uint256 funded;
        uint256 fundingAmount;
        (funded, fundingAmount, collateral) = helper.fund(params);
        start = block.timestamp;

        assertEq(funded, before.obligation);
        assertEq(fundingAmount, before.obligation);
        assertEq(VAULT.getEpochState(epoch).fundedAmount - before.funded, funded);
        assertTrue(VAULT.fundedEpoch(epoch, funder));
        assertEq(VAULT.obligationOf(epoch, funder), 0);
        assertEq(IERC20(WA_ETH_USDC).balanceOf(funder) - before.margin, before.released, "margin release");
        assertEq(_collateralOf(funder) - before.collateral, collateral);
        assertEq(_positionLtv(funder), params.maxEntryLtv);
        assertEq(IERC20(USDC).balanceOf(funder), 0);
        assertEq(USD3L.balanceOf(funder), 0);
        _assertHelperClean(address(VAULT));
    }

    /// @dev A funder's state before `_fundLeveredAgainstTheVault`'s entry, with the vault's predicted release.
    struct FundBaseline {
        uint256 obligation;
        uint256 released;
        uint256 margin;
        uint256 collateral;
        uint256 funded;
    }

    function _collateralOf(address user) internal view returns (uint256) {
        (,, uint128 collateral) = MORPHO.position(marketId, user);
        return collateral;
    }

    /* COLLATERAL LEAVING OUTSIDE THE HELPER */

    /// @dev After a levered entry the funder withdraws part of its collateral directly on Morpho, staying healthy. At
    /// maturity live collateral, not the cooldown book, caps the unwind: `maxUnwindable` is the remaining collateral,
    /// one share more reverts `SharesExceedCollateral`, and a full unwind of the remainder closes the position while
    /// the book keeps the withdrawn shares' cooldown. A re-entry by the same funder in the same market then trims the
    /// book to its pre-entry collateral, zero, before adding its own cooldown, so the departed shares' matured cooldown
    /// makes none of the new collateral unwindable.
    function testDirectCollateralWithdrawalCapsUnwindsAndReentryTrimsTheDepartedCooldown() public requiresFork {
        address user = funders[2];
        (uint256 start, uint256 collateral) = _enterFunder(user, true);
        uint256 withdrawn = collateral / 20;
        vm.prank(user);
        MORPHO.withdrawCollateral(marketParams, withdrawn, user, user);
        assertEq(USD3L.balanceOf(user), withdrawn);
        assertLt(_positionLtv(user), LLTV);

        vm.warp(start + _cooldown());
        _assertUnwindCappedByLiveCollateral(user, collateral, start, withdrawn);
        _assertReentryTrimsDepartedCooldown(user, start, withdrawn);
    }

    /// @dev Mocks only the market oracle's `price()`, 10% below the USD3 share rate, because no reachable USD3 share
    /// price makes the entry liquidatable; Morpho's real `liquidate` then seizes half the funder's collateral from a
    /// liquidator holding USDC, and the mock is cleared. A third party calling `trimCooldowns` right after the
    /// liquidation trims the book to Morpho's post-liquidation collateral. Without that trim, at maturity the
    /// post-liquidation collateral caps the unwind as for a direct withdrawal, the full unwind repays Morpho's
    /// post-liquidation debt, and the seized shares' cooldown stays in the book until a re-entry by the same funder in
    /// the same market trims it before adding its own cooldown.
    function testLiquidationCapsUnwindsAndTrimCooldownsOrReentryTrimsTheSeizedCooldown() public requiresFork {
        address user = funders[2];
        (uint256 start, uint256 collateral) = _enterFunder(user, true);
        uint256 seized = _liquidateHalf(user);
        uint256 liquidated = vm.snapshotState();

        vm.recordLogs();
        vm.prank(makeAddr("third-party"));
        assertEq(helper.trimCooldowns(user, marketId), seized);
        assertEq(_singleLogData(address(helper), ILCCLeveragedFundHelper.CooldownsTrimmed.selector), abi.encode(seized));
        assertEq(_collateralOf(user), collateral - seized);
        ILCCLeveragedFundHelper.Cooldown[] memory book = helper.cooldowns(user, marketId);
        assertEq(book.length, 1);
        _assertCooldown(book[0], collateral - seized, start, _cooldown());
        vm.revertToState(liquidated);

        vm.warp(start + _cooldown());
        _assertUnwindCappedByLiveCollateral(user, collateral, start, seized);
        _assertReentryTrimsDepartedCooldown(user, start, seized);
    }

    /// @dev After `user`'s position closed with `departed` shares of the cooldown started at `start` left in its book,
    /// a re-entry at a later call trims those shares (`CooldownsTrimmed`) and leaves only its own, unmatured cooldown.
    function _assertReentryTrimsDepartedCooldown(address user, uint256 start, uint256 departed) internal {
        _openLaterCall(CALL_EPOCH + 2);
        vm.recordLogs();
        (uint256 reentryStart, uint256 reentryCollateral) = _enterFunder(user, true);
        assertEq(
            _singleLogData(address(helper), ILCCLeveragedFundHelper.CooldownsTrimmed.selector), abi.encode(departed)
        );
        assertGt(reentryStart, start + _cooldown());
        ILCCLeveragedFundHelper.Cooldown[] memory book = helper.cooldowns(user, marketId);
        assertEq(book.length, 1);
        _assertCooldown(book[0], reentryCollateral, reentryStart, _cooldown());
        assertEq(helper.maxUnwindable(user, marketId), 0);
    }

    /// @dev Makes `user`'s position liquidatable by mocking the market oracle's `price()` 10% low, liquidates half
    /// its collateral through Morpho's real `liquidate`, and clears the mock; returns the shares seized.
    function _liquidateHalf(address user) internal returns (uint256 seized) {
        uint256 price = IOracle(USD3_USDC_ORACLE).price();
        vm.mockCall(USD3_USDC_ORACLE, abi.encodeCall(IOracle.price, ()), abi.encode(price * 9 / 10));
        assertGt(_positionLtv(user), LLTV);

        address liquidator = makeAddr("liquidator");
        uint256 debtBefore = _debt(user);
        deal(USDC, liquidator, debtBefore);
        vm.startPrank(liquidator);
        IERC20(USDC).forceApprove(address(MORPHO), debtBefore);
        uint256 repaidAssets;
        (seized, repaidAssets) =
            ILCCForkMorphoLiquidation(address(MORPHO)).liquidate(marketParams, user, _collateralOf(user) / 2, 0, "");
        vm.stopPrank();
        vm.clearMockedCalls();

        assertGt(seized, 0);
        assertEq(USD3L.balanceOf(liquidator), seized);
        assertEq(IERC20(USDC).balanceOf(liquidator), debtBefore - repaidAssets);
        assertApproxEqAbs(_borrowAssetsOf(marketId, user), debtBefore - repaidAssets, 1);
        assertGt(_borrowAssetsOf(marketId, user), 0);
        assertLt(_positionLtv(user), LLTV);
    }

    /// @dev At `user`'s maturity, after `removed` of its `collateral` left the position outside the helper:
    /// `maxUnwindable` is the live collateral, one share more reverts `SharesExceedCollateral`, and a full unwind of
    /// the live collateral repays Morpho's debt and closes the position, leaving `removed` shares of the entry's
    /// cooldown in the book and nothing unwindable.
    function _assertUnwindCappedByLiveCollateral(address user, uint256 collateral, uint256 start, uint256 removed)
        internal
    {
        uint256 live = collateral - removed;
        assertEq(_collateralOf(user), live);
        assertEq(helper.maxUnwindable(user, marketId), live);

        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.SharesExceedCollateral.selector, live + 1, live));
        vm.prank(user);
        helper.unwind(_unwindParams(live + 1, true, 0));

        uint256 debt = _debt(user);
        uint256 expectedOut = _expectedUnwindOut(live, debt);
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        vm.prank(user);
        (uint256 repaid, uint256 usdcOut) = helper.unwind(_unwindParams(live, true, 0));

        assertEq(repaid, debt);
        assertEq(usdcOut, expectedOut);
        assertEq(IERC20(USDC).balanceOf(user) - usdcBefore, usdcOut);
        _assertPositionClosed(user);
        ILCCLeveragedFundHelper.Cooldown[] memory book = helper.cooldowns(user, marketId);
        assertEq(book.length, 1);
        _assertCooldown(book[0], removed, start, _cooldown());
        assertEq(helper.maxUnwindable(user, marketId), 0);
    }

    /* UNWIND */

    function testFullUnwindWithUsd3OutDeliversUsd3() public requiresFork {
        address funder = funders[2];
        (uint256 start, uint256 collateral) = _enterFunder(funder, true);
        vm.warp(start + _cooldown());

        uint256 debt = _debt(funder);
        uint256 expectedUsd3 = USD3L.previewRedeem(collateral) - IERC4626(USD3).previewWithdraw(debt);
        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(collateral, true, 0);
        params.usd3Out = true;
        params.minOut = expectedUsd3;
        vm.prank(funder);
        (uint256 repaid, uint256 amountOut) = helper.unwind(params);

        assertEq(repaid, debt);
        assertEq(IERC20(USDC).balanceOf(funder), 0);
        _assertFullyUnwound(funder, USD3, amountOut, expectedUsd3);
    }

    /// @dev Mocks only USD3's `availableWithdrawLimit` to zero, the one read USD3's `withdraw` checks, to isolate it
    /// from the pending-loss state that `testPendingUsd3LossRevertsDebtBearingUnwindButNotZeroDebtUsd3Out` drives: a
    /// debt-bearing `usd3Out` unwind converts its repayment through USD3's `withdraw` and reverts there.
    function testUsd3OutUnwindWithZeroUsd3WithdrawLimitReverts() public requiresFork {
        address levered = funders[2];
        (uint256 start, uint256 collateral) = _enterFunder(levered, true);
        vm.warp(start + _cooldown());

        vm.mockCall(USD3, abi.encodeWithSelector(ILCCForkTokenizedVault.availableWithdrawLimit.selector), abi.encode(0));
        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(collateral, true, 0);
        params.usd3Out = true;
        vm.expectRevert(bytes("ERC4626: withdraw more than max"));
        vm.prank(levered);
        helper.unwind(params);
    }

    function testPartialUnwindAfterCooldown() public requiresFork {
        address funder = funders[2];
        (uint256 start, uint256 collateral) = _enterFunder(funder, true);
        vm.warp(start + _cooldown());

        uint256 repay = _debt(funder) / 2;
        uint256 shares = collateral / 2;
        uint256 expectedOut = _expectedUnwindOut(shares, repay);
        vm.prank(funder);
        (uint256 repaid, uint256 usdcOut) = helper.unwind(_unwindParams(shares, false, repay));

        assertEq(repaid, repay);
        assertEq(usdcOut, expectedOut);
        assertEq(_collateralOf(funder), collateral - shares);
        assertEq(helper.cooldowns(funder, marketId)[0].shares, collateral - shares);
        _assertUnwindHelperClean();
    }

    /// @dev All three funders unwind their whole levered positions in one block against real USD3 liquidity, each
    /// receiving USD3's live `previewRedeem` of its collateral's USD3 minus its accrued debt.
    function testBackToBackFullUnwindsInOneBlockPayTheRealRedemptionValue() public requiresFork {
        uint256[] memory collateral = new uint256[](funders.length);
        uint256 start;
        for (uint256 i; i < funders.length; ++i) {
            (start, collateral[i]) = _enterFunder(funders[i], true);
        }
        vm.warp(start + _cooldown());
        MORPHO.accrueInterest(marketParams);
        assertGe(ILCCForkUSD3(USD3).nav() + 2, ILCCForkUSD3(USD3).totalAssets(), "pending USD3 loss");

        for (uint256 i; i < funders.length; ++i) {
            address funder = funders[i];
            uint256 debt = _borrowAssetsOf(marketId, funder);
            uint256 expectedOut = _expectedUnwindOut(collateral[i], debt);
            vm.prank(funder);
            (uint256 repaid, uint256 usdcOut) = helper.unwind(_unwindParams(collateral[i], true, 0));

            assertEq(repaid, debt);
            _assertFullyUnwound(funder, USDC, usdcOut, expectedOut);
        }
    }

    /// @dev A real pending USD3 loss zeroes USD3's withdraw limit, so a debt-bearing USDC unwind reverts inside USD3's
    /// redemption, while a zero-debt `usd3Out` unwind never reaches USD3's withdraw limit and succeeds. The zero-debt
    /// funder entered unlevered and never authorized the helper on Morpho, so it unwinds through
    /// `unwindWithAuthorization` with a real Morpho authorization signed by its key.
    function testPendingUsd3LossRevertsDebtBearingUnwindButNotZeroDebtUsd3Out() public requiresFork {
        address levered = funders[2];
        (uint256 start, uint256 leveredCollateral) = _enterFunder(levered, true);
        address unlevered = funders[1];
        (, uint256 unleveredCollateral) = _enterFunder(unlevered, false);
        vm.warp(start + _cooldown());
        _createPendingLoss();

        vm.expectRevert(bytes("ERC4626: redeem more than max"), USD3);
        vm.prank(levered);
        helper.unwind(_unwindParams(leveredCollateral, true, 0));

        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(unleveredCollateral, true, 0);
        params.usd3Out = true;
        uint256 expectedUsd3 = USD3L.previewRedeem(unleveredCollateral);
        assertFalse(MORPHO.isAuthorized(unlevered, address(helper)));
        IMorphoBlue.Authorization memory authorization =
            _morphoAuthorization(address(MORPHO), unlevered, address(helper), block.timestamp);
        IMorphoBlue.Signature memory signature = _signMorphoAuthorization(address(MORPHO), funderKeys[1], authorization);

        vm.expectCall(USD3, abi.encodeWithSelector(ILCCRedeemableVault.withdraw.selector), 0);
        vm.prank(unlevered);
        (uint256 repaid, uint256 amountOut) = helper.unwindWithAuthorization(params, authorization, signature);

        assertEq(repaid, 0);
        assertTrue(MORPHO.isAuthorized(unlevered, address(helper)));
        assertEq(MORPHO.nonce(unlevered), authorization.nonce + 1);
        _assertFullyUnwound(unlevered, USD3, amountOut, expectedUsd3);
    }

    function testEntryAboveLtvCapReverts() public requiresFork {
        address funder = funders[0];
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(funder);
        _approveAll(funder, params.maxContribution);
        params = _boundAtMeasuredLtv(funder, params);

        vm.prank(funder);
        helper.fund(params);
        assertTrue(VAULT.fundedEpoch(CALL_EPOCH, funder));
        assertEq(_positionLtv(funder), params.maxEntryLtv);
    }

    /* AUCTION TAKES */

    function testPartialLeveredTakeDeliversPreviewedCollateralAndRealAward() public requiresFork {
        _assertAuctionWiring();
        _openForkAuction(1);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(TAKE_FILL, TAKE_BORROW);
        deal(USDC, taker, TAKE_FILL - TAKE_BORROW);
        uint256 previewed = _previewCollateral(TAKE_FILL);
        uint256 award = _dryRunAward(address(VAULT), TAKE_FILL);
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
        assertEq(_collateralOf(taker), collateral);
        assertApproxEqAbs(_borrowAssetsOf(marketId, taker), TAKE_BORROW, 1);
        assertEq(helper.cooldowns(taker, marketId)[0].shares, collateral);
        assertEq(VAULT.syncState().pendingAuctionEpochPlusOne, CALL_EPOCH + 1);
        assertEq(VAULT.getAuctionState(CALL_EPOCH).filledAmount, filled);
        _assertHelperClean(address(VAULT));
    }

    function testLateStepTakeSourcesContributionFromRealAwardWithdrawal() public requiresFork {
        _openForkAuction(LATE_STEP);
        uint256 award = _dryRunAward(address(VAULT), TAKE_FILL);
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
        assertApproxEqAbs(_borrowAssetsOf(marketId, taker), TAKE_BORROW, 1);
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

    /// @dev A take quoted for the whole remaining shortfall, with borrow, award-sourced margin, and an award floor,
    /// executes after another filler took part of the auction directly: the helper sizes the fill after the vault's
    /// sync, scales the quote to it with the rounding dust on the borrow, and completes and settles the auction.
    function testFrontRunTakeFillsTheRemainderWithScaledBridgedAmounts() public requiresFork {
        _openForkAuction(LATE_STEP);
        VAULT.finalizeEpochSlash(CALL_EPOCH);
        LCCAuctionLib.AuctionState memory auction = VAULT.getAuctionState(CALL_EPOCH);
        uint256 quotedFill = uint256(auction.shortfallAmount) - auction.filledAmount;
        uint256 quotedAward = _dryRunAward(address(VAULT), quotedFill);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(quotedFill, quotedFill * 4 / 10 + 7);
        params.marginAssets = IERC4626(WA_ETH_USDC).previewRedeem(quotedAward) / 4 + 3;
        params.minMarginAward = quotedAward * 9 / 10;
        params.maxEntryLtv = 0.5e18;
        uint256 quotedContribution = quotedFill - params.borrowAssets - params.marginAssets;
        deal(USDC, taker, quotedContribution);
        vm.prank(taker);
        IERC20(USDC).forceApprove(address(helper), quotedContribution);

        uint256 fill = quotedFill - _frontRunTake(quotedFill / 3);
        TakeScaled memory scaled = _scaleTake(params, quotedContribution, fill);
        uint256 award = _dryRunAward(address(VAULT), fill);
        assertGe(award, scaled.awardFloor);
        uint256 burned = IERC4626(WA_ETH_USDC).previewWithdraw(scaled.marginAssets);
        uint256 previewed = _previewCollateral(fill);

        vm.recordLogs();
        vm.prank(taker);
        (uint256 filled, uint256 collateral) = helper.takeAuction(params);

        assertEq(filled, fill);
        assertEq(collateral, previewed);
        assertEq(IERC20(USDC).balanceOf(taker), quotedContribution - scaled.contribution);
        assertEq(IERC20(WA_ETH_USDC).balanceOf(taker), award - burned);
        assertApproxEqAbs(_borrowAssetsOf(marketId, taker), scaled.borrowAssets, 1);
        assertLe(_positionLtv(taker), params.maxEntryLtv);
        assertEq(_countLogs(address(VAULT), LCCEventsLib.AuctionSettled.selector), 1);
        assertEq(VAULT.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(VAULT.getAuctionState(CALL_EPOCH).filledAmount, auction.shortfallAmount);
        assertEq(helper.cooldowns(taker, marketId)[0].shares, collateral);
        _assertHelperClean(address(VAULT));
    }

    /// @dev A levered take on top of a levered funding position, after interest accrued untouched since the funding:
    /// the entry LTV bound is judged on the debt Morpho's `borrow` accrued, the two entries form a two-cooldown book
    /// under the real USD3l duration, and the position then unwinds in two stages, a partial `usd3Out` unwind leaving
    /// debt at the first maturity and a full USDC unwind at the second.
    function testTakeAfterAccrualThenStagedUnwinds() public requiresFork {
        (address user, uint256 fundStart, uint256 fundCollateral, uint256 fill) = _leveredFundIntoAuction();
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(fill, fill / 2);
        _approveAll(user, fill - fill / 2);
        uint256 takeLtv = _accruedTakeLtv(user, params);

        params.maxEntryLtv = takeLtv - 1;
        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.EntryLtvExceeded.selector, takeLtv, takeLtv - 1));
        vm.prank(user);
        helper.takeAuction(params);

        params.maxEntryLtv = takeLtv;
        vm.prank(user);
        (, uint256 takeCollateral) = helper.takeAuction(params);
        uint256 takeStart = block.timestamp;
        assertEq(_positionLtv(user), takeLtv);
        _assertHelperClean(address(VAULT));

        ILCCLeveragedFundHelper.Cooldown[] memory book = helper.cooldowns(user, marketId);
        assertEq(book.length, 2);
        _assertCooldown(book[0], fundCollateral, fundStart, _cooldown());
        _assertCooldown(book[1], takeCollateral, takeStart, _cooldown());

        vm.warp(fundStart + _cooldown());
        assertLt(block.timestamp, takeStart + _cooldown());
        assertEq(helper.maxUnwindable(user, marketId), fundCollateral);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILCCLeveragedFundHelper.InsufficientMaturedShares.selector, fundCollateral + 1, fundCollateral
            )
        );
        vm.prank(user);
        helper.unwind(_unwindParams(fundCollateral + 1, false, 0));

        _partialUsd3OutUnwind(user, fundCollateral);
        (, uint128 borrowShares,) = MORPHO.position(marketId, user);
        assertGt(borrowShares, 0);
        assertEq(_collateralOf(user), takeCollateral);
        assertLt(_positionLtv(user), LLTV);
        book = helper.cooldowns(user, marketId);
        assertEq(book.length, 1);
        _assertCooldown(book[0], takeCollateral, takeStart, _cooldown());

        vm.warp(takeStart + _cooldown());
        uint256 expectedOut = _expectedUnwindOut(takeCollateral, _debt(user));
        vm.prank(user);
        (, uint256 usdcOut) = helper.unwind(_unwindParams(takeCollateral, true, 0));
        _assertFullyUnwound(user, USDC, usdcOut, expectedOut);
    }

    /// @dev USD3l management shuts USD3l down through its real TokenizedStrategy path before any cooldown matures. The
    /// vault then waives its own cooldown for a non-bypassed holder of cooled USD3l, the helper waives its gate so an
    /// unmatured unwind consumes the book oldest first, and a new entry reverts because USD3l takes no deposits.
    function testUsd3lShutdownWaivesTheCooldownForVaultAndHelper() public requiresFork {
        (address user, uint256 fundStart, uint256 fundCollateral, uint256 fill) = _leveredFundIntoAuction();
        (uint256 takeStart, uint256 takeCollateral) = _take(user, fill, fill / 2);

        _shutDownUsd3lWithCooledHolder(funders[1]);
        assertLt(block.timestamp, fundStart + _cooldown());
        _assertTakeRevertsWhileUsd3lShutDown();

        uint256 liveCollateral = fundCollateral + takeCollateral;
        assertEq(helper.maxUnwindable(user, marketId), liveCollateral);
        uint256 shares = fundCollateral + takeCollateral / 2;
        uint256 expectedOut = _expectedUnwindOut(shares, _debt(user));
        vm.prank(user);
        (, uint256 usdcOut) = helper.unwind(_unwindParams(shares, true, 0));

        assertEq(usdcOut, expectedOut);
        assertEq(IERC20(USDC).balanceOf(user), usdcOut);
        (, uint128 borrowShares, uint128 positionCollateral) = MORPHO.position(marketId, user);
        assertEq(borrowShares, 0);
        assertEq(positionCollateral, liveCollateral - shares);
        ILCCLeveragedFundHelper.Cooldown[] memory book = helper.cooldowns(user, marketId);
        assertEq(book.length, 1);
        _assertCooldown(book[0], takeCollateral - takeCollateral / 2, takeStart, _cooldown());
        assertEq(helper.maxUnwindable(user, marketId), liveCollateral - shares);
        _assertUnwindHelperClean();
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
        _assertFullyUnwound(taker, USDC, usdcOut, expectedOut);
    }

    /// @dev With the helper's USD3l cooldown bypass revoked, a matured unwind reverts inside USD3l's redemption; once
    /// management restores the bypass the same unwind succeeds.
    function testUnwindRevertsWhileBypassRevokedAndSucceedsOnceRestored() public requiresFork {
        (uint256 start, uint256 collateral) = _takeLevered();
        vm.warp(start + _cooldown());
        _setHelperBypass(false);

        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(collateral, true, 0);
        vm.expectRevert(bytes("ERC4626: redeem more than max"), address(USD3L));
        vm.prank(taker);
        helper.unwind(params);

        _setHelperBypass(true);
        uint256 expectedOut = _expectedUnwindOut(collateral, _debt(taker));
        vm.prank(taker);
        (, uint256 usdcOut) = helper.unwind(params);
        _assertFullyUnwound(taker, USDC, usdcOut, expectedOut);
    }

    /* SHARED FLOWS & ASSERTIONS */

    /// @dev A take quote scaled to `fill` as `ILCCLeveragedFundHelper.TakeParams` specifies.
    struct TakeScaled {
        uint256 contribution;
        uint256 marginAssets;
        uint256 borrowAssets;
        uint256 awardFloor;
    }

    /// @dev Lowers USD3's MorphoCredit deployment ratio through the ProtocolConfig owner and tends through the USD3
    /// keeper, so USD3 withdraws waUSDC from MorphoCredit to hold locally, then removes that local waUSDC with `deal`
    /// so live NAV trails USD3's stored total assets: a real pending loss.
    function _createPendingLoss() internal {
        ILCCForkUSD3 usd3 = ILCCForkUSD3(USD3);
        IProtocolConfig config = IProtocolConfig(IMorphoCredit(usd3.morphoCredit()).protocolConfig());
        uint256 lowered = usd3.maxOnCredit() - 100;
        vm.prank(ILCCForkOwnable(address(config)).owner());
        config.setConfig(ProtocolConfigLib.MAX_ON_CREDIT, lowered);
        assertEq(usd3.maxOnCredit(), lowered);
        vm.prank(usd3.keeper());
        usd3.tend();
        assertGt(usd3.balanceOfWaUSDC(), 0);
        assertGe(usd3.nav() + 2, usd3.totalAssets());

        deal(WA_ETH_USDC, USD3, 0);
        assertLt(usd3.nav() + 2, usd3.totalAssets());
        assertEq(ILCCForkTokenizedVault(USD3).availableWithdrawLimit(address(helper)), 0);
    }

    /// @dev `holder` puts all its USD3l into the vault's own cooldown, which locks it, then USD3l management shuts
    /// USD3l down; the vault then lets the still-cooling holder transfer half and redeem the rest.
    function _shutDownUsd3lWithCooledHolder(address holder) internal {
        ILCCForkTokenizedVault usd3l = ILCCForkTokenizedVault(address(USD3L));
        uint256 held = USD3L.balanceOf(holder);
        assertGt(held, 1);
        vm.prank(holder);
        usd3l.startCooldown(held);
        address recipient = makeAddr("usd3l-recipient");
        vm.expectRevert(ILCCForkTokenizedVault.InsufficientShares.selector);
        vm.prank(holder);
        USD3L.transfer(recipient, 1);
        assertEq(USD3L.maxRedeem(holder), 0);

        vm.prank(usd3l.management());
        usd3l.shutdownStrategy();
        assertTrue(usd3l.isShutdown());

        uint256 transferred = held / 2;
        uint256 expectedUsd3 = USD3L.previewRedeem(held - transferred);
        uint256 usd3Before = IERC20(USD3).balanceOf(holder);
        vm.startPrank(holder);
        assertTrue(USD3L.transfer(recipient, transferred));
        uint256 redeemed = USD3L.redeem(held - transferred, holder, holder);
        vm.stopPrank();
        assertEq(USD3L.balanceOf(recipient), transferred);
        assertEq(USD3L.balanceOf(holder), 0);
        assertEq(redeemed, expectedUsd3);
        assertEq(IERC20(USD3).balanceOf(holder) - usd3Before, redeemed);
    }

    /// @dev A new unlevered take while USD3l is shut down: the vault's delivery deposits into USD3l, which takes no
    /// deposits once shut down.
    function _assertTakeRevertsWhileUsd3lShutDown() internal {
        address lateTaker = makeAddr("shutdown-taker");
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(TAKE_FILL, 0);
        _approveAll(lateTaker, TAKE_FILL);
        vm.expectRevert(bytes("ERC4626: deposit more than max"));
        vm.prank(lateTaker);
        helper.takeAuction(params);
    }

    /// @dev The whole-position LTV after `user`'s take, measured in a rolled-back run. Requires interest to have
    /// accrued since the stored market totals by more than the LTV's rounding, so a bound read from unaccrued debt
    /// would admit `takeLtv - 1`.
    function _accruedTakeLtv(address user, ILCCLeveragedFundHelper.TakeParams memory params)
        internal
        returns (uint256 takeLtv)
    {
        uint256 storedDebt = _borrowAssetsOf(marketId, user);
        uint256 snapshot = vm.snapshotState();
        vm.prank(user);
        helper.takeAuction(params);
        takeLtv = _positionLtv(user);
        uint256 unaccruedLtv = _ltv(user, storedDebt + params.borrowAssets + 2);
        vm.revertToState(snapshot);
        assertLt(unaccruedLtv, takeLtv - 1, "accrual does not move the entry LTV");
    }

    /// @dev At `user`'s first maturity, unwinds `shares` delivering USD3 and repaying 90% of their redemption value
    /// by shares; requires the repayment priced from the accrued market and the USD3 left after it.
    function _partialUsd3OutUnwind(address user, uint256 shares) internal {
        uint256 debt = _debt(user);
        uint256 usd3Redeemed = USD3L.previewRedeem(shares);
        uint256 repay = IERC4626(USD3).previewRedeem(usd3Redeemed) * 9 / 10;
        uint256 expectedRepaid = _repaidFor(repay);
        uint256 expectedUsd3 = usd3Redeemed - IERC4626(USD3).previewWithdraw(expectedRepaid);

        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(shares, false, repay);
        params.usd3Out = true;
        params.maxRepayAssets = repay;
        params.minOut = expectedUsd3;
        vm.prank(user);
        (uint256 repaid, uint256 usd3Out) = helper.unwind(params);

        assertEq(repaid, expectedRepaid);
        assertLe(repaid, repay);
        assertEq(usd3Out, expectedUsd3);
        assertEq(IERC20(USD3).balanceOf(user), usd3Out);
        assertEq(IERC20(USDC).balanceOf(user), 0);
        assertApproxEqAbs(_borrowAssetsOf(marketId, user), debt - repaid, 1);
        _assertUnwindHelperClean();
    }

    /// @dev What a partial unwind of `repay` repays against the market's stored totals: the borrow shares `repay`
    /// buys, rounded down, valued rounding up.
    function _repaidFor(uint256 repay) internal view returns (uint256) {
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(marketId);
        return repay.toSharesDown(totalBorrowAssets, totalBorrowShares).toAssetsUp(totalBorrowAssets, totalBorrowShares);
    }

    /// @dev Another filler takes `amount` of the live auction directly on the vault; returns the amount filled.
    function _frontRunTake(uint256 amount) internal returns (uint256 filled) {
        (filled,) = _directTake(address(VAULT), makeAddr("direct-filler"), amount);
        assertEq(filled, amount);
    }

    /// @dev Scales `params`, quoted at `maxFill`, to `fill`: contribution and margin round down, the dust goes to
    /// the borrow, and the award floor rounds down.
    function _scaleTake(ILCCLeveragedFundHelper.TakeParams memory params, uint256 quotedContribution, uint256 fill)
        internal
        pure
        returns (TakeScaled memory scaled)
    {
        scaled.contribution = Math.mulDiv(quotedContribution, fill, params.maxFill);
        scaled.marginAssets = Math.mulDiv(params.marginAssets, fill, params.maxFill);
        scaled.borrowAssets = fill - scaled.contribution - scaled.marginAssets;
        scaled.awardFloor = Math.mulDiv(params.minMarginAward, fill, params.maxFill);
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
}

/// @dev setUp opens a one-unit call, so every obligation is one base unit (the vault rounds obligations up).
contract LCCLeveragedFundDustObligationForkTest is LCCLeveragedFundForkBase {
    function _callAmount() internal pure override returns (uint256) {
        return 1;
    }

    /// @dev A one-base-unit obligation is below the live `usd3.previewMint(1)`, so the helper and the vault both top
    /// the funding up to one USD3 share. The entry is unlevered because one USD3l share cannot back a one-unit borrow
    /// at the market's LLTV.
    function testDustObligationFundsTheLiveOneShareMinimum() public requiresFork {
        address funder = funders[0];
        uint256 obligation = VAULT.obligationOf(CALL_EPOCH, funder);
        uint256 minimum = IERC4626(USD3).previewMint(1);
        assertEq(obligation, 1);
        assertGt(minimum, obligation);
        assertLe(minimum - obligation, 1_000);

        uint256 previewed = _previewCollateral(minimum);
        assertGt(previewed, 0);
        ILCCLeveragedFundHelper.FundParams memory params = ILCCLeveragedFundHelper.FundParams({
            vault: address(VAULT),
            market: marketParams,
            borrowAssets: 0,
            marginAssets: 0,
            maxMarginShares: 0,
            maxContribution: minimum,
            minCollateral: previewed,
            maxCollateral: previewed,
            maxEntryLtv: LLTV,
            maxObligation: obligation,
            deadline: block.timestamp
        });
        _approveAll(funder, minimum);
        uint256 fundedBefore = VAULT.getEpochState(CALL_EPOCH).fundedAmount;

        vm.expectEmit(true, true, true, true, address(VAULT));
        emit LCCEventsLib.CallFunded(address(helper), funder, CALL_EPOCH, obligation, minimum);
        vm.prank(funder);
        (uint256 funded, uint256 fundingAmount, uint256 collateral) = helper.fund(params);

        assertEq(funded, obligation);
        assertEq(fundingAmount, minimum);
        assertEq(collateral, previewed);
        assertEq(VAULT.getEpochState(CALL_EPOCH).fundedAmount - fundedBefore, obligation);
        _assertEntry(funder, 0, collateral);
    }
}
