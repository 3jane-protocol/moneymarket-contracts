// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.sol";
import {ConfigurableIrmMock} from "../../mocks/ConfigurableIrmMock.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {MarkdownManagerMock} from "../../../../src/mocks/MarkdownManagerMock.sol";
import {Market, Position} from "../../../../src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "../../../../src/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoStorageLib} from "../../../../src/libraries/periphery/MorphoStorageLib.sol";
import {SharesMathLib} from "../../../../src/libraries/SharesMathLib.sol";
import {EventsLib} from "../../../../src/libraries/EventsLib.sol";
import {MAX_FEE} from "../../../../src/libraries/ConstantsLib.sol";

/// @title SupplySharePriceFloorTest
/// @notice Regression tests for supply-share growth after credit losses.
contract SupplySharePriceFloorTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;

    uint256 internal constant SUPPLY_SHARE_PRICE_FLOOR_RATIO = 1e15;

    CreditLineMock internal creditLine;
    MarkdownManagerMock internal markdownManager;
    IMorphoCredit internal morphoCredit;

    function setUp() public override {
        super.setUp();

        creditLine = new CreditLineMock(morphoAddress);
        markdownManager = new MarkdownManagerMock(address(protocolConfig), OWNER);
        morphoCredit = IMorphoCredit(morphoAddress);

        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(0),
            lltv: DEFAULT_TEST_LLTV,
            creditLine: address(creditLine)
        });
        id = marketParams.id();

        vm.startPrank(OWNER);
        morpho.createMarket(marketParams);
        markdownManager.setEnableMarkdown(BORROWER, true);
        protocolConfig.setConfig(keccak256("IRP"), 0);
        vm.stopPrank();
        creditLine.setMm(address(markdownManager));

        _ensureMarketActive(id);
    }

    function testFeeZeroTwoCycleLossCannotOverflowSupplyShares() public {
        uint256 assets = 1 ether;
        uint256 firstCycleShares = _supplyFrom(SUPPLIER, assets);
        assertLe(firstCycleShares, assets * SUPPLY_SHARE_PRICE_FLOOR_RATIO, "first-cycle shares exceed bound");

        _setupBorrowerWithLoan(BORROWER, assets);
        _moveToDefaultAndTouch(BORROWER, assets);

        assertTrue(morphoCredit.marketInWindDown(id), "full-book markdown should wind down market");

        vm.prank(address(creditLine));
        morphoCredit.settleAccount(marketParams, BORROWER);

        Market memory beforeSecondCycle = morpho.market(id);
        uint256 quotedSecondCycleShares =
            assets.toSharesDown(beforeSecondCycle.totalSupplyAssets, beforeSecondCycle.totalSupplyShares);

        assertLe(quotedSecondCycleShares, assets * SUPPLY_SHARE_PRICE_FLOOR_RATIO, "second-cycle quote exceeds bound");
        _assertSupplySharePriceFloor(beforeSecondCycle);

        loanToken.setBalance(SUPPLIER, assets);
        vm.expectRevert(ErrorsLib.MarketInWindDown.selector);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, assets, 0, SUPPLIER, "");

        Market memory afterSecondCycle = morpho.market(id);
        assertEq(afterSecondCycle.totalSupplyShares, beforeSecondCycle.totalSupplyShares, "shares changed on rejection");
        assertLt(afterSecondCycle.totalSupplyShares, type(uint128).max, "supply shares saturated");
        assertEq(morpho.expectedSupplyAssets(marketParams, SUPPLIER), afterSecondCycle.totalSupplyAssets);
    }

    function testMarkdownReversalFromFloorRestoresExactly() public {
        uint256 assets = 1 ether;
        _supplyFrom(SUPPLIER, assets);
        _setupBorrowerWithLoan(BORROWER, assets);
        _moveToDefaultAndTouch(BORROWER, assets);

        Market memory atFloor = morpho.market(id);
        uint256 appliedMarkdown = atFloor.totalMarkdownAmount;
        uint256 supplySharesBefore = atFloor.totalSupplyShares;
        assertGt(appliedMarkdown, 0, "markdown not applied");
        _assertSupplySharePriceFloor(atFloor);

        Position memory borrowerPosition = morpho.position(id, BORROWER);
        loanToken.setBalance(BORROWER, assets);
        vm.prank(BORROWER);
        morpho.repay(marketParams, 0, borrowerPosition.borrowShares, BORROWER, "");

        Market memory cured = morpho.market(id);
        assertEq(
            cured.totalSupplyAssets,
            uint256(atFloor.totalSupplyAssets) + appliedMarkdown,
            "cure did not reverse applied markdown"
        );
        assertEq(cured.totalSupplyAssets, assets, "supply assets not restored exactly");
        assertEq(cured.totalMarkdownAmount, 0, "markdown tally not cleared");
        assertEq(cured.totalSupplyShares, supplySharesBefore, "supply shares changed on cure");
        assertEq(
            cured.totalSupplyShares,
            morpho.position(id, SUPPLIER).supplyShares + morpho.position(id, FEE_RECIPIENT).supplyShares,
            "market supply shares differ from position sum"
        );
        assertTrue(morphoCredit.marketInWindDown(id), "wind-down cleared without governance");
    }

    function testFloorTruncatedBorrowerCureRestoresOnlyAppliedMarkdown() public {
        uint256 assets = 1 ether;
        _supplyFrom(SUPPLIER, 2 * assets);
        _setupBorrowerWithLoan(BORROWER, assets);
        _setupBorrowerWithLoan(ONBEHALF, assets);

        vm.prank(OWNER);
        markdownManager.setEnableMarkdown(ONBEHALF, true);

        address[] memory borrowers = new address[](2);
        borrowers[0] = BORROWER;
        borrowers[1] = ONBEHALF;
        uint256[] memory bpsList = new uint256[](2);
        bpsList[0] = 10_000;
        bpsList[1] = 10_000;
        uint256[] memory balances = new uint256[](2);
        balances[0] = assets;
        balances[1] = assets;
        _createMultipleObligations(id, borrowers, bpsList, balances, 0);

        markdownManager.setMarkdownForBorrower(BORROWER, assets);
        markdownManager.setMarkdownForBorrower(ONBEHALF, assets);
        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);

        uint256 minAssets = _minSupplyAssets(morpho.market(id).totalSupplyShares);
        uint256 appliedForOnBehalf = assets - minAssets;

        // BORROWER's full markdown applies first; ONBEHALF's is truncated at the floor.
        vm.expectEmit(true, true, false, true, address(morphoCredit));
        emit EventsLib.BorrowerMarkdownUpdated(id, ONBEHALF, 0, appliedForOnBehalf);
        morphoCredit.accruePremiumsForBorrowers(id, borrowers);

        Market memory atFloor = morpho.market(id);
        assertEq(atFloor.totalSupplyAssets, minAssets, "second markdown did not stop at floor");
        assertTrue(morphoCredit.marketInWindDown(id), "truncated markdown did not wind down market");
        assertEq(atFloor.totalMarkdownAmount, assets + appliedForOnBehalf, "market markdown tally");
        assertEq(morphoCredit.markdownState(id, BORROWER), assets, "untruncated stored markdown");
        assertEq(
            morphoCredit.markdownState(id, ONBEHALF), appliedForOnBehalf, "stored markdown exceeds applied markdown"
        );

        // The truncated borrower cures in full; only the markdown applied for it may be restored.
        Position memory onBehalfPosition = morpho.position(id, ONBEHALF);
        loanToken.setBalance(ONBEHALF, assets);
        vm.prank(ONBEHALF);
        morpho.repay(marketParams, 0, onBehalfPosition.borrowShares, ONBEHALF, "");

        Market memory afterCure = morpho.market(id);
        assertEq(afterCure.totalSupplyAssets, assets, "cure restored more than was applied for the borrower");
        assertEq(afterCure.totalMarkdownAmount, assets, "cure consumed the defaulted borrower's markdown");
        assertEq(morphoCredit.markdownState(id, ONBEHALF), 0, "cured borrower markdown not cleared");

        // Settle the still-defaulted borrower; supply must not exceed the tokens actually backing the market.
        vm.prank(address(creditLine));
        morphoCredit.settleAccount(marketParams, BORROWER);

        Market memory settled = morpho.market(id);
        assertEq(settled.totalBorrowAssets, 0, "borrow assets not cleared");
        assertEq(settled.totalMarkdownAmount, 0, "markdown tally not cleared");
        assertEq(
            settled.totalSupplyAssets,
            loanToken.balanceOf(address(morpho)),
            "supply assets exceed tokens backing the market"
        );
        _assertSupplySharePriceFloor(settled);
    }

    function testWithdrawThenMarkdownUsesSaturatingAvailableAssets() public {
        uint256 assets = 1 ether;
        _supplyFrom(SUPPLIER, assets);
        _setupBorrowerWithLoan(BORROWER, 1);

        // Model a legacy market whose denominator had already collapsed before this implementation was installed.
        Market memory legacy = morpho.market(id);
        _setSupplyTotals(10, legacy.totalSupplyShares);

        vm.prank(SUPPLIER);
        morpho.withdraw(marketParams, 9, 0, SUPPLIER, SUPPLIER);

        Market memory afterWithdraw = morpho.market(id);
        uint256 minAssets = _minSupplyAssets(afterWithdraw.totalSupplyShares);
        assertEq(afterWithdraw.totalSupplyAssets, 1, "unexpected post-withdraw assets");
        assertLt(afterWithdraw.totalSupplyAssets, minAssets, "test did not construct T below the floor");

        _moveToDefaultAndTouch(BORROWER, 1);

        Market memory afterMarkdown = morpho.market(id);
        assertEq(afterMarkdown.totalSupplyAssets, afterWithdraw.totalSupplyAssets, "markdown reduced protected assets");
        assertEq(afterMarkdown.totalMarkdownAmount, 0, "unapplied markdown was recorded");
        assertTrue(morphoCredit.marketInWindDown(id), "truncated markdown did not wind down market");
    }

    function testMaxFeeAccrualAtFloorKeepsFeeSharesBounded() public {
        ConfigurableIrmMock feeIrm = new ConfigurableIrmMock();
        feeIrm.setApr(0.1 ether);

        marketParams.irm = address(feeIrm);
        id = marketParams.id();

        vm.startPrank(OWNER);
        morpho.enableIrm(address(feeIrm));
        morpho.createMarket(marketParams);
        morpho.setFee(marketParams, MAX_FEE);
        vm.stopPrank();
        _ensureMarketActive(id);

        uint256 assets = 1 ether;
        _supplyFrom(SUPPLIER, assets);
        _setupBorrowerWithLoan(BORROWER, assets * 2, uint128(PREMIUM_RATE_PER_SECOND), assets);
        _moveToDefaultAndTouch(BORROWER, type(uint256).max);

        assertTrue(morphoCredit.marketInWindDown(id), "full markdown did not reach floor");
        _assertSupplySharePriceFloor(morpho.market(id));

        uint256 totalInterest;
        uint256 totalFeeShares;
        for (uint256 i = 0; i < 8; i++) {
            Market memory beforeAccrual = morpho.market(id);
            uint256 feeSharesBefore = morpho.position(id, FEE_RECIPIENT).supplyShares;

            _continueMarketCycles(id, block.timestamp + 1 days);
            morphoCredit.accruePremiumsForBorrowers(id, _toArray(BORROWER));

            Market memory afterAccrual = morpho.market(id);
            uint256 interest = uint256(afterAccrual.totalBorrowAssets) - beforeAccrual.totalBorrowAssets;
            uint256 feeShares = morpho.position(id, FEE_RECIPIENT).supplyShares - feeSharesBefore;
            uint256 maxFeeShares = (interest * MAX_FEE / 1 ether) * SUPPLY_SHARE_PRICE_FLOOR_RATIO;

            assertGt(interest, 0, "no interest accrued");
            assertLe(feeShares, maxFeeShares, "fee shares exceed 25% interest times floor ratio");
            // This exact per-iteration floor check carries the fee-path regression: pre-floor code leaves T at zero.
            assertEq(
                afterAccrual.totalSupplyAssets,
                _minSupplyAssets(afterAccrual.totalSupplyShares),
                "full markdown did not restore exact floor after fee issuance"
            );
            _assertSupplySharePriceFloor(afterAccrual);

            totalInterest += interest;
            totalFeeShares += feeShares;
        }

        assertGt(totalInterest, 0, "loop accrued no interest");
        assertGt(totalFeeShares, 0, "loop issued no fee shares");
        assertLt(morpho.market(id).totalSupplyShares, type(uint128).max, "fee shares saturated accumulator");
        morpho.expectedSupplyAssets(marketParams, FEE_RECIPIENT);
    }

    function testSettlementLossFloorWithoutMarkdownManager() public {
        creditLine.setMm(address(0));

        uint256 assets = 1 ether;
        _supplyFrom(SUPPLIER, assets);
        _setupBorrowerWithLoan(BORROWER, assets);

        vm.prank(address(creditLine));
        morphoCredit.settleAccount(marketParams, BORROWER);

        Market memory settled = morpho.market(id);
        assertEq(settled.totalSupplyAssets, _minSupplyAssets(settled.totalSupplyShares), "loss did not stop at floor");
        assertEq(settled.totalBorrowAssets, 0, "borrow assets not cleared");
        assertEq(settled.totalBorrowShares, 0, "borrow shares not cleared");
        assertEq(settled.totalMarkdownAmount, 0, "market without manager recorded markdown");
        assertTrue(morphoCredit.marketInWindDown(id), "truncated settlement did not wind down market");
        _assertSupplySharePriceFloor(settled);
    }

    function testSettlementAtExactFloorTripsWindDown() public {
        creditLine.setMm(address(0));

        uint256 assets = 1 ether;
        _supplyFrom(SUPPLIER, assets);

        Market memory supplied = morpho.market(id);
        uint256 protectedAssets = _minSupplyAssets(supplied.totalSupplyShares);
        uint256 exactFloorLoss = uint256(supplied.totalSupplyAssets) - protectedAssets;
        _setupBorrowerWithLoan(BORROWER, exactFloorLoss);

        vm.prank(address(creditLine));
        morphoCredit.settleAccount(marketParams, BORROWER);

        Market memory settled = morpho.market(id);
        assertEq(settled.totalSupplyAssets, protectedAssets, "settlement did not land at exact floor");
        assertTrue(morphoCredit.marketInWindDown(id), "exact-floor settlement did not trip wind-down");
        _assertSupplySharePriceFloor(settled);
    }

    function testWindDownTripsAtExactFloorAndLeavesExitPathsOpen() public {
        uint256 assets = 1 ether;
        _supplyFrom(SUPPLIER, assets);
        _setupBorrowerWithLoan(BORROWER, assets);

        Market memory supplied = morpho.market(id);
        uint256 available = uint256(supplied.totalSupplyAssets) - _minSupplyAssets(supplied.totalSupplyShares);
        _moveToDefaultAndTouch(BORROWER, available);

        assertEq(
            morpho.market(id).totalSupplyAssets,
            _minSupplyAssets(supplied.totalSupplyShares),
            "exact markdown did not land at the floor"
        );
        assertTrue(morphoCredit.marketInWindDown(id), "exact-floor markdown did not trip wind-down");
        assertEq(morpho.market(id).totalMarkdownAmount, available, "exact markdown was truncated");

        markdownManager.setMarkdownForBorrower(BORROWER, assets);
        morphoCredit.accruePremiumsForBorrowers(id, _toArray(BORROWER));
        assertTrue(morphoCredit.marketInWindDown(id), "truncated markdown did not trip wind-down");

        loanToken.setBalance(SUPPLIER, 1);
        vm.expectRevert(ErrorsLib.MarketInWindDown.selector);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 1, 0, SUPPLIER, "");

        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, ONBEHALF, assets, 0);
        vm.expectRevert(ErrorsLib.MarketInWindDown.selector);
        vm.prank(ONBEHALF);
        morpho.borrow(marketParams, 1, 0, ONBEHALF, ONBEHALF);

        Position memory borrowerPosition = morpho.position(id, BORROWER);
        loanToken.setBalance(BORROWER, assets);
        vm.prank(BORROWER);
        morpho.repay(marketParams, 0, borrowerPosition.borrowShares, BORROWER, "");

        vm.prank(address(creditLine));
        morphoCredit.settleAccount(marketParams, BORROWER);

        vm.prank(SUPPLIER);
        morpho.withdraw(marketParams, 1, 0, SUPPLIER, SUPPLIER);

        assertTrue(morphoCredit.marketInWindDown(id), "exit paths cleared wind-down");
    }

    function testSettleFullyTruncatedBorrowerOnLegacySubFloorMarketSaturates() public {
        uint256 assets = 1 ether;
        _supplyFrom(SUPPLIER, assets);
        _setupBorrowerWithLoan(BORROWER, assets / 2);

        // Model a legacy market whose supply collapsed below the floor before this implementation was installed.
        Market memory legacy = morpho.market(id);
        _setSupplyTotals(10, legacy.totalSupplyShares);

        // No capacity above the floor remains, so the borrower's markdown increase is fully truncated.
        _moveToDefaultAndTouch(BORROWER, assets / 2);
        assertEq(morphoCredit.markdownState(id, BORROWER), 0, "truncated markdown was stored");
        assertTrue(morphoCredit.marketInWindDown(id), "full truncation did not wind down market");

        // Settlement must saturate at the protected assets instead of reverting: wind-down blocks new supply,
        // so a revert here would make the bad debt permanently unwritable.
        vm.prank(address(creditLine));
        morphoCredit.settleAccount(marketParams, BORROWER);

        Market memory settled = morpho.market(id);
        assertEq(settled.totalBorrowAssets, 0, "borrow assets not cleared");
        assertEq(settled.totalBorrowShares, 0, "borrow shares not cleared");
        assertEq(settled.totalSupplyAssets, 10, "settlement changed protected assets");
        assertEq(settled.totalMarkdownAmount, 0, "markdown tally not cleared");
        assertTrue(morphoCredit.marketInWindDown(id), "settlement cleared wind-down");
    }

    function testSupplyConsistencyCheckIncludesVirtualShares() public {
        uint256 assets = 1 ether;
        _supplyFrom(SUPPLIER, assets);

        _setSupplyTotals(0, uint128(SUPPLY_SHARE_PRICE_FLOOR_RATIO - SharesMathLib.VIRTUAL_SHARES + 1));

        loanToken.setBalance(SUPPLIER, assets);
        vm.expectRevert(ErrorsLib.SupplySharePriceBelowFloor.selector);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, assets, 0, SUPPLIER, "");
    }

    function testBorrowConsistencyCheckRejectsLegacyMarketBelowFloor() public {
        uint256 assets = 1 ether;
        _supplyFrom(SUPPLIER, assets);

        uint128 totalSupplyAssets = 1;
        uint128 totalSupplyShares = uint128(
            (uint256(totalSupplyAssets) + 1) * SUPPLY_SHARE_PRICE_FLOOR_RATIO - SharesMathLib.VIRTUAL_SHARES + 1
        );
        _setSupplyTotals(totalSupplyAssets, totalSupplyShares);

        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, assets, 0);
        vm.expectRevert(ErrorsLib.SupplySharePriceBelowFloor.selector);
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 1, 0, BORROWER, BORROWER);
    }

    function testGovernanceCanClearWindDownOnlyAfterTwoTimesMarginRecovery() public {
        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        vm.prank(OWNER);
        morphoCredit.clearMarketWindDown(id);

        uint256 assets = 1 ether;
        _supplyFrom(SUPPLIER, assets);
        _setupBorrowerWithLoan(BORROWER, assets);
        _moveToDefaultAndTouch(BORROWER, assets);
        assertTrue(morphoCredit.marketInWindDown(id), "markdown did not trip wind-down");

        vm.expectRevert(ErrorsLib.NotOwner.selector);
        vm.prank(BORROWER);
        morphoCredit.clearMarketWindDown(id);

        vm.expectRevert(ErrorsLib.SupplySharePriceBelowFloor.selector);
        vm.prank(OWNER);
        morphoCredit.clearMarketWindDown(id);

        Position memory borrowerPosition = morpho.position(id, BORROWER);
        loanToken.setBalance(BORROWER, assets);
        vm.prank(BORROWER);
        morpho.repay(marketParams, 0, borrowerPosition.borrowShares, BORROWER, "");

        Market memory recovered = morpho.market(id);
        assertLe(
            uint256(recovered.totalSupplyShares) + SharesMathLib.VIRTUAL_SHARES,
            (uint256(recovered.totalSupplyAssets) + 1) * (SUPPLY_SHARE_PRICE_FLOOR_RATIO / 2),
            "market did not recover two-times reopening margin"
        );

        vm.expectEmit(true, false, false, false, address(morphoCredit));
        emit EventsLib.MarketWindDownCleared(id);
        vm.prank(OWNER);
        morphoCredit.clearMarketWindDown(id);
        assertFalse(morphoCredit.marketInWindDown(id), "governance did not clear wind-down");

        _supplyFrom(SUPPLIER, 1 ether);

        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, ONBEHALF, assets, 0);
        vm.prank(ONBEHALF);
        morpho.borrow(marketParams, 1, 0, ONBEHALF, ONBEHALF);
        assertEq(morpho.expectedBorrowAssets(marketParams, ONBEHALF), 1, "borrowing not re-enabled");
    }

    function _supplyFrom(address supplier, uint256 assets) internal returns (uint256 shares) {
        loanToken.setBalance(supplier, assets);
        vm.prank(supplier);
        (, shares) = morpho.supply(marketParams, assets, 0, supplier, "");
    }

    function _moveToDefaultAndTouch(address borrower, uint256 markdown) internal {
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, borrower);
        _createPastObligation(borrower, 10_000, borrowAssets);
        markdownManager.setMarkdownForBorrower(borrower, markdown);
        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);
        morphoCredit.accruePremiumsForBorrowers(id, _toArray(borrower));
    }

    function _minSupplyAssets(uint256 totalSupplyShares) internal pure returns (uint256) {
        return (totalSupplyShares + SharesMathLib.VIRTUAL_SHARES - 1) / SUPPLY_SHARE_PRICE_FLOOR_RATIO;
    }

    function _assertSupplySharePriceFloor(Market memory marketState) internal pure {
        assertLe(
            uint256(marketState.totalSupplyShares) + SharesMathLib.VIRTUAL_SHARES,
            SUPPLY_SHARE_PRICE_FLOOR_RATIO * (uint256(marketState.totalSupplyAssets) + 1),
            "supply-share floor invariant"
        );
    }

    function _setSupplyTotals(uint128 totalSupplyAssets, uint128 totalSupplyShares) internal {
        bytes32 slot = MorphoStorageLib.marketTotalSupplyAssetsAndSharesSlot(id);
        vm.store(address(morpho), slot, bytes32(uint256(totalSupplyAssets) | (uint256(totalSupplyShares) << 128)));
    }
}
