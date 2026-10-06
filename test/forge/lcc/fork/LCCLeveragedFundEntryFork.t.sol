// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "../../../../lib/openzeppelin/contracts/interfaces/IERC4626.sol";

import {LCCMainnetForkBase} from "./LCCMainnetForkBase.sol";
import {LCCLeveragedFundSigUtils} from "../LCCLeveragedFundSigUtils.sol";
import {IMorphoBlueTest} from "../IMorphoBlueTest.sol";
import {ILCCVault} from "../../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCVaultFactory} from "../../../../src/lcc/LCCVaultFactory.sol";
import {LCCLeveragedFundHelper} from "../../../../src/lcc/LCCLeveragedFundHelper.sol";
import {ILCCLeveragedFundHelper} from "../../../../src/lcc/interfaces/ILCCLeveragedFundHelper.sol";
import {IMorphoBlue, IMorphoBlueOracle} from "../../../../src/lcc/interfaces/IMorphoBlue.sol";
import {ORACLE_PRICE_SCALE} from "../../../../src/libraries/ConstantsLib.sol";
import {MathLib} from "../../../../src/libraries/MathLib.sol";
import {SharesMathLib} from "../../../../src/libraries/SharesMathLib.sol";

contract LCCLeveragedFundEntryForkTest is LCCMainnetForkBase, LCCLeveragedFundSigUtils {
    using SafeERC20 for IERC20;
    using MathLib for uint256;
    using SharesMathLib for uint256;

    uint256 internal constant ENTRY_FORK_BLOCK = 26_129_000;
    uint256 internal constant CALL_EPOCH = 2;
    uint256 internal constant CALL_AMOUNT = 1_234_567_891_011;
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant ENTRY_LTV_BPS = 8_000;
    uint256 internal constant LENDER_LIQUIDITY = 5_000_000e6;

    IMorphoBlueTest internal constant MORPHO = IMorphoBlueTest(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    address internal constant ADAPTIVE_CURVE_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    IERC4626 internal constant USD3L = IERC4626(0xDF697c55f0D696CA9E3E624cD52d8186C6745904);
    ILCCVault internal constant VAULT = ILCCVault(0x8350ba7c69aeADD74b891EFc53F52a0f592aD796);
    address internal constant FACTORY = 0x95431c2Fbfe3E0f17a61EF1d7601Eb34aE6cd6ba;
    address internal constant FACTORY_OWNER = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address internal constant LISTER = 0x485828f6373c5FB1aA1DD8A58D6A6E7803fC5b15;

    IMorphoBlue.MarketParams internal marketParams;
    bytes32 internal marketId;
    LCCLeveragedFundHelper internal helper;
    address internal lender;
    address[] internal funders;
    uint256[] internal funderKeys;

    function _forkBlock() internal pure override returns (uint256) {
        return ENTRY_FORK_BLOCK;
    }

    function setUp() public override {
        super.setUp();
        if (!forkEnabled) return;

        _createMarket();
        helper = new LCCLeveragedFundHelper(address(MORPHO), FACTORY, USDC, address(USD3L));

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
        uint256 price = IMorphoBlueOracle(USD3_USDC_ORACLE).price();
        assertEq(price, IERC4626(USD3).convertToAssets(1e6) * 1e30);
        assertGt(price, ORACLE_PRICE_SCALE);
    }

    function testHelperDerivesUSD3AndRejectsMarketWithWrongTokens() public requiresFork {
        assertEq(helper.usd3(), USD3);

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

            _approveAll(funder, params.maxContribution);
            vm.prank(funder);
            (uint256 funded, uint256 fundingAmount, uint256 collateral) = helper.fund(params);

            assertEq(funded, params.maxObligation);
            assertEq(fundingAmount, params.maxObligation);
            assertGt(IERC20(WA_ETH_USDC).balanceOf(funder), marginBefore, "margin not released");
            _assertEntry(funder, params.borrowAssets, collateral);
        }
    }

    function testSignatureEntryAppliesRealPermitsAndAuthorization() public requiresFork {
        address funder = funders[1];
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(funder);
        uint256 previewed = _previewCollateral(params.maxObligation);
        deal(USDC, funder, params.maxContribution);

        Signed memory s = _sign(funderKeys[1], params.maxContribution, previewed);
        assertFalse(MORPHO.isAuthorized(funder, address(helper)));

        vm.prank(funder);
        (,, uint256 collateral) =
            helper.fundWithSignatures(params, s.usdcPermit, s.usd3lPermit, s.authorization, s.signature);

        assertEq(collateral, previewed);
        assertTrue(MORPHO.isAuthorized(funder, address(helper)), "authorization stays enabled");
        assertEq(MORPHO.nonce(funder), s.authorization.nonce + 1);
        assertEq(IERC20(USDC).allowance(funder, address(helper)), 0);
        assertEq(USD3L.allowance(funder, address(helper)), 0);
        _assertEntry(funder, params.borrowAssets, collateral);
    }

    function testSignatureEntryToleratesThirdPartySubmittingEachSignatureFirst() public requiresFork {
        address funder = funders[2];
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(funder);
        deal(USDC, funder, params.maxContribution);

        Signed memory s = _sign(funderKeys[2], params.maxContribution, _previewCollateral(params.maxObligation));

        vm.startPrank(makeAddr("front-runner"));
        _submitPermit(USDC, funder, address(helper), s.usdcPermit);
        _submitPermit(address(USD3L), funder, address(helper), s.usd3lPermit);
        MORPHO.setAuthorizationWithSig(s.authorization, s.signature);
        vm.stopPrank();

        vm.prank(funder);
        (,, uint256 collateral) =
            helper.fundWithSignatures(params, s.usdcPermit, s.usd3lPermit, s.authorization, s.signature);
        _assertEntry(funder, params.borrowAssets, collateral);
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

    function _previewCollateral(uint256 fundingAmount) internal view returns (uint256) {
        return USD3L.previewDeposit(IERC4626(USD3).previewDeposit(fundingAmount));
    }

    function _fundParams(address funder) internal view returns (ILCCLeveragedFundHelper.FundParams memory) {
        uint256 obligation = VAULT.obligationOf(CALL_EPOCH, funder);
        assertGt(obligation, 0);
        assertGt(obligation, IERC4626(USD3).previewMint(1));
        uint256 borrowAssets = obligation * ENTRY_LTV_BPS / 10_000;
        return ILCCLeveragedFundHelper.FundParams({
            vault: address(VAULT),
            market: marketParams,
            borrowAssets: borrowAssets,
            maxContribution: obligation - borrowAssets,
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

    function _assertEntry(address funder, uint256 borrowAssets, uint256 collateral) internal view {
        assertTrue(VAULT.fundedEpoch(CALL_EPOCH, funder));
        assertEq(IERC20(USDC).balanceOf(funder), 0, "contribution not fully spent");
        assertEq(USD3L.balanceOf(funder), 0, "collateral left with funder");

        (, uint128 borrowShares, uint128 positionCollateral) = MORPHO.position(marketId, funder);
        assertEq(positionCollateral, collateral);
        assertApproxEqAbs(_borrowAssets(borrowShares), borrowAssets, 1);

        assertEq(IERC20(USDC).balanceOf(address(helper)), 0);
        assertEq(USD3L.balanceOf(address(helper)), 0);
        assertEq(IERC20(USDC).allowance(address(helper), address(VAULT)), 0);
        assertEq(USD3L.allowance(address(helper), address(MORPHO)), 0);
    }

    function _positionLtv(address funder) internal view returns (uint256) {
        (, uint128 borrowShares, uint128 collateral) = MORPHO.position(marketId, funder);
        uint256 collateralValue =
            uint256(collateral).mulDivDown(IMorphoBlueOracle(marketParams.oracle).price(), ORACLE_PRICE_SCALE);
        return _borrowAssets(borrowShares).wDivUp(collateralValue);
    }

    function _borrowAssets(uint256 borrowShares) internal view returns (uint256) {
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(marketId);
        return borrowShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
    }

    function _createMarket() internal {
        marketParams = IMorphoBlue.MarketParams({
            loanToken: USDC,
            collateralToken: address(USD3L),
            oracle: USD3_USDC_ORACLE,
            irm: ADAPTIVE_CURVE_IRM,
            lltv: LLTV
        });
        marketId = keccak256(abi.encode(marketParams));
        MORPHO.createMarket(marketParams);

        lender = makeAddr("curator-vault");
        deal(USDC, lender, LENDER_LIQUIDITY);
        vm.startPrank(lender);
        IERC20(USDC).forceApprove(address(MORPHO), LENDER_LIQUIDITY);
        MORPHO.supply(marketParams, LENDER_LIQUIDITY, 0, lender, "");
        vm.stopPrank();
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
