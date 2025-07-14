// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../lib/forge-std/src/Test.sol";
import "../../lib/forge-std/src/console.sol";

import {IMorpho, IMorphoCredit} from "../../src/interfaces/IMorpho.sol";
import "../../src/interfaces/IMorphoCallbacks.sol";
import {IrmMock} from "../../src/mocks/IrmMock.sol";
import {ERC20Mock} from "../../src/mocks/ERC20Mock.sol";
import {OracleMock} from "../../src/mocks/OracleMock.sol";

import "../../src/Morpho.sol";
import "../../src/MorphoCredit.sol";
import {Math} from "./helpers/Math.sol";
import {SigUtils} from "./helpers/SigUtils.sol";
import {ArrayLib} from "./helpers/ArrayLib.sol";
import {MorphoLib} from "../../src/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "../../src/libraries/periphery/MorphoBalancesLib.sol";
import {TransparentUpgradeableProxy} from
    "../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract BaseTest is Test {
    using Math for uint256;
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using ArrayLib for address[];
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
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

        // Deploy implementation
        MorphoCredit morphoImpl = new MorphoCredit();

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

        vm.startPrank(BORROWER);
        loanToken.approve(address(morpho), type(uint256).max);
        collateralToken.approve(address(morpho), type(uint256).max);

        vm.startPrank(REPAYER);
        loanToken.approve(address(morpho), type(uint256).max);
        collateralToken.approve(address(morpho), type(uint256).max);

        vm.startPrank(LIQUIDATOR);
        loanToken.approve(address(morpho), type(uint256).max);
        collateralToken.approve(address(morpho), type(uint256).max);

        vm.startPrank(ONBEHALF);
        loanToken.approve(address(morpho), type(uint256).max);
        collateralToken.approve(address(morpho), type(uint256).max);
        morpho.setAuthorization(BORROWER, true);
        vm.stopPrank();

        _setLltv(DEFAULT_TEST_LLTV);
    }

    function _setLltv(uint256 lltv) internal {
        marketParams =
            MarketParams(address(loanToken), address(collateralToken), address(oracle), address(irm), lltv, address(0));
        id = marketParams.id();

        vm.startPrank(OWNER);
        if (!morpho.isLltvEnabled(lltv)) morpho.enableLltv(lltv);
        if (morpho.lastUpdate(marketParams.id()) == 0) morpho.createMarket(marketParams);
        vm.stopPrank();

        _forward(1);
    }

    /// @dev Rolls & warps the given number of blocks forward the blockchain.
    function _forward(uint256 blocks) internal {
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * BLOCK_TIME); // Block speed should depend on test network.
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
            MAX_TEST_AMOUNT.toSharesDown(morpho.totalSupplyAssets(_id), morpho.totalSupplyShares(_id)).zeroFloorSub(
                supplyShares
            )
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
        uint256 cycleEndDate = block.timestamp - (daysAgo * 1 days);
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = borrower;
        // Calculate basis points from amountDue and endingBalance
        repaymentBps[0] = amountDue * 10000 / endingBalance;
        balances[0] = endingBalance;

        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            _id, cycleEndDate, borrowers, repaymentBps, balances
        );
    }

    // Overloaded version that accepts repaymentBps directly
    function _createRepaymentObligationBps(
        Id _id,
        address borrower,
        uint256 repaymentBps,
        uint256 endingBalance,
        uint256 daysAgo
    ) internal {
        uint256 cycleEndDate = block.timestamp - (daysAgo * 1 days);
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBpsArray = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = borrower;
        repaymentBpsArray[0] = repaymentBps;
        balances[0] = endingBalance;

        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            _id, cycleEndDate, borrowers, repaymentBpsArray, balances
        );
    }

    function _createMultipleObligations(
        Id _id,
        address[] memory borrowers,
        uint256[] memory repaymentBps,
        uint256[] memory balances,
        uint256 daysAgo
    ) internal {
        uint256 cycleEndDate = block.timestamp - (daysAgo * 1 days);

        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            _id, cycleEndDate, borrowers, repaymentBps, balances
        );
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
        // Trigger borrower-specific accrual using the public accrueBorrowerPremium function
        // This works even for borrowers with outstanding repayments
        IMorphoCredit(address(morpho)).accrueBorrowerPremium(id, borrower);
    }

    function _getRepaymentDetails(Id _id, address borrower)
        internal
        view
        returns (uint128 cycleId, uint128 amountDue, uint256 endingBalance, RepaymentStatus status)
    {
        (cycleId, amountDue, endingBalance) = IMorphoCredit(address(morpho)).repaymentObligation(_id, borrower);
        (status,) = IMorphoCredit(address(morpho)).getRepaymentStatus(_id, borrower);
    }

    function _calculatePenaltyInterest(uint256 endingBalance, uint256 penaltyDuration, uint256 penaltyRate)
        internal
        pure
        returns (uint256)
    {
        return endingBalance.wMulDown(penaltyRate.wTaylorCompounded(penaltyDuration));
    }

    function _assertRepaymentStatus(Id _id, address borrower, RepaymentStatus expectedStatus) internal {
        (RepaymentStatus actualStatus,) = IMorphoCredit(address(morpho)).getRepaymentStatus(_id, borrower);
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
    function _createPastObligation(address borrower, uint256 repaymentBps, uint256 endingBalance) internal {
        // First forward time to allow for a past cycle
        vm.warp(block.timestamp + 2 days);
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
