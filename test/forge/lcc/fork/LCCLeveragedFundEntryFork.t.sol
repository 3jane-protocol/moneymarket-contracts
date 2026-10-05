// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "../../../../lib/openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "../../../../lib/openzeppelin/contracts/utils/math/Math.sol";

import {LCCMainnetForkBase, ILCCForkOracle, ILCCForkOracleFactory} from "./LCCMainnetForkBase.sol";
import {ILCCVault} from "../../../../src/lcc/interfaces/ILCCVault.sol";

/// @dev Canonical Morpho Blue market parameters. The repository's own `MarketParams` belongs to the MorphoCredit fork
/// and is not ABI-compatible with the canonical singleton.
struct CanonicalMarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

interface ICanonicalMorpho {
    function createMarket(CanonicalMarketParams calldata marketParams) external;
    function setAuthorization(address authorized, bool newIsAuthorized) external;
    function supply(
        CanonicalMarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);
    function supplyCollateral(
        CanonicalMarketParams calldata marketParams,
        uint256 assets,
        address onBehalf,
        bytes calldata data
    ) external;
    function borrow(
        CanonicalMarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);
    function position(bytes32 id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
    function market(bytes32 id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );
}

interface ILCCForkFactoryCaps {
    function setDepositorCaps(address[] calldata depositors, uint128[] calldata caps) external;
}

/// @dev Test-only prototype of the leveraged amortizing entry path. It supplies previewed USD3l collateral through
/// Morpho's collateral callback, borrows inside the callback, push-funds the caller's obligation, and hands Morpho the
/// freshly minted USD3l. The beneficiary is always `msg.sender`.
contract LCCLeveragedFundEntryProbe {
    using SafeERC20 for IERC20;

    error NotMorpho();
    error EquityExceedsMax(uint256 equity, uint256 maxEquity);
    error CollateralPreviewMismatch(uint256 previewed, uint256 minted);

    ICanonicalMorpho public immutable morpho;
    IERC20 public immutable usdc;
    IERC4626 public immutable usd3;
    IERC4626 public immutable usd3l;
    CanonicalMarketParams public marketParams;

    constructor(ICanonicalMorpho morpho_, CanonicalMarketParams memory marketParams_, IERC4626 usd3_) {
        morpho = morpho_;
        marketParams = marketParams_;
        usdc = IERC20(marketParams_.loanToken);
        usd3 = usd3_;
        usd3l = IERC4626(marketParams_.collateralToken);
    }

    function leveragedFund(ILCCVault vault, uint256 borrowAssets, uint256 maxEquity)
        external
        returns (uint256 fundingAmount, uint256 collateral)
    {
        uint256 obligation = vault.obligationOf(vault.currentEpoch(), msg.sender);
        fundingAmount = Math.max(obligation, usd3.previewMint(1));
        uint256 equity = fundingAmount - borrowAssets;
        if (equity > maxEquity) revert EquityExceedsMax(equity, maxEquity);

        usdc.safeTransferFrom(msg.sender, address(this), equity);
        collateral = usd3l.previewDeposit(usd3.previewDeposit(fundingAmount));
        morpho.supplyCollateral(
            marketParams, collateral, msg.sender, abi.encode(vault, msg.sender, fundingAmount, borrowAssets)
        );
    }

    function onMorphoSupplyCollateral(uint256 collateral, bytes calldata data) external {
        if (msg.sender != address(morpho)) revert NotMorpho();
        (ILCCVault vault, address user, uint256 fundingAmount, uint256 borrowAssets) =
            abi.decode(data, (ILCCVault, address, uint256, uint256));

        morpho.borrow(marketParams, borrowAssets, 0, user, address(this));

        uint256 balanceBefore = usd3l.balanceOf(user);
        usdc.forceApprove(address(vault), fundingAmount);
        vault.fundCall(user);
        uint256 minted = usd3l.balanceOf(user) - balanceBefore;
        if (minted != collateral) revert CollateralPreviewMismatch(collateral, minted);

        IERC20(address(usd3l)).safeTransferFrom(user, address(this), collateral);
        IERC20(address(usd3l)).forceApprove(address(morpho), collateral);
    }
}

contract LCCLeveragedFundEntryForkTest is LCCMainnetForkBase {
    using SafeERC20 for IERC20;

    uint256 internal constant ENTRY_FORK_BLOCK = 26_129_000;
    uint256 internal constant CALL_EPOCH = 2;
    uint256 internal constant CALL_AMOUNT = 1_234_567_891_011;
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant ENTRY_LTV_BPS = 8_000;

    ICanonicalMorpho internal constant MORPHO = ICanonicalMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    address internal constant ADAPTIVE_CURVE_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    IERC4626 internal constant USD3 = IERC4626(0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc);
    IERC4626 internal constant USD3L = IERC4626(0xDF697c55f0D696CA9E3E624cD52d8186C6745904);
    ILCCVault internal constant VAULT = ILCCVault(0x8350ba7c69aeADD74b891EFc53F52a0f592aD796);
    address internal constant FACTORY = 0x95431c2Fbfe3E0f17a61EF1d7601Eb34aE6cd6ba;
    address internal constant FACTORY_OWNER = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address internal constant LISTER = 0x485828f6373c5FB1aA1DD8A58D6A6E7803fC5b15;

    CanonicalMarketParams internal marketParams;
    bytes32 internal marketId;
    ILCCForkOracle internal oracle;
    LCCLeveragedFundEntryProbe internal probe;
    address[] internal funders;

    function _forkBlock() internal pure override returns (uint256) {
        return ENTRY_FORK_BLOCK;
    }

    function setUp() public override {
        super.setUp();
        if (!forkEnabled) return;

        _createMarket();
        probe = new LCCLeveragedFundEntryProbe(MORPHO, marketParams, USD3);

        funders.push(makeAddr("levered-funder-small"));
        funders.push(makeAddr("levered-funder-odd"));
        funders.push(makeAddr("levered-funder-large"));
        uint256[3] memory marginUsdc = [uint256(2_500e6), 9_876_543_211, 23_000e6];

        uint128[] memory caps = new uint128[](funders.length);
        for (uint256 i; i < funders.length; ++i) {
            caps[i] = type(uint128).max;
        }
        vm.prank(LISTER);
        ILCCForkFactoryCaps(FACTORY).setDepositorCaps(funders, caps);

        for (uint256 i; i < funders.length; ++i) {
            _depositMargin(funders[i], marginUsdc[i]);
        }

        vm.warp(VAULT.phaseEndsAt(CALL_EPOCH, ILCCVault.Phase.Normal));
        vm.prank(FACTORY_OWNER);
        VAULT.openEpochCall(CALL_EPOCH, CALL_AMOUNT);
        vm.warp(VAULT.phaseEndsAt(CALL_EPOCH, ILCCVault.Phase.PreCall));
    }

    function testFeedlessOraclePricesUSD3lAtTheUSD3ShareRate() public requiresFork {
        assertEq(USD3L.asset(), address(USD3));
        assertEq(USD3L.convertToAssets(1e6), 1e6);
        assertEq(USD3L.previewDeposit(1e6), 1e6);
        assertEq(oracle.price(), USD3.convertToAssets(1e12) * 1e24);
        assertGt(oracle.price(), 1e36);
    }

    function testCollateralCallbackEntryMintsExactlyThePreviewedCollateral() public requiresFork {
        assertEq(uint256(VAULT.currentPhase()), uint256(ILCCVault.Phase.Funding));
        for (uint256 i; i < funders.length; ++i) {
            _leveragedFundAndAssert(funders[i]);
        }
    }

    function _leveragedFundAndAssert(address funder) internal {
        uint256 obligation = VAULT.obligationOf(CALL_EPOCH, funder);
        assertGt(obligation, 0);
        uint256 borrowAssets = obligation * ENTRY_LTV_BPS / 10_000;
        uint256 equity = obligation - borrowAssets;
        uint256 marginBefore = IERC20(WA_ETH_USDC).balanceOf(funder);

        deal(USDC, funder, equity);
        vm.startPrank(funder);
        IERC20(USDC).forceApprove(address(probe), equity);
        IERC20(address(USD3L)).forceApprove(address(probe), type(uint256).max);
        MORPHO.setAuthorization(address(probe), true);
        (uint256 fundingAmount, uint256 collateral) = probe.leveragedFund(VAULT, borrowAssets, equity);
        vm.stopPrank();

        assertEq(fundingAmount, obligation);
        assertTrue(VAULT.fundedEpoch(CALL_EPOCH, funder));
        assertGt(IERC20(WA_ETH_USDC).balanceOf(funder), marginBefore, "margin not released");
        assertEq(IERC20(USDC).balanceOf(funder), 0, "equity not fully spent");
        assertEq(USD3L.balanceOf(funder), 0, "collateral left with funder");

        (, uint128 borrowShares, uint128 positionCollateral) = MORPHO.position(marketId, funder);
        assertEq(positionCollateral, collateral);
        assertApproxEqAbs(_borrowAssets(borrowShares), borrowAssets, 1);

        assertEq(IERC20(USDC).balanceOf(address(probe)), 0);
        assertEq(USD3L.balanceOf(address(probe)), 0);
        assertEq(IERC20(USDC).allowance(address(probe), address(VAULT)), 0);
        assertEq(USD3L.allowance(address(probe), address(MORPHO)), 0);
    }

    function _borrowAssets(uint256 borrowShares) internal view returns (uint256) {
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(marketId);
        return
            Math.mulDiv(
                borrowShares, uint256(totalBorrowAssets) + 1, uint256(totalBorrowShares) + 1e6, Math.Rounding.Ceil
            );
    }

    function _createMarket() internal {
        oracle = ILCCForkOracle(
            ILCCForkOracleFactory(ORACLE_FACTORY)
                .createMorphoChainlinkOracleV2(
                    address(USD3),
                    1e12,
                    address(0),
                    address(0),
                    6,
                    address(0),
                    1,
                    address(0),
                    address(0),
                    6,
                    keccak256("LCC_LEVERAGED_FUND_ENTRY_FORK")
                )
        );
        marketParams = CanonicalMarketParams({
            loanToken: USDC,
            collateralToken: address(USD3L),
            oracle: address(oracle),
            irm: ADAPTIVE_CURVE_IRM,
            lltv: LLTV
        });
        marketId = keccak256(abi.encode(marketParams));
        MORPHO.createMarket(marketParams);

        address lender = makeAddr("curator-vault");
        deal(USDC, lender, 5_000_000e6);
        vm.startPrank(lender);
        IERC20(USDC).forceApprove(address(MORPHO), 5_000_000e6);
        MORPHO.supply(marketParams, 5_000_000e6, 0, lender, "");
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
