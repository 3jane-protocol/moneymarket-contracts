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
import {IERC4626} from "../../../lib/openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Errors} from "../../../lib/openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {
    LCCBase,
    LCCMockToken,
    LCCMockUSD3,
    LCCMockNotificationVault,
    LCCReentryProbe,
    LCCAssetOnlyVault
} from "./LCCBase.t.sol";
import {LCCLeveragedFundSigUtils, morphoAuthorizationDigest} from "./LCCLeveragedFundSigUtils.sol";
import {LCCLeveragedFundTestBase} from "./LCCLeveragedFundTestBase.sol";
import {IMorphoBlueTest} from "./IMorphoBlueTest.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {LCCLeveragedFundHelper} from "../../../src/lcc/LCCLeveragedFundHelper.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {LCCEventsLib} from "../../../src/lcc/libraries/LCCEventsLib.sol";
import {ILCCLeveragedFundHelper} from "../../../src/lcc/interfaces/ILCCLeveragedFundHelper.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {IMorphoBlue, IMorphoBlueFlashLoanCallback} from "../../../src/lcc/interfaces/IMorphoBlue.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {OracleMock} from "../../../src/mocks/OracleMock.sol";
import {ORACLE_PRICE_SCALE, DOMAIN_TYPEHASH} from "../../../src/libraries/ConstantsLib.sol";
import {MathLib} from "../../../src/libraries/MathLib.sol";
import {SharesMathLib} from "../../../src/libraries/SharesMathLib.sol";

/// @dev Smart-wallet stand-in that executes a batch of calls in one transaction.
contract LCCHelperMulticallFunder {
    function execute(address[] calldata targets, bytes[] calldata calls) external returns (bytes[] memory results) {
        results = new bytes[](targets.length);
        for (uint256 i; i < targets.length; ++i) {
            (bool ok, bytes memory result) = targets[i].call(calls[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }
            results[i] = result;
        }
    }
}

/// @dev ERC-4626 margin asset over the test USDC with ERC-2612 permit, standing in for waEthUSDC. `withdrawShortfall`
/// pays the receiver less than the requested assets while burning the full share amount; `extraBurn` burns more shares
/// than `withdraw` returns.
contract LCCMockUsdcMarginVault is ERC4626, ERC20Permit {
    uint256 public withdrawShortfall;
    uint256 public extraBurn;

    constructor(IERC20 asset_) ERC20("Mock waUSDC", "mwaUSDC") ERC4626(asset_) ERC20Permit("Mock waUSDC") {}

    function setWithdrawShortfall(uint256 shortfall) external {
        withdrawShortfall = shortfall;
    }

    function setExtraBurn(uint256 extra) external {
        extraBurn = extra;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        super._withdraw(caller, receiver, owner, assets - withdrawShortfall, shares);
        if (extraBurn != 0) _burn(owner, extraBurn);
    }

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }
}

/// @dev USD3 stand-in whose `redeem` with a loss bound honours a settable withdraw limit; `reportProfit` moves the
/// share price.
contract LCCUnwindMockUSD3 is LCCMockUSD3 {
    uint256 public withdrawLimit = type(uint256).max;

    constructor(IERC20 asset_) LCCMockUSD3(asset_) {}

    function setWithdrawLimit(uint256 limit) external {
        withdrawLimit = limit;
    }

    function redeem(uint256 shares, address receiver, address owner, uint256) external returns (uint256) {
        require(previewRedeem(shares) <= withdrawLimit, "ERC4626: redeem more than max");
        return redeem(shares, receiver, owner);
    }

    uint256 public withdrawOverDelivery;

    function setWithdrawOverDelivery(uint256 extra) external {
        withdrawOverDelivery = extra;
    }

    function withdraw(uint256 assets, address receiver, address owner, uint256) external returns (uint256 shares) {
        require(assets <= withdrawLimit, "ERC4626: withdraw more than max");
        shares = withdraw(assets, receiver, owner);
        if (withdrawOverDelivery != 0) IERC20(asset()).transfer(receiver, withdrawOverDelivery);
    }
}

contract LCCPermitMockToken is LCCMockToken, ERC20Permit {
    constructor(string memory name_, string memory symbol_) LCCMockToken(name_, symbol_) ERC20Permit(name_) {}
}

/// @dev USD3l stand-in with the NotificationVault cooldown surface the helper reads: `redeem` with a loss bound is
/// available only to a bypassed owner, or to anyone while shut down or with a zero cooldown.
contract LCCPermitNotificationVault is LCCMockNotificationVault, ERC20Permit {
    uint256 public extraMint;
    uint64 public cooldownDuration = 35 days;
    bool public isShutdown;
    mapping(address => bool) public cooldownBypass;

    constructor(IERC20 asset_) LCCMockNotificationVault(asset_) ERC20Permit("Mock Notification USD3") {}

    function setExtraMint(uint256 extra) external {
        extraMint = extra;
    }

    function setCooldownDuration(uint64 duration) external {
        cooldownDuration = duration;
    }

    function setShutdown(bool shutdown) external {
        isShutdown = shutdown;
    }

    function setCooldownBypass(address account, bool allowed) external {
        cooldownBypass[account] = allowed;
    }

    function redeem(uint256 shares, address receiver, address owner, uint256) external returns (uint256) {
        require(isShutdown || cooldownDuration == 0 || cooldownBypass[owner], "ERC4626: redeem more than max");
        return redeem(shares, receiver, owner);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        if (extraMint != 0) _mint(receiver, extraMint);
    }

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }
}

/// @dev Canonical Morpho Blue semantics for the paths the helper uses: a flash loan transfers the assets, calls back,
/// and pulls the same amount without a fee; collateral is credited and then pulled; borrowing requires authorization,
/// health, and liquidity; authorization signatures follow the canonical EIP-712 domain and nonce rules. Knobs alter
/// the flash-loan callback to exercise the helper's binding checks.
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
    mapping(bytes32 => uint256) public pendingInterest;
    bool public skipCallback;
    uint256 public callbackAssetsDelta;
    uint256 public flashRepayExtra;
    uint256 public flashLoanCount;
    uint256 public lastFlashAssets;
    bytes public lastFlashData;
    /// @dev Operation kind written into payload byte 31 plus one; zero leaves the payload's own kind.
    uint16 public callbackKindOverride;

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

    /// @dev Relabels every later callback payload with operation kind `kind`.
    function setCallbackKind(uint8 kind) external {
        callbackKindOverride = uint16(kind) + 1;
    }

    /// @dev Interest added to the market's borrow and supply totals at its next accrual.
    function setPendingInterest(bytes32 id, uint256 assets) external {
        pendingInterest[id] = assets;
    }

    /// @dev Moves `assets` of `user`'s collateral to the caller, standing in for a liquidation.
    function seizeCollateral(IMorphoBlue.MarketParams calldata params, address user, uint256 assets) external {
        position[_created(params)][user].collateral -= uint128(assets);
        IERC20(params.collateralToken).safeTransfer(msg.sender, assets);
    }

    function accrueInterest(IMorphoBlue.MarketParams calldata params) external {
        _accrue(_created(params));
    }

    function repay(
        IMorphoBlue.MarketParams calldata params,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata
    ) external returns (uint256, uint256) {
        bytes32 id = _created(params);
        require((assets == 0) != (shares == 0), "inconsistent input");
        _accrue(id);
        _fireReentry();
        MarketState storage m = market[id];
        if (assets > 0) shares = assets.toSharesDown(m.totalBorrowAssets, m.totalBorrowShares);
        else assets = shares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
        position[id][onBehalf].borrowShares -= uint128(shares);
        m.totalBorrowShares -= uint128(shares);
        m.totalBorrowAssets = assets > m.totalBorrowAssets ? 0 : m.totalBorrowAssets - uint128(assets);
        IERC20(params.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        return (assets, shares);
    }

    function withdrawCollateral(
        IMorphoBlue.MarketParams calldata params,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external {
        bytes32 id = _created(params);
        require(assets != 0, "zero assets");
        require(msg.sender == onBehalf || isAuthorized[onBehalf][msg.sender], "unauthorized");
        _accrue(id);
        position[id][onBehalf].collateral -= uint128(assets);
        require(_isHealthy(params, id, onBehalf), "insufficient collateral");
        IERC20(params.collateralToken).safeTransfer(receiver, assets);
    }

    function _accrue(bytes32 id) internal {
        uint256 interest = pendingInterest[id];
        if (interest == 0) return;
        pendingInterest[id] = 0;
        market[id].totalBorrowAssets += uint128(interest);
        market[id].totalSupplyAssets += uint128(interest);
    }

    function setCallbackAssetsDelta(uint256 delta) external {
        callbackAssetsDelta = delta;
    }

    /// @dev Pulls `extra` more than the loaned assets back from the borrower after the callback.
    function setFlashRepayExtra(uint256 extra) external {
        flashRepayExtra = extra;
    }

    /// @dev With `skipCallback` set, the loaned assets are left with the borrower and nothing is pulled back.
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        require(assets != 0, "zero assets");
        ++flashLoanCount;
        lastFlashAssets = assets;
        lastFlashData = data;
        IERC20(token).safeTransfer(msg.sender, assets);
        if (skipCallback) return;
        bytes memory payload = data;
        if (tamperCallbackData) payload[payload.length - 1] ^= 0x01;
        if (callbackKindOverride != 0) payload[31] = bytes1(uint8(callbackKindOverride - 1));
        for (uint256 i; i < callbackCount; ++i) {
            IMorphoBlueFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets + callbackAssetsDelta, payload);
        }
        IERC20(token).safeTransferFrom(msg.sender, address(this), assets + flashRepayExtra);
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
        require(data.length == 0, "callback unsupported");
        position[id][onBehalf].collateral += uint128(assets);
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
        _accrue(id);

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
        bytes32 digest = morphoAuthorizationDigest(DOMAIN_SEPARATOR(), authorization);
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
        if (position[id][user].borrowShares == 0) return true;
        uint256 maxBorrow = uint256(position[id][user].collateral)
            .mulDivDown(IOracle(params.oracle).price(), ORACLE_PRICE_SCALE)
            .wMulDown(params.lltv);
        return maxBorrow >= borrowAssetsOf(id, user);
    }
}

contract LCCLeveragedFundHelperTest is LCCBase, LCCLeveragedFundSigUtils, LCCLeveragedFundTestBase {
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant LIQUIDITY = 1_000_000e18;
    uint256 internal constant MARGIN = 100e18;
    uint256 internal constant CALL = 100e18;
    uint256 internal constant RELEASED = 50e18;
    uint256 internal constant SECOND_ENTRY_EPOCH = 21 days / 100 + 1;
    uint256 internal constant SHORTFALL = 50e18;
    uint256 internal constant AUCTION_STEP = 5;
    /// @dev OpenZeppelin `ReentrancyGuardTransient`'s slot, which some Forge versions list among storage accesses.
    bytes32 internal constant REENTRANCY_GUARD_SLOT =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

    LCCMockMorphoBlue internal morpho;
    OracleMock internal marketOracle;
    LCCPermitNotificationVault internal usd3l;
    LCCUnwindMockUSD3 internal unwindUsd3;
    LCCMockUsdcMarginVault internal waUsdc;
    LCCVault internal marginFacility;
    LCCVault internal auctionVault;
    address internal auctionFunder = makeAddr("auction-funder");
    address internal auctionDefaulter = makeAddr("auction-defaulter");

    address internal signer;
    uint256 internal signerKey;
    uint256 internal otherKey;

    /// @dev The helper's `MAX_COOLDOWNS` and the USD3l stand-in's initial cooldown, read at setUp.
    uint256 internal maxCooldowns;
    uint256 internal cooldown;

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

        helper = new LCCLeveragedFundHelper(address(morpho), address(factory), address(usd3l));
        usd3l.setCooldownBypass(address(helper), true);
        maxCooldowns = helper.MAX_COOLDOWNS();
        cooldown = usd3l.cooldownDuration();

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
        _assertHelperClean(address(vault));
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
        _assertHelperClean(address(vault));
    }

    function testFullyLeveredSignedFundDoesNotSubmitValidUsdcPermit() public {
        _depositAndOpenCall(signer);
        _supplyExtraCollateral(signer, CALL);
        usdc.mint(signer, 5e18);
        vm.prank(signer);
        usdc.approve(address(helper), 7e18);
        Signed memory s = _sign(1, CALL);
        uint256 usdcNonce = LCCPermitMockToken(address(usdc)).nonces(signer);

        _fundSigned(_fundParams(CALL), s);

        assertTrue(vault.fundedEpoch(0, signer));
        assertEq(usdc.balanceOf(signer), 5e18);
        assertEq(usdc.allowance(signer, address(helper)), 7e18);
        assertEq(LCCPermitMockToken(address(usdc)).nonces(signer), usdcNonce);
        assertEq(morpho.borrowAssetsOf(marketId, signer), CALL);
        _assertHelperClean(address(vault));
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
        params.minCollateral = 1;
        params.maxCollateral = 1;
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
        _assertHelperClean(address(vault));
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
        vm.mockCallRevert(address(marketOracle), abi.encodeCall(IOracle.price, ()), "ORACLE_DOWN");

        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(0);
        params.maxEntryLtv = 0;
        vm.prank(alice);
        helper.fund(params);

        assertTrue(vault.fundedEpoch(0, alice));
        (,, uint128 positionCollateral) = morpho.position(marketId, alice);
        assertEq(positionCollateral, 100e18 + CALL);
        assertEq(morpho.borrowAssetsOf(marketId, alice), 50e18);
        _assertHelperClean(address(vault));
    }

    /* MARKETS */

    function testRejectsMarketWithWrongLoanOrCollateralToken() public {
        _depositAndOpenCall(alice);
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(80e18);

        params.market.loanToken = address(margin);
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidRequest.selector);
        vm.prank(alice);
        helper.fund(params);

        params.market = marketParams;
        params.market.collateralToken = address(usd3);
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidRequest.selector);
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
        params.minCollateral = obligation;
        params.maxCollateral = obligation;
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
        _assertHelperClean(address(vault));
    }

    /* FAIL-FAST BOUNDS */

    function testFundingOutsideFundingPhaseRejected() public {
        _deposit(alice, MARGIN);
        _openCall(CALL);
        usdc.mint(alice, 20e18);
        vm.expectRevert(ILCCLeveragedFundHelper.NothingToFund.selector);
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
        params.minCollateral = 1;
        params.maxCollateral = 1;
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

    /* RELEASED MARGIN */

    function testMarginOnlyEntryTakesOneFlashLoanWithoutOracleOrAuthorization() public {
        _openMarginFacility(alice);
        usdc.mint(alice, CALL - RELEASED);
        vm.prank(alice);
        morpho.setAuthorization(address(helper), false);
        vm.mockCallRevert(address(marketOracle), abi.encodeCall(IOracle.price, ()), "ORACLE_DOWN");

        ILCCLeveragedFundHelper.FundParams memory params = _marginParams(0, RELEASED);
        params.maxEntryLtv = 0;
        vm.prank(alice);
        (,, uint256 collateral) = helper.fund(params);

        assertEq(collateral, CALL);
        assertEq(morpho.flashLoanCount(), 1);
        assertEq(morpho.lastFlashAssets(), RELEASED);
        assertTrue(marginFacility.fundedEpoch(0, alice));
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(waUsdc.balanceOf(alice), 0);
        (, uint128 borrowShares, uint128 positionCollateral) = morpho.position(marketId, alice);
        assertEq(borrowShares, 0);
        assertEq(positionCollateral, CALL);
        _assertHelperClean(address(marginFacility));
    }

    function testLeveredMarginEntryFlashLoansBorrowPlusMargin() public {
        _openMarginFacility(alice);
        usdc.mint(alice, CALL - 40e18 - RELEASED);

        vm.prank(alice);
        (, uint256 fundingAmount, uint256 collateral) = helper.fund(_marginParams(40e18, RELEASED));

        assertEq(fundingAmount, CALL);
        assertEq(collateral, CALL);
        assertEq(morpho.flashLoanCount(), 1);
        assertEq(morpho.lastFlashAssets(), 40e18 + RELEASED);
        assertEq(morpho.borrowAssetsOf(marketId, alice), 40e18);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(waUsdc.balanceOf(alice), 0);
        assertEq(waUsdc.allowance(alice, address(helper)), 0);
        _assertHelperClean(address(marginFacility));
    }

    function testMarginAboveHeldSharesReverts() public {
        _openMarginFacility(alice);
        usdc.mint(alice, CALL);
        vm.prank(alice);
        waUsdc.approve(address(helper), RELEASED + 1);

        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, alice, RELEASED + 1, RELEASED)
        );
        vm.prank(alice);
        helper.fund(_marginParams(0, RELEASED + 1));
    }

    function testMarginSharesAboveMaximumReverts() public {
        _openMarginFacility(alice);
        usdc.mint(alice, CALL - RELEASED);
        ILCCLeveragedFundHelper.FundParams memory params = _marginParams(0, RELEASED);
        params.maxMarginShares = RELEASED - 1;

        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.MarginSharesExceedMax.selector, RELEASED, RELEASED - 1)
        );
        vm.prank(alice);
        helper.fund(params);
    }

    function testMarginReceiptShortfallReverts() public {
        _openMarginFacility(alice);
        usdc.mint(alice, CALL - RELEASED);
        waUsdc.setWithdrawShortfall(1);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILCCLeveragedFundHelper.UnexpectedBalance.selector, address(usdc), RELEASED - 1, RELEASED
            )
        );
        vm.prank(alice);
        helper.fund(_marginParams(0, RELEASED));
    }

    function testZeroMaxMarginSharesRejected() public {
        _openMarginFacility(alice);
        ILCCLeveragedFundHelper.FundParams memory params = _marginParams(0, RELEASED);
        params.maxMarginShares = 0;

        _expectNoFunding(address(marginFacility));
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidRequest.selector);
        vm.prank(alice);
        helper.fund(params);
    }

    function testMarginPathRequiresMarginAssetVaultOverUsdc() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(40e18);
        params.marginAssets = 40e18;
        params.maxMarginShares = 40e18;
        params.maxContribution = 20e18;
        LCCMockUsdcMarginVault foreignVault = new LCCMockUsdcMarginVault(IERC20(address(margin)));
        ILCCVault.VaultParams memory vaultParams = _params(CAP, CAP);
        vaultParams.marginAsset = address(foreignVault);
        address foreignFacility = address(_newVault(vaultParams));
        _expectNoFunding(address(vault));
        vm.expectCall(foreignFacility, abi.encodeWithSignature("fundCall(address)"), 0);

        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.UnsupportedMarginAsset.selector, address(margin))
        );
        vm.prank(alice);
        helper.fund(params);

        params.vault = foreignFacility;
        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.UnsupportedMarginAsset.selector, address(foreignVault))
        );
        vm.prank(alice);
        helper.fund(params);
    }

    function testCodelessMarginAssetRejected() public {
        address codeless = makeAddr("codeless-margin");
        ILCCVault.VaultParams memory vaultParams = _params(CAP, CAP);
        vaultParams.marginAsset = codeless;
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(0);
        params.vault = address(_newVault(vaultParams));
        params.marginAssets = 1;
        params.maxMarginShares = 1;

        _expectNoFunding(params.vault);
        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.UnsupportedMarginAsset.selector, codeless));
        vm.prank(alice);
        helper.fund(params);
    }

    function testMarginBeyondReleasedRejectedForSurplusHolder() public {
        _openMarginFacility(alice);
        _mintSurplusMargin(alice, 30e18);
        usdc.mint(alice, CALL);
        vm.prank(alice);
        waUsdc.approve(address(helper), RELEASED + 10);
        ILCCLeveragedFundHelper.FundParams memory params = _marginParams(0, RELEASED + 1);
        params.maxMarginShares = RELEASED + 10;

        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.MarginSharesUnavailable.selector, RELEASED + 1, RELEASED)
        );
        vm.prank(alice);
        helper.fund(params);
        assertFalse(marginFacility.fundedEpoch(0, alice));
        assertEq(waUsdc.balanceOf(alice), 30e18);
    }

    function testSurplusHolderSpendsExactlyReleasedMargin() public {
        _openMarginFacility(alice);
        _mintSurplusMargin(alice, 30e18);
        usdc.mint(alice, CALL - RELEASED);
        ILCCLeveragedFundHelper.FundParams memory params = _marginParams(0, RELEASED);
        params.maxMarginShares = RELEASED + 10;
        vm.prank(alice);
        waUsdc.approve(address(helper), RELEASED + 10);

        vm.prank(alice);
        helper.fund(params);

        assertTrue(marginFacility.fundedEpoch(0, alice));
        assertEq(waUsdc.balanceOf(alice), 30e18);
        assertEq(usdc.balanceOf(alice), 0);
        _assertHelperClean(address(marginFacility));
    }

    function testMeasuredMarginBurnAboveMaximumReverts() public {
        _openMarginFacility(alice);
        _mintSurplusMargin(alice, 30e18);
        usdc.mint(alice, CALL - RELEASED);
        waUsdc.setExtraBurn(1);

        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.MarginSharesExceedMax.selector, RELEASED + 1, RELEASED)
        );
        vm.prank(alice);
        helper.fund(_marginParams(0, RELEASED));
    }

    function testEntryWithoutMarginNeverCallsMarginAsset() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);

        vm.expectCall(address(margin), abi.encodeWithSelector(IERC4626.asset.selector), 0);
        vm.expectCall(address(margin), abi.encodeWithSelector(IERC4626.withdraw.selector), 0);
        vm.prank(alice);
        helper.fund(_fundParams(80e18));
        assertTrue(vault.fundedEpoch(0, alice));
    }

    function testBorrowAndMarginAboveFundingRejected() public {
        _openMarginFacility(alice);
        ILCCLeveragedFundHelper.FundParams memory params = _marginParams(0, RELEASED);
        params.borrowAssets = CALL - RELEASED + 1;
        params.maxContribution = 0;

        vm.expectRevert(
            abi.encodeWithSelector(
                ILCCLeveragedFundHelper.BorrowAndMarginExceedTotal.selector, CALL - RELEASED + 1, RELEASED, CALL
            )
        );
        vm.prank(alice);
        helper.fund(params);
    }

    function testOverflowingBorrowAndMarginRejectedWithTypedError() public {
        _openMarginFacility(alice);
        ILCCLeveragedFundHelper.FundParams memory params = _marginParams(0, RELEASED);
        params.borrowAssets = CALL;
        params.marginAssets = type(uint256).max;
        params.maxContribution = 0;

        vm.expectRevert(
            abi.encodeWithSelector(
                ILCCLeveragedFundHelper.BorrowAndMarginExceedTotal.selector, CALL, type(uint256).max, CALL
            )
        );
        vm.prank(alice);
        helper.fund(params);
    }

    function testCallbackAssetsMustEqualBorrowPlusMargin() public {
        _openMarginFacility(alice);
        usdc.mint(alice, CALL - 40e18 - RELEASED);
        morpho.setCallbackAssetsDelta(1);

        vm.expectRevert(ILCCLeveragedFundHelper.InvalidCallback.selector);
        vm.prank(alice);
        helper.fund(_marginParams(40e18, RELEASED));
    }

    function testFundWithShortMarginAllowanceRevertsBeforeFunding() public {
        _openMarginFacility(alice);
        usdc.mint(alice, CALL - RELEASED);
        vm.prank(alice);
        waUsdc.approve(address(helper), RELEASED - 1);

        _expectNoFunding(address(marginFacility));
        _expectInsufficientAllowance(address(waUsdc), RELEASED - 1, RELEASED, "");
        vm.prank(alice);
        helper.fund(_marginParams(0, RELEASED));
    }

    function testFundWithSignaturesAppliesMarginPermit() public {
        _openMarginFacility(signer);
        vm.prank(signer);
        waUsdc.approve(address(helper), 0);
        usdc.mint(signer, CALL - 40e18 - RELEASED);
        Signed memory s = _sign(CALL - 40e18 - RELEASED, CALL);
        s.marginPermit = _signPermit(address(waUsdc), signerKey, address(helper), RELEASED, type(uint256).max);
        uint256 nonceBefore = waUsdc.nonces(signer);

        _fundSigned(_marginParams(40e18, RELEASED), s);

        assertTrue(marginFacility.fundedEpoch(0, signer));
        assertEq(waUsdc.nonces(signer), nonceBefore + 1);
        assertEq(waUsdc.allowance(signer, address(helper)), 0);
        assertEq(waUsdc.balanceOf(signer), 0);
        assertEq(morpho.borrowAssetsOf(marketId, signer), 40e18);
        _assertHelperClean(address(marginFacility));
    }

    function testFundWithSignaturesIgnoresMarginPermitWithoutMargin() public {
        _openMarginFacility(signer);
        vm.prank(signer);
        waUsdc.approve(address(helper), 7);
        usdc.mint(signer, 20e18);
        Signed memory s = _sign(20e18, CALL);
        s.marginPermit = _signPermit(address(waUsdc), signerKey, address(helper), 1, type(uint256).max);
        uint256 nonceBefore = waUsdc.nonces(signer);

        _fundSigned(_marginParams(80e18, 0), s);

        assertTrue(marginFacility.fundedEpoch(0, signer));
        assertEq(waUsdc.nonces(signer), nonceBefore);
        assertEq(waUsdc.allowance(signer, address(helper)), 7);
        assertEq(waUsdc.balanceOf(signer), RELEASED);
        _assertHelperClean(address(marginFacility));
    }

    function testMarginPermitSubmittedFirstByThirdPartyIsTolerated() public {
        _openMarginFacility(signer);
        vm.prank(signer);
        waUsdc.approve(address(helper), 0);
        usdc.mint(signer, CALL - 40e18 - RELEASED);
        Signed memory s = _sign(CALL - 40e18 - RELEASED, CALL);
        s.marginPermit = _signPermit(address(waUsdc), signerKey, address(helper), RELEASED, type(uint256).max);

        vm.prank(stranger);
        _submitPermit(address(waUsdc), signer, address(helper), s.marginPermit);

        _fundSigned(_marginParams(40e18, RELEASED), s);
        assertTrue(marginFacility.fundedEpoch(0, signer));
        assertEq(waUsdc.allowance(signer, address(helper)), 0);
        _assertHelperClean(address(marginFacility));
    }

    /* COOLDOWNS */

    function testEntryOpensCooldownForSuppliedCollateral() public {
        uint256 start = _enterLevered(alice);

        ILCCLeveragedFundHelper.Cooldown[] memory book = helper.cooldowns(alice, marketId);
        assertEq(book.length, 1);
        assertEq(book[0].shares, CALL);
        assertEq(book[0].start, start);
        assertEq(book[0].duration, cooldown);
        assertEq(_maturedShares(alice), 0);
        assertEq(helper.maxUnwindable(alice, marketId), 0);
    }

    function testCooldownMaturesExactlyAtCooldownEnd() public {
        uint256 start = _enterLevered(alice);

        vm.warp(start + cooldown - 1);
        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.InsufficientMaturedShares.selector, CALL, 0));
        vm.prank(alice);
        helper.unwind(_unwindParams(CALL, true, 0));

        vm.warp(start + cooldown);
        assertEq(helper.maxUnwindable(alice, marketId), CALL);
        vm.prank(alice);
        helper.unwind(_unwindParams(CALL, true, 0));
        assertEq(helper.cooldowns(alice, marketId).length, 0);
    }

    function testCooldownsConsumeOldestMaturedFirstAndPartially() public {
        uint256 first = _enterLevered(alice);
        uint256 second = _enterLeveredAtEpoch(alice, SECOND_ENTRY_EPOCH);
        assertGe(second - first, 21 days);

        vm.warp(first + cooldown);
        assertEq(_maturedShares(alice), CALL);
        vm.prank(alice);
        helper.unwind(_unwindParams(60e18, false, 60e18));

        ILCCLeveragedFundHelper.Cooldown[] memory book = helper.cooldowns(alice, marketId);
        assertEq(book.length, 2);
        assertEq(book[0].shares, CALL - 60e18);
        assertEq(book[1].shares, CALL);

        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.InsufficientMaturedShares.selector, 70e18, 40e18)
        );
        vm.prank(alice);
        helper.unwind(_unwindParams(70e18, false, 70e18));

        vm.warp(second + cooldown);
        vm.prank(alice);
        helper.unwind(_unwindParams(140e18, true, 0));
        assertEq(helper.cooldowns(alice, marketId).length, 0);
        (,, uint128 collateral) = morpho.position(marketId, alice);
        assertEq(collateral, 0);
    }

    function testLiveCollateralCapsUnwindAfterDirectWithdrawalAndCooldownOutlivesIt() public {
        uint256 start = _enterUnlevered(alice);
        vm.prank(alice);
        morpho.withdrawCollateral(marketParams, 40e18, alice, alice);

        vm.warp(start + cooldown);
        assertEq(helper.maxUnwindable(alice, marketId), 60e18);
        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.SharesExceedCollateral.selector, 60e18 + 1, 60e18)
        );
        vm.prank(alice);
        helper.unwind(_unwindParams(60e18 + 1, true, 0));

        vm.prank(alice);
        helper.unwind(_unwindParams(60e18, true, 0));
        assertEq(helper.cooldowns(alice, marketId)[0].shares, 40e18);

        vm.startPrank(alice);
        usd3l.approve(address(morpho), 40e18);
        morpho.supplyCollateral(marketParams, 40e18, alice, "");
        (, uint256 usdcOut) = helper.unwind(_unwindParams(40e18, true, 0));
        vm.stopPrank();
        assertEq(usdcOut, 40e18);
        assertEq(helper.cooldowns(alice, marketId).length, 0);
    }

    function testLiveCollateralCapsUnwindAfterLiquidation() public {
        uint256 start = _enterLevered(alice);
        morpho.seizeCollateral(marketParams, alice, 30e18);

        vm.warp(start + cooldown);
        assertEq(helper.maxUnwindable(alice, marketId), 70e18);
        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.SharesExceedCollateral.selector, CALL, 70e18));
        vm.prank(alice);
        helper.unwind(_unwindParams(CALL, true, 0));
    }

    function testPartialConsumptionOfOldestCooldownTouchesOnlyThatEntry() public {
        _deposit(alice, MARGIN);
        for (uint256 epoch; epoch < maxCooldowns; ++epoch) {
            _fundUnleveredAtEpoch(alice, epoch, 1e18);
        }
        ILCCLeveragedFundHelper.Cooldown[] memory before = helper.cooldowns(alice, marketId);
        vm.warp(uint256(before[0].start) + cooldown);
        assertEq(_maturedShares(alice), 1e18);
        bytes32 bookSlot = keccak256(abi.encode(marketId, keccak256(abi.encode(alice, uint256(0)))));
        bytes32 oldestSlot = keccak256(abi.encode(bookSlot));

        vm.record();
        vm.prank(alice);
        helper.unwind(_unwindParams(0.4e18, true, 0));
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(helper));

        // Via-IR can store a packed cooldown member by member, so the written cooldown may appear more than once.
        uint256 bookWrites;
        for (uint256 i; i < writes.length; ++i) {
            if (writes[i] == REENTRANCY_GUARD_SLOT) continue;
            assertEq(writes[i], oldestSlot, "only the oldest cooldown is written");
            ++bookWrites;
        }
        assertGt(bookWrites, 0);
        for (uint256 i; i < reads.length; ++i) {
            if (reads[i] == REENTRANCY_GUARD_SLOT) continue;
            assertTrue(reads[i] == bookSlot || reads[i] == oldestSlot, "only the length and the oldest are read");
        }
        ILCCLeveragedFundHelper.Cooldown[] memory book = helper.cooldowns(alice, marketId);
        assertEq(book.length, maxCooldowns);
        assertEq(book[0].shares, 0.6e18);
        assertEq(book[0].start, before[0].start);
        assertEq(book[0].duration, before[0].duration);
        for (uint256 i = 1; i < maxCooldowns; ++i) {
            assertEq(abi.encode(book[i]), abi.encode(before[i]));
        }
    }

    function testFullBookMergesTheTwoOldestCooldownsAndFundingNeverReverts() public {
        _deposit(alice, MARGIN);
        uint256[] memory starts = new uint256[](maxCooldowns + 1);
        for (uint256 epoch; epoch < maxCooldowns; ++epoch) {
            starts[epoch] = _fundUnleveredAtEpoch(alice, epoch, 1e18);
        }

        vm.recordLogs();
        starts[maxCooldowns] = _fundUnleveredAtEpoch(alice, maxCooldowns, 1e18);
        assertEq(_countLogs(address(helper), ILCCLeveragedFundHelper.CooldownsMerged.selector), 1);

        ILCCLeveragedFundHelper.Cooldown[] memory book = helper.cooldowns(alice, marketId);
        assertEq(book.length, maxCooldowns);
        assertEq(book[0].shares, 2e18);
        assertEq(book[0].start, starts[1], "merged pair keeps the later start");
        assertEq(book[0].duration, cooldown, "merged pair keeps the later recorded maturity");
        assertEq(book[1].start, starts[2]);
        assertEq(book[maxCooldowns - 2].start, starts[maxCooldowns - 1], "previous newest untouched");
        assertEq(book[maxCooldowns - 2].shares, 1e18);
        assertEq(book[maxCooldowns - 1].start, starts[maxCooldowns]);
        assertEq(book[maxCooldowns - 1].shares, 1e18);
    }

    function testFullBookMergeLeavesUnmaturedNewestCooldownUntouched() public {
        _deposit(alice, MARGIN);
        for (uint256 epoch; epoch < maxCooldowns; ++epoch) {
            _fundUnleveredAtEpoch(alice, epoch, 1e18);
        }
        ILCCLeveragedFundHelper.Cooldown memory newestBefore = helper.cooldowns(alice, marketId)[maxCooldowns - 1];
        ILCCLeveragedFundHelper.Cooldown memory oldestBefore = helper.cooldowns(alice, marketId)[0];
        vm.warp(uint256(oldestBefore.start) + cooldown);
        assertGt(_maturedShares(alice), 0);

        uint256 epoch = (block.timestamp - START) / EPOCH + 1;
        _fundUnleveredAtEpoch(alice, epoch, 1e18);

        ILCCLeveragedFundHelper.Cooldown[] memory book = helper.cooldowns(alice, marketId);
        assertEq(book[maxCooldowns - 2].start, newestBefore.start);
        assertEq(book[maxCooldowns - 2].shares, newestBefore.shares);
        assertEq(book[maxCooldowns - 2].duration, newestBefore.duration);
        assertGt(uint256(book[0].start) + book[0].duration, uint256(oldestBefore.start) + oldestBefore.duration);
    }

    function testFullBookMergeKeepsLaterStartAndLaterRecordedMaturity() public {
        _deposit(alice, MARGIN);
        usd3l.setCooldownDuration(uint64(100 days));
        uint256 firstStart = _fundUnleveredAtEpoch(alice, 0, 1e18);
        usd3l.setCooldownDuration(uint64(1 days));
        uint256 secondStart = _fundUnleveredAtEpoch(alice, 1, 1e18);
        usd3l.setCooldownDuration(uint64(cooldown));
        for (uint256 epoch = 2; epoch < maxCooldowns; ++epoch) {
            _fundUnleveredAtEpoch(alice, epoch, 1e18);
        }
        assertGt(secondStart, firstStart);
        uint256 mergedDuration = firstStart + 100 days - secondStart;

        vm.recordLogs();
        _fundUnleveredAtEpoch(alice, maxCooldowns, 1e18);
        assertEq(
            _singleLogData(ILCCLeveragedFundHelper.CooldownsMerged.selector),
            abi.encode(uint256(2e18), secondStart, mergedDuration)
        );

        assertEq(helper.cooldowns(alice, marketId)[0].shares, 2e18);
        assertEq(helper.cooldowns(alice, marketId)[0].start, secondStart);
        assertEq(helper.cooldowns(alice, marketId)[0].duration, mergedDuration);

        usd3l.setCooldownDuration(uint64(200 days));
        vm.warp(secondStart + 200 days - 1);
        assertEq(_maturedShares(alice), 0);
        vm.warp(secondStart + 200 days);
        assertEq(_maturedShares(alice), 2e18);
    }

    function testFundAfterUnwindRefillsBookWithoutMerging() public {
        _deposit(alice, MARGIN);
        for (uint256 epoch; epoch < maxCooldowns; ++epoch) {
            _fundUnleveredAtEpoch(alice, epoch, 1e18);
        }
        vm.warp(uint256(helper.cooldowns(alice, marketId)[0].start) + cooldown);
        vm.prank(alice);
        helper.unwind(_unwindParams(1e18, true, 0));
        assertEq(helper.cooldowns(alice, marketId).length, maxCooldowns - 1);

        uint256 epoch = (block.timestamp - START) / EPOCH + 1;
        vm.recordLogs();
        uint256 start = _fundUnleveredAtEpoch(alice, epoch, 1e18);
        assertEq(_countLogs(address(helper), ILCCLeveragedFundHelper.CooldownsMerged.selector), 0);
        ILCCLeveragedFundHelper.Cooldown[] memory book = helper.cooldowns(alice, marketId);
        assertEq(book.length, maxCooldowns);
        assertEq(book[maxCooldowns - 1].start, start);
        assertEq(book[0].shares, 1e18);
    }

    function testConsumptionSkipsUnmaturedCooldownAndKeepsOrder() public {
        _deposit(alice, MARGIN);
        uint256 first = _fundUnleveredAtEpoch(alice, 0, 30e18);
        usd3l.setCooldownDuration(uint64(100 days));
        uint256 second = _fundUnleveredAtEpoch(alice, 1 days / EPOCH, 30e18);
        usd3l.setCooldownDuration(uint64(cooldown));
        uint256 third = _fundUnleveredAtEpoch(alice, 2 days / EPOCH, 30e18);

        vm.warp(third + cooldown);
        assertLt(block.timestamp, second + 100 days);
        assertEq(_maturedShares(alice), 60e18);

        vm.prank(alice);
        helper.unwind(_unwindParams(40e18, true, 0));

        ILCCLeveragedFundHelper.Cooldown[] memory book = helper.cooldowns(alice, marketId);
        assertEq(book.length, 2);
        assertEq(book[0].shares, 30e18);
        assertEq(book[0].start, second);
        assertEq(book[0].duration, 100 days);
        assertEq(book[1].shares, 20e18);
        assertEq(book[1].start, third);
        assertEq(book[1].duration, cooldown);
        assertGt(third, first);
    }

    function testCooldownsAreIsolatedPerMarket() public {
        uint256 start = _enterUnlevered(alice);
        IMorphoBlue.MarketParams memory other = _createMarket(0.5e18, LIQUIDITY);
        bytes32 otherId = keccak256(abi.encode(other));
        vm.prank(alice);
        morpho.withdrawCollateral(marketParams, 50e18, alice, alice);
        vm.startPrank(alice);
        usd3l.approve(address(morpho), 50e18);
        morpho.supplyCollateral(other, 50e18, alice, "");
        vm.stopPrank();

        vm.warp(start + cooldown);
        assertEq(helper.cooldowns(alice, otherId).length, 0);
        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(50e18, true, 0);
        params.market = other;
        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.InsufficientMaturedShares.selector, 50e18, 0));
        vm.prank(alice);
        helper.unwind(params);
    }

    function testShutdownAndZeroCooldownWaiveTheCooldownGate() public {
        _enterUnlevered(alice);

        usd3l.setShutdown(true);
        assertEq(helper.maxUnwindable(alice, marketId), CALL);
        vm.prank(alice);
        helper.unwind(_unwindParams(40e18, true, 0));
        assertEq(helper.cooldowns(alice, marketId)[0].shares, CALL);

        usd3l.setShutdown(false);
        usd3l.setCooldownDuration(0);
        vm.prank(alice);
        helper.unwind(_unwindParams(60e18, true, 0));
        (,, uint128 collateral) = morpho.position(marketId, alice);
        assertEq(collateral, 0);
    }

    function testLiveCooldownIncreaseDelaysOpenCooldown() public {
        uint256 start = _enterLevered(alice);
        usd3l.setCooldownDuration(uint64(2 * cooldown));

        vm.warp(start + cooldown);
        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.InsufficientMaturedShares.selector, CALL, 0));
        vm.prank(alice);
        helper.unwind(_unwindParams(CALL, true, 0));

        vm.warp(start + 2 * cooldown);
        vm.prank(alice);
        helper.unwind(_unwindParams(CALL, true, 0));
    }

    /* UNWIND */

    function testFullUnwindRepaysAccruedDebtByShares() public {
        uint256 start = _enterLevered(alice);
        morpho.setPendingInterest(marketId, 1e18);
        vm.warp(start + cooldown);
        uint256 flashLoansBefore = morpho.flashLoanCount();

        vm.prank(alice);
        (uint256 repaid, uint256 usdcOut) = helper.unwind(_unwindParams(CALL, true, 0));

        assertGe(repaid, 81e18);
        assertLe(repaid, 81e18 + 1);
        assertEq(usdcOut, CALL - repaid);
        assertEq(usdc.balanceOf(alice), usdcOut);
        assertEq(morpho.flashLoanCount(), flashLoansBefore + 1);
        assertEq(morpho.lastFlashAssets(), repaid);
        (, uint128 borrowShares, uint128 collateral) = morpho.position(marketId, alice);
        assertEq(borrowShares, 0);
        assertEq(collateral, 0);
        _assertUnwindHelperClean();
    }

    function testPartialUnwindRepaysByAssetsAndKeepsHealthyPosition() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);

        vm.prank(alice);
        (uint256 repaid, uint256 usdcOut) = helper.unwind(_unwindParams(50e18, false, 40e18));

        assertEq(repaid, 40e18);
        assertEq(usdcOut, 10e18);
        assertEq(morpho.borrowAssetsOf(marketId, alice), 40e18);
        (,, uint128 collateral) = morpho.position(marketId, alice);
        assertEq(collateral, 50e18);
        assertEq(helper.cooldowns(alice, marketId)[0].shares, 50e18);
        _assertUnwindHelperClean();
    }

    function testPartialUnwindFailingHealthReverts() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);

        vm.expectRevert("insufficient collateral");
        vm.prank(alice);
        helper.unwind(_unwindParams(10e18, false, 0));
    }

    function testFullUnwindSucceedsWithRevertingOracle() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);
        vm.mockCallRevert(address(marketOracle), abi.encodeCall(IOracle.price, ()), "ORACLE_DOWN");

        vm.prank(alice);
        helper.unwind(_unwindParams(CALL, true, 0));
        (,, uint128 collateral) = morpho.position(marketId, alice);
        assertEq(collateral, 0);
    }

    /* USD3 OUTPUT */

    function testFullUnwindWithUsd3OutConvertsOnlyTheRepayment() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);
        uint256 usd3Before = usd3.balanceOf(alice);

        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(CALL, true, 0);
        params.usd3Out = true;
        vm.prank(alice);
        (uint256 repaid, uint256 amountOut) = helper.unwind(params);

        assertEq(repaid, 80e18);
        assertEq(amountOut, CALL - usd3.previewWithdraw(80e18));
        assertEq(usd3.balanceOf(alice) - usd3Before, amountOut);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(morpho.borrowAssetsOf(marketId, alice), 0);
        _assertUnwindHelperClean();
    }

    function testPartialUnwindWithUsd3Out() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);

        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(50e18, false, 40e18);
        params.usd3Out = true;
        vm.prank(alice);
        (uint256 repaid, uint256 amountOut) = helper.unwind(params);

        assertEq(repaid, 40e18);
        assertEq(amountOut, 10e18);
        assertEq(usd3.balanceOf(alice), 10e18);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(morpho.borrowAssetsOf(marketId, alice), 40e18);
        _assertUnwindHelperClean();
    }

    function testZeroRepayUsd3OutUnwindIgnoresUsd3WithdrawLimit() public {
        uint256 start = _enterUnlevered(alice);
        vm.warp(start + cooldown);
        unwindUsd3.setWithdrawLimit(0);

        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(CALL, true, 0);
        params.usd3Out = true;
        vm.prank(alice);
        (uint256 repaid, uint256 amountOut) = helper.unwind(params);

        assertEq(repaid, 0);
        assertEq(amountOut, CALL);
        assertEq(usd3.balanceOf(alice), CALL);
        _assertUnwindHelperClean();
    }

    function testRepayingUsd3OutUnwindRevertsWhenUsd3WithdrawLimitIsZero() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);
        unwindUsd3.setWithdrawLimit(0);

        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(CALL, true, 0);
        params.usd3Out = true;
        vm.expectRevert("ERC4626: withdraw more than max");
        vm.prank(alice);
        helper.unwind(params);
        assertEq(helper.cooldowns(alice, marketId)[0].shares, CALL);
    }

    function testUsd3OutMinimumIsEnforcedOnUsd3() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);

        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(CALL, true, 0);
        params.usd3Out = true;
        params.minOut = 20e18 + 1;
        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.UnwindOutputBelowMinimum.selector, 20e18, 20e18 + 1)
        );
        vm.prank(alice);
        helper.unwind(params);
    }

    function testUsd3OutLeavesDonatedUsd3Untouched() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);
        deal(address(usd3), address(helper), 7);

        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(CALL, true, 0);
        params.usd3Out = true;
        vm.prank(alice);
        (, uint256 amountOut) = helper.unwind(params);

        assertEq(amountOut, 20e18);
        assertEq(usd3.balanceOf(address(helper)), 7);
    }

    function testUsd3OutRepaymentNeedingMoreUsd3ThanRedeemedReverts() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);

        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(10e18, true, 0);
        params.usd3Out = true;
        vm.expectRevert(
            abi.encodeWithSelector(
                ILCCLeveragedFundHelper.RedemptionBelowRepayment.selector, address(usd3), 10e18, 80e18
            )
        );
        vm.prank(alice);
        helper.unwind(params);
    }

    function testUsd3OutUnwindRejectsUsdcBalanceChange() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);
        unwindUsd3.setWithdrawOverDelivery(1);

        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(CALL, true, 0);
        params.usd3Out = true;
        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.UnexpectedBalance.selector, address(usdc), 1, 0));
        vm.prank(alice);
        helper.unwind(params);
    }

    function testUsd3OutUnwindRejectsUsdcBalanceDrop() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);
        deal(address(usdc), address(helper), 5);
        morpho.setFlashRepayExtra(1);

        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(CALL, true, 0);
        params.usd3Out = true;
        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.UnexpectedBalance.selector, address(usdc), 4, 5));
        vm.prank(alice);
        helper.unwind(params);
    }

    function testUnwoundEventCarriesUsdcOutput() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);

        vm.expectEmit(address(helper));
        emit ILCCLeveragedFundHelper.Unwound(alice, marketId, address(usdc), 80e18, CALL, 20e18);
        vm.prank(alice);
        helper.unwind(_unwindParams(CALL, true, 0));
    }

    function testUnwoundEventCarriesUsd3Output() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);
        uint256 amountOut = CALL - usd3.previewWithdraw(80e18);

        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(CALL, true, 0);
        params.usd3Out = true;
        vm.expectEmit(address(helper));
        emit ILCCLeveragedFundHelper.Unwound(alice, marketId, address(usd3), 80e18, CALL, amountOut);
        vm.prank(alice);
        helper.unwind(params);
    }

    function testUsd3OutUnwindWithAuthorizationSignature() public {
        uint256 start = _enterUnlevered(signer);
        vm.warp(start + cooldown);
        IMorphoBlue.Authorization memory authorization =
            _morphoAuthorization(address(morpho), signer, address(helper), type(uint256).max);
        IMorphoBlue.Signature memory signature = _signMorphoAuthorization(address(morpho), signerKey, authorization);

        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(CALL, true, 0);
        params.usd3Out = true;
        vm.prank(signer);
        (uint256 repaid, uint256 amountOut) = helper.unwindWithAuthorization(params, authorization, signature);

        assertEq(repaid, 0);
        assertEq(amountOut, CALL);
        assertEq(usd3.balanceOf(signer), CALL);
        assertTrue(morpho.isAuthorized(signer, address(helper)));
        _assertUnwindHelperClean();
    }

    function testUsd3OutRepaymentCannotBurnDonatedUsd3() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);
        deal(address(usd3), address(helper), CALL);

        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(10e18, true, 0);
        params.usd3Out = true;
        vm.expectRevert(
            abi.encodeWithSelector(
                ILCCLeveragedFundHelper.RedemptionBelowRepayment.selector, address(usd3), 10e18, 80e18
            )
        );
        vm.prank(alice);
        helper.unwind(params);
    }

    function testUsdcRedemptionBelowRepaymentReverts() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILCCLeveragedFundHelper.RedemptionBelowRepayment.selector, address(usdc), 10e18, 80e18
            )
        );
        vm.prank(alice);
        helper.unwind(_unwindParams(10e18, true, 0));
    }

    function testRedemptionBelowRepaymentReportsTheTokenOfItsPath() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);
        uint256 snapshot = vm.snapshotState();

        _assertRevertToken(
            _unwindRevert(_unwindParams(10e18, true, 0)),
            ILCCLeveragedFundHelper.RedemptionBelowRepayment.selector,
            address(usdc)
        );
        vm.revertToState(snapshot);

        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(10e18, true, 0);
        params.usd3Out = true;
        _assertRevertToken(
            _unwindRevert(params), ILCCLeveragedFundHelper.RedemptionBelowRepayment.selector, address(usd3)
        );
    }

    function testUnexpectedBalanceReportsTheTokenOfItsPath() public {
        uint256 snapshot = vm.snapshotState();
        _depositAndOpenCall(alice);
        _supplyExtraCollateral(alice, CALL);
        usdc.mint(alice, CALL);
        vm.mockCall(address(morpho), abi.encodeWithSelector(IMorphoBlue.supplyCollateral.selector), "");
        ILCCLeveragedFundHelper.FundParams memory fundParams = _fundParams(0);
        fundParams.maxContribution = CALL;
        vm.prank(alice);
        try helper.fund(fundParams) {
            revert("fund succeeded");
        } catch (bytes memory reason) {
            _assertRevertToken(reason, ILCCLeveragedFundHelper.UnexpectedBalance.selector, address(usd3l));
        }
        vm.clearMockedCalls();
        vm.revertToState(snapshot);

        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);
        unwindUsd3.setWithdrawOverDelivery(1);
        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(CALL, true, 0);
        params.usd3Out = true;
        _assertRevertToken(_unwindRevert(params), ILCCLeveragedFundHelper.UnexpectedBalance.selector, address(usdc));
    }

    function _unwindRevert(ILCCLeveragedFundHelper.UnwindParams memory params) private returns (bytes memory reason) {
        vm.prank(alice);
        try helper.unwind(params) {
            revert("unwind succeeded");
        } catch (bytes memory data) {
            reason = data;
        }
    }

    function _assertRevertToken(bytes memory reason, bytes4 selector, address token) private pure {
        assertGe(reason.length, 36);
        assertEq(bytes4(reason), selector);
        address reported;
        assembly ("memory-safe") {
            reported := mload(add(reason, 36))
        }
        assertEq(reported, token);
    }

    function testDustPartialRepaymentThatBuysNoShareReverts() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);
        morpho.setPendingInterest(marketId, 1e26);

        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.RepayRoundsToZero.selector, 1));
        vm.prank(alice);
        helper.unwind(_unwindParams(10e18, false, 1));
    }

    function testUnwindBoundsRevert() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);

        ILCCLeveragedFundHelper.UnwindParams memory params = _unwindParams(CALL, true, 0);
        params.maxRepayAssets = 80e18 - 1;
        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.RepayExceedsMax.selector, 80e18, 80e18 - 1));
        vm.prank(alice);
        helper.unwind(params);

        params = _unwindParams(CALL, true, 0);
        params.minOut = 20e18 + 1;
        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.UnwindOutputBelowMinimum.selector, 20e18, 20e18 + 1)
        );
        vm.prank(alice);
        helper.unwind(params);

        params = _unwindParams(CALL, true, 0);
        params.deadline = block.timestamp - 1;
        vm.expectRevert(ILCCLeveragedFundHelper.DeadlineExpired.selector);
        vm.prank(alice);
        helper.unwind(params);

        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.RepayExceedsDebt.selector, 80e18 + 1, 80e18));
        vm.prank(alice);
        helper.unwind(_unwindParams(CALL, false, 80e18 + 1));

        vm.expectRevert(ILCCLeveragedFundHelper.InvalidRequest.selector);
        vm.prank(alice);
        helper.unwind(_unwindParams(0, true, 0));
    }

    function testRedemptionLimitsRevertAtomicallyWithCooldownsRestored() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);

        unwindUsd3.setWithdrawLimit(CALL - 1);
        _expectFailedUnwindRestoresState(bytes("ERC4626: redeem more than max"));

        unwindUsd3.setWithdrawLimit(0);
        _expectFailedUnwindRestoresState(bytes("ERC4626: redeem more than max"));

        unwindUsd3.setWithdrawLimit(type(uint256).max);
        usd3l.setCooldownBypass(address(helper), false);
        _expectFailedUnwindRestoresState(bytes("ERC4626: redeem more than max"));
    }

    function testUnwindPayloadContentAndAmountAreBound() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);

        morpho.setTamperCallbackData(true);
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidCallback.selector);
        vm.prank(alice);
        helper.unwind(_unwindParams(CALL, true, 0));

        morpho.setTamperCallbackData(false);
        morpho.setCallbackAssetsDelta(1);
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidCallback.selector);
        vm.prank(alice);
        helper.unwind(_unwindParams(CALL, true, 0));
    }

    function testDonatedUsd3lAndUsd3StayUntouched() public {
        uint256 start = _enterLevered(alice);
        vm.warp(start + cooldown);
        deal(address(usd3l), address(helper), 7);
        deal(address(usd3), address(helper), 7);

        vm.prank(alice);
        (, uint256 usdcOut) = helper.unwind(_unwindParams(CALL, true, 0));

        assertEq(usdcOut, 20e18);
        assertEq(usd3l.balanceOf(address(helper)), 7);
        assertEq(usd3.balanceOf(address(helper)), 7);
        assertEq(usdc.balanceOf(address(helper)), 0);
    }

    function testRetainedUsd3lRevertsOnDirectAndFlashFunding() public {
        _depositAndOpenCall(alice);
        _supplyExtraCollateral(alice, CALL);
        usdc.mint(alice, CALL);
        vm.mockCall(address(morpho), abi.encodeWithSelector(IMorphoBlue.supplyCollateral.selector), "");

        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(0);
        params.maxContribution = CALL;
        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.UnexpectedBalance.selector, address(usd3l), CALL, 0)
        );
        vm.prank(alice);
        helper.fund(params);

        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.UnexpectedBalance.selector, address(usd3l), CALL, 0)
        );
        vm.prank(alice);
        helper.fund(_fundParams(80e18));
    }

    function testRetainedUsd3lRevertsOnUnwind() public {
        uint256 start = _enterUnlevered(alice);
        vm.warp(start + cooldown);
        deal(address(usd3l), address(helper), 7);
        vm.mockCall(
            address(usd3l),
            abi.encodeWithSelector(bytes4(keccak256("redeem(uint256,address,address,uint256)"))),
            abi.encode(uint256(0))
        );

        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.UnexpectedBalance.selector, address(usd3l), CALL + 7, 7)
        );
        vm.prank(alice);
        helper.unwind(_unwindParams(CALL, true, 0));
    }

    function testUnwindRequiresAuthorizationAndSignatureVariantAppliesIt() public {
        uint256 start = _enterUnlevered(signer);
        vm.warp(start + cooldown);
        assertFalse(morpho.isAuthorized(signer, address(helper)));

        vm.expectRevert(ILCCLeveragedFundHelper.NotAuthorized.selector);
        vm.prank(signer);
        helper.unwind(_unwindParams(CALL, true, 0));

        IMorphoBlue.Authorization memory authorization =
            _morphoAuthorization(address(morpho), signer, address(helper), type(uint256).max);
        IMorphoBlue.Signature memory signature = _signMorphoAuthorization(address(morpho), signerKey, authorization);
        vm.prank(signer);
        (, uint256 usdcOut) = helper.unwindWithAuthorization(_unwindParams(CALL, true, 0), authorization, signature);

        assertEq(usdcOut, CALL);
        assertTrue(morpho.isAuthorized(signer, address(helper)));
    }

    function testZeroDebtUnwindTakesNoFlashLoan() public {
        uint256 start = _enterUnlevered(alice);
        vm.warp(start + cooldown);
        uint256 flashLoansBefore = morpho.flashLoanCount();

        vm.prank(alice);
        (uint256 repaid, uint256 usdcOut) = helper.unwind(_unwindParams(CALL, true, 0));

        assertEq(repaid, 0);
        assertEq(usdcOut, CALL);
        assertEq(morpho.flashLoanCount(), flashLoansBefore);
        _assertUnwindHelperClean();
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
        _assertHelperClean(address(vault));
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
        _assertHelperClean(address(vault));
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
        _assertHelperClean(address(vault));
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
        _assertHelperClean(address(vault));
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
        _assertHelperClean(address(vault));
    }

    function testAuthorizationForWrongPartiesOrRevocationIsRejected() public {
        _prepareSigner();
        Signed memory s = _sign(20e18, CALL);

        s.authorization.authorizer = alice;
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidRequest.selector);
        _fundSigned(_fundParams(80e18), s);

        s.authorization = _morphoAuthorization(address(morpho), signer, stranger, type(uint256).max);
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidRequest.selector);
        _fundSigned(_fundParams(80e18), s);

        s.authorization = _morphoAuthorization(address(morpho), signer, address(helper), type(uint256).max);
        s.authorization.isAuthorized = false;
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidRequest.selector);
        _fundSigned(_fundParams(80e18), s);
    }

    function testAuthorizationSignedByAnotherKeyFails() public {
        _prepareSigner();
        Signed memory s = _sign(20e18, CALL);
        s.signature = _signMorphoAuthorization(address(morpho), otherKey, s.authorization);

        vm.expectRevert(ILCCLeveragedFundHelper.NotAuthorized.selector);
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

        vm.expectRevert(ILCCLeveragedFundHelper.InvalidConfiguration.selector);
        vm.prank(alice);
        helper.fund(_fundParams(0));
    }

    function testUsd3lMarginVaultRejected() public {
        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        params.marginAsset = address(usd3l);
        LCCVault usd3lMarginVault = _newVault(params);

        ILCCLeveragedFundHelper.FundParams memory fundParams = _fundParams(0);
        fundParams.vault = address(usd3lMarginVault);
        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.UnsupportedMarginAsset.selector, address(usd3l)));
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
        params.minCollateral = obligation;
        params.maxCollateral = obligation;

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
        _assertHelperClean(address(vault));
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

    function testZeroObligationRejected() public {
        _depositAndOpenCall(bob);
        vm.expectRevert(ILCCLeveragedFundHelper.NothingToFund.selector);
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
        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.BorrowAndMarginExceedTotal.selector, CALL + 1, 0, CALL)
        );
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
        vm.mockCalls(address(marketOracle), abi.encodeCall(IOracle.price, ()), prices);

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

        vm.expectRevert(ILCCLeveragedFundHelper.VaultAmountMismatch.selector);
        vm.prank(alice);
        helper.fund(_fundParams(80e18));
    }

    function testFundCallLeavingAllowanceRejected() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        vm.mockCall(address(vault), abi.encodeWithSignature("fundCall(address)", alice), abi.encode(CALL));

        vm.expectRevert(ILCCLeveragedFundHelper.VaultAmountMismatch.selector);
        vm.prank(alice);
        helper.fund(_fundParams(80e18));
    }

    function testSkippedCallbackRejected() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        morpho.setSkipCallback(true);

        vm.expectRevert(ILCCLeveragedFundHelper.InvalidCallback.selector);
        vm.prank(alice);
        helper.fund(_fundParams(80e18));
    }

    function testCollateralBelowMinimumRejected() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(80e18);
        params.minCollateral = CALL + 1;
        params.maxCollateral = CALL + 1;

        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.CollateralBelowMinimum.selector, CALL, CALL + 1));
        vm.prank(alice);
        helper.fund(params);
    }

    function testCollateralAtMinimumAccepted() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);

        vm.prank(alice);
        (,, uint256 collateral) = helper.fund(_fundParams(80e18));

        assertEq(collateral, CALL);
        (,, uint128 positionCollateral) = morpho.position(marketId, alice);
        assertEq(positionCollateral, CALL);
        _assertHelperClean(address(vault));
    }

    function testDeliveryAboveMaximumLeavesSurplusWithCaller() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        usd3l.setExtraMint(1);

        vm.prank(alice);
        (,, uint256 collateral) = helper.fund(_fundParams(80e18));

        assertEq(collateral, CALL);
        (,, uint128 positionCollateral) = morpho.position(marketId, alice);
        assertEq(positionCollateral, CALL);
        assertEq(usd3l.balanceOf(alice), 1);
        _assertHelperClean(address(vault));
    }

    function testDeliveryWithinMaximumIsSuppliedInFull() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        usd3l.setExtraMint(1);
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(80e18);
        params.maxCollateral = CALL + 5;

        vm.prank(alice);
        (,, uint256 collateral) = helper.fund(params);

        assertEq(collateral, CALL + 1);
        (,, uint128 positionCollateral) = morpho.position(marketId, alice);
        assertEq(positionCollateral, CALL + 1);
        assertEq(usd3l.balanceOf(alice), 0);
        _assertHelperClean(address(vault));
    }

    function testFundWithShortUsdcAllowanceRevertsBeforeFunding() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        vm.prank(alice);
        usdc.approve(address(helper), 20e18 - 1);

        _expectNoFunding();
        _expectInsufficientAllowance(address(usdc), 20e18 - 1, 20e18, "");
        vm.prank(alice);
        helper.fund(_fundParams(80e18));
        assertFalse(vault.fundedEpoch(0, alice));
        assertEq(morpho.flashLoanCount(), 0);
        assertEq(usdc.balanceOf(alice), 20e18);
    }

    function testFundWithShortUsd3lAllowanceRevertsBeforeFunding() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        vm.prank(alice);
        usd3l.approve(address(helper), CALL - 1);

        _expectNoFunding();
        _expectInsufficientAllowance(address(usd3l), CALL - 1, CALL, "");
        vm.prank(alice);
        helper.fund(_fundParams(80e18));
        assertFalse(vault.fundedEpoch(0, alice));
        assertEq(morpho.flashLoanCount(), 0);
        assertEq(usdc.balanceOf(alice), 20e18);
    }

    function testZeroMinimumCollateralRejected() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(80e18);
        params.minCollateral = 0;

        _expectNoFunding();
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidRequest.selector);
        vm.prank(alice);
        helper.fund(params);
    }

    function testMaximumBelowMinimumCollateralRejected() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(80e18);
        params.maxCollateral = CALL - 1;

        _expectNoFunding();
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidRequest.selector);
        vm.prank(alice);
        helper.fund(params);
    }

    function testUsd3lPermitBelowMaximumCollateralRevertsBeforeFunding() public {
        _prepareSigner();
        Signed memory s = _sign(20e18, CALL);
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(80e18);
        params.maxCollateral = CALL + 5;

        _expectNoFunding();
        _expectInsufficientAllowance(address(usd3l), CALL, CALL + 5, "");
        _fundSigned(params, s);
        assertFalse(vault.fundedEpoch(0, signer));
        assertEq(morpho.flashLoanCount(), 0);
    }

    function testLeveredEntryRevertsWhenSingletonHoldsLessThanTwiceTheBorrow() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        deal(address(usdc), address(morpho), 120e18);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(morpho), 40e18, 80e18)
        );
        vm.prank(alice);
        helper.fund(_fundParams(80e18));
    }

    function testUnleveredEntryUsesNoFlashLoanOracleOrAuthorization() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, CALL);
        vm.prank(alice);
        morpho.setAuthorization(address(helper), false);
        vm.mockCallRevert(address(marketOracle), abi.encodeCall(IOracle.price, ()), "ORACLE_DOWN");

        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(0);
        params.maxEntryLtv = 0;
        vm.prank(alice);
        (,, uint256 collateral) = helper.fund(params);

        assertEq(collateral, CALL);
        assertEq(morpho.flashLoanCount(), 0);
        (, uint128 borrowShares, uint128 positionCollateral) = morpho.position(marketId, alice);
        assertEq(borrowShares, 0);
        assertEq(positionCollateral, CALL);
        _assertHelperClean(address(vault));
    }

    function testTwoEntriesInOneTransactionKeepSeparateResults() public {
        LCCHelperMulticallFunder funder = new LCCHelperMulticallFunder();
        _setDepositorCap(address(funder), type(uint128).max);
        factory.setOneVaultPolicyEnabled(false);
        LCCVault secondVault = _newVault(_params(CAP, CAP));
        margin.mint(address(funder), 2 * MARGIN);

        address[] memory targets = new address[](7);
        bytes[] memory calls = new bytes[](7);
        (targets[0], calls[0]) = (address(margin), abi.encodeCall(IERC20.approve, (address(vault), MARGIN)));
        (targets[1], calls[1]) = (address(margin), abi.encodeCall(IERC20.approve, (address(secondVault), MARGIN)));
        (targets[2], calls[2]) =
        (
            address(vault),
            abi.encodeCall(LCCVault.deposit, (MARGIN, address(funder), 1, type(uint256).max, true, type(uint256).max))
        );
        (targets[3], calls[3]) =
        (
            address(secondVault),
            abi.encodeCall(LCCVault.deposit, (MARGIN, address(funder), 1, type(uint256).max, true, type(uint256).max))
        );
        (targets[4], calls[4]) = (address(usdc), abi.encodeCall(IERC20.approve, (address(helper), type(uint256).max)));
        (targets[5], calls[5]) = (address(usd3l), abi.encodeCall(IERC20.approve, (address(helper), type(uint256).max)));
        (targets[6], calls[6]) =
        (address(morpho), abi.encodeCall(IMorphoBlueTest.setAuthorization, (address(helper), true)));
        funder.execute(targets, calls);

        _openCall(CALL);
        secondVault.openEpochCall(0, CALL / 2);
        vm.warp(START + NORMAL + PRE_CALL);
        usdc.mint(address(funder), 20e18 + CALL / 2);

        ILCCLeveragedFundHelper.FundParams memory levered = _fundParams(80e18);
        ILCCLeveragedFundHelper.FundParams memory unlevered = _fundParams(0);
        unlevered.vault = address(secondVault);
        unlevered.maxContribution = CALL / 2;
        unlevered.minCollateral = CALL / 2;
        unlevered.maxCollateral = CALL / 2;
        unlevered.maxObligation = CALL / 2;

        targets = new address[](2);
        calls = new bytes[](2);
        (targets[0], calls[0]) = (address(helper), abi.encodeCall(ILCCLeveragedFundHelper.fund, (levered)));
        (targets[1], calls[1]) = (address(helper), abi.encodeCall(ILCCLeveragedFundHelper.fund, (unlevered)));
        bytes[] memory results = funder.execute(targets, calls);

        (,, uint256 leveredCollateral) = abi.decode(results[0], (uint256, uint256, uint256));
        (,, uint256 unleveredCollateral) = abi.decode(results[1], (uint256, uint256, uint256));
        assertEq(leveredCollateral, CALL);
        assertEq(unleveredCollateral, CALL / 2);
        assertTrue(vault.fundedEpoch(0, address(funder)));
        assertTrue(secondVault.fundedEpoch(0, address(funder)));
        (,, uint128 positionCollateral) = morpho.position(marketId, address(funder));
        assertEq(positionCollateral, CALL + CALL / 2);
        assertEq(morpho.borrowAssetsOf(marketId, address(funder)), 80e18);
        assertEq(morpho.flashLoanCount(), 1);
        _assertHelperClean(address(vault));
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

    /* CALLBACK */

    function testCallbackFromNonMorphoRejected() public {
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidCallback.selector);
        vm.prank(stranger);
        helper.onMorphoFlashLoan(1, hex"01");
    }

    function testCallbackWithoutOperationInFlightRejected() public {
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidCallback.selector);
        vm.prank(address(morpho));
        helper.onMorphoFlashLoan(1, hex"01");
    }

    function testRepeatedCallbackRejected() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        morpho.setCallbackCount(2);
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidCallback.selector);
        vm.prank(alice);
        helper.fund(_fundParams(80e18));
    }

    function testCallbackWithMismatchedOperationRejected() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        morpho.setTamperCallbackData(true);
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidCallback.selector);
        vm.prank(alice);
        helper.fund(_fundParams(80e18));
    }

    function testCallbackWithWrongAmountRejected() public {
        _depositAndOpenCall(alice);
        usdc.mint(alice, 20e18);
        morpho.setCallbackAssetsDelta(1);
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidCallback.selector);
        vm.prank(alice);
        helper.fund(_fundParams(80e18));
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

    /* AUCTION TAKES */

    function testTakeFillsRemainderAndForwardsWholeAward() public {
        _openTakeAuction(false, true);
        uint256 award = _dryRunAward(SHORTFALL);
        assertGt(award, 0);
        uint256 usdcBefore = usdc.balanceOf(carol);
        uint256 marginBefore = margin.balanceOf(carol);

        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(80e18);
        vm.expectEmit(true, true, true, true, address(helper));
        emit ILCCLeveragedFundHelper.AuctionTaken(carol, address(auctionVault), marketId, SHORTFALL, SHORTFALL, 0, 0);
        vm.prank(carol);
        (uint256 filled, uint256 collateral) = helper.takeAuction(params);

        assertEq(filled, SHORTFALL);
        assertEq(collateral, SHORTFALL);
        assertEq(usdcBefore - usdc.balanceOf(carol), SHORTFALL);
        assertEq(margin.balanceOf(carol) - marginBefore, award);
        assertEq(usd3l.balanceOf(carol), 0);
        (, uint128 borrowShares, uint128 positionCollateral) = morpho.position(marketId, carol);
        assertEq(borrowShares, 0);
        assertEq(positionCollateral, SHORTFALL);
        ILCCLeveragedFundHelper.Cooldown[] memory book = helper.cooldowns(carol, marketId);
        assertEq(book.length, 1);
        assertEq(book[0].shares, collateral);
        assertEq(book[0].start, block.timestamp);
        assertEq(morpho.flashLoanCount(), 0);
        assertEq(auctionVault.getAuctionState(0).filledAmount, SHORTFALL);
        _assertHelperClean(address(auctionVault));
    }

    function testTakeWithBorrowBorrowsScaledAmountWithinLtv() public {
        _openTakeAuction(false, true);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
        params.borrowAssets = 40e18;
        uint256 usdcBefore = usdc.balanceOf(carol);

        vm.prank(carol);
        (uint256 filled, uint256 collateral) = helper.takeAuction(params);

        assertEq(filled, SHORTFALL);
        assertEq(collateral, SHORTFALL);
        assertEq(morpho.borrowAssetsOf(marketId, carol), 40e18);
        assertEq(usdcBefore - usdc.balanceOf(carol), 10e18);
        assertEq(morpho.flashLoanCount(), 1);
        assertEq(morpho.lastFlashAssets(), 40e18);
        assertEq(helper.cooldowns(carol, marketId)[0].shares, SHORTFALL);
        _assertHelperClean(address(auctionVault));
    }

    function testTakeEntryLtvCoversWholePosition() public {
        _openTakeAuction(false, true);
        _supplyExtraCollateral(carol, 50e18);
        vm.startPrank(carol);
        morpho.borrow(marketParams, 20e18, 0, carol, carol);
        vm.stopPrank();

        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
        params.borrowAssets = 40e18;
        params.maxEntryLtv = 0.6e18 - 1;
        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.EntryLtvExceeded.selector, 0.6e18, 0.6e18 - 1));
        vm.prank(carol);
        helper.takeAuction(params);

        params.maxEntryLtv = 0.6e18;
        vm.prank(carol);
        helper.takeAuction(params);
        assertEq(morpho.borrowAssetsOf(marketId, carol), 60e18);
    }

    function testTakeWithBorrowRequiresAuthorizationBeforeAnyTokenMovement() public {
        _openTakeAuction(false, true);
        vm.prank(carol);
        morpho.setAuthorization(address(helper), false);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
        params.borrowAssets = 40e18;

        _expectNoTake();
        vm.expectCall(address(usdc), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
        vm.expectRevert(ILCCLeveragedFundHelper.NotAuthorized.selector);
        vm.prank(carol);
        helper.takeAuction(params);
    }

    function testUnleveredPartialTakeContributesExactFillWithoutAuthorizationOrOracle() public {
        _openTakeAuction(false, true);
        vm.prank(carol);
        morpho.setAuthorization(address(helper), false);
        vm.mockCallRevert(address(marketOracle), abi.encodeCall(IOracle.price, ()), "ORACLE_DOWN");
        uint256 usdcBefore = usdc.balanceOf(carol);

        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(100e18 + 7);
        params.maxEntryLtv = 0;
        vm.prank(carol);
        (uint256 filled,) = helper.takeAuction(params);

        assertEq(filled, SHORTFALL);
        assertEq(usdcBefore - usdc.balanceOf(carol), SHORTFALL);
        assertEq(morpho.flashLoanCount(), 0);
        assertEq(morpho.borrowAssetsOf(marketId, carol), 0);
        _assertHelperClean(address(auctionVault));
    }

    function testNominalDustBorrowStillBorrowsAndNeedsAuthorization() public {
        _openTakeAuction(false, true);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(100e18);
        params.borrowAssets = 1;
        vm.prank(carol);
        morpho.setAuthorization(address(helper), false);
        vm.expectRevert(ILCCLeveragedFundHelper.NotAuthorized.selector);
        vm.prank(carol);
        helper.takeAuction(params);

        vm.prank(carol);
        morpho.setAuthorization(address(helper), true);
        vm.prank(carol);
        helper.takeAuction(params);
        assertEq(morpho.borrowAssetsOf(marketId, carol), 1);
        assertEq(morpho.lastFlashAssets(), 1);
    }

    function testFullyLeveredPartialTakeNeedsNoUsdcAllowance() public {
        _openTakeAuction(true, true);
        vm.prank(carol);
        usdc.approve(address(helper), 0);
        uint256 maxFill = 70e18;
        uint256 borrowAssets = 50e18 + 1;
        uint256 marginAssets = 20e18 - 1;
        assertEq(
            SHORTFALL - Math.mulDiv(borrowAssets, SHORTFALL, maxFill) - Math.mulDiv(marginAssets, SHORTFALL, maxFill),
            1,
            "independent flooring leaves one wei of dust"
        );
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(maxFill);
        params.borrowAssets = borrowAssets;
        params.marginAssets = marginAssets;
        uint256 usdcBefore = usdc.balanceOf(carol);

        vm.prank(carol);
        (uint256 filled,) = helper.takeAuction(params);

        assertEq(filled, SHORTFALL);
        assertEq(usdc.balanceOf(carol), usdcBefore);
        LCCLeveragedFundHelper.TakeOperation memory op = _lastTakeOperation();
        assertEq(op.marginAssets, Math.mulDiv(marginAssets, SHORTFALL, maxFill));
        assertEq(op.borrowAssets + op.marginAssets, SHORTFALL);
        assertEq(morpho.borrowAssetsOf(marketId, carol), op.borrowAssets);
        _assertHelperClean(address(auctionVault));
    }

    function testMarginOnlyPartialTakePullsNoUsdc() public {
        _openTakeAuctionSized(true, true, 200e18);
        vm.warp(START + NORMAL + PRE_CALL + FUNDING + 3 * AUCTION_STEP);
        _directFill(stranger, 40e18);
        uint256 remaining = 60e18;
        assertEq(_dryRunAward(remaining), remaining);
        vm.prank(carol);
        usdc.approve(address(helper), 0);
        vm.prank(carol);
        morpho.setAuthorization(address(helper), false);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(70e18);
        params.marginAssets = 70e18;
        uint256 usdcBefore = usdc.balanceOf(carol);
        uint256 sharesBefore = waUsdc.balanceOf(carol);

        vm.prank(carol);
        (uint256 filled,) = helper.takeAuction(params);

        assertEq(filled, remaining);
        assertEq(usdc.balanceOf(carol), usdcBefore);
        assertEq(waUsdc.balanceOf(carol), sharesBefore);
        assertEq(morpho.lastFlashAssets(), remaining);
        assertEq(morpho.borrowAssetsOf(marketId, carol), 0);
        _assertHelperClean(address(auctionVault));
    }

    function testScaledMinMarginAwardRoundsDown() public {
        _openTakeAuction(false, true);
        _directFill(stranger, 30e18);
        uint256 award = _dryRunAward(20e18);
        assertGt(award, 0);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(60e18);

        params.minMarginAward = 3 * award + 3;
        vm.expectRevert(LCCErrorsLib.InsufficientMarginAward.selector);
        vm.prank(carol);
        helper.takeAuction(params);

        params.minMarginAward = 3 * award + 2;
        uint256 awardedBefore = auctionVault.getAuctionState(0).marginAwarded;
        vm.expectCall(address(auctionVault), abi.encodeCall(LCCVault.takeAuction, (20e18, award, block.timestamp)));
        vm.prank(carol);
        (uint256 filled,) = helper.takeAuction(params);
        assertEq(filled, 20e18);
        assertEq(auctionVault.getAuctionState(0).marginAwarded - awardedBefore, award);
    }

    function testTakeBelowRemainingFillsMaxFillUnscaled() public {
        _openTakeAuction(false, true);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(20e18);
        params.borrowAssets = 10e18 + 1;
        params.minMarginAward = 1;
        params.minCollateral = 20e18 - 1;
        uint256 award = _dryRunAward(20e18);

        vm.expectCall(address(auctionVault), abi.encodeCall(LCCVault.takeAuction, (20e18, 1, block.timestamp)));
        vm.prank(carol);
        (uint256 filled, uint256 collateral) = helper.takeAuction(params);

        assertEq(filled, 20e18);
        assertEq(collateral, 20e18);
        assertEq(morpho.borrowAssetsOf(marketId, carol), 10e18 + 1);
        LCCLeveragedFundHelper.TakeOperation memory op = _lastTakeOperation();
        assertEq(op.fill, 20e18);
        assertEq(op.borrowAssets, 10e18 + 1);
        assertEq(op.minMarginAward, 1);
        assertEq(op.minCollateral, 20e18 - 1);
        assertEq(auctionVault.getAuctionState(0).filledAmount, 20e18);
        assertEq(auctionVault.getAuctionState(0).marginAwarded, award);
    }

    function testTakeAboveRemainingScalesEveryQuotedAmount() public {
        _openTakeAuction(true, true);
        uint256 maxFill = 80e18;
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(maxFill);
        params.borrowAssets = 33e18 + 1;
        params.marginAssets = 16e18 + 1;
        params.minMarginAward = 1e18 + 1;
        params.minCollateral = 40e18 + 1;
        uint256 contribution = Math.mulDiv(maxFill - (33e18 + 1) - (16e18 + 1), SHORTFALL, maxFill);
        uint256 marginPart = Math.mulDiv(16e18 + 1, SHORTFALL, maxFill);
        uint256 borrow = SHORTFALL - contribution - marginPart;
        uint256 minAward = Math.mulDiv(1e18 + 1, SHORTFALL, maxFill);
        assertEq(contribution, 19.375e18 - 2);
        assertEq(marginPart, 10e18);
        assertEq(borrow, 20.625e18 + 2);
        assertEq(minAward, 0.625e18);
        uint256 usdcBefore = usdc.balanceOf(carol);

        vm.expectCall(
            address(auctionVault), abi.encodeCall(LCCVault.takeAuction, (SHORTFALL, minAward, block.timestamp))
        );
        vm.prank(carol);
        helper.takeAuction(params);

        LCCLeveragedFundHelper.TakeOperation memory op = _lastTakeOperation();
        assertEq(op.user, carol);
        assertEq(op.vault, address(auctionVault));
        assertEq(op.marginAsset, address(waUsdc));
        assertEq(op.fill, SHORTFALL);
        assertEq(op.borrowAssets, borrow);
        assertEq(op.marginAssets, marginPart);
        assertEq(op.minMarginAward, minAward);
        assertEq(op.minCollateral, 25e18);
        assertEq(morpho.lastFlashAssets(), borrow + marginPart);
        assertEq(morpho.borrowAssetsOf(marketId, carol), borrow);
        assertEq(usdcBefore - usdc.balanceOf(carol), contribution);
        _assertHelperClean(address(auctionVault));
    }

    function testFrontRunPartialFillShrinksFillAndContribution() public {
        _openTakeAuction(false, true);
        _directFill(stranger, 30e18);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
        params.borrowAssets = 40e18;
        params.minFill = 20e18;
        uint256 usdcBefore = usdc.balanceOf(carol);

        vm.prank(carol);
        (uint256 filled, uint256 collateral) = helper.takeAuction(params);

        assertEq(filled, 20e18);
        assertEq(collateral, 20e18);
        assertEq(morpho.borrowAssetsOf(marketId, carol), 16e18);
        assertEq(usdcBefore - usdc.balanceOf(carol), 4e18);
        _assertHelperClean(address(auctionVault));
    }

    function testFillBelowMinimumRevertsBeforeAnyTokenMovement() public {
        _openTakeAuction(false, true);
        _directFill(stranger, 30e18);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
        params.minFill = 20e18 + 1;

        _expectNoTake();
        vm.expectCall(address(usdc), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.FillBelowMinimum.selector, 20e18, 20e18 + 1));
        vm.prank(carol);
        helper.takeAuction(params);
    }

    function testMalformedFillBoundsRejected() public {
        _openTakeAuction(false, true);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
        params.minFill = SHORTFALL + 1;
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidRequest.selector);
        vm.prank(carol);
        helper.takeAuction(params);

        params.minFill = 0;
        params.maxFill = 0;
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidRequest.selector);
        vm.prank(carol);
        helper.takeAuction(params);
    }

    function testUnboundedMaxFillDoesNotOverflow() public {
        _openTakeAuction(false, true);
        uint256 maxFill = type(uint256).max;
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(maxFill);
        params.borrowAssets = maxFill / 2;
        params.minCollateral = maxFill;
        uint256 borrow = SHORTFALL - Math.mulDiv(maxFill - maxFill / 2, SHORTFALL, maxFill);

        vm.prank(carol);
        (uint256 filled, uint256 collateral) = helper.takeAuction(params);

        assertEq(filled, SHORTFALL);
        assertEq(collateral, SHORTFALL);
        assertEq(morpho.borrowAssetsOf(marketId, carol), borrow);
        assertEq(_lastTakeOperation().minCollateral, SHORTFALL);
    }

    function testOverflowingTakeBorrowAndMarginRejectedWithTypedError() public {
        _openTakeAuction(true, true);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
        params.borrowAssets = SHORTFALL;
        params.marginAssets = type(uint256).max;
        vm.expectRevert(
            abi.encodeWithSelector(
                ILCCLeveragedFundHelper.BorrowAndMarginExceedTotal.selector, SHORTFALL, type(uint256).max, SHORTFALL
            )
        );
        vm.prank(carol);
        helper.takeAuction(params);

        params.borrowAssets = SHORTFALL + 1;
        params.marginAssets = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                ILCCLeveragedFundHelper.BorrowAndMarginExceedTotal.selector, SHORTFALL + 1, 0, SHORTFALL
            )
        );
        vm.prank(carol);
        helper.takeAuction(params);
    }

    function testNominalBorrowAndMarginOnHugeMaxFillLeaveDustOnBorrowOrMargin() public {
        _openTakeAuction(true, true);
        uint256 maxFill = 1e40;
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(maxFill);
        params.borrowAssets = 1;
        params.marginAssets = 1;
        uint256 snapshot = vm.snapshotState();

        vm.prank(carol);
        (uint256 filled,) = helper.takeAuction(params);
        assertEq(filled, SHORTFALL);
        LCCLeveragedFundHelper.TakeOperation memory op = _lastTakeOperation();
        assertEq(op.marginAssets, 0);
        assertEq(op.borrowAssets, 1);
        assertEq(morpho.borrowAssetsOf(marketId, carol), 1);
        vm.revertToState(snapshot);

        params.borrowAssets = 0;
        vm.prank(carol);
        helper.takeAuction(params);
        op = _lastTakeOperation();
        assertEq(op.marginAssets, 1);
        assertEq(op.borrowAssets, 0);
        assertEq(morpho.borrowAssetsOf(marketId, carol), 0);
        _assertHelperClean(address(auctionVault));
    }

    function testMarginOnlyTakeWithdrawsFromAwardAndForwardsRest() public {
        _openTakeAuction(true, true);
        vm.prank(carol);
        morpho.setAuthorization(address(helper), false);
        vm.mockCallRevert(address(marketOracle), abi.encodeCall(IOracle.price, ()), "ORACLE_DOWN");
        uint256 award = _dryRunAward(SHORTFALL);
        uint256 marginPart = 10e18;
        assertGt(award, marginPart);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
        params.marginAssets = marginPart;
        params.maxEntryLtv = 0;
        uint256 usdcBefore = usdc.balanceOf(carol);
        uint256 sharesBefore = waUsdc.balanceOf(carol);

        vm.expectEmit(true, true, true, true, address(helper));
        emit ILCCLeveragedFundHelper.AuctionTaken(
            carol, address(auctionVault), marketId, SHORTFALL, SHORTFALL, 0, marginPart
        );
        vm.prank(carol);
        helper.takeAuction(params);

        assertEq(morpho.flashLoanCount(), 1);
        assertEq(morpho.lastFlashAssets(), marginPart);
        assertEq(usdcBefore - usdc.balanceOf(carol), SHORTFALL - marginPart);
        assertEq(waUsdc.balanceOf(carol) - sharesBefore, award - marginPart);
        assertEq(morpho.borrowAssetsOf(marketId, carol), 0);
        _assertHelperClean(address(auctionVault));
    }

    /* AUCTION TAKES: SYNC POKE */

    function testTakeKicksUntouchedAuctionThroughMaterializeAccount() public {
        _openTakeAuction(false, false);
        assertEq(auctionVault.syncState().pendingAuctionEpochPlusOne, 0);
        assertFalse(auctionVault.getEpochState(0).slashFinalized);

        vm.expectCall(address(auctionVault), abi.encodeWithSelector(LCCVault.finalizeEpochSlash.selector), 0);
        vm.expectCall(address(auctionVault), abi.encodeCall(LCCVault.materializeAccount, (address(helper))), 1);
        vm.expectEmit(true, false, false, true, address(auctionVault));
        emit LCCEventsLib.AuctionKicked(0, SHORTFALL, 50e18);
        vm.prank(carol);
        (uint256 filled,) = helper.takeAuction(_takeParams(20e18));

        assertEq(filled, 20e18);
        assertTrue(auctionVault.getEpochState(0).slashFinalized);
        assertEq(auctionVault.syncState().pendingAuctionEpochPlusOne, 1);
        assertEq(auctionVault.getAuctionState(0).filledAmount, 20e18);
    }

    function testTakeOnKickedAuctionPokesThroughFinalizeEpochSlash() public {
        _openTakeAuction(false, true);
        assertEq(auctionVault.syncState().pendingAuctionEpochPlusOne, 1);
        bytes memory accountBefore = abi.encode(auctionVault.getAccount(address(helper)));

        vm.expectCall(address(auctionVault), abi.encodeWithSelector(LCCVault.materializeAccount.selector), 0);
        vm.expectCall(address(auctionVault), abi.encodeCall(LCCVault.finalizeEpochSlash, (0)), 1);
        vm.prank(carol);
        (uint256 filled,) = helper.takeAuction(_takeParams(20e18));

        assertEq(filled, 20e18);
        assertEq(abi.encode(auctionVault.getAccount(address(helper))), accountBefore);
        assertEq(auctionVault.getAuctionState(0).filledAmount, 20e18);
    }

    function testExpiredAuctionRevertsNothingToFundAndRollsBackSettlement() public {
        _openTakeAuction(false, true);
        vm.warp(START + EPOCH);
        uint256 treasuryBefore = auctionVault.pendingTreasuryMargin();

        vm.expectRevert(ILCCLeveragedFundHelper.NothingToFund.selector);
        vm.prank(carol);
        helper.takeAuction(_takeParams(SHORTFALL));

        assertEq(auctionVault.syncState().pendingAuctionEpochPlusOne, 1);
        assertEq(auctionVault.pendingTreasuryMargin(), treasuryBefore);
        assertEq(auctionVault.getEpochState(0).returnPool, 0);
    }

    function testTakeAfterExpiredAuctionFillsNewerCall() public {
        _openTakeAuction(false, true);
        vm.warp(START + EPOCH + NORMAL);
        vm.recordLogs();
        auctionVault.openEpochCall(1, 40e18);
        assertEq(_countLogs(address(auctionVault), LCCEventsLib.AuctionSettled.selector), 1);
        vm.warp(START + EPOCH + NORMAL + PRE_CALL + FUNDING + 5);
        assertEq(auctionVault.syncState().pendingAuctionEpochPlusOne, 0);

        vm.recordLogs();
        vm.prank(carol);
        (uint256 filled, uint256 collateral) = helper.takeAuction(_takeParams(10e18));

        assertEq(filled, 10e18);
        assertEq(collateral, 10e18);
        assertEq(auctionVault.syncState().pendingAuctionEpochPlusOne, 2);
        assertEq(auctionVault.getAuctionState(1).filledAmount, 10e18);
    }

    function testShutdownRevertsNothingToFundWithoutCallingTake() public {
        _openTakeAuction(false, true);
        auctionVault.shutdown();

        vm.expectCall(address(auctionVault), abi.encodeWithSelector(LCCVault.takeAuction.selector), 0);
        vm.expectRevert(ILCCLeveragedFundHelper.NothingToFund.selector);
        vm.prank(carol);
        helper.takeAuction(_takeParams(SHORTFALL));
    }

    function testPausedVaultRevertsAtSync() public {
        _openTakeAuction(false, true);
        vm.prank(guardian);
        auctionVault.pause();

        vm.expectRevert(LCCErrorsLib.Paused.selector);
        vm.prank(carol);
        helper.takeAuction(_takeParams(SHORTFALL));
    }

    function testStaleTakeDeadlineRevertsBeforeSync() public {
        _openTakeAuction(false, true);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
        params.deadline = block.timestamp - 1;

        _expectNoSync(address(auctionVault));
        vm.expectRevert(ILCCLeveragedFundHelper.DeadlineExpired.selector);
        vm.prank(carol);
        helper.takeAuction(params);
    }

    /* AUCTION TAKES: VAULT CHECKS AND SETTLEMENT */

    function testInsufficientMarginAwardRevertsAtomically() public {
        _openTakeAuction(false, true);
        uint256 award = _dryRunAward(SHORTFALL);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
        params.borrowAssets = 40e18;
        params.minMarginAward = award + 1;
        uint256 usdcBefore = usdc.balanceOf(carol);

        vm.expectRevert(LCCErrorsLib.InsufficientMarginAward.selector);
        vm.prank(carol);
        helper.takeAuction(params);

        _assertTakeRolledBack(usdcBefore);
    }

    function testMarginOracleFailureRevertsAtomically() public {
        _openTakeAuction(false, true);
        vm.mockCallRevert(address(oracle), abi.encodeWithSignature("price()"), "MARGIN_ORACLE_DOWN");
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
        params.borrowAssets = 40e18;
        uint256 usdcBefore = usdc.balanceOf(carol);

        vm.expectRevert(bytes("MARGIN_ORACLE_DOWN"));
        vm.prank(carol);
        helper.takeAuction(params);

        _assertTakeRolledBack(usdcBefore);
    }

    function testCompletingTakeSettlesAuction() public {
        _openTakeAuction(false, true);
        _directFill(stranger, 30e18);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
        params.borrowAssets = 40e18;

        vm.recordLogs();
        vm.prank(carol);
        (uint256 filled,) = helper.takeAuction(params);

        assertEq(filled, 20e18);
        assertEq(_countLogs(address(auctionVault), LCCEventsLib.AuctionSettled.selector), 1);
        assertEq(auctionVault.syncState().pendingAuctionEpochPlusOne, 0);
        assertGt(auctionVault.getEpochState(0).returnPool, 0);
        assertEq(morpho.borrowAssetsOf(marketId, carol), 16e18);
        _assertHelperClean(address(auctionVault));
    }

    function testCompletingTakeWithMissingPriceSnapshotRevertsAtomically() public {
        _openTakeAuction(false, true);
        vm.store(address(auctionVault), _mappingSlot(0, MARGIN_PRICE_AT_CALL_OPEN_SLOT), bytes32(0));
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
        params.borrowAssets = 40e18;
        uint256 usdcBefore = usdc.balanceOf(carol);

        vm.expectRevert(LCCErrorsLib.OraclePriceInvalid.selector);
        vm.prank(carol);
        helper.takeAuction(params);

        _assertTakeRolledBack(usdcBefore);
        assertEq(auctionVault.syncState().pendingAuctionEpochPlusOne, 1);

        params = _takeParams(20e18);
        params.borrowAssets = 10e18;
        vm.prank(carol);
        (uint256 filled,) = helper.takeAuction(params);
        assertEq(filled, 20e18);
    }

    /* AUCTION TAKES: DELIVERY */

    function testTakeDeliveryBelowMinimumReverts() public {
        _openTakeAuction(false, true);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
        params.minCollateral = SHORTFALL + 1;
        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.CollateralBelowMinimum.selector, SHORTFALL, SHORTFALL + 1)
        );
        vm.prank(carol);
        helper.takeAuction(params);
    }

    function testDonatedUsd3lUntouchedOnDirectAndFlashTakes() public {
        _openTakeAuction(false, true);
        deal(address(usd3l), address(helper), 7);

        vm.prank(carol);
        (, uint256 collateral) = helper.takeAuction(_takeParams(20e18));
        assertEq(collateral, 20e18);
        assertEq(usd3l.balanceOf(address(helper)), 7);

        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(30e18);
        params.borrowAssets = 20e18;
        vm.prank(carol);
        (, collateral) = helper.takeAuction(params);
        assertEq(collateral, 30e18);
        assertEq(usd3l.balanceOf(address(helper)), 7);
        (,, uint128 positionCollateral) = morpho.position(marketId, carol);
        assertEq(positionCollateral, SHORTFALL);
    }

    function testRetainedUsd3lRevertsOnDirectAndFlashTakes() public {
        _openTakeAuction(false, true);
        _supplyExtraCollateral(carol, SHORTFALL);
        vm.mockCall(address(morpho), abi.encodeWithSelector(IMorphoBlue.supplyCollateral.selector), "");

        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.UnexpectedBalance.selector, address(usd3l), 20e18, 0)
        );
        vm.prank(carol);
        helper.takeAuction(_takeParams(20e18));

        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(20e18);
        params.borrowAssets = 10e18;
        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.UnexpectedBalance.selector, address(usd3l), 20e18, 0)
        );
        vm.prank(carol);
        helper.takeAuction(params);
    }

    function testDustFillBelowOneUsd3ShareFailsInVault() public {
        _openTakeAuction(false, true);
        usd3.reportProfit(1);
        assertEq(usd3.previewDeposit(1), 0);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(1);

        vm.expectRevert(bytes("ZERO_SHARES"));
        vm.prank(carol);
        helper.takeAuction(params);
    }

    /* AUCTION TAKES: AWARD CONTRIBUTION */

    function testStepZeroAwardWithMarginRevertsEvenWithDonatedShares() public {
        _openTakeAuction(true, true);
        vm.warp(START + NORMAL + PRE_CALL + FUNDING + 1);
        assertEq(_dryRunAward(SHORTFALL), 0);
        _mintSurplusMargin(address(helper), 20e18);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
        params.marginAssets = 10e18;

        vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.MarginSharesUnavailable.selector, 10e18, 0));
        vm.prank(carol);
        helper.takeAuction(params);
    }

    function testAwardWithdrawalReceiptShortfallReverts() public {
        _openTakeAuction(true, true);
        waUsdc.setWithdrawShortfall(1);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
        params.marginAssets = 10e18;

        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.UnexpectedBalance.selector, address(usdc), 10e18 - 1, 10e18)
        );
        vm.prank(carol);
        helper.takeAuction(params);
    }

    function testDonatedMarginSharesNeverSpentOnTake() public {
        _openTakeAuction(true, true);
        _mintSurplusMargin(address(helper), 7);
        uint256 award = _dryRunAward(SHORTFALL);
        uint256 sharesBefore = waUsdc.balanceOf(carol);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
        params.marginAssets = 10e18;
        params.borrowAssets = 20e18;

        vm.prank(carol);
        helper.takeAuction(params);

        assertEq(waUsdc.balanceOf(address(helper)), 7);
        assertEq(waUsdc.balanceOf(carol) - sharesBefore, award - 10e18);
        assertEq(morpho.borrowAssetsOf(marketId, carol), 20e18);
    }

    function testTakeMarginRequiresMarginAssetVaultOverUsdc() public {
        _openTakeAuction(false, true);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
        params.marginAssets = 10e18;

        _expectNoSync(address(auctionVault));
        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.UnsupportedMarginAsset.selector, address(margin))
        );
        vm.prank(carol);
        helper.takeAuction(params);
    }

    function testTakeRejectsUsdcOrUsd3MarginAsset() public {
        address[2] memory assets = [address(usdc), address(usd3)];
        for (uint256 i; i < assets.length; ++i) {
            ILCCVault.VaultParams memory vaultParams = _auctionParams();
            vaultParams.marginAsset = assets[i];
            ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
            params.vault = address(_newVault(vaultParams));

            _expectNoSync(params.vault);
            vm.expectRevert(abi.encodeWithSelector(ILCCLeveragedFundHelper.UnsupportedMarginAsset.selector, assets[i]));
            vm.prank(carol);
            helper.takeAuction(params);
        }
    }

    function testTakeRejectsUnregisteredVaultAndWrongMarket() public {
        _openTakeAuction(false, true);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
        params.vault = address(_newVaultWithMockFactory(_auctionParams()));
        vm.expectRevert(ILCCLeveragedFundHelper.UnregisteredVault.selector);
        vm.prank(carol);
        helper.takeAuction(params);

        params = _takeParams(SHORTFALL);
        params.market.collateralToken = address(usd3);
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidRequest.selector);
        vm.prank(carol);
        helper.takeAuction(params);

        params = _takeParams(SHORTFALL);
        params.minCollateral = 0;
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidRequest.selector);
        vm.prank(carol);
        helper.takeAuction(params);
    }

    /* AUCTION TAKES: LIQUIDITY AND CALLBACK */

    function testTakeRevertsWhenSingletonHoldsLessThanTwiceTheBorrowPlusMargin() public {
        _openTakeAuction(true, true);
        ILCCLeveragedFundHelper.TakeParams memory params = _takeParams(SHORTFALL);
        params.borrowAssets = 30e18;
        params.marginAssets = 10e18;
        deal(address(usdc), address(morpho), 2 * 30e18 + 10e18 - 1);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(morpho), 30e18 - 1, 30e18)
        );
        vm.prank(carol);
        helper.takeAuction(params);
    }

    function testTakeCallbackWithWrongAmountRejected() public {
        _openTakeAuction(false, true);
        morpho.setCallbackAssetsDelta(1);
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidCallback.selector);
        vm.prank(carol);
        helper.takeAuction(_leveredTakeParams());
    }

    function testEveryOperationKindRelabelIsRejectedByTheHashCheck() public {
        _openTakeAuction(false, true);
        uint256 snapshot = vm.snapshotState();

        uint8[3] memory fromTake = [uint8(0), 1, 3];
        for (uint256 i; i < fromTake.length; ++i) {
            morpho.setCallbackKind(fromTake[i]);
            vm.expectRevert(ILCCLeveragedFundHelper.InvalidCallback.selector);
            vm.prank(carol);
            helper.takeAuction(_leveredTakeParams());
            vm.revertToState(snapshot);
        }

        _deposit(alice, MARGIN);
        _openCallAtEpoch(1, CALL);
        vm.warp(START + EPOCH + NORMAL + PRE_CALL);
        assertEq(vault.obligationOf(1, alice), CALL);
        usdc.mint(alice, 20e18);
        snapshot = vm.snapshotState();
        uint8[3] memory fromFunding = [uint8(1), 2, 3];
        for (uint256 i; i < fromFunding.length; ++i) {
            morpho.setCallbackKind(fromFunding[i]);
            vm.expectRevert(ILCCLeveragedFundHelper.InvalidCallback.selector);
            vm.prank(alice);
            helper.fund(_fundParams(80e18));
            vm.revertToState(snapshot);
        }

        vm.prank(alice);
        helper.fund(_fundParams(80e18));
        vm.warp(block.timestamp + cooldown);
        snapshot = vm.snapshotState();
        uint8[3] memory fromUnwind = [uint8(0), 2, 3];
        for (uint256 i; i < fromUnwind.length; ++i) {
            morpho.setCallbackKind(fromUnwind[i]);
            vm.expectRevert(ILCCLeveragedFundHelper.InvalidCallback.selector);
            vm.prank(alice);
            helper.unwind(_unwindParams(CALL, true, 0));
            vm.revertToState(snapshot);
        }
    }

    function testRepeatedTakeCallbackRejected() public {
        _openTakeAuction(false, true);
        morpho.setCallbackCount(2);
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidCallback.selector);
        vm.prank(carol);
        helper.takeAuction(_leveredTakeParams());
    }

    /* REENTRANCY */

    /// @dev Every outer entrypoint, run on a path whose Morpho call fires the armed reentry, rejects a nested call to
    /// every entrypoint with the reentrancy guard and still completes.
    function testNoEntrypointIsReenterableFromAnyOther() public {
        Signed memory empty;
        bytes[] memory nested = new bytes[](5);
        nested[0] = abi.encodeCall(ILCCLeveragedFundHelper.fund, (_fundParams(80e18)));
        nested[1] = abi.encodeCall(
            ILCCLeveragedFundHelper.fundWithSignatures,
            (
                _fundParams(80e18),
                empty.usdcPermit,
                empty.usd3lPermit,
                empty.marginPermit,
                empty.authorization,
                empty.signature
            )
        );
        nested[2] = abi.encodeCall(ILCCLeveragedFundHelper.takeAuction, (_leveredTakeParams()));
        nested[3] = abi.encodeCall(ILCCLeveragedFundHelper.unwind, (_unwindParams(1, true, 0)));
        nested[4] = abi.encodeCall(
            ILCCLeveragedFundHelper.unwindWithAuthorization,
            (_unwindParams(1, true, 0), empty.authorization, empty.signature)
        );

        uint256 clean = vm.snapshotState();
        for (uint256 outer; outer < nested.length; ++outer) {
            (address caller, bytes memory call) = _prepareReentryOuter(outer);
            uint256 prepared = vm.snapshotState();
            for (uint256 inner; inner < nested.length; ++inner) {
                morpho.armReentry(address(helper), nested[inner]);
                vm.prank(caller);
                (bool ok,) = address(helper).call(call);
                assertTrue(ok, "outer entrypoint completes");
                assertEq(
                    morpho.reentryError(),
                    ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
                    "nested entrypoint rejected"
                );
                vm.revertToState(prepared);
            }
            vm.revertToState(clean);
        }
    }

    /// @dev Prepares outer entrypoint `index` (fund, fundWithSignatures, takeAuction, unwind, unwindWithAuthorization)
    /// on a path that borrows or repays through Morpho, and returns its caller and calldata.
    function _prepareReentryOuter(uint256 index) internal returns (address caller, bytes memory call) {
        Signed memory empty;
        if (index == 0) {
            _depositAndOpenCall(alice);
            usdc.mint(alice, 20e18);
            return (alice, abi.encodeCall(ILCCLeveragedFundHelper.fund, (_fundParams(80e18))));
        }
        if (index == 1) {
            _prepareSigner();
            Signed memory s = _sign(20e18, CALL);
            return (
                signer,
                abi.encodeCall(
                    ILCCLeveragedFundHelper.fundWithSignatures,
                    (_fundParams(80e18), s.usdcPermit, s.usd3lPermit, s.marginPermit, s.authorization, s.signature)
                )
            );
        }
        if (index == 2) {
            _openTakeAuction(false, true);
            return (carol, abi.encodeCall(ILCCLeveragedFundHelper.takeAuction, (_leveredTakeParams())));
        }
        vm.warp(_enterLevered(alice) + cooldown);
        if (index == 3) return (alice, abi.encodeCall(ILCCLeveragedFundHelper.unwind, (_unwindParams(CALL, true, 0))));
        return (
            alice,
            abi.encodeCall(
                ILCCLeveragedFundHelper.unwindWithAuthorization,
                (_unwindParams(CALL, true, 0), empty.authorization, empty.signature)
            )
        );
    }

    /* AUCTION TAKES: COOLDOWNS */

    function testFullBookMixingFundAndTakeEntriesMergesTheTwoOldest() public {
        _openTakeAuction(false, true);
        usdc.mint(alice, 20e18);
        vm.prank(alice);
        (, uint256 takeCollateral) = helper.takeAuction(_takeParams(20e18));
        uint256 takeStart = vm.getBlockTimestamp();

        _deposit(alice, MARGIN);
        uint256 secondStart = _fundUnleveredAtEpoch(alice, 1, 1e18);
        for (uint256 epoch = 2; epoch < maxCooldowns; ++epoch) {
            _fundUnleveredAtEpoch(alice, epoch, 1e18);
        }
        ILCCLeveragedFundHelper.Cooldown[] memory book = helper.cooldowns(alice, marketId);
        assertEq(book.length, maxCooldowns);
        assertEq(book[0].shares, takeCollateral);
        assertEq(book[0].start, takeStart);

        vm.recordLogs();
        uint256 newestStart = _fundUnleveredAtEpoch(alice, maxCooldowns, 1e18);
        assertEq(
            _singleLogData(ILCCLeveragedFundHelper.CooldownsMerged.selector),
            abi.encode(takeCollateral + 1e18, secondStart, cooldown)
        );

        book = helper.cooldowns(alice, marketId);
        assertEq(book.length, maxCooldowns);
        assertEq(book[0].shares, takeCollateral + 1e18);
        assertEq(book[0].start, secondStart);
        assertEq(book[maxCooldowns - 1].start, newestStart);
    }

    function testTakeBookedCollateralUnwindsAtMaturity() public {
        _openTakeAuction(false, true);
        vm.prank(carol);
        (, uint256 collateral) = helper.takeAuction(_leveredTakeParams());
        uint256 start = vm.getBlockTimestamp();
        uint256 debt = morpho.borrowAssetsOf(marketId, carol);
        assertEq(debt, 40e18);

        vm.warp(start + cooldown - 1);
        vm.expectRevert(
            abi.encodeWithSelector(ILCCLeveragedFundHelper.InsufficientMaturedShares.selector, collateral, 0)
        );
        vm.prank(carol);
        helper.unwind(_unwindParams(collateral, true, 0));

        vm.warp(start + cooldown);
        uint256 usdcBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        (uint256 repaid, uint256 usdcOut) = helper.unwind(_unwindParams(collateral, true, 0));
        assertEq(repaid, debt);
        assertEq(usdcOut, collateral - debt);
        assertEq(usdc.balanceOf(carol) - usdcBefore, usdcOut);
        assertEq(helper.cooldowns(carol, marketId).length, 0);
        _assertUnwindHelperClean();
    }

    /* CONSTRUCTOR */

    function testConstructorDerivesTokensFromUsd3l() public {
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidConfiguration.selector);
        new LCCLeveragedFundHelper(address(0), address(factory), address(usd3l));

        vm.expectRevert(ILCCLeveragedFundHelper.InvalidConfiguration.selector);
        new LCCLeveragedFundHelper(address(morpho), address(factory), makeAddr("codeless-usd3l"));

        LCCAssetOnlyVault codelessUsd3 = new LCCAssetOnlyVault(makeAddr("codeless-usd3"));
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidConfiguration.selector);
        new LCCLeveragedFundHelper(address(morpho), address(factory), address(codelessUsd3));

        LCCAssetOnlyVault codelessUsdc =
            new LCCAssetOnlyVault(address(new LCCAssetOnlyVault(makeAddr("codeless-usdc"))));
        vm.expectRevert(ILCCLeveragedFundHelper.InvalidConfiguration.selector);
        new LCCLeveragedFundHelper(address(morpho), address(factory), address(codelessUsdc));

        vm.expectRevert();
        new LCCLeveragedFundHelper(address(morpho), address(factory), address(margin));

        assertEq(helper.usd3(), address(usd3));
        assertEq(helper.usdc(), address(usdc));
        assertEq(helper.usd3l(), address(usd3l));
        assertEq(helper.MAX_COOLDOWNS(), 32);
        assertEq(usd3l.allowance(address(helper), address(morpho)), type(uint256).max);
        assertEq(usdc.allowance(address(helper), address(morpho)), type(uint256).max);
    }

    /* HELPERS */

    function _deployTokens() internal override {
        usdc = new LCCPermitMockToken("USD Coin", "USDC");
        unwindUsd3 = new LCCUnwindMockUSD3(IERC20(address(usdc)));
        usd3 = unwindUsd3;
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
            marginAssets: 0,
            maxMarginShares: 0,
            maxContribution: CALL - borrowAssets,
            minCollateral: CALL,
            maxCollateral: CALL,
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

    function _expectNoFunding() internal {
        _expectNoFunding(address(vault));
    }

    function _expectNoFunding(address target) internal {
        _expectNoEntry(target, bytes4(keccak256("fundCall(address)")));
    }

    function _expectNoEntry(address target, bytes4 selector) internal {
        vm.expectCall(address(morpho), abi.encodeWithSelector(IMorphoBlue.flashLoan.selector), 0);
        vm.expectCall(target, abi.encodeWithSelector(selector), 0);
    }

    /// @dev Lists a facility whose margin asset is an ERC-4626 over USDC, deposits `MARGIN` of fresh shares for `user`,
    /// opens a `CALL` and warps into Funding. With `user` the only depositor, half its margin is released on funding.
    function _openMarginFacility(address user) internal {
        waUsdc = new LCCMockUsdcMarginVault(IERC20(address(usdc)));
        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        params.marginAsset = address(waUsdc);
        marginFacility = _newVault(params);

        _mintSurplusMargin(user, MARGIN);
        vm.startPrank(user);
        waUsdc.approve(address(marginFacility), MARGIN);
        waUsdc.approve(address(helper), RELEASED);
        vm.stopPrank();
        _deposit(marginFacility, user, MARGIN);

        _openCallAtEpoch(marginFacility, 0, CALL);
        vm.warp(START + NORMAL + PRE_CALL);
    }

    function _mintSurplusMargin(address user, uint256 assets) internal {
        usdc.mint(user, assets);
        vm.startPrank(user);
        usdc.approve(address(waUsdc), assets);
        waUsdc.deposit(assets, user);
        vm.stopPrank();
    }

    function _marginParams(uint256 borrowAssets, uint256 marginAssets)
        internal
        view
        returns (ILCCLeveragedFundHelper.FundParams memory params)
    {
        params = _fundParams(borrowAssets);
        params.vault = address(marginFacility);
        params.marginAssets = marginAssets;
        params.maxMarginShares = marginAssets;
    }

    /// @dev Levered entry at epoch 0 (80% borrowed); returns the cooldown start.
    function _enterLevered(address user) internal returns (uint256) {
        _depositAndOpenCall(user);
        usdc.mint(user, 20e18);
        vm.prank(user);
        helper.fund(_fundParams(80e18));
        return vm.getBlockTimestamp();
    }

    /// @dev Second levered entry for a user who already funded epoch 0, at a later called epoch.
    function _enterLeveredAtEpoch(address user, uint256 epoch) internal returns (uint256) {
        _openCallAtEpoch(epoch, CALL);
        vm.warp(START + EPOCH * epoch + NORMAL + PRE_CALL);
        usdc.mint(user, 20e18);
        vm.prank(user);
        helper.fund(_fundParams(80e18));
        return vm.getBlockTimestamp();
    }

    /// @dev Unlevered entry at epoch 0 (no borrow); returns the cooldown start.
    function _enterUnlevered(address user) internal returns (uint256) {
        _depositAndOpenCall(user);
        usdc.mint(user, CALL);
        vm.startPrank(user);
        usdc.approve(address(helper), type(uint256).max);
        usd3l.approve(address(helper), type(uint256).max);
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(0);
        helper.fund(params);
        vm.stopPrank();
        return vm.getBlockTimestamp();
    }

    /// @dev Unlevered entry for `call` at `epoch` by a user who already deposited; returns the cooldown start.
    function _fundUnleveredAtEpoch(address user, uint256 epoch, uint256 call) internal returns (uint256) {
        _openCallAtEpoch(epoch, call);
        vm.warp(START + EPOCH * epoch + NORMAL + PRE_CALL);
        uint256 obligation = vault.obligationOf(epoch, user);
        usdc.mint(user, obligation);
        ILCCLeveragedFundHelper.FundParams memory params = _fundParams(0);
        params.maxObligation = obligation;
        params.minCollateral = obligation;
        vm.prank(user);
        helper.fund(params);
        return vm.getBlockTimestamp();
    }

    /// @dev `user`'s matured cooldown shares, read from `cooldowns()` and the live USD3l duration.
    function _maturedShares(address user) internal view returns (uint256 shares) {
        ILCCLeveragedFundHelper.Cooldown[] memory book = helper.cooldowns(user, marketId);
        uint256 liveDuration = usd3l.cooldownDuration();
        for (uint256 i; i < book.length; ++i) {
            if (block.timestamp >= uint256(book[i].start) + Math.max(book[i].duration, liveDuration)) {
                shares += book[i].shares;
            }
        }
    }

    function _singleLogData(bytes32 topic) internal returns (bytes memory data) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(helper) && logs[i].topics[0] == topic) {
                data = logs[i].data;
                ++count;
            }
        }
        assertEq(count, 1);
    }

    function _expectFailedUnwindRestoresState(bytes memory reason) internal {
        uint256 debtBefore = morpho.borrowAssetsOf(marketId, alice);
        vm.expectRevert(reason);
        vm.prank(alice);
        helper.unwind(_unwindParams(CALL, true, 0));
        assertEq(helper.cooldowns(alice, marketId)[0].shares, CALL);
        assertEq(morpho.borrowAssetsOf(marketId, alice), debtBefore);
        (,, uint128 collateral) = morpho.position(marketId, alice);
        assertEq(collateral, CALL);
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
        helper.fundWithSignatures(params, s.usdcPermit, s.usd3lPermit, s.marginPermit, s.authorization, s.signature);
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
        bytes32 digest =
            _permitDigest(token, signer, spender, permit.value, ERC20Permit(token).nonces(signer), permit.deadline);
        address recovered = ecrecover(digest, permit.v, permit.r, permit.s);
        return abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, recovered, signer);
    }

    /* AUCTION TAKE HELPERS */

    /// @dev Lists an auction facility (four 5-second steps, 5,000 bps decay, 1,000 bps fee) whose margin asset is the
    /// mock token or, with `usdcMargin`, an ERC-4626 over USDC. A funder with 100e18 of margin honours a 150e18 call
    /// and a defaulter with 50e18 defaults, leaving a `SHORTFALL` of USDC against a 50e18 margin pool. With `kick` the
    /// slash is finalized at the funding deadline; otherwise no synced call runs after Funding ends. Warps to the first
    /// award step.
    function _openTakeAuction(bool usdcMargin, bool kick) internal {
        _openTakeAuctionSized(usdcMargin, kick, 50e18);
    }

    /// @dev `_openTakeAuction` with a defaulter posting `defaulterMargin`; the shortfall is the defaulter's share of
    /// the 150e18 call and the margin pool is its whole margin.
    function _openTakeAuctionSized(bool usdcMargin, bool kick, uint256 defaulterMargin) internal {
        ILCCVault.VaultParams memory params = _auctionParams();
        if (usdcMargin) {
            waUsdc = new LCCMockUsdcMarginVault(IERC20(address(usdc)));
            params.marginAsset = address(waUsdc);
        }
        auctionVault = _newVault(params);
        _depositAuctionMargin(auctionFunder, 100e18);
        _depositAuctionMargin(auctionDefaulter, defaulterMargin);

        _openCallAtEpoch(auctionVault, 0, 150e18);
        _mintAndApprove(auctionVault, auctionFunder, 0, 100e18);
        _fundAtEpoch(auctionVault, auctionFunder, 0);

        _finishFundingAtEpoch(0);
        if (kick) auctionVault.finalizeEpochSlash(0);
        vm.warp(START + NORMAL + PRE_CALL + FUNDING + AUCTION_STEP);
        _approveHelper(carol);
    }

    function _depositAuctionMargin(address user, uint256 assets) internal {
        bool usdcMargin = auctionVault.assetConfig().marginAsset == address(waUsdc);
        _mintAndApprove(auctionVault, user, usdcMargin ? 0 : assets, 0);
        if (usdcMargin) {
            _mintSurplusMargin(user, assets);
            vm.prank(user);
            waUsdc.approve(address(auctionVault), assets);
        }
        _deposit(auctionVault, user, assets);
    }

    function _takeParams(uint256 maxFill) internal view returns (ILCCLeveragedFundHelper.TakeParams memory) {
        return ILCCLeveragedFundHelper.TakeParams({
            vault: address(auctionVault),
            market: marketParams,
            maxFill: maxFill,
            minFill: 0,
            borrowAssets: 0,
            marginAssets: 0,
            minMarginAward: 0,
            minCollateral: maxFill,
            maxEntryLtv: LLTV,
            deadline: block.timestamp
        });
    }

    /// @dev A whole-shortfall take borrowing 40e18.
    function _leveredTakeParams() internal view returns (ILCCLeveragedFundHelper.TakeParams memory params) {
        params = _takeParams(SHORTFALL);
        params.borrowAssets = 40e18;
    }

    /// @dev The margin award a direct `fill` would receive now, measured and rolled back.
    function _dryRunAward(uint256 fill) internal returns (uint256 award) {
        IERC20 marginToken = IERC20(auctionVault.assetConfig().marginAsset);
        address filler = makeAddr("dry-run-filler");
        uint256 snapshot = vm.snapshotState();
        uint256 before = marginToken.balanceOf(filler);
        _directFill(filler, fill);
        award = marginToken.balanceOf(filler) - before;
        vm.revertToState(snapshot);
    }

    function _directFill(address filler, uint256 amount) internal {
        usdc.mint(filler, amount);
        vm.startPrank(filler);
        usdc.approve(address(auctionVault), amount);
        auctionVault.takeAuction(amount, 0, block.timestamp);
        vm.stopPrank();
    }

    function _expectNoTake() internal {
        _expectNoEntry(address(auctionVault), LCCVault.takeAuction.selector);
    }

    function _expectNoSync(address target) internal {
        vm.expectCall(target, abi.encodeWithSelector(LCCVault.materializeAccount.selector), 0);
        vm.expectCall(target, abi.encodeWithSelector(LCCVault.finalizeEpochSlash.selector), 0);
    }

    function _lastTakeOperation() internal view returns (LCCLeveragedFundHelper.TakeOperation memory op) {
        uint8 kind;
        (kind, op) = abi.decode(morpho.lastFlashData(), (uint8, LCCLeveragedFundHelper.TakeOperation));
        assertEq(kind, 2);
    }

    function _assertTakeRolledBack(uint256 usdcBefore) internal view {
        assertEq(usdc.balanceOf(carol), usdcBefore);
        assertEq(usd3l.balanceOf(carol), 0);
        assertEq(auctionVault.getAuctionState(0).filledAmount, 0);
        assertEq(auctionVault.getAuctionState(0).marginAwarded, 0);
        assertEq(morpho.borrowAssetsOf(marketId, carol), 0);
        (,, uint128 positionCollateral) = morpho.position(marketId, carol);
        assertEq(positionCollateral, 0);
        assertEq(helper.cooldowns(carol, marketId).length, 0);
        _assertHelperClean(address(auctionVault));
    }
}
