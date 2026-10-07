// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "../../../lib/openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20Permit} from "../../../lib/openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {UpgradeableBeacon} from "../../../lib/openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {SafeERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "../../../lib/openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "../../../lib/forge-std/src/Vm.sol";

import {LCCBase, LCCMockToken, LCCMockUSD3, LCCMockNotificationVault, LCCReentryProbe} from "./LCCBase.t.sol";
import {LCCLeveragedFundSigUtils} from "./LCCLeveragedFundSigUtils.sol";
import {IMorphoBlueTest} from "./IMorphoBlueTest.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {LCCLeveragedFundHelper} from "../../../src/lcc/LCCLeveragedFundHelper.sol";
import {ILCCLeveragedFundHelper} from "../../../src/lcc/interfaces/ILCCLeveragedFundHelper.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {
    IMorphoBlue,
    IMorphoBlueOracle,
    IMorphoBlueSupplyCollateralCallback
} from "../../../src/lcc/interfaces/IMorphoBlue.sol";
import {OracleMock} from "../../../src/mocks/OracleMock.sol";
import {ORACLE_PRICE_SCALE, DOMAIN_TYPEHASH, AUTHORIZATION_TYPEHASH} from "../../../src/libraries/ConstantsLib.sol";
import {MathLib} from "../../../src/libraries/MathLib.sol";
import {SharesMathLib} from "../../../src/libraries/SharesMathLib.sol";

contract LCCPermitMockToken is LCCMockToken, ERC20Permit {
    constructor(string memory name_, string memory symbol_) LCCMockToken(name_, symbol_) ERC20Permit(name_) {}
}

contract LCCPermitNotificationVault is LCCMockNotificationVault, ERC20Permit {
    uint256 public extraMint;

    constructor(IERC20 asset_) LCCMockNotificationVault(asset_) ERC20Permit("Mock Notification USD3") {}

    function setExtraMint(uint256 extra) external {
        extraMint = extra;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        if (extraMint != 0) _mint(receiver, extraMint);
    }

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }
}

/// @dev Canonical Morpho Blue semantics for the paths the helper uses: collateral is credited before the callback and
/// pulled after it, borrowing requires authorization, health, and liquidity, and authorization signatures follow the
/// canonical EIP-712 domain and nonce rules.
contract LCCMockMorphoBlue is IMorphoBlueTest, LCCReentryProbe {
    using SafeERC20 for IERC20;
    using MathLib for uint256;
    using SharesMathLib for uint256;

    struct MarketState {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee;
    }

    struct PositionState {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

    mapping(bytes32 => MarketState) public market;
    mapping(bytes32 => mapping(address => PositionState)) public position;
    mapping(address => mapping(address => bool)) public isAuthorized;
    mapping(address => uint256) public nonce;

    uint256 public callbackCount = 1;
    bool public tamperCallbackData;
    bool public skipCallback;

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(this)));
    }

    function setCallbackCount(uint256 count) external {
        callbackCount = count;
    }

    function setSkipCallback(bool skip) external {
        skipCallback = skip;
    }

    function setTamperCallbackData(bool tamper) external {
        tamperCallbackData = tamper;
    }

    function createMarket(IMorphoBlue.MarketParams calldata params) external {
        bytes32 id = keccak256(abi.encode(params));
        require(market[id].lastUpdate == 0, "market created");
        market[id].lastUpdate = uint128(block.timestamp);
    }

    function supply(IMorphoBlue.MarketParams calldata params, uint256 assets, uint256, address onBehalf, bytes calldata)
        external
        returns (uint256, uint256)
    {
        bytes32 id = _created(params);
        uint256 shares = assets * 1e6;
        market[id].totalSupplyAssets += uint128(assets);
        market[id].totalSupplyShares += uint128(shares);
        position[id][onBehalf].supplyShares += shares;
        IERC20(params.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        return (assets, shares);
    }

    function withdraw(
        IMorphoBlue.MarketParams calldata params,
        uint256 assets,
        uint256,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        bytes32 id = _created(params);
        require(msg.sender == onBehalf, "unauthorized");
        uint256 shares = assets * 1e6;
        market[id].totalSupplyAssets -= uint128(assets);
        market[id].totalSupplyShares -= uint128(shares);
        position[id][onBehalf].supplyShares -= shares;
        require(market[id].totalBorrowAssets <= market[id].totalSupplyAssets, "insufficient liquidity");
        IERC20(params.loanToken).safeTransfer(receiver, assets);
        return (assets, shares);
    }

    function supplyCollateral(
        IMorphoBlue.MarketParams calldata params,
        uint256 assets,
        address onBehalf,
        bytes calldata data
    ) external {
        bytes32 id = _created(params);
        require(assets != 0, "zero assets");
        require(onBehalf != address(0), "zero address");
        position[id][onBehalf].collateral += uint128(assets);
        if (skipCallback) return;
        if (data.length > 0) {
            bytes memory payload = data;
            if (tamperCallbackData) payload[payload.length - 1] ^= 0x01;
            for (uint256 i; i < callbackCount; ++i) {
                IMorphoBlueSupplyCollateralCallback(msg.sender).onMorphoSupplyCollateral(assets, payload);
            }
        }
        IERC20(params.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    function borrow(
        IMorphoBlue.MarketParams calldata params,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        bytes32 id = _created(params);
        require((assets == 0) != (shares == 0), "inconsistent input");
        require(receiver != address(0), "zero address");
        require(msg.sender == onBehalf || isAuthorized[onBehalf][msg.sender], "unauthorized");

        _fireReentry();

        MarketState storage m = market[id];
        shares = assets.toSharesUp(m.totalBorrowAssets, m.totalBorrowShares);
        position[id][onBehalf].borrowShares += uint128(shares);
        m.totalBorrowShares += uint128(shares);
        m.totalBorrowAssets += uint128(assets);

        require(_isHealthy(params, id, onBehalf), "insufficient collateral");
        require(m.totalBorrowAssets <= m.totalSupplyAssets, "insufficient liquidity");
        IERC20(params.loanToken).safeTransfer(receiver, assets);
        return (assets, shares);
    }

    function setAuthorization(address authorized, bool newIsAuthorized) external {
        isAuthorized[msg.sender][authorized] = newIsAuthorized;
    }

    function setAuthorizationWithSig(
        IMorphoBlue.Authorization calldata authorization,
        IMorphoBlue.Signature calldata signature
    ) external {
        require(block.timestamp <= authorization.deadline, "signature expired");
        require(authorization.nonce == nonce[authorization.authorizer]++, "invalid nonce");
        bytes32 structHash = keccak256(abi.encode(AUTHORIZATION_TYPEHASH, authorization));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        address signatory = ecrecover(digest, signature.v, signature.r, signature.s);
        require(signatory != address(0) && authorization.authorizer == signatory, "invalid signature");
        isAuthorized[authorization.authorizer][authorization.authorized] = authorization.isAuthorized;
    }

    function borrowAssetsOf(bytes32 id, address user) public view returns (uint256) {
        MarketState storage m = market[id];
        return uint256(position[id][user].borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
    }

    function _created(IMorphoBlue.MarketParams calldata params) internal view returns (bytes32 id) {
        id = keccak256(abi.encode(params));
        require(market[id].lastUpdate != 0, "market not created");
    }

    function _isHealthy(IMorphoBlue.MarketParams calldata params, bytes32 id, address user)
        internal
        view
        returns (bool)
    {
        uint256 maxBorrow = uint256(position[id][user].collateral)
            .mulDivDown(IMorphoBlueOracle(params.oracle).price(), ORACLE_PRICE_SCALE).wMulDown(params.lltv);
        return maxBorrow >= borrowAssetsOf(id, user);
    }
}

contract LCCLeveragedFundHelperTest is LCCBase, LCCLeveragedFundSigUtils {
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant LIQUIDITY = 1_000_000e18;
    uint256 internal constant MARGIN = 100e18;
    uint256 internal constant CALL = 100e18;

    LCCMockMorphoBlue internal morpho;
    OracleMock internal marketOracle;
    IMorphoBlue.MarketParams internal marketParams;
    bytes32 internal marketId;
    LCCLeveragedFundHelper internal helper;
    LCCPermitNotificationVault internal usd3l;

    address internal signer;
    uint256 internal signerKey;
    uint256 internal otherKey;

    function setUp() public override {
        super.setUp();
        usdc.burn(alice, usdc.balanceOf(alice));
        usdc.burn(bob, usdc.balanceOf(bob));

        morpho = new LCCMockMorphoBlue();
        marketOracle = new OracleMock();
        marketOracle.setPrice(ORACLE_PRICE_SCALE);
        marketParams = IMorphoBlue.MarketParams({
            loanToken: address(usdc),
            collateralToken: address(usd3l),
            oracle: address(marketOracle),
            irm: makeAddr("irm"),
            lltv: LLTV
        });
        marketId = keccak256(abi.encode(marketParams));
        morpho.createMarket(marketParams);
        usdc.mint(address(this), LIQUIDITY);
        usdc.approve(address(morpho), LIQUIDITY);
        morpho.supply(marketParams, LIQUIDITY, 0, address(this), "");

        helper = new LCCLeveragedFundHelper(address(morpho), address(factory), address(usdc), address(usd3l));

        (signer, signerKey) = makeAddrAndKey("signer");
        (, otherKey) = makeAddrAndKey("other-signer");

        _mintAndApprove(signer, 1_000_000e18, 0);
        _approveHelper(alice);
        _approveHelper(bob);
    }

    /* SUCCESS PATHS */

    function testFundBorrowsFundsAndSuppliesExactCollateral() public {
        _depositAndOpenCall(alice);
        uint256 marginBefore = margin.balanceOf(alice);
        usdc.mint(alice, 20e18);

        vm.prank(alice);
        (uint256 obligation, uint256 fundingAmount, uint256 collateral) = helper.fund(_fundParams(80e18));

        assertEq(obligation, CALL);
        assertEq(fundingAmount, CALL);
        assertEq(collateral, CALL);
        assertTrue(vault.fundedEpoch(0, alice));
        assertEq(margin.balanceOf(alice) - marginBefore, MARGIN / 2);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usd3l.balanceOf(alice), 0);
        (, uint128 borrowShares, uint128 positionCollateral) = morpho.position(marketId, alice);
        assertEq(positionCollateral, CALL);
        assertGt(borrowShares, 0);
        assertEq(morpho.borrowAssetsOf(marketId, alice), 80e18);
        assertEq(usd3l.balanceOf(address(morpho)), CALL);
        _assertHelperClean();
    }

    function testZeroBorrowNeedsNoMorphoAuthorization() public {
        _depositAndOpenCall(alice);
        vm.prank(alice);
        morpho.setAuthorization(address(helper), false);
        usdc.mint(alice, CALL);

        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(0);
        params.maxContribution = CALL;
        vm.prank(alice);
        helper.fund(params);

        (, uint128 borrowShares, uint128 positionCollateral) = morpho.position(marketId, alice);
        assertEq(borrowShares, 0);
        assertEq(positionCollateral, CALL);
        _assertHelperClean();
    }

    function testFullyLeveredFundNeedsNoUsdcAllowance() public {
        _depositAndOpenCall(alice);
        _supplyExtraCollateral(alice, CALL);
        vm.prank(alice);
        usdc.approve(address(helper), 0);

        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(CALL);
        assertEq(params.maxContribution, 0);
        vm.prank(alice);
        (, uint256 fundingAmount,) = helper.fund(params);

        assertEq(fundingAmount, CALL);
        assertTrue(vault.fundedEpoch(0, alice));
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.allowance(alice, address(helper)), 0);
        assertEq(morpho.borrowAssetsOf(marketId, alice), CALL);
        _assertHelperClean();
    }

    function testFullyLeveredSignedFundIgnoresUsdcPermit() public {
        _depositAndOpenCall(signer);
        _supplyExtraCollateral(signer, CALL);
        usdc.mint(signer, 5e18);
        vm.prank(signer);
        usdc.approve(address(helper), 7e18);
        Signed memory s = _sign(0, CALL);
        delete s.usdcPermit;
        uint256 usdcNonce = LCCPermitMockToken(address(usdc)).nonces(signer);

        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(CALL);
        _fundSigned(params, s);

        assertTrue(vault.fundedEpoch(0, signer));
        assertEq(usdc.balanceOf(signer), 5e18);
        assertEq(usdc.allowance(signer, address(helper)), 7e18);
        assertEq(LCCPermitMockToken(address(usdc)).nonces(signer), usdcNonce);
        assertEq(morpho.borrowAssetsOf(marketId, signer), CALL);
        _assertHelperClean();
    }

    function testFullyLeveredSignedFundDoesNotSubmitValidUsdcPermit() public {
        _depositAndOpenCall(signer);
        _supplyExtraCollateral(signer, CALL);
        vm.prank(signer);
        usdc.approve(address(helper), 7e18);
        Signed memory s = _sign(1, CALL);
        uint256 usdcNonce = LCCPermitMockToken(address(usdc)).nonces(signer);

        _fundSigned(_fundParams(CALL), s);

        assertTrue(vault.fundedEpoch(0, signer));
        assertEq(usdc.allowance(signer, address(helper)), 7e18);
        assertEq(LCCPermitMockToken(address(usdc)).nonces(signer), usdcNonce);
        _assertHelperClean();
    }

    function testDustTopUpFundsMinimumShareAndBoundsContributionByFundingAmount() public {
        _seedUsd3(2, 1);
        _mintAndApprove(alice, 0, 0);
        vm.prank(alice);
        vault.deposit(1e18, alice, 1, type(uint256).max, true, type(uint256).max);
        _openCall(1);
        vm.warp(START + NORMAL + PRE_CALL);
        assertEq(vault.obligationOf(0, alice), 1);
        assertEq(usd3.previewMint(1), 2);

        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(0);
        params.maxObligation = 1;
        params.maxContribution = 1;
        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.ContributionExceedsMax.selector, 2, 1));
        vm.prank(alice);
        helper.fund(params);

        usdc.mint(alice, 2);
        params.maxContribution = 2;
        vm.prank(alice);
        (uint256 obligation, uint256 fundingAmount, uint256 collateral) = helper.fund(params);

        assertEq(obligation, 1);
        assertEq(fundingAmount, 2);
        assertEq(collateral, 1);
        assertEq(usdc.balanceOf(alice), 0);
        (,, uint128 positionCollateral) = morpho.position(marketId, alice);
        assertEq(positionCollateral, 1);
        _assertHelperClean();
    }

    function testLtvBoundCoversWholePosition() public {
        _depositAndOpenCall(alice);
        deal(address(usd3l), alice, 100e18);
        vm.startPrank(alice);
        usd3l.approve(address(morpho), 100e18);
        morpho.supplyCollateral(marketParams, 100e18, alice, "");
        morpho.borrow(marketParams, 50e18, 0, alice, alice);
        vm.stopPrank();

        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(80e18);
        params.maxEntryLtv = 0.65e18 - 1;
        vm.expectPartialRevert(ILCCLeveragedFundHelper.EntryLtvExceeded.selector);
        vm.prank(alice);
        helper.fund(params);

        params.maxEntryLtv = 0.65e18;
        vm.prank(alice);
        helper.fund(params);
        (,, uint128 positionCollateral) = morpho.position(marketId, alice);
        assertEq(positionCollateral, 200e18);
        assertEq(morpho.borrowAssetsOf(marketId, alice), 130e18);
    }

    function testZeroBorrowEntrySucceedsDuringOracleOutage() public {
        _depositAndOpenCall(alice);
        deal(address(usd3l), alice, 100e18);
        vm.startPrank(alice);
        usd3l.approve(address(morpho), 100e18);
        morpho.supplyCollateral(marketParams, 100e18, alice, "");
        morpho.borrow(marketParams, 50e18, 0, alice, alice);
        vm.stopPrank();
        usdc.mint(alice, CALL - 50e18);
        vm.mockCallRevert(address(marketOracle), abi.encodeCall(IMorphoBlueOracle.price, ()), "ORACLE_DOWN");

        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(0);
        params.maxEntryLtv = 0;
        vm.prank(alice);
        helper.fund(params);

        assertTrue(vault.fundedEpoch(0, alice));
        (,, uint128 positionCollateral) = morpho.position(marketId, alice);
        assertEq(positionCollateral, 100e18 + CALL);
        assertEq(morpho.borrowAssetsOf(marketId, alice), 50e18);
        _assertHelperClean();
    }

    /* MARKETS */

    function testRejectsMarketWithWrongLoanOrCollateralToken() public {
        _depositAndOpenCall(alice);
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(80e18);

        params.market.loanToken = address(margin);
        vm.expectRevert(ILCCLeveragedFundHelper.MarketTokenMismatch.selector);
        vm.prank(alice);
        helper.fund(params);

        params.market = marketParams;
        params.market.collateralToken = address(usd3);
        vm.expectRevert(ILCCLeveragedFundHelper.MarketTokenMismatch.selector);
        vm.prank(alice);
        helper.fund(params);
    }

    function testSameHelperServesMarketsWithDifferentLltv() public {
        IMorphoBlue.MarketParams memory conservative = _createMarket(0.5e18, LIQUIDITY);
        _deposit(bob, MARGIN);
        _depositAndOpenCall(alice);
        uint256 obligation = vault.obligationOf(0, alice);
        assertEq(vault.obligationOf(0, bob), obligation);

        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(0);
        params.maxObligation = obligation;
        params.maxContribution = obligation;

        params.borrowAssets = obligation * 4 / 5;
        usdc.mint(alice, obligation - params.borrowAssets);
        vm.prank(alice);
        helper.fund(params);

        params.market = conservative;
        params.borrowAssets = obligation * 2 / 5;
        usdc.mint(bob, obligation - params.borrowAssets);
        vm.prank(bob);
        helper.fund(params);

        bytes32 conservativeId = keccak256(abi.encode(conservative));
        (,, uint128 aliceCollateral) = morpho.position(marketId, alice);
        (,, uint128 bobCollateral) = morpho.position(conservativeId, bob);
        assertEq(aliceCollateral, obligation);
        assertEq(bobCollateral, obligation);
        assertEq(morpho.borrowAssetsOf(marketId, alice), obligation * 4 / 5);
        assertEq(morpho.borrowAssetsOf(conservativeId, bob), obligation * 2 / 5);
        (,, uint128 bobInDefault) = morpho.position(marketId, bob);
        assertEq(bobInDefault, 0);
        _assertHelperClean();
    }

    /* FAIL-FAST BOUNDS */

    function testFundingOutsideFundingPhaseRejected() public {
        _deposit(alice, MARGIN);
        _openCall(CALL);
        usdc.mint(alice, 20e18);
        vm.expectRevert(ILCCLeveragedFundHelper.NotFundingPhase.selector);
        vm.prank(alice);
        helper.fund(_fundParams(80e18));
    }

    function testExcessiveFundingTopUpRejected() public {
        _seedUsd3(1, 2_000);
        _deposit(alice, 1e18);
        _openCall(1);
        vm.warp(START + NORMAL + PRE_CALL);
        assertEq(vault.obligationOf(0, alice), 1);

        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(0);
        params.maxObligation = 1;
        params.maxContribution = type(uint256).max;
        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.FundingTopUpExceeded.selector, 2_001, 1));
        vm.prank(alice);
        helper.fund(params);
    }

    function testFundingTopUpBoundaryMatchesVault() public {
        _seedUsd3(1, 1_000);
        _deposit(alice, 1e18);
        _openCall(1);
        vm.warp(START + NORMAL + PRE_CALL);
        assertEq(vault.obligationOf(0, alice), 1);
        assertEq(usd3.previewMint(1) - 1, 1_000);

        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(0);
        params.maxObligation = 1;
        params.maxContribution = type(uint256).max;
        usdc.mint(alice, 1_001);

        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        (, uint256 fundingAmount,) = helper.fund(params);
        assertEq(fundingAmount, 1_001);
        vm.revertToState(snapshot);

        usd3.reportProfit(1);
        assertEq(usd3.previewMint(1) - 1, 1_001);
        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.FundingTopUpExceeded.selector, 1_002, 1));
        vm.prank(alice);
        helper.fund(params);

        vm.expectRevert(LCCErrorsLib.FundingTopUpExcessive.selector);
        vm.prank(alice);
        vault.fundCall(alice);
    }

    function testLeveredFundRequiresMorphoAuthorization() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        vm.prank(alice);
        morpho.setAuthorization(address(helper), false);

        vm.expectRevert(ILCCLeveragedFundHelper.NotAuthorized.selector);
        vm.prank(alice);
        helper.fund(_fundParams(80e18));
    }

    /* SIGNATURES */

    function testFundWithSignaturesAppliesPermitsAndAuthorization() public {
        _prepareSigner();
        _fundSigned(_fundParams(80e18), _sign(20e18, CALL));

        assertTrue(vault.fundedEpoch(0, signer));
        assertTrue(morpho.isAuthorized(signer, address(helper)));
        assertEq(usdc.allowance(signer, address(helper)), 0);
        assertEq(usd3l.allowance(signer, address(helper)), 0);
        assertEq(morpho.borrowAssetsOf(marketId, signer), 80e18);
        _assertHelperClean();
    }

    function testFundWithSignaturesToleratesThirdPartySubmittingEachSignatureFirst() public {
        _prepareSigner();
        Signed memory s = _sign(20e18, CALL);

        vm.startPrank(stranger);
        _submitPermit(address(usdc), signer, address(helper), s.usdcPermit);
        _submitPermit(address(usd3l), signer, address(helper), s.usd3lPermit);
        morpho.setAuthorizationWithSig(s.authorization, s.signature);
        vm.stopPrank();

        _fundSigned(_fundParams(80e18), s);
        assertTrue(vault.fundedEpoch(0, signer));
        _assertHelperClean();
    }

    function testUsdcPermitForWrongSpenderIsRejected() public {
        _prepareSigner();
        Signed memory s = _sign(20e18, CALL);
        s.usdcPermit = _signPermit(address(usdc), signerKey, stranger, 20e18, type(uint256).max);

        _expectInsufficientAllowance(
            address(usdc), 0, 20e18, _invalidSignerRevert(address(usdc), s.usdcPermit, address(helper))
        );
        _fundSigned(_fundParams(80e18), s);
    }

    function testUsd3lPermitForWrongOwnerIsRejected() public {
        _prepareSigner();
        Signed memory s = _sign(20e18, CALL);
        s.usd3lPermit = _signPermit(address(usd3l), otherKey, address(helper), CALL, type(uint256).max);

        _expectInsufficientAllowance(
            address(usd3l), 0, CALL, _invalidSignerRevert(address(usd3l), s.usd3lPermit, address(helper))
        );
        _fundSigned(_fundParams(80e18), s);
    }

    function testPermitBelowRequiredAllowanceIsRejected() public {
        _prepareSigner();
        Signed memory s = _sign(20e18, CALL);
        s.usd3lPermit = _signPermit(address(usd3l), signerKey, address(helper), CALL - 1, type(uint256).max);

        _expectInsufficientAllowance(address(usd3l), CALL - 1, CALL, "");
        _fundSigned(_fundParams(80e18), s);
    }

    function testPermitReplacesLargerStandingAllowance() public {
        _prepareSigner();
        vm.startPrank(signer);
        usdc.approve(address(helper), 50e18);
        usd3l.approve(address(helper), 3 * CALL);
        vm.stopPrank();
        Signed memory s = _sign(25e18, CALL);
        uint256 usdcNonce = LCCPermitMockToken(address(usdc)).nonces(signer);
        uint256 usd3lNonce = usd3l.nonces(signer);

        _fundSigned(_fundParams(80e18), s);

        assertTrue(vault.fundedEpoch(0, signer));
        assertEq(usdc.allowance(signer, address(helper)), 25e18 - 20e18);
        assertEq(usd3l.allowance(signer, address(helper)), 0);
        assertEq(LCCPermitMockToken(address(usdc)).nonces(signer), usdcNonce + 1);
        assertEq(usd3l.nonces(signer), usd3lNonce + 1);
        _assertHelperClean();
    }

    function testLowerValuedPermitRevertsDespiteSufficientStandingAllowance() public {
        _prepareSigner();
        vm.prank(signer);
        usdc.approve(address(helper), 50e18);
        Signed memory s = _sign(20e18 - 1, CALL);

        _expectInsufficientAllowance(address(usdc), 20e18 - 1, 20e18, "");
        _fundSigned(_fundParams(80e18), s);
    }

    function testFrontRunPermitWithShortValueRevertsAsInsufficient() public {
        _prepareSigner();
        Signed memory s = _sign(20e18 - 1, CALL);

        vm.prank(stranger);
        _submitPermit(address(usdc), signer, address(helper), s.usdcPermit);

        bytes memory permitRevert = _invalidSignerRevert(address(usdc), s.usdcPermit, address(helper));
        assertGt(permitRevert.length, 0);
        _expectInsufficientAllowance(address(usdc), 20e18 - 1, 20e18, permitRevert);
        _fundSigned(_fundParams(80e18), s);
    }

    function testFundWithSignaturesZeroBorrowIgnoresAuthorization() public {
        _depositAndOpenCall(signer);
        usdc.mint(signer, CALL);
        Signed memory s = _sign(CALL, CALL);
        delete s.authorization;
        delete s.signature;

        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(0);
        params.maxContribution = CALL;
        _fundSigned(params, s);

        assertTrue(vault.fundedEpoch(0, signer));
        assertFalse(morpho.isAuthorized(signer, address(helper)));
        assertEq(morpho.nonce(signer), 0);
        (, uint128 borrowShares, uint128 positionCollateral) = morpho.position(marketId, signer);
        assertEq(borrowShares, 0);
        assertEq(positionCollateral, CALL);
        _assertHelperClean();
    }

    function testAlreadyAuthorizedCallerNeedsNoAuthorizationSignature() public {
        _prepareSigner();
        vm.prank(signer);
        morpho.setAuthorization(address(helper), true);
        Signed memory s = _sign(20e18, CALL);
        delete s.authorization;
        delete s.signature;
        uint256 nonceBefore = morpho.nonce(signer);

        _fundSigned(_fundParams(80e18), s);

        assertTrue(vault.fundedEpoch(0, signer));
        assertEq(morpho.nonce(signer), nonceBefore);
        assertEq(morpho.borrowAssetsOf(marketId, signer), 80e18);
        _assertHelperClean();
    }

    function testAuthorizationForWrongPartiesOrRevocationIsRejected() public {
        _prepareSigner();
        Signed memory s = _sign(20e18, CALL);

        s.authorization.authorizer = alice;
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidAuthorization.selector);
        _fundSigned(_fundParams(80e18), s);

        s.authorization = _morphoAuthorization(address(morpho), signer, stranger, type(uint256).max);
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidAuthorization.selector);
        _fundSigned(_fundParams(80e18), s);

        s.authorization = _morphoAuthorization(address(morpho), signer, address(helper), type(uint256).max);
        s.authorization.isAuthorized = false;
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidAuthorization.selector);
        _fundSigned(_fundParams(80e18), s);
    }

    function testAuthorizationSignedByAnotherKeyFails() public {
        _prepareSigner();
        Signed memory s = _sign(20e18, CALL);
        s.signature = _signMorphoAuthorization(address(morpho), otherKey, s.authorization);

        vm.expectRevert(ILCCLeveragedFundHelper.AuthorizationFailed.selector);
        _fundSigned(_fundParams(80e18), s);
    }

    /* VAULT VALIDATION */

    function testUnregisteredVaultRejected() public {
        LCCVault unregistered = _newVaultWithMockFactory(_params(CAP, CAP));
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(0);
        params.vault = address(unregistered);
        vm.expectRevert(ILCCLeveragedFundHelper.UnregisteredVault.selector);
        vm.prank(alice);
        helper.fund(params);
    }

    function testMisWiredVaultRejected() public {
        LCCMockNotificationVault otherNotificationVault = new LCCMockNotificationVault(IERC20(address(usd3)));
        beacon.upgradeTo(address(new LCCVault(address(otherNotificationVault), treasury)));

        vm.expectRevert(ILCCLeveragedFundHelper.VaultAssetMismatch.selector);
        vm.prank(alice);
        helper.fund(_fundParams(0));
    }

    function testUsd3lMarginVaultRejected() public {
        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        params.marginAsset = address(usd3l);
        LCCVault usd3lMarginVault = _newVault(params);

        ILCCLeveragedFundHelper.FundParams memory fundParams = _fundParams(0);
        fundParams.vault = address(usd3lMarginVault);
        vm.expectRevert(ILCCLeveragedFundHelper.MarginAssetIsCollateral.selector);
        vm.prank(alice);
        helper.fund(fundParams);
    }

    /* STALE ACCOUNTS */

    function testStaleAccountObligationMatchesChargedObligation() public {
        usdc.mint(bob, 1_000_000e18);
        _deposit(bob, MARGIN);
        _openCallAtEpoch(0, CALL);
        _deposit(alice, MARGIN);

        _openCallAtEpoch(1, CALL);
        _fundAtEpoch(bob, 1);
        _openCallAtEpoch(2, CALL);
        _fundAtEpoch(bob, 2);
        _openCallAtEpoch(3, CALL);
        vm.warp(START + EPOCH * 3 + NORMAL + PRE_CALL);

        uint256 obligation = vault.obligationOf(3, alice);
        assertGt(obligation, 0);
        usdc.mint(alice, obligation);
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(obligation / 2);
        params.maxContribution = obligation;
        params.maxObligation = obligation;

        vm.recordLogs();
        vm.prank(alice);
        (uint256 funded, uint256 fundingAmount,) = helper.fund(params);

        assertEq(funded, obligation);
        assertEq(fundingAmount, obligation);
        assertTrue(vault.fundedEpoch(3, alice));
        uint256 replayedDefaults;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (_isUserDefaulted(logs[i], address(vault)) && address(uint160(uint256(logs[i].topics[1]))) == alice) {
                ++replayedDefaults;
            }
        }
        assertEq(replayedDefaults, 2);
        _assertHelperClean();
    }

    /* BOUNDS */

    function testExpiredDeadlineRejected() public {
        _depositAndOpenCall(alice);
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(80e18);
        params.deadline = block.timestamp - 1;
        vm.expectRevert(ILCCLeveragedFundHelper.DeadlineExpired.selector);
        vm.prank(alice);
        helper.fund(params);
    }

    function testNoObligationRejected() public {
        _depositAndOpenCall(bob);
        vm.expectRevert(ILCCLeveragedFundHelper.NoObligation.selector);
        vm.prank(alice);
        helper.fund(_fundParams(0));
    }

    function testObligationAboveMaximumRejected() public {
        _depositAndOpenCall(alice);
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(80e18);
        params.maxObligation = CALL - 1;
        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.ObligationExceedsMax.selector, CALL, CALL - 1));
        vm.prank(alice);
        helper.fund(params);
    }

    function testBorrowAboveFundingAmountRejected() public {
        _depositAndOpenCall(alice);
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(0);
        params.borrowAssets = CALL + 1;
        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.BorrowExceedsFunding.selector, CALL + 1, CALL));
        vm.prank(alice);
        helper.fund(params);
    }

    function testContributionAboveMaximumRejected() public {
        _depositAndOpenCall(alice);
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(80e18);
        params.maxContribution = 20e18 - 1;
        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.ContributionExceedsMax.selector, 20e18, 20e18 - 1)
        );
        vm.prank(alice);
        helper.fund(params);
    }

    function testEntryLtvAboveMaximumRejected() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(80e18);
        params.maxEntryLtv = 0.8e18 - 1;
        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.EntryLtvExceeded.selector, 0.8e18, 0.8e18 - 1));
        vm.prank(alice);
        helper.fund(params);

        params.maxEntryLtv = 0.8e18;
        vm.prank(alice);
        helper.fund(params);
    }

    function testZeroOraclePriceAfterBorrowRevertsAsUnboundedLtv() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        bytes[] memory prices = new bytes[](2);
        prices[0] = abi.encode(ORACLE_PRICE_SCALE);
        prices[1] = abi.encode(uint256(0));
        vm.mockCalls(address(marketOracle), abi.encodeCall(IMorphoBlueOracle.price, ()), prices);

        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.EntryLtvExceeded.selector, type(uint256).max, LLTV)
        );
        vm.prank(alice);
        helper.fund(_fundParams(80e18));
    }

    function testFundCallReturningDifferentObligationRejected() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        vm.mockCall(address(vault), abi.encodeWithSignature("fundCall(address)", alice), abi.encode(CALL - 1));

        vm.expectRevert(ILCCLeveragedFundHelper.FundingMismatch.selector);
        vm.prank(alice);
        helper.fund(_fundParams(80e18));
    }

    function testFundCallLeavingAllowanceRejected() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        vm.mockCall(address(vault), abi.encodeWithSignature("fundCall(address)", alice), abi.encode(CALL));

        vm.expectRevert(ILCCLeveragedFundHelper.FundingMismatch.selector);
        vm.prank(alice);
        helper.fund(_fundParams(80e18));
    }

    function testSkippedCallbackRejected() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        morpho.setSkipCallback(true);

        vm.expectRevert(ILCCLeveragedFundHelper.CallbackNotExecuted.selector);
        vm.prank(alice);
        helper.fund(_fundParams(80e18));
    }

    function testCollateralPreviewMismatchRejected() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        usd3l.setExtraMint(1);
        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.CollateralPreviewMismatch.selector, CALL, CALL + 1)
        );
        vm.prank(alice);
        helper.fund(_fundParams(80e18));
    }

    function testBorrowAboveMarketLiquidityRejected() public {
        _depositAndOpenCall(alice);
        IMorphoBlue.MarketParams memory thin = _createMarket(0.85e18, 10e18);
        usdc.mint(alice, 20e18);

        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(80e18);
        params.market = thin;
        vm.expectRevert("insufficient liquidity");
        vm.prank(alice);
        helper.fund(params);
    }

    /* CALLBACK AND REENTRANCY */

    function testCallbackFromNonMorphoRejected() public {
        vm.expectRevert(ILCCLeveragedFundHelper.NotMorpho.selector);
        vm.prank(stranger);
        helper.onMorphoSupplyCollateral(1, hex"01");
    }

    function testCallbackWithNoOperationInFlightRejected() public {
        vm.expectRevert(ILCCLeveragedFundHelper.NoOperationInFlight.selector);
        vm.prank(address(morpho));
        helper.onMorphoSupplyCollateral(1, hex"01");
    }

    function testRepeatedCallbackRejected() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        morpho.setCallbackCount(2);
        vm.expectRevert(ILCCLeveragedFundHelper.NoOperationInFlight.selector);
        vm.prank(alice);
        helper.fund(_fundParams(80e18));
    }

    function testCallbackWithMismatchedOperationRejected() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        morpho.setTamperCallbackData(true);
        vm.expectRevert(ILCCLeveragedFundHelper.OperationMismatch.selector);
        vm.prank(alice);
        helper.fund(_fundParams(80e18));
    }

    function testEntrypointsAreNotReenterable() public {
        _assertNotReenterable(abi.encodeCall(ILCCLeveragedFundHelper.fund, (_fundParams(80e18))));
    }

    function testSignatureEntrypointIsNotReenterable() public {
        Signed memory s;
        _assertNotReenterable(
            abi.encodeCall(
                ILCCLeveragedFundHelper.fundWithSignatures,
                (_fundParams(80e18), s.usdcPermit, s.usd3lPermit, s.authorization, s.signature)
            )
        );
    }

    function testDonatedBalancesDoNotBlockFunding() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        usdc.mint(address(helper), 7);
        deal(address(usd3l), address(helper), 7);

        vm.prank(alice);
        helper.fund(_fundParams(80e18));
        assertEq(usdc.balanceOf(address(helper)), 7);
        assertEq(usd3l.balanceOf(address(helper)), 7);
        assertEq(usdc.allowance(address(helper), address(vault)), 0);
        assertEq(usd3l.allowance(address(helper), address(morpho)), type(uint256).max);
    }

    /* CONSTRUCTOR */

    function testConstructorValidatesTokenWiring() public {
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidConfiguration.selector);
        new LCCLeveragedFundHelper(address(morpho), address(factory), address(margin), address(usd3l));

        vm.expectRevert(ILCCLeveragedFundHelper.InvalidConfiguration.selector);
        new LCCLeveragedFundHelper(address(0), address(factory), address(usdc), address(usd3l));

        assertEq(helper.usd3(), address(usd3));
        assertEq(helper.usdc(), address(usdc));
        assertEq(helper.usd3l(), address(usd3l));
        assertEq(usd3l.allowance(address(helper), address(morpho)), type(uint256).max);
    }

    /* HELPERS */

    function _deployTokens() internal override {
        usdc = new LCCPermitMockToken("USD Coin", "USDC");
        usd3 = new LCCMockUSD3(IERC20(address(usdc)));
        usd3l = new LCCPermitNotificationVault(IERC20(address(usd3)));
        notificationVault = usd3l;
    }

    function _approveHelper(address user) internal {
        vm.startPrank(user);
        usdc.approve(address(helper), type(uint256).max);
        usd3l.approve(address(helper), type(uint256).max);
        morpho.setAuthorization(address(helper), true);
        vm.stopPrank();
    }

    function _depositAndOpenCall(address user) internal {
        _deposit(user, MARGIN);
        _openCall(CALL);
        vm.warp(START + NORMAL + PRE_CALL);
    }

    function _fundParams(uint256 borrowAssets) internal view returns (ILCCLeveragedFundHelper.FundParams memory) {
        return ILCCLeveragedFundHelper.FundParams({
            vault: address(vault),
            market: marketParams,
            borrowAssets: borrowAssets,
            maxContribution: CALL - borrowAssets,
            maxEntryLtv: LLTV,
            maxObligation: CALL,
            deadline: block.timestamp
        });
    }

    function _createMarket(uint256 lltv, uint256 liquidity) internal returns (IMorphoBlue.MarketParams memory market) {
        market = marketParams;
        market.lltv = lltv;
        morpho.createMarket(market);
        usdc.mint(address(this), liquidity);
        usdc.approve(address(morpho), liquidity);
        morpho.supply(market, liquidity, 0, address(this), "");
    }

    function _supplyExtraCollateral(address user, uint256 amount) internal {
        deal(address(usd3l), user, amount);
        vm.startPrank(user);
        usd3l.approve(address(morpho), amount);
        morpho.supplyCollateral(marketParams, amount, user, "");
        vm.stopPrank();
    }

    function _prepareSigner() internal {
        _depositAndOpenCall(signer);
        usdc.mint(signer, 20e18);
    }

    function _sign(uint256 usdcValue, uint256 usd3lValue) internal view returns (Signed memory) {
        return _signAll(
            SignRequest({
                helper: address(helper),
                morpho: address(morpho),
                usdc: address(usdc),
                usd3l: address(usd3l),
                key: signerKey,
                usdcValue: usdcValue,
                usd3lValue: usd3lValue,
                deadline: type(uint256).max
            })
        );
    }

    function _fundSigned(ILCCLeveragedFundHelper.FundParams memory params, Signed memory s) internal {
        vm.prank(signer);
        helper.fundWithSignatures(params, s.usdcPermit, s.usd3lPermit, s.authorization, s.signature);
    }

    function _expectInsufficientAllowance(address token, uint256 allowance, uint256 required, bytes memory permitRevert)
        internal
    {
        vm.expectRevert(
            abi.encodeWithSelector(
                ILCCLeveragedFundHelper.InsufficientAllowance.selector, token, allowance, required, permitRevert
            )
        );
    }

    /// @dev The OpenZeppelin `ERC2612InvalidSigner` revert the token raises when the helper relays `permit` for the
    /// signer at the token's current nonce and the signature recovers to a different address.
    function _invalidSignerRevert(address token, ILCCLeveragedFundHelper.PermitSignature memory permit, address spender)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH, signer, spender, permit.value, ERC20Permit(token).nonces(signer), permit.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ERC20Permit(token).DOMAIN_SEPARATOR(), structHash));
        address recovered = ecrecover(digest, permit.v, permit.r, permit.s);
        return abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, recovered, signer);
    }

    function _assertNotReenterable(bytes memory call) internal {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        morpho.armReentry(address(helper), call);

        vm.prank(alice);
        helper.fund(_fundParams(80e18));
        assertEq(morpho.reentryError(), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertTrue(vault.fundedEpoch(0, alice));
    }

    function _assertHelperClean() internal view {
        assertEq(usdc.balanceOf(address(helper)), 0);
        assertEq(usd3l.balanceOf(address(helper)), 0);
        assertEq(usdc.allowance(address(helper), address(vault)), 0);
        assertEq(usd3l.allowance(address(helper), address(morpho)), type(uint256).max);
    }
}
