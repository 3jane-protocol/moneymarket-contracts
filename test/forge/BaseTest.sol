// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../lib/forge-std/src/Test.sol";
import "../../lib/forge-std/src/console.sol";

import {IMorpho, IMorphoCredit} from "../../src/interfaces/IMorpho.sol";
import "../../src/interfaces/IMorphoCallbacks.sol";
import {IrmMock} from "../../src/mocks/IrmMock.sol";
import {ERC20Mock} from "../../src/mocks/ERC20Mock.sol";
import {OracleMock} from "../../src/mocks/OracleMock.sol";
import {MorphoCreditMock} from "../../src/mocks/MorphoCreditMock.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {ProtocolConfigLib} from "../../src/libraries/ProtocolConfigLib.sol";

import "../../src/Morpho.sol";
import "../../src/MorphoCredit.sol";
import {Math} from "./helpers/Math.sol";
import {SigUtils} from "./helpers/SigUtils.sol";
import {ArrayLib} from "./helpers/ArrayLib.sol";
import {MorphoLib} from "../../src/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "../../src/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoCreditLib} from "../../src/libraries/periphery/MorphoCreditLib.sol";
import {
    TransparentUpgradeableProxy
} from "../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract BaseTest is Test {
    using Math for uint256;
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using ArrayLib for address[];
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    using MorphoCreditLib for IMorphoCredit;
    using MarketParamsLib for MarketParams;

    uint256 internal constant BLOCK_TIME = 1;
    uint256 internal constant HIGH_COLLATERAL_AMOUNT = 1e35;
    uint256 internal constant MIN_TEST_AMOUNT = 100;
    uint256 internal constant MAX_TEST_AMOUNT = 1e28;
    uint256 internal constant MIN_TEST_SHARES = MIN_TEST_AMOUNT * SharesMathLib.VIRTUAL_SHARES;
    uint256 internal constant MAX_TEST_SHARES = MAX_TEST_AMOUNT * SharesMathLib.VIRTUAL_SHARES;
    uint256 internal constant MIN_TEST_LLTV = 0.01 ether;
    uint256 internal constant MAX_TEST_LLTV = 0.99 ether;
    uint256 internal constant DEFAULT_TEST_LLTV = 0.8 ether;
    uint256 internal constant MIN_COLLATERAL_PRICE = 1e10;
    uint256 internal constant MAX_COLLATERAL_PRICE = 1e40;
    uint256 internal constant MAX_COLLATERAL_ASSETS = type(uint128).max;

    // Repayment tracking constants
    uint256 internal constant GRACE_PERIOD_DURATION = 7 days;
    uint256 internal constant DELINQUENCY_PERIOD_DURATION = 23 days;
    uint256 internal constant CYCLE_DURATION = 30 days;

    // Rate constants (per second)
    uint256 internal constant BASE_RATE_PER_SECOND = 3170979198; // ~10% APR
    uint256 internal constant PENALTY_RATE_PER_SECOND = 3170979198; // ~10% APR
    uint256 internal constant PREMIUM_RATE_PER_SECOND = 634195840; // ~2% APR

    address internal SUPPLIER;
    address internal BORROWER;
    address internal REPAYER;
    address internal ONBEHALF;
    address internal RECEIVER;
    address internal LIQUIDATOR;
    address internal OWNER; // Morpho protocol owner
    address internal PROXY_ADMIN_OWNER; // ProxyAdmin owner

    // Helper function to check if address should be excluded from fuzzing
    function _isProxyRelatedAddress(address addr) internal returns (bool) {
        return addr == OWNER || addr == PROXY_ADMIN_OWNER || addr == address(proxyAdmin) || addr == address(morphoProxy)
            || _wouldCauseProxyDeniedAccess(addr);
    }

    // Dynamically detect addresses that would cause ProxyDeniedAdminAccess errors
    function _wouldCauseProxyDeniedAccess(address addr) internal returns (bool) {
        // Try a view function call that should work for normal addresses
        // but fail with ProxyDeniedAdminAccess for proxy admins
        vm.prank(addr);
        try morpho.owner() returns (address) {
            return false; // Call succeeded, so it's not a problematic proxy admin
        } catch (bytes memory) {
            return true; // Call failed, likely due to ProxyDeniedAdminAccess
        }
    }

    address internal FEE_RECIPIENT;

    address internal morphoAddress;
    ProxyAdmin internal proxyAdmin;
    TransparentUpgradeableProxy internal morphoProxy;

    IMorpho internal morpho;
    ERC20Mock internal loanToken;
    ERC20Mock internal collateralToken;
    OracleMock internal oracle;
    IIrm internal irm;
    ProtocolConfig internal protocolConfig;

    MarketParams internal marketParams;
    Id internal id;

    function setUp() public virtual {
        SUPPLIER = makeAddr("Supplier");
        BORROWER = makeAddr("Borrower");
        REPAYER = makeAddr("Repayer");
        ONBEHALF = makeAddr("OnBehalf");
        RECEIVER = makeAddr("Receiver");
        LIQUIDATOR = makeAddr("Liquidator");
        OWNER = makeAddr("Owner");
        PROXY_ADMIN_OWNER = makeAddr("ProxyAdminOwner");
        FEE_RECIPIENT = makeAddr("FeeRecipient");

        // Deploy protocol config mock
        ProtocolConfig protocolConfigImpl = new ProtocolConfig();
        TransparentUpgradeableProxy protocolConfigProxy = new TransparentUpgradeableProxy(
            address(protocolConfigImpl),
            address(this), // Test contract acts as admin
            abi.encodeWithSelector(ProtocolConfig.initialize.selector, OWNER)
        );

        // Set the protocolConfig to the proxy address
        protocolConfig = ProtocolConfig(address(protocolConfigProxy));

        // Deploy implementation
        MorphoCredit morphoImpl = new MorphoCreditMock(address(protocolConfig));

        // Deploy proxy admin (owned by PROXY_ADMIN_OWNER, separate from Morpho owner)
        proxyAdmin = new ProxyAdmin(PROXY_ADMIN_OWNER);

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeWithSelector(MorphoCredit.initialize.selector, OWNER);
        morphoProxy = new TransparentUpgradeableProxy(address(morphoImpl), address(proxyAdmin), initData);

        // Set up contract references
        morphoAddress = address(morphoProxy);
        morpho = IMorpho(morphoAddress);

        loanToken = new ERC20Mock();
        vm.label(address(loanToken), "LoanToken");

        collateralToken = new ERC20Mock();
        vm.label(address(collateralToken), "CollateralToken");

        oracle = new OracleMock();

        oracle.setPrice(ORACLE_PRICE_SCALE);

        irm = new IrmMock();

        vm.startPrank(OWNER);
        morpho.enableIrm(address(0));
        morpho.enableIrm(address(irm));
        morpho.enableLltv(0);
        morpho.setFeeRecipient(FEE_RECIPIENT);
        vm.stopPrank();

        loanToken.approve(address(morpho), type(uint256).max);
        collateralToken.approve(address(morpho), type(uint256).max);

        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        collateralToken.approve(address(morpho), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(BORROWER);
        loanToken.approve(address(morpho), type(uint256).max);
        collateralToken.approve(address(morpho), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(REPAYER);
        loanToken.approve(address(morpho), type(uint256).max);
        collateralToken.approve(address(morpho), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(LIQUIDATOR);
        loanToken.approve(address(morpho), type(uint256).max);
        collateralToken.approve(address(morpho), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(ONBEHALF);
        loanToken.approve(address(morpho), type(uint256).max);
        collateralToken.approve(address(morpho), type(uint256).max);
        vm.stopPrank();

        _setLltv(DEFAULT_TEST_LLTV);
        _setProtocolConfig();
    }

    function _setLltv(uint256 lltv) internal {
        marketParams =
            MarketParams(address(loanToken), address(collateralToken), address(oracle), address(irm), lltv, address(0));
        id = marketParams.id();

        vm.startPrank(OWNER);
        if (!morpho.isLltvEnabled(lltv)) morpho.enableLltv(lltv);
        if (morpho.lastUpdate(marketParams.id()) == 0) {
            morpho.createMarket(marketParams);
            vm.stopPrank();

            // Initialize market cycles if it has a credit line
            if (marketParams.creditLine != address(0)) {
                _ensureMarketActive(id);
            }
            vm.startPrank(OWNER);
        }
        vm.stopPrank();

        _forward(1);
    }

    function _setProtocolConfig() internal {
        vm.startPrank(OWNER);

        // Credit Line configurations
        protocolConfig.setConfig(keccak256("MAX_LTV"), 0.8 ether); // 80% LTV
        protocolConfig.setConfig(keccak256("MAX_VV"), 0.9 ether); // 90% VV
        protocolConfig.setConfig(keccak256("MAX_CREDIT_LINE"), 1e30); // Large credit line for testing
        protocolConfig.setConfig(keccak256("MIN_CREDIT_LINE"), 1e18); // 1 token minimum
        protocolConfig.setConfig(keccak256("MAX_DRP"), 0.1 ether); // 10% max DRP

        // Market configurations
        protocolConfig.setConfig(keccak256("IS_PAUSED"), 0); // Not paused
        protocolConfig.setConfig(keccak256("MAX_ON_CREDIT"), 0.95 ether); // 95% max on credit
        protocolConfig.setConfig(keccak256("IRP"), uint256(0.1 ether / int256(365 days))); // 10% IRP
        protocolConfig.setConfig(keccak256("MIN_BORROW"), 1000e18); // 1000 token minimum borrow
        protocolConfig.setConfig(keccak256("GRACE_PERIOD"), 7 days); // 7 days grace period
        protocolConfig.setConfig(keccak256("DELINQUENCY_PERIOD"), 23 days); // 23 days delinquency period
        protocolConfig.setConfig(keccak256("CYCLE_DURATION"), CYCLE_DURATION); // 30 days cycle duration

        // IRM configurations
        protocolConfig.setConfig(keccak256("CURVE_STEEPNESS"), uint256(4 ether)); // 4 curve steepness
        protocolConfig.setConfig(keccak256("ADJUSTMENT_SPEED"), uint256(50 ether / int256(365 days)));
        protocolConfig.setConfig(keccak256("TARGET_UTILIZATION"), uint256(0.9 ether)); // 90% target utilization
        protocolConfig.setConfig(keccak256("INITIAL_RATE_AT_TARGET"), uint256(0.04 ether / int256(365 days))); // 4%
            // initial rate
        protocolConfig.setConfig(keccak256("MIN_RATE_AT_TARGET"), uint256(0.001 ether / int256(365 days))); // 0.1%
            // minimum rate
        protocolConfig.setConfig(keccak256("MAX_RATE_AT_TARGET"), uint256(2.0 ether / int256(365 days))); // 200%
            // maximum rate

        // USD3 & sUSD3 configurations
        protocolConfig.setConfig(keccak256("TRANCHE_RATIO"), 0.7 ether); // 70% tranche ratio
        protocolConfig.setConfig(keccak256("TRANCHE_SHARE_VARIANT"), 1); // Variant 1
        protocolConfig.setConfig(keccak256("SUSD3_LOCK_DURATION"), 30 days); // 30 days lock duration
        protocolConfig.setConfig(keccak256("SUSD3_COOLDOWN_PERIOD"), 7 days); // 7 days cooldown period

        // Markdown configuration
        protocolConfig.setConfig(ProtocolConfigLib.FULL_MARKDOWN_DURATION, 70 days); // 70 days for 100% markdown

        vm.stopPrank();
    }

    /// @dev Rolls & warps the given number of blocks forward the blockchain.
    function _forward(uint256 blocks) internal {
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * BLOCK_TIME); // Block speed should depend on test network.
    }

    /// @dev Rolls & warps the given number of blocks forward the blockchain for a specific market.
    function _forwardWithMarket(uint256 blocks, Id marketId) internal {
        vm.roll(block.number + blocks);
        uint256 targetTime = block.timestamp + blocks * BLOCK_TIME;

        // Only continue cycles for markets with credit lines
        // Get market params for this ID to check if it has a credit line
        MarketParams memory mktParams = morpho.idToMarketParams(marketId);
        if (mktParams.creditLine != address(0)) {
            _continueMarketCycles(marketId, targetTime);
        } else {
            // For non-credit line markets, just warp time
            vm.warp(targetTime);
        }
    }

    /// @dev Bounds the fuzzing input to a realistic number of blocks.
    function _boundBlocks(uint256 blocks) internal pure returns (uint256) {
        return bound(blocks, 1, type(uint32).max);
    }

    function _supply(uint256 amount) internal {
        loanToken.setBalance(address(this), amount);
        morpho.supply(marketParams, amount, 0, address(this), hex"");
    }

    function _setupCreditLineForBorrower(address borrower) internal {
        // In 3Jane, we set up a credit line instead of supplying collateral
        // This assumes the market has a creditLine contract configured
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(marketParams.id(), borrower, HIGH_COLLATERAL_AMOUNT, 0);
    }

    function _disableMinBorrow() internal {
        // Helper to disable minBorrow for tests that need to test small amounts
        vm.prank(OWNER);
        protocolConfig.setConfig(keccak256("MIN_BORROW"), 0);
    }

    function _setupMockUsd3() internal returns (address) {
        address mockUsd3 = makeAddr("MockUSD3");
        vm.prank(OWNER);
        IMorphoCredit(address(morpho)).setUsd3(mockUsd3);
        return mockUsd3;
    }

    function _supplyThroughMockUsd3(uint256 amount) internal returns (address) {
        address mockUsd3 = _setupMockUsd3();
        loanToken.setBalance(mockUsd3, amount);
        vm.startPrank(mockUsd3);
        loanToken.approve(address(morpho), amount);
        morpho.supply(marketParams, amount, 0, mockUsd3, hex"");
        vm.stopPrank();
        return mockUsd3;
    }

    /// @notice Initialize the first cycle for a market to unfreeze it
    /// @param _id Market ID to initialize
    function _initializeFirstCycle(Id _id) internal {
        // Only initialize if no cycles exist
        if (MorphoCreditLib.getPaymentCycleLength(IMorphoCredit(address(morpho)), _id) == 0) {
            // Warp to ensure we can close the cycle
            vm.warp(block.timestamp + CYCLE_DURATION);

            address[] memory borrowers = new address[](0);
            uint256[] memory repaymentBps = new uint256[](0);
            uint256[] memory endingBalances = new uint256[](0);

            // Post first cycle with current timestamp
            vm.prank(marketParams.creditLine);
            IMorphoCredit(address(morpho))
                .closeCycleAndPostObligations(_id, block.timestamp, borrowers, repaymentBps, endingBalances);
        }
    }

    /// @notice Initialize the first cycle for the default market
    function _initializeFirstCycle() internal {
        _initializeFirstCycle(id);
    }

    function _boundHealthyPosition(uint256 amountCollateral, uint256 amountBorrowed, uint256 priceCollateral)
        internal
        view
        returns (uint256, uint256, uint256)
    {
        priceCollateral = bound(priceCollateral, MIN_COLLATERAL_PRICE, MAX_COLLATERAL_PRICE);
        amountBorrowed = bound(amountBorrowed, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        uint256 minCollateral = amountBorrowed.wDivUp(marketParams.lltv).mulDivUp(ORACLE_PRICE_SCALE, priceCollateral);

        if (minCollateral <= MAX_COLLATERAL_ASSETS) {
            amountCollateral = bound(amountCollateral, minCollateral, MAX_COLLATERAL_ASSETS);
        } else {
            amountCollateral = MAX_COLLATERAL_ASSETS;
            amountBorrowed = Math.min(
                amountBorrowed.wMulDown(marketParams.lltv).mulDivDown(priceCollateral, ORACLE_PRICE_SCALE),
                MAX_TEST_AMOUNT
            );
        }

        vm.assume(amountBorrowed > 0);
        vm.assume(amountCollateral < type(uint256).max / priceCollateral);
        return (amountCollateral, amountBorrowed, priceCollateral);
    }

    function _boundUnhealthyPosition(uint256 amountCollateral, uint256 amountBorrowed, uint256 priceCollateral)
        internal
        view
        returns (uint256, uint256, uint256)
    {
        priceCollateral = bound(priceCollateral, MIN_COLLATERAL_PRICE, MAX_COLLATERAL_PRICE);
        amountBorrowed = bound(amountBorrowed, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        uint256 maxCollateral =
            amountBorrowed.wDivDown(marketParams.lltv).mulDivDown(ORACLE_PRICE_SCALE, priceCollateral);
        amountCollateral = bound(amountCollateral, 0, Math.min(maxCollateral, MAX_COLLATERAL_ASSETS));

        vm.assume(amountCollateral > 0 && amountCollateral < maxCollateral);
        return (amountCollateral, amountBorrowed, priceCollateral);
    }

    function _boundTestLltv(uint256 lltv) internal pure returns (uint256) {
        return bound(lltv, MIN_TEST_LLTV, MAX_TEST_LLTV);
    }

    function _boundSupplyCollateralAssets(MarketParams memory _marketParams, address onBehalf, uint256 assets)
        internal
        view
        returns (uint256)
    {
        Id _id = _marketParams.id();

        uint256 collateral = morpho.collateral(_id, onBehalf);

        return bound(assets, 0, MAX_TEST_AMOUNT.zeroFloorSub(collateral));
    }

    function _boundWithdrawCollateralAssets(MarketParams memory _marketParams, address onBehalf, uint256 assets)
        internal
        view
        returns (uint256)
    {
        Id _id = _marketParams.id();

        uint256 collateral = morpho.collateral(_id, onBehalf);
        uint256 collateralPrice = IOracle(_marketParams.oracle).price();
        uint256 borrowed = morpho.expectedBorrowAssets(_marketParams, onBehalf);

        return bound(
            assets,
            0,
            collateral.zeroFloorSub(borrowed.wDivUp(_marketParams.lltv).mulDivUp(ORACLE_PRICE_SCALE, collateralPrice))
        );
    }

    function _boundSupplyAssets(MarketParams memory _marketParams, address onBehalf, uint256 assets)
        internal
        view
        returns (uint256)
    {
        uint256 supplyBalance = morpho.expectedSupplyAssets(_marketParams, onBehalf);

        return bound(assets, 0, MAX_TEST_AMOUNT.zeroFloorSub(supplyBalance));
    }

    function _boundSupplyShares(MarketParams memory _marketParams, address onBehalf, uint256 assets)
        internal
        view
        returns (uint256)
    {
        Id _id = _marketParams.id();

        uint256 supplyShares = morpho.supplyShares(_id, onBehalf);

        return bound(
            assets,
            0,
            MAX_TEST_AMOUNT.toSharesDown(morpho.totalSupplyAssets(_id), morpho.totalSupplyShares(_id))
                .zeroFloorSub(supplyShares)
        );
    }

    function _boundWithdrawAssets(MarketParams memory _marketParams, address onBehalf, uint256 assets)
        internal
        view
        returns (uint256)
    {
        Id _id = _marketParams.id();

        uint256 supplyBalance = morpho.expectedSupplyAssets(_marketParams, onBehalf);
        uint256 liquidity = morpho.totalSupplyAssets(_id) - morpho.totalBorrowAssets(_id);

        return bound(assets, 0, MAX_TEST_AMOUNT.min(supplyBalance).min(liquidity));
    }

    function _boundWithdrawShares(MarketParams memory _marketParams, address onBehalf, uint256 shares)
        internal
        view
        returns (uint256)
    {
        Id _id = _marketParams.id();

        uint256 supplyShares = morpho.supplyShares(_id, onBehalf);
        uint256 totalSupplyAssets = morpho.totalSupplyAssets(_id);

        uint256 liquidity = totalSupplyAssets - morpho.totalBorrowAssets(_id);
        uint256 liquidityShares = liquidity.toSharesDown(totalSupplyAssets, morpho.totalSupplyShares(_id));

        return bound(shares, 0, supplyShares.min(liquidityShares));
    }

    function _boundBorrowAssets(MarketParams memory _marketParams, address onBehalf, uint256 assets)
        internal
        view
        returns (uint256)
    {
        Id _id = _marketParams.id();

        uint256 maxBorrow = _maxBorrow(_marketParams, onBehalf);
        uint256 borrowed = morpho.expectedBorrowAssets(_marketParams, onBehalf);
        uint256 liquidity = morpho.totalSupplyAssets(_id) - morpho.totalBorrowAssets(_id);

        return bound(assets, 0, MAX_TEST_AMOUNT.min(maxBorrow - borrowed).min(liquidity));
    }

    function _boundRepayAssets(MarketParams memory _marketParams, address onBehalf, uint256 assets)
        internal
        view
        returns (uint256)
    {
        Id _id = _marketParams.id();

        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) = morpho.expectedMarketBalances(_marketParams);
        uint256 maxRepayAssets = morpho.borrowShares(_id, onBehalf).toAssetsDown(totalBorrowAssets, totalBorrowShares);

        return bound(assets, 0, maxRepayAssets);
    }

    function _boundRepayShares(MarketParams memory _marketParams, address onBehalf, uint256 shares)
        internal
        view
        returns (uint256)
    {
        Id _id = _marketParams.id();

        uint256 borrowShares = morpho.borrowShares(_id, onBehalf);

        return bound(shares, 0, borrowShares);
    }

    function _maxBorrow(MarketParams memory _marketParams, address user) internal view returns (uint256) {
        Id _id = _marketParams.id();

        uint256 collateralPrice = IOracle(_marketParams.oracle).price();

        return morpho.collateral(_id, user).mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(_marketParams.lltv);
    }

    function _isHealthy(MarketParams memory _marketParams, address user) internal view returns (bool) {
        uint256 maxBorrow = _maxBorrow(_marketParams, user);
        uint256 borrowed = morpho.expectedBorrowAssets(_marketParams, user);

        return maxBorrow >= borrowed;
    }

    function _boundValidLltv(uint256 lltv) internal pure returns (uint256) {
        return bound(lltv, 0, WAD - 1);
    }

    function neq(MarketParams memory a, MarketParams memory b) internal pure returns (bool) {
        return (Id.unwrap(a.id()) != Id.unwrap(b.id()));
    }

    function _randomCandidate(address[] memory candidates, uint256 seed) internal pure returns (address) {
        if (candidates.length == 0) return address(0);

        return candidates[seed % candidates.length];
    }

    function _randomNonZero(address[] memory users, uint256 seed) internal pure returns (address) {
        users = users.removeAll(address(0));

        return _randomCandidate(users, seed);
    }

    // ============ Repayment Testing Helpers ============

    function _createRepaymentObligation(
        Id _id,
        address borrower,
        uint256 amountDue,
        uint256 endingBalance,
        uint256 daysAgo
    ) internal {
        // For tests that need obligations in the past relative to current time,
        // we just use the existing _createPastObligation which already handles cycle spacing
        uint256 repaymentBps = amountDue * 10000 / endingBalance;
        _createPastObligation(borrower, repaymentBps, endingBalance);
    }

    // Overloaded version that accepts repaymentBps directly
    function _createRepaymentObligationBps(
        Id _id,
        address borrower,
        uint256 repaymentBps,
        uint256 endingBalance,
        uint256 daysAgo
    ) internal {
        // For tests that need obligations in the past relative to current time,
        // we just use the existing _createPastObligation which already handles cycle spacing
        _createPastObligation(borrower, repaymentBps, endingBalance);
    }

    function _createMultipleObligations(
        Id _id,
        address[] memory borrowers,
        uint256[] memory repaymentBps,
        uint256[] memory balances,
        uint256 daysAgo
    ) internal {
        // Get the correct market params for this market ID
        MarketParams memory mktParams = morpho.idToMarketParams(_id);

        // Ensure market has a cycle and enough time has passed
        uint256 cycleLength = MorphoCreditLib.getPaymentCycleLength(IMorphoCredit(address(morpho)), _id);
        require(cycleLength > 0, "Market needs at least one cycle");

        // Get last cycle end date
        (, uint256 lastCycleEnd) = MorphoCreditLib.getCycleDates(IMorphoCredit(address(morpho)), _id, cycleLength - 1);

        // Calculate new cycle end that's at least CYCLE_DURATION after last one
        uint256 targetCycleEnd = lastCycleEnd + CYCLE_DURATION + (daysAgo * 1 days);

        // Warp to the target time if needed
        if (block.timestamp < targetCycleEnd) {
            vm.warp(targetCycleEnd);
        }

        vm.prank(mktParams.creditLine);
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(_id, block.timestamp, borrowers, repaymentBps, balances);
    }

    function _makePayment(address borrower, uint256 amount) internal {
        deal(address(loanToken), borrower, amount);
        vm.prank(borrower);
        morpho.repay(marketParams, amount, 0, borrower, "");
    }

    function _triggerAccrual() internal {
        // Supply 1 wei to trigger accrual without significantly changing the market
        deal(address(loanToken), address(this), 1);
        loanToken.approve(address(morpho), 1);
        morpho.supply(marketParams, 1, 0, address(this), "");
    }

    function _triggerBorrowerAccrual(address borrower) internal {
        IMorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, _toArray(borrower));
    }

    function _toArray(address value) internal pure virtual returns (address[] memory) {
        address[] memory array = new address[](1);
        array[0] = value;
        return array;
    }

    function _getRepaymentDetails(Id _id, address borrower)
        internal
        view
        returns (uint128 cycleId, uint128 amountDue, uint128 endingBalance, RepaymentStatus status)
    {
        (cycleId, amountDue, endingBalance) = IMorphoCredit(address(morpho)).repaymentObligation(_id, borrower);
        (status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), _id, borrower);
    }

    function _calculatePenaltyInterest(uint256 endingBalance, uint256 penaltyDuration, uint256 penaltyRate)
        internal
        pure
        returns (uint256)
    {
        return uint256(endingBalance).wMulDown(penaltyRate.wTaylorCompounded(penaltyDuration));
    }

    function _assertRepaymentStatus(Id _id, address borrower, RepaymentStatus expectedStatus) internal {
        (RepaymentStatus actualStatus,) =
            MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), _id, borrower);
        assertEq(uint256(actualStatus), uint256(expectedStatus), "Unexpected repayment status");
    }

    function _setupBorrowerWithLoan(address borrower, uint256 creditLimit, uint128 premiumRate, uint256 borrowAmount)
        internal
    {
        // Setup credit line
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, borrower, creditLimit, premiumRate);

        // Execute borrow
        if (borrowAmount > 0) {
            deal(address(loanToken), borrower, borrowAmount);
            vm.prank(borrower);
            morpho.borrow(marketParams, borrowAmount, 0, borrower, borrower);
        }
    }

    // Simplified overload used by markdown tests
    function _setupBorrowerWithLoan(address borrower, uint256 amount) internal {
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, borrower, amount * 2, 0);

        vm.prank(borrower);
        morpho.borrow(marketParams, amount, 0, borrower, borrower);
    }

    // Helper for creating past obligations (used by markdown tests)
    /// @notice Continues market cycles up to a target time to prevent MarketFrozen errors
    /// @param marketId The market to continue cycles for
    /// @param targetTime The timestamp to continue cycles up to
    function _continueMarketCycles(Id marketId, uint256 targetTime) internal {
        // Get the correct market params for this market ID
        MarketParams memory mktParams = morpho.idToMarketParams(marketId);

        // Only continue cycles if market has a credit line
        if (mktParams.creditLine == address(0)) return;

        uint256 cycleLength = MorphoCreditLib.getPaymentCycleLength(IMorphoCredit(address(morpho)), marketId);

        // If no cycles exist yet, initialize first cycle
        if (cycleLength == 0) {
            uint256 firstCycleEnd = block.timestamp > CYCLE_DURATION ? block.timestamp : CYCLE_DURATION;
            vm.warp(firstCycleEnd);

            address[] memory borrowers = new address[](0);
            uint256[] memory repaymentBps = new uint256[](0);
            uint256[] memory endingBalances = new uint256[](0);

            vm.prank(mktParams.creditLine);
            IMorphoCredit(address(morpho))
                .closeCycleAndPostObligations(marketId, firstCycleEnd, borrowers, repaymentBps, endingBalances);
            cycleLength = 1;
        }

        // Continue posting cycles until we reach target time
        while (true) {
            (, uint256 lastCycleEnd) =
                MorphoCreditLib.getCycleDates(IMorphoCredit(address(morpho)), marketId, cycleLength - 1);
            uint256 nextCycleEnd = lastCycleEnd + CYCLE_DURATION;

            // Stop if next cycle would be beyond target time
            if (nextCycleEnd > targetTime) break;

            // Post empty cycle
            vm.warp(nextCycleEnd);
            address[] memory borrowers = new address[](0);
            uint256[] memory repaymentBps = new uint256[](0);
            uint256[] memory endingBalances = new uint256[](0);

            vm.prank(mktParams.creditLine);
            IMorphoCredit(address(morpho))
                .closeCycleAndPostObligations(marketId, nextCycleEnd, borrowers, repaymentBps, endingBalances);

            cycleLength++;
        }

        // Finally warp to target time
        if (block.timestamp < targetTime) {
            vm.warp(targetTime);
        }
    }

    /// @notice Ensures a market with credit line is active (not frozen)
    /// @param marketId The market to check and unfreeze if needed
    function _ensureMarketActive(Id marketId) internal {
        // Get the correct market params for this market ID
        MarketParams memory mktParams = morpho.idToMarketParams(marketId);

        if (mktParams.creditLine == address(0)) return;

        uint256 cycleLength = MorphoCreditLib.getPaymentCycleLength(IMorphoCredit(address(morpho)), marketId);

        if (cycleLength == 0) {
            // Initialize first cycle
            _continueMarketCycles(marketId, block.timestamp + CYCLE_DURATION);
        } else {
            // Check if market is frozen and post new cycle if needed
            (, uint256 lastCycleEnd) =
                MorphoCreditLib.getCycleDates(IMorphoCredit(address(morpho)), marketId, cycleLength - 1);
            uint256 expectedNextEnd = lastCycleEnd + CYCLE_DURATION;

            if (block.timestamp > expectedNextEnd) {
                // Market is frozen, post a new cycle
                uint256 newCycleEnd = block.timestamp;
                address[] memory borrowers = new address[](0);
                uint256[] memory repaymentBps = new uint256[](0);
                uint256[] memory endingBalances = new uint256[](0);

                vm.prank(mktParams.creditLine);
                IMorphoCredit(address(morpho))
                    .closeCycleAndPostObligations(marketId, newCycleEnd, borrowers, repaymentBps, endingBalances);
            }
        }
    }

    function _createPastObligation(address borrower, uint256 repaymentBps, uint256 endingBalance) internal {
        // Ensure enough time has passed for a new cycle
        uint256 cycleLength = MorphoCreditLib.getPaymentCycleLength(IMorphoCredit(address(morpho)), id);
        uint256 minTimeForNextCycle = CYCLE_DURATION + 1 days;

        if (cycleLength > 0) {
            // Get the last cycle's end date and ensure we're past the minimum duration
            (, uint256 lastCycleEnd) =
                MorphoCreditLib.getCycleDates(IMorphoCredit(address(morpho)), id, cycleLength - 1);
            uint256 timeNeeded = lastCycleEnd + CYCLE_DURATION + 1 days;
            if (block.timestamp < timeNeeded) {
                vm.warp(timeNeeded);
            }
        } else {
            // If no cycles exist, warp forward enough to create one
            vm.warp(block.timestamp + minTimeForNextCycle);
        }

        uint256 cycleEndDate = block.timestamp - 1 days;

        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;

        uint256[] memory bpsList = new uint256[](1);
        bpsList[0] = repaymentBps;

        uint256[] memory balances = new uint256[](1);
        balances[0] = endingBalance;

        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, bpsList, balances);
    }
}
