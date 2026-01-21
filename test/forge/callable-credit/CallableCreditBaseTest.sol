// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {CallableCredit} from "../../../src/CallableCredit.sol";
import {ICallableCredit} from "../../../src/interfaces/ICallableCredit.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {WaUSDCMock} from "../mocks/WaUSDCMock.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../../../src/libraries/SharesMathLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {ProtocolConfigLib} from "../../../src/libraries/ProtocolConfigLib.sol";

/// @title CallableCreditBaseTest
/// @notice Base test setup for CallableCredit tests
contract CallableCreditBaseTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    // Callable Credit specific actors
    address internal COUNTER_PROTOCOL;
    address internal COUNTER_PROTOCOL_2;
    address internal BORROWER_1;
    address internal BORROWER_2;
    address internal RECIPIENT;

    // Contracts
    CallableCredit internal callableCredit;
    CreditLineMock internal creditLine;
    WaUSDCMock internal wausdc;
    ERC20Mock internal usdc;

    // Market with credit line
    MarketParams internal ccMarketParams;
    Id internal ccMarketId;

    // Test amounts
    uint256 internal constant CREDIT_LINE_AMOUNT = 1_000_000e6; // 1M USDC
    uint256 internal constant DEFAULT_OPEN_AMOUNT = 100_000e6; // 100k USDC
    uint256 internal constant SUPPLY_AMOUNT = 10_000_000e6; // 10M USDC for liquidity

    function setUp() public virtual override {
        super.setUp();

        // Create additional actors
        COUNTER_PROTOCOL = makeAddr("CounterProtocol");
        COUNTER_PROTOCOL_2 = makeAddr("CounterProtocol2");
        BORROWER_1 = makeAddr("Borrower1");
        BORROWER_2 = makeAddr("Borrower2");
        RECIPIENT = makeAddr("Recipient");

        // Deploy USDC mock (underlying)
        usdc = new ERC20Mock();
        vm.label(address(usdc), "USDC");

        // Deploy waUSDC mock (ERC4626 wrapper)
        wausdc = new WaUSDCMock(address(usdc));
        vm.label(address(wausdc), "waUSDC");

        // Deploy credit line mock
        creditLine = new CreditLineMock(address(morpho));

        // Create market params with waUSDC as loan token and credit line
        ccMarketParams = MarketParams({
            loanToken: address(wausdc),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: DEFAULT_TEST_LLTV,
            creditLine: address(creditLine)
        });
        ccMarketId = ccMarketParams.id();

        // Enable LLTV and create market
        vm.startPrank(OWNER);
        if (!morpho.isLltvEnabled(DEFAULT_TEST_LLTV)) {
            morpho.enableLltv(DEFAULT_TEST_LLTV);
        }
        morpho.createMarket(ccMarketParams);
        vm.stopPrank();

        // Initialize first cycle to unfreeze the market
        _initializeMarketCycle();

        // Deploy CallableCredit
        callableCredit = new CallableCredit(address(morpho), address(wausdc), address(protocolConfig), ccMarketId);
        vm.label(address(callableCredit), "CallableCredit");

        // Authorize CallableCredit in MorphoCredit to borrow on behalf of users
        vm.prank(OWNER);
        IMorphoCredit(address(morpho)).setCallableCredit(address(callableCredit));

        // Authorize counter-protocol
        vm.prank(OWNER);
        callableCredit.setAuthorizedCounterProtocol(COUNTER_PROTOCOL, true);

        // Set default CC caps to unlimited (>= 10000 bps = 100%)
        vm.startPrank(OWNER);
        protocolConfig.setConfig(ProtocolConfigLib.CC_DEBT_CAP_BPS, 10000);
        protocolConfig.setConfig(ProtocolConfigLib.CC_CREDIT_LINE_BPS, 10000);
        vm.stopPrank();

        // Setup approvals
        _setupApprovals();

        // Supply liquidity to the market
        _supplyLiquidity(SUPPLY_AMOUNT);
    }

    // ============ Setup Helpers ============

    function _initializeMarketCycle() internal {
        vm.warp(block.timestamp + CYCLE_DURATION);
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(ccMarketId, block.timestamp, borrowers, repaymentBps, endingBalances);
    }

    function _setupApprovals() internal {
        // waUSDC approvals for morpho
        vm.prank(address(callableCredit));
        IERC20(address(wausdc)).approve(address(morpho), type(uint256).max);

        // USDC approvals for waUSDC
        vm.prank(SUPPLIER);
        usdc.approve(address(wausdc), type(uint256).max);
    }

    function _supplyLiquidity(uint256 amount) internal {
        // Mint USDC to supplier
        usdc.setBalance(SUPPLIER, amount);

        // Supplier deposits USDC into waUSDC
        vm.startPrank(SUPPLIER);
        wausdc.deposit(amount, SUPPLIER);

        // Supplier approves morpho
        IERC20(address(wausdc)).approve(address(morpho), type(uint256).max);

        // Supplier supplies waUSDC to morpho market
        morpho.supply(ccMarketParams, amount, 0, SUPPLIER, "");
        vm.stopPrank();
    }

    // ============ Test Helpers ============

    /// @notice Set up a borrower with a credit line in MorphoCredit
    /// @dev Also grants max allowance to COUNTER_PROTOCOL and COUNTER_PROTOCOL_2 for convenience
    function _setupBorrowerWithCreditLine(address borrower, uint256 creditAmount) internal {
        creditLine.setCreditLine(ccMarketId, borrower, creditAmount, 0);
        // Grant max allowance to both counter-protocols for convenience in existing tests
        vm.startPrank(borrower);
        callableCredit.approve(COUNTER_PROTOCOL, type(uint256).max);
        callableCredit.approve(COUNTER_PROTOCOL_2, type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Approve counter-protocol allowance for a borrower
    function _approveBorrowerAllowance(address borrower, address counterProtocol, uint256 amount) internal {
        vm.prank(borrower);
        callableCredit.approve(counterProtocol, amount);
    }

    /// @notice Authorize a counter-protocol
    function _authorizeCounterProtocol(address counterProtocol) internal {
        vm.prank(OWNER);
        callableCredit.setAuthorizedCounterProtocol(counterProtocol, true);
    }

    /// @notice Open a position via counter-protocol
    function _openPosition(address counterProtocol, address borrower, uint256 usdcAmount) internal {
        vm.prank(counterProtocol);
        callableCredit.open(borrower, usdcAmount);
    }

    /// @notice Set waUSDC max redeem limit (simulates Aave liquidity constraints)
    function _setMaxRedeem(uint256 amount) internal {
        wausdc.setMaxRedeem(amount);
    }

    /// @notice Set waUSDC exchange rate (simulates appreciation)
    function _setExchangeRate(uint256 rate) internal {
        wausdc.setExchangeRate(rate);
    }

    /// @notice Freeze callable credit
    function _freezeCallableCredit() internal {
        vm.prank(OWNER);
        protocolConfig.setEmergencyConfig(keccak256("CC_FROZEN"), 1);
    }

    /// @notice Get borrower's debt in MorphoCredit
    function _getBorrowerDebt(address borrower) internal view returns (uint256) {
        uint128 borrowShares = IMorpho(address(morpho)).position(ccMarketId, borrower).borrowShares;
        if (borrowShares == 0) return 0;

        Market memory m = IMorpho(address(morpho)).market(ccMarketId);
        if (m.totalBorrowShares == 0) return 0;

        return uint256(borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
    }

    /// @notice Repay debt directly to MorphoCredit (bypassing CallableCredit)
    function _repayDirectToMorpho(address borrower, uint256 waUsdcAmount) internal {
        // Mint waUSDC for repayment
        usdc.setBalance(address(this), waUsdcAmount);
        usdc.approve(address(wausdc), waUsdcAmount);
        wausdc.deposit(waUsdcAmount, address(this));

        // Approve and repay
        IERC20(address(wausdc)).approve(address(morpho), waUsdcAmount);
        morpho.repay(ccMarketParams, waUsdcAmount, 0, borrower, "");
    }
}
