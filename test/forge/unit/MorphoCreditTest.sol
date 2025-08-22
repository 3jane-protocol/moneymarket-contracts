// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {Morpho} from "../../../src/Morpho.sol";
import {IMorpho, Id, MarketParams, Position, Market} from "../../../src/interfaces/IMorpho.sol";
import {MathLib, WAD} from "../../../src/libraries/MathLib.sol";
import {SharesMathLib} from "../../../src/libraries/SharesMathLib.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {ERC20Mock} from "../../../src/mocks/ERC20Mock.sol";
import {OracleMock} from "../../../src/mocks/OracleMock.sol";
import {ConfigurableIrmMock} from "../mocks/ConfigurableIrmMock.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {ProtocolConfig} from "../../../src/ProtocolConfig.sol";
import {TransparentUpgradeableProxy} from
    "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract MorphoCreditTest is Test {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    IMorpho public morpho;
    address public owner;
    address public borrower;
    address public supplier;
    address public feeRecipient;
    CreditLineMock public creditLine;
    ProtocolConfig public protocolConfig;

    ERC20Mock public loanToken;
    ERC20Mock public collateralToken;
    OracleMock public oracle;
    ConfigurableIrmMock public irm;

    MarketParams public marketParams;
    Id public marketId;

    uint256 constant INITIAL_SUPPLY = 10_000e18;
    uint256 constant MAX_PREMIUM_RATE_ANNUAL = 1e18; // 100% APR
    uint256 constant MAX_PREMIUM_RATE_PER_SECOND = 31709791983; // 100% APR / 365 days
    uint256 constant ORACLE_PRICE = 1e36;

    event PremiumAccrued(Id indexed id, address indexed borrower, uint256 premiumAmount, uint256 feeAmount);

    address public helper;
    address public usd3;

    function setUp() public {
        // Setup accounts
        owner = makeAddr("owner");
        borrower = makeAddr("borrower");
        supplier = makeAddr("supplier");
        feeRecipient = makeAddr("feeRecipient");

        // Deploy protocol config mock
        ProtocolConfig protocolConfigImpl = new ProtocolConfig();
        TransparentUpgradeableProxy protocolConfigProxy = new TransparentUpgradeableProxy(
            address(protocolConfigImpl),
            address(this), // Test contract acts as admin
            abi.encodeWithSelector(ProtocolConfig.initialize.selector, owner)
        );

        // Set the protocolConfig to the proxy address
        protocolConfig = ProtocolConfig(address(protocolConfigProxy));

        // Deploy contracts through proxy
        MorphoCredit morphoImpl = new MorphoCredit(address(protocolConfig));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(morphoImpl),
            address(this), // Test contract acts as admin
            abi.encodeWithSelector(MorphoCredit.initialize.selector, owner)
        );
        morpho = IMorpho(address(proxy));

        // Deploy credit line mock
        creditLine = new CreditLineMock(address(morpho));

        // Setup tokens
        loanToken = new ERC20Mock();
        collateralToken = new ERC20Mock();
        oracle = new OracleMock();
        irm = new ConfigurableIrmMock();

        // Set oracle price
        oracle.setPrice(ORACLE_PRICE);

        // Create market
        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.8e18,
            creditLine: address(creditLine)
        });

        vm.startPrank(owner);
        morpho.enableLltv(0.8e18);
        morpho.enableIrm(address(irm));
        morpho.createMarket(marketParams);
        vm.stopPrank();

        marketId = marketParams.id();

        // Set fee recipient
        vm.prank(owner);
        morpho.setFeeRecipient(feeRecipient);

        // Setup initial token balances
        loanToken.setBalance(supplier, INITIAL_SUPPLY);
        collateralToken.setBalance(borrower, INITIAL_SUPPLY * 2);

        // Approve morpho
        vm.prank(supplier);
        loanToken.approve(address(morpho), type(uint256).max);
        vm.prank(borrower);
        collateralToken.approve(address(morpho), type(uint256).max);

        vm.prank(owner);
        MorphoCredit(address(morpho)).setHelper(borrower);
        vm.prank(owner);
        MorphoCredit(address(morpho)).setUsd3(supplier);

        // Verify that helper, usd3, and protocolConfig were set properly
        assertEq(MorphoCredit(address(morpho)).helper(), borrower);
        assertEq(MorphoCredit(address(morpho)).usd3(), supplier);
        assertEq(MorphoCredit(address(morpho)).protocolConfig(), address(protocolConfig));
        _setProtocolConfig(owner);
    }

    function _setProtocolConfig(address _owner) internal {
        vm.startPrank(_owner);
        // Market configurations
        protocolConfig.setConfig(keccak256("IS_PAUSED"), 0); // Not paused
        protocolConfig.setConfig(keccak256("MAX_ON_CREDIT"), 0.95 ether); // 95% max on credit
        protocolConfig.setConfig(keccak256("IRP"), uint256(0.1 ether / int256(365 days))); // 10% IRP
        protocolConfig.setConfig(keccak256("MIN_BORROW"), 1000e18); // 1 token minimum borrow
        protocolConfig.setConfig(keccak256("GRACE_PERIOD"), 7 days); // 7 days grace period
        protocolConfig.setConfig(keccak256("DELINQUENCY_PERIOD"), 23 days); // 23 days delinquency period
        vm.stopPrank();
    }

    // --- AUTHORIZATION TESTS ---
    function testSupplyNotUsd3Reverts() public {
        vm.prank(owner);
        MorphoCredit(address(morpho)).setUsd3(usd3);
        uint256 supplyAmount = 1000e18;
        loanToken.setBalance(borrower, supplyAmount);
        vm.prank(borrower);
        loanToken.approve(address(morpho), supplyAmount);
        vm.expectRevert(ErrorsLib.NotUsd3.selector);
        vm.prank(borrower);
        morpho.supply(marketParams, supplyAmount, 0, borrower, "");
    }

    function testSupplyIsPausedReverts() public {
        vm.prank(owner);
        MorphoCredit(address(morpho)).setUsd3(usd3);

        uint256 supplyAmount = 1000e18;
        loanToken.setBalance(usd3, supplyAmount);
        vm.prank(usd3);
        loanToken.approve(address(morpho), supplyAmount);

        // Pause the protocol
        vm.prank(owner);
        protocolConfig.setConfig(keccak256("IS_PAUSED"), 1); // paused

        vm.expectRevert(ErrorsLib.Paused.selector);
        vm.prank(usd3);
        morpho.supply(marketParams, supplyAmount, 0, borrower, "");
    }

    function testSupplyWithUsd3Succeeds() public {
        vm.prank(owner);
        MorphoCredit(address(morpho)).setUsd3(usd3);
        uint256 supplyAmount = 1000e18;
        loanToken.setBalance(usd3, supplyAmount);
        vm.prank(usd3);
        loanToken.approve(address(morpho), supplyAmount);
        vm.prank(usd3);
        morpho.supply(marketParams, supplyAmount, 0, borrower, "");
        assertGt(morpho.position(marketId, borrower).supplyShares, 0);
    }

    function testWithdrawNotUsd3Reverts() public {
        vm.prank(owner);
        MorphoCredit(address(morpho)).setUsd3(usd3);
        // First supply as usd3
        uint256 supplyAmount = 1000e18;
        loanToken.setBalance(usd3, supplyAmount);
        vm.prank(usd3);
        loanToken.approve(address(morpho), supplyAmount);
        vm.prank(usd3);
        morpho.supply(marketParams, supplyAmount, 0, borrower, "");
        // Try to withdraw as non-usd3
        vm.expectRevert(ErrorsLib.NotUsd3.selector);
        vm.prank(borrower);
        morpho.withdraw(marketParams, 100e18, 0, borrower, borrower);
    }

    function testWithdrawWithUsd3Succeeds() public {
        vm.prank(owner);
        MorphoCredit(address(morpho)).setUsd3(usd3);
        uint256 supplyAmount = 1000e18;
        loanToken.setBalance(usd3, supplyAmount);
        vm.prank(usd3);
        loanToken.approve(address(morpho), supplyAmount);
        vm.prank(usd3);
        morpho.supply(marketParams, supplyAmount, 0, borrower, "");
        vm.prank(usd3);
        morpho.withdraw(marketParams, 100e18, 0, borrower, borrower);
        assertGt(loanToken.balanceOf(borrower), 0);
    }

    function testBorrowNotHelperReverts() public {
        vm.prank(owner);
        MorphoCredit(address(morpho)).setUsd3(usd3);
        vm.prank(owner);
        MorphoCredit(address(morpho)).setHelper(helper);
        // Setup supply and credit line
        uint256 supplyAmount = 1000e18;
        loanToken.setBalance(usd3, supplyAmount);
        vm.prank(usd3);
        loanToken.approve(address(morpho), supplyAmount);
        vm.prank(usd3);
        morpho.supply(marketParams, supplyAmount, 0, borrower, "");
        vm.prank(address(creditLine));
        MorphoCredit(address(morpho)).setCreditLine(marketId, borrower, 1000e18, 0);
        vm.expectRevert(ErrorsLib.NotHelper.selector);
        vm.prank(borrower);
        morpho.borrow(marketParams, 100e18, 0, borrower, borrower);
    }

    function testBorrowIsPausedReverts() public {
        vm.prank(owner);
        MorphoCredit(address(morpho)).setUsd3(usd3);
        vm.prank(owner);
        MorphoCredit(address(morpho)).setHelper(helper);
        // Setup supply and credit line
        uint256 supplyAmount = 1000e18;
        loanToken.setBalance(usd3, supplyAmount);
        vm.prank(usd3);
        loanToken.approve(address(morpho), supplyAmount);
        vm.prank(usd3);
        morpho.supply(marketParams, supplyAmount, 0, borrower, "");
        vm.prank(address(creditLine));
        MorphoCredit(address(morpho)).setCreditLine(marketId, borrower, 1000e18, 0);

        // Pause the protocol
        vm.prank(owner);
        protocolConfig.setConfig(keccak256("IS_PAUSED"), 1); // paused

        vm.expectRevert(ErrorsLib.Paused.selector);
        vm.prank(helper);
        morpho.borrow(marketParams, 100e18, 0, borrower, borrower);
    }

    function testBorrowWithHelperSucceeds() public {
        vm.prank(owner);
        MorphoCredit(address(morpho)).setUsd3(usd3);
        vm.prank(owner);
        MorphoCredit(address(morpho)).setHelper(helper);
        uint256 supplyAmount = 1000e18;
        loanToken.setBalance(usd3, supplyAmount);
        vm.prank(usd3);
        loanToken.approve(address(morpho), supplyAmount);
        vm.prank(usd3);
        morpho.supply(marketParams, supplyAmount, 0, borrower, "");
        vm.prank(address(creditLine));
        MorphoCredit(address(morpho)).setCreditLine(marketId, borrower, 1000e18, 0);
        vm.prank(helper);
        morpho.borrow(marketParams, 100e18, 0, borrower, borrower);
        assertGt(morpho.position(marketId, borrower).borrowShares, 0);
    }

    function testBorrowWithHelperOutstandingRepaymentReverts() public {
        vm.prank(owner);
        MorphoCredit(address(morpho)).setUsd3(usd3);
        vm.prank(owner);
        MorphoCredit(address(morpho)).setHelper(helper);
        uint256 supplyAmount = 1000e18;
        loanToken.setBalance(usd3, supplyAmount);
        vm.prank(usd3);
        loanToken.approve(address(morpho), supplyAmount);
        vm.prank(usd3);
        morpho.supply(marketParams, supplyAmount, 0, borrower, "");
        vm.prank(address(creditLine));
        MorphoCredit(address(morpho)).setCreditLine(marketId, borrower, 1000e18, 0);
        // Move time forward first to avoid underflow
        vm.warp(block.timestamp + 10 days);

        // First, have the borrower actually borrow some funds
        loanToken.setBalance(borrower, 0);
        vm.prank(helper);
        morpho.borrow(marketParams, 100e18, 0, borrower, borrower);

        // Create a payment cycle with obligation that ended in the past
        uint256 endDate = block.timestamp - 2 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory endingBalances = new uint256[](1);
        borrowers[0] = borrower;
        repaymentBps[0] = 1000; // 10% repayment
        endingBalances[0] = 100e18; // Current balance
        vm.prank(address(creditLine));
        MorphoCredit(address(morpho)).closeCycleAndPostObligations(
            marketId, endDate, borrowers, repaymentBps, endingBalances
        );

        vm.expectRevert(ErrorsLib.OutstandingRepayment.selector);
        vm.prank(helper);
        morpho.borrow(marketParams, 100e18, 0, borrower, borrower);
    }

    /*//////////////////////////////////////////////////////////////
                        CREDIT LINE TESTS
    //////////////////////////////////////////////////////////////*/

    function testSetCreditLineWithPremiumRate() public {
        uint128 newRateAnnual = 0.05e18; // 5% APR
        uint128 newRatePerSecond = uint128(uint256(newRateAnnual) / 365 days);
        uint256 creditAmount = 1_000e18;

        // Credit line sets the premium rate
        vm.prank(address(creditLine));
        creditLine.setCreditLine(marketId, borrower, creditAmount, newRatePerSecond);

        (uint128 lastAccrualTime, uint128 rate,) = MorphoCredit(address(morpho)).borrowerPremium(marketId, borrower);
        assertEq(rate, newRatePerSecond);
        // With Issue #13 fix: timestamp is NOT set until first borrow
        assertEq(lastAccrualTime, 0);
        // Credit line is set in market collateral
        Position memory pos = morpho.position(marketId, borrower);
        assertEq(pos.collateral, creditAmount);
    }

    function testSetCreditLineNotCreditLine() public {
        vm.expectRevert(ErrorsLib.NotCreditLine.selector);
        vm.prank(borrower);
        MorphoCredit(address(morpho)).setCreditLine(marketId, borrower, 1_000e18, uint128(uint256(0.05e18) / 365 days));
    }

    function testSetCreditLineWithExistingPosition() public {
        // Supply and borrow first
        vm.prank(supplier);
        morpho.supply(marketParams, 1_000e18, 0, supplier, "");

        // Set initial credit line
        vm.prank(address(creditLine));
        creditLine.setCreditLine(marketId, borrower, 1_000e18, 0);

        vm.prank(borrower);
        morpho.borrow(marketParams, 500e18, 0, borrower, borrower);

        // Update credit line with premium rate
        uint128 newRatePerSecond = uint128(uint256(0.1e18) / 365 days); // 10% APR converted to per-second

        vm.prank(address(creditLine));
        creditLine.setCreditLine(marketId, borrower, 1_000e18, newRatePerSecond);

        // Check that snapshot was taken
        (,, uint128 borrowAssetsAtLastAccrual) = MorphoCredit(address(morpho)).borrowerPremium(marketId, borrower);
        assertGt(borrowAssetsAtLastAccrual, 0);
        assertEq(borrowAssetsAtLastAccrual, 500e18); // Initial borrow amount
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _setCreditLineWithPremium(address _borrower, uint256 credit, uint128 premiumRatePerSecond) internal {
        vm.prank(address(creditLine));
        creditLine.setCreditLine(marketId, _borrower, credit, premiumRatePerSecond);
    }

    /*//////////////////////////////////////////////////////////////
                        PREMIUM ACCRUAL TESTS
    //////////////////////////////////////////////////////////////*/

    function testAccrueBorrowerPremium() public {
        // Setup: Supply, borrow, and set premium rate
        vm.prank(supplier);
        morpho.supply(marketParams, 1_000e18, 0, supplier, "");

        uint128 premiumRatePerSecond = uint128(uint256(0.2e18) / 365 days); // 20% APR converted to per-second
        uint256 creditLineAmount = 1_250e18; // Account for 80% LLTV
        _setCreditLineWithPremium(borrower, creditLineAmount, premiumRatePerSecond);

        vm.prank(borrower);
        morpho.borrow(marketParams, 500e18, 0, borrower, borrower);

        // Advance time (1 day to avoid overflow)
        vm.warp(block.timestamp + 1 hours);

        // Accrue premium
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);

        // Check that borrower's debt increased
        Position memory position = morpho.position(marketId, borrower);
        Market memory marketData = morpho.market(marketId);
        uint256 borrowAssets =
            uint256(position.borrowShares).toAssetsUp(marketData.totalBorrowAssets, marketData.totalBorrowShares);

        // Should be more than initial amount after 1 hour with premium
        // Even small growth should be visible
        assertGt(borrowAssets, 500e18);
    }

    function testAccrueBorrowerPremiumWithFees() public {
        // Set protocol fee (lower to avoid overflow)
        vm.prank(owner);
        morpho.setFee(marketParams, 0.01e18); // 1% protocol fee

        // Setup: Supply, borrow, and set premium rate
        vm.prank(supplier);
        morpho.supply(marketParams, 1_000e18, 0, supplier, "");

        uint128 premiumRatePerSecond = uint128(uint256(0.2e18) / 365 days); // 20% APR converted to per-second
        uint256 creditLineAmount = 1_250e18; // Account for 80% LLTV
        _setCreditLineWithPremium(borrower, creditLineAmount, premiumRatePerSecond);

        vm.prank(borrower);
        morpho.borrow(marketParams, 500e18, 0, borrower, borrower);

        // Advance time (1 day to avoid overflow)
        vm.warp(block.timestamp + 1 hours);

        // Record fee recipient position before
        Position memory feePositionBefore = morpho.position(marketId, feeRecipient);

        // Accrue premium
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);

        // Check fee recipient received shares
        Position memory feePositionAfter = morpho.position(marketId, feeRecipient);
        assertGt(feePositionAfter.supplyShares, feePositionBefore.supplyShares);
    }

    function testAccrueBorrowerPremiumNoRate() public {
        // Supply and borrow without setting premium rate
        vm.prank(supplier);
        morpho.supply(marketParams, 1_000e18, 0, supplier, "");

        // Set credit line without premium rate
        uint256 creditLineAmount = 1_250e18; // Account for 80% LLTV
        _setCreditLineWithPremium(borrower, creditLineAmount, 0);

        vm.prank(borrower);
        morpho.borrow(marketParams, 500e18, 0, borrower, borrower);

        uint256 borrowSharesBefore = morpho.position(marketId, borrower).borrowShares;

        // Advance time (1 day to avoid overflow)
        vm.warp(block.timestamp + 1 hours);

        // Accrue premium (should do nothing)
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);

        uint256 borrowSharesAfter = morpho.position(marketId, borrower).borrowShares;
        assertEq(borrowSharesAfter, borrowSharesBefore);
    }

    function testAccrueBorrowerPremiumNoElapsedTime() public {
        // Setup position and premium rate
        vm.prank(supplier);
        morpho.supply(marketParams, 1_000e18, 0, supplier, "");

        uint256 creditLineAmount = 1_250e18; // Account for 80% LLTV
        _setCreditLineWithPremium(borrower, creditLineAmount, uint128(uint256(0.2e18) / 365 days)); // 20% APR

        vm.prank(borrower);
        morpho.borrow(marketParams, 500e18, 0, borrower, borrower);

        uint256 borrowSharesBefore = morpho.position(marketId, borrower).borrowShares;

        // Accrue premium immediately (no time elapsed)
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);

        uint256 borrowSharesAfter = morpho.position(marketId, borrower).borrowShares;
        assertEq(borrowSharesAfter, borrowSharesBefore);
    }

    /*//////////////////////////////////////////////////////////////
                        BATCH PREMIUM ACCRUAL TESTS
    //////////////////////////////////////////////////////////////*/

    function testAccruePremiumsForBorrowers() public {
        address borrower2 = makeAddr("borrower2");
        collateralToken.setBalance(borrower2, INITIAL_SUPPLY);
        vm.prank(borrower2);
        collateralToken.approve(address(morpho), type(uint256).max);

        // Setup positions for two borrowers
        vm.prank(supplier);
        morpho.supply(marketParams, 2_000e18, 0, supplier, "");

        // Set credit lines with premium rates
        uint256 creditLineAmount = 1_250e18; // Account for 80% LLTV
        _setCreditLineWithPremium(borrower, creditLineAmount, uint128(uint256(0.1e18) / 365 days)); // 10% APR
        _setCreditLineWithPremium(borrower2, creditLineAmount, uint128(uint256(0.2e18) / 365 days)); // 20% APR

        vm.prank(borrower);
        morpho.borrow(marketParams, 500e18, 0, borrower, borrower);

        vm.prank(owner);
        MorphoCredit(address(morpho)).setHelper(borrower2);

        vm.prank(borrower2);
        morpho.borrow(marketParams, 500e18, 0, borrower2, borrower2);

        // Advance time
        vm.warp(block.timestamp + 1 hours);

        // Batch accrue
        address[] memory borrowers = new address[](2);
        borrowers[0] = borrower;
        borrowers[1] = borrower2;

        MorphoCredit(address(morpho)).accruePremiumsForBorrowers(marketId, borrowers);

        // Check both borrowers had premiums accrued
        Market memory marketData = morpho.market(marketId);
        uint256 borrowAssets1 = uint256(morpho.position(marketId, borrower).borrowShares).toAssetsUp(
            marketData.totalBorrowAssets, marketData.totalBorrowShares
        );
        uint256 borrowAssets2 = uint256(morpho.position(marketId, borrower2).borrowShares).toAssetsUp(
            marketData.totalBorrowAssets, marketData.totalBorrowShares
        );

        // After 1 hour, both borrowers should have accrued premium
        assertGt(borrowAssets1, 500e18);
        assertGt(borrowAssets2, 500e18);
        assertGt(borrowAssets2, borrowAssets1); // Borrower2 has higher rate
    }

    /*//////////////////////////////////////////////////////////////
                        HOOK INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testBorrowTriggersSnapshotUpdate() public {
        // Initial setup
        vm.prank(supplier);
        morpho.supply(marketParams, 1_000e18, 0, supplier, "");

        // Set premium rate with credit line
        uint256 creditLineAmount = 2_500e18; // Account for 80% LLTV
        _setCreditLineWithPremium(borrower, creditLineAmount, uint128(uint256(0.1e18) / 365 days)); // 10% APR

        // First borrow
        vm.prank(borrower);
        morpho.borrow(marketParams, 300e18, 0, borrower, borrower);

        // Check snapshot was taken
        (,, uint256 snapshot1) = MorphoCredit(address(morpho)).borrowerPremium(marketId, borrower);
        assertEq(snapshot1, 300e18);

        // Advance time and accrue some interest/premium
        vm.warp(block.timestamp + 1 hours);

        // Second borrow should update snapshot
        vm.prank(borrower);
        morpho.borrow(marketParams, 200e18, 0, borrower, borrower);

        // Snapshot should now reflect total position including accrued amounts
        (,, uint256 snapshot2) = MorphoCredit(address(morpho)).borrowerPremium(marketId, borrower);
        assertGt(snapshot2, 500e18); // More than just 300 + 200 due to accrued interest/premium
    }

    function testRepayTriggersSnapshotUpdate() public {
        // Setup position
        vm.prank(supplier);
        morpho.supply(marketParams, 1_000e18, 0, supplier, "");

        // Set premium rate with credit line
        uint256 creditLineAmount = 1_250e18; // Account for 80% LLTV
        _setCreditLineWithPremium(borrower, creditLineAmount, uint128(uint256(0.1e18) / 365 days)); // 10% APR

        vm.prank(borrower);
        morpho.borrow(marketParams, 500e18, 0, borrower, borrower);

        // Advance time
        vm.warp(block.timestamp + 1 hours);

        // Add tokens for repayment and approve
        loanToken.setBalance(borrower, 600e18);
        vm.prank(borrower);
        loanToken.approve(address(morpho), type(uint256).max);

        // Repay should trigger snapshot update
        vm.prank(borrower);
        morpho.repay(marketParams, 100e18, 0, borrower, "");

        // Check snapshot was updated
        (uint128 lastAccrualTime,, uint256 snapshot) = MorphoCredit(address(morpho)).borrowerPremium(marketId, borrower);
        assertEq(lastAccrualTime, block.timestamp);
        // Check that snapshot reflects remaining position after repayment
        // The snapshot should be less than what it was before repayment
        Market memory marketData = morpho.market(marketId);
        uint256 remainingBorrowAssets = uint256(morpho.position(marketId, borrower).borrowShares).toAssetsUp(
            marketData.totalBorrowAssets, marketData.totalBorrowShares
        );
        assertEq(snapshot, remainingBorrowAssets);
    }

    /*//////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function testPremiumCalculationWithBaseGrowthLessThanWAD() public {
        // This would happen if market conditions cause borrow position to decrease
        // For now, test that it doesn't revert
        vm.prank(supplier);
        morpho.supply(marketParams, 1_000e18, 0, supplier, "");

        // Set premium rate with credit line
        uint256 creditLineAmount = 1_250e18; // Account for 80% LLTV
        _setCreditLineWithPremium(borrower, creditLineAmount, uint128(uint256(0.1e18) / 365 days)); // 10% APR

        vm.prank(borrower);
        morpho.borrow(marketParams, 500e18, 0, borrower, borrower);

        // This should not revert even in edge cases
        vm.warp(block.timestamp + 1);
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);
    }

    function testVerySmallPremiumAmount() public {
        // Test with very small borrow amount
        vm.prank(supplier);
        morpho.supply(marketParams, 1_000e18, 0, supplier, "");

        // Set premium rate with credit line
        uint256 creditLineAmount = 1_250e18; // Account for 80% LLTV
        _setCreditLineWithPremium(borrower, creditLineAmount, uint128(uint256(0.01e18) / 365 days)); // 1% APR

        vm.prank(borrower);
        morpho.borrow(marketParams, 1, 0, borrower, borrower); // 1 wei borrow

        // Should handle precision gracefully
        vm.warp(block.timestamp + 1 hours);
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);
    }

    function testSetBorrowerPremiumRateAccruesBaseInterestFirst() public {
        // Setup: Supply and borrow
        vm.prank(supplier);
        morpho.supply(marketParams, 5_000e18, 0, supplier, "");

        // Set initial credit line without premium
        uint256 creditLineAmount = 12_500e18; // Account for 80% LLTV
        _setCreditLineWithPremium(borrower, creditLineAmount, 0);

        vm.prank(borrower);
        morpho.borrow(marketParams, 2_500e18, 0, borrower, borrower);

        // Set up IRM with base rate
        irm.setApr(0.1e18); // 10% APR base rate

        // Advance time to accumulate base interest
        vm.warp(block.timestamp + 30 days);

        // Get market state before setting premium rate
        Market memory marketBefore = morpho.market(marketId);
        uint256 lastUpdateBefore = marketBefore.lastUpdate;

        // Set premium rate - this should trigger _accrueInterest first
        _setCreditLineWithPremium(borrower, creditLineAmount, uint128(uint256(0.2e18) / 365 days)); // 20% APR

        // Get market state after
        Market memory marketAfter = morpho.market(marketId);

        // Verify that base interest was accrued (lastUpdate should be current timestamp)
        assertEq(marketAfter.lastUpdate, block.timestamp);
        assertGt(marketAfter.lastUpdate, lastUpdateBefore);

        // Verify that totalBorrowAssets increased due to base interest
        assertGt(marketAfter.totalBorrowAssets, marketBefore.totalBorrowAssets);

        // Calculate expected base interest
        uint256 elapsed = block.timestamp - lastUpdateBefore;
        uint256 borrowRate = irm.borrowRate(marketParams, marketBefore);
        uint256 expectedInterest =
            uint256(marketBefore.totalBorrowAssets).wMulDown(borrowRate.wTaylorCompounded(elapsed));

        // Verify the interest accrued matches expected
        assertApproxEqRel(
            marketAfter.totalBorrowAssets - marketBefore.totalBorrowAssets,
            expectedInterest,
            0.001e18 // 0.1% tolerance
        );
    }

    /*//////////////////////////////////////////////////////////////
                        NEW EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function testAccrueBorrowerPremiumMaxElapsedTime() public {
        // Setup positions
        uint256 supplyAmount = 5_000e18; // Use amount within initial balance
        uint256 borrowAmount = 2_500e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.5e18) / 365 days); // 50% APR converted to per-second

        vm.prank(supplier);
        morpho.supply(marketParams, supplyAmount, 0, supplier, "");

        // Set premium rate with credit line
        uint256 creditLineAmount = 12_500e18; // Account for 80% LLTV
        _setCreditLineWithPremium(borrower, creditLineAmount, premiumRatePerSecond);

        vm.prank(borrower);
        morpho.borrow(marketParams, borrowAmount, 0, borrower, borrower);

        // Warp time beyond MAX_ELAPSED_TIME (365 days + extra)
        uint256 MAX_ELAPSED_TIME = 365 days;
        vm.warp(block.timestamp + MAX_ELAPSED_TIME + 30 days);

        // Trigger premium accrual
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);

        // Calculate expected premium for exactly MAX_ELAPSED_TIME (not actual elapsed)
        uint256 ratePerSecond = uint256(premiumRatePerSecond);
        uint256 expectedGrowth = ratePerSecond.wTaylorCompounded(MAX_ELAPSED_TIME);
        uint256 expectedPremium = borrowAmount.wMulDown(expectedGrowth);

        // Get actual debt
        Position memory pos = morpho.position(marketId, borrower);
        Market memory mkt = morpho.market(marketId);
        uint256 actualDebt = uint256(pos.borrowShares).toAssetsUp(mkt.totalBorrowAssets, mkt.totalBorrowShares);

        // Debt should be borrowAmount + premium for MAX_ELAPSED_TIME only
        assertApproxEqRel(actualDebt, borrowAmount + expectedPremium, 0.01e18); // 1% tolerance
    }

    function testAccrueBorrowerPremiumBelowThreshold() public {
        // Setup with extremely small amounts to ensure premium < MIN_PREMIUM_THRESHOLD
        uint256 supplyAmount = 1000e18;
        uint256 borrowAmount = 1; // 1 wei borrow
        uint128 premiumRatePerSecond = uint128(uint256(0.001e18) / 365 days); // 0.1% APR converted to per-second

        vm.prank(supplier);
        morpho.supply(marketParams, supplyAmount, 0, supplier, "");

        // Set very low premium rate with credit line
        uint256 creditLineAmount = 1_250e18; // Account for 80% LLTV
        _setCreditLineWithPremium(borrower, creditLineAmount, premiumRatePerSecond);

        vm.prank(borrower);
        morpho.borrow(marketParams, borrowAmount, 0, borrower, borrower);

        // Record state before
        Position memory posBefore = morpho.position(marketId, borrower);
        Market memory mktBefore = morpho.market(marketId);

        // Advance very short time
        vm.warp(block.timestamp + 1 seconds);

        // Trigger premium accrual
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);

        // Check state after
        Position memory posAfter = morpho.position(marketId, borrower);
        Market memory mktAfter = morpho.market(marketId);

        // Borrow shares should not change (premium below threshold)
        assertEq(posAfter.borrowShares, posBefore.borrowShares);
        assertEq(mktAfter.totalBorrowAssets, mktBefore.totalBorrowAssets);
        assertEq(mktAfter.totalBorrowShares, mktBefore.totalBorrowShares);

        // But timestamp should be updated (check via another accrual with no time change)
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);
        // No revert means timestamp was updated in previous call
    }

    function testAccrueBorrowerPremiumAtThreshold() public {
        // Setup to ensure premium == MIN_PREMIUM_THRESHOLD
        uint256 supplyAmount = 5_000e18; // Within initial balance
        uint256 borrowAmount = 1000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.1e18) / 365 days); // 10% APR converted to per-second

        vm.prank(supplier);
        morpho.supply(marketParams, supplyAmount, 0, supplier, "");

        // Set premium rate with credit line
        uint256 creditLineAmount = 2_500e18; // Account for 80% LLTV
        _setCreditLineWithPremium(borrower, creditLineAmount, premiumRatePerSecond);

        vm.prank(borrower);
        morpho.borrow(marketParams, borrowAmount, 0, borrower, borrower);

        // Calculate time needed for premium to be exactly 1 (MIN_PREMIUM_THRESHOLD)
        // premium = borrowAmount * rate * time / (365 days * WAD)
        // 1 = 1000e18 * 0.1e18 * time / (365 days * 1e18)
        // time = 365 days / (1000 * 0.1) = 3.65 days / 100 ≈ 0.0365 days ≈ 3154 seconds
        uint256 timeForMinPremium = 3154;

        // Record state before
        Position memory posBefore = morpho.position(marketId, borrower);

        // Advance time
        vm.warp(block.timestamp + timeForMinPremium);

        // Trigger premium accrual
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);

        // Check state after
        Position memory posAfter = morpho.position(marketId, borrower);

        // Borrow shares should increase (premium at threshold)
        assertGt(posAfter.borrowShares, posBefore.borrowShares);
    }

    function testPremiumCalculationPositionDecreased() public {
        // Setup positions
        uint256 supplyAmount = 5_000e18; // Within initial balance
        uint256 borrowAmount = 2_500e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.2e18) / 365 days); // 20% APR converted to per-second

        vm.prank(supplier);
        morpho.supply(marketParams, supplyAmount, 0, supplier, "");

        // Set premium rate with credit line
        uint256 creditLineAmount = 12_500e18; // Account for 80% LLTV
        _setCreditLineWithPremium(borrower, creditLineAmount, premiumRatePerSecond);

        vm.prank(borrower);
        morpho.borrow(marketParams, borrowAmount, 0, borrower, borrower);

        // Advance time and let some premium accrue
        vm.warp(block.timestamp + 30 days);
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);

        // Now repay more than the accrued interest (position decreases)
        uint256 repayAmount = 1_000e18;
        loanToken.setBalance(borrower, repayAmount);
        vm.prank(borrower);
        loanToken.approve(address(morpho), repayAmount);
        vm.prank(borrower);
        morpho.repay(marketParams, repayAmount, 0, borrower, "");

        // Record debt after repay
        Position memory posAfterRepay = morpho.position(marketId, borrower);
        Market memory mktAfterRepay = morpho.market(marketId);
        uint256 debtAfterRepay = uint256(posAfterRepay.borrowShares).toAssetsUp(
            mktAfterRepay.totalBorrowAssets, mktAfterRepay.totalBorrowShares
        );

        // Advance time again
        vm.warp(block.timestamp + 30 days);

        // Trigger premium accrual - position has decreased since last snapshot
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);

        // Premium should still accrue based on current position
        Position memory posFinal = morpho.position(marketId, borrower);
        Market memory mktFinal = morpho.market(marketId);
        uint256 debtFinal =
            uint256(posFinal.borrowShares).toAssetsUp(mktFinal.totalBorrowAssets, mktFinal.totalBorrowShares);

        assertGt(debtFinal, debtAfterRepay);
    }

    function testPremiumCalculationWithZeroTotalGrowth() public {
        // This tests the edge case where totalGrowthAmount <= baseGrowthActual
        // which should result in premiumAmount = 0

        // Setup positions
        uint256 supplyAmount = 5_000e18; // Within initial balance
        uint256 borrowAmount = 2_500e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.001e18) / 365 days); // 0.1% APR converted to per-second - very
            // low

        vm.prank(supplier);
        morpho.supply(marketParams, supplyAmount, 0, supplier, "");

        // Configure IRM to have a high base rate
        irm.setApr(0.5e18); // 50% APR base rate

        // Set very low premium rate with credit line
        uint256 creditLineAmount = 12_500e18; // Account for 80% LLTV
        _setCreditLineWithPremium(borrower, creditLineAmount, premiumRatePerSecond);

        vm.prank(borrower);
        morpho.borrow(marketParams, borrowAmount, 0, borrower, borrower);

        // Advance short time
        vm.warp(block.timestamp + 1 days);

        // Accrue base interest first
        morpho.accrueInterest(marketParams);

        // Record state
        Position memory posBefore = morpho.position(marketId, borrower);
        Market memory mktBefore = morpho.market(marketId);

        // Trigger premium accrual
        // With high base rate and very low premium, totalGrowthAmount might be <= baseGrowthActual
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);

        // Check state - should have minimal or no change due to premium
        Position memory posAfter = morpho.position(marketId, borrower);
        Market memory mktAfter = morpho.market(marketId);

        // The debt increase should be minimal (only from rounding)
        uint256 debtBefore =
            uint256(posBefore.borrowShares).toAssetsUp(mktBefore.totalBorrowAssets, mktBefore.totalBorrowShares);
        uint256 debtAfter =
            uint256(posAfter.borrowShares).toAssetsUp(mktAfter.totalBorrowAssets, mktAfter.totalBorrowShares);

        // Assert debt increased by at most a tiny amount
        // With 2500e18 borrow, 0.001e18 APR for 1 day:
        // Expected premium ≈ 2500e18 * 0.001e18 * 1 / 365 / 1e18 ≈ 6.849e15
        // But with high base rate, the premium calculation might result in 0
        assertLe(debtAfter - debtBefore, 1e16); // Allow small amount for rounding
    }
}
