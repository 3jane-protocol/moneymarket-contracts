// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.sol";

import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {MarkdownManagerMock} from "../../../../src/mocks/MarkdownManagerMock.sol";
import {IMorphoCredit, Id, Market, MarketParams, RepaymentStatus} from "../../../../src/interfaces/IMorpho.sol";
import {IProtocolConfig, MarketConfig} from "../../../../src/interfaces/IProtocolConfig.sol";
import {MAX_FEE} from "../../../../src/libraries/ConstantsLib.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {MorphoLib} from "../../../../src/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "../../../../src/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoCreditLib} from "../../../../src/libraries/periphery/MorphoCreditLib.sol";

import {CoreLiquidityHandler} from "./handlers/CoreLiquidityHandler.sol";
import {CoreCreditLifecycleHandler} from "./handlers/CoreCreditLifecycleHandler.sol";
import {CoreGovernanceHandler} from "./handlers/CoreGovernanceHandler.sol";

contract CoreInvariantHarness is BaseTest {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant ACTOR_COUNT = 10;
    uint256 internal constant MARKET_COUNT = 3;
    uint256 internal constant INITIAL_SUPPLY_PER_MARKET = 2_000_000e18;

    IMorphoCredit internal morphoCredit;
    MarkdownManagerMock internal markdownManager;

    address[] internal actors;
    Id[] internal marketIds;

    CoreLiquidityHandler internal liquidityHandler;
    CoreCreditLifecycleHandler internal creditLifecycleHandler;
    CoreGovernanceHandler internal governanceHandler;

    function setUp() public override {
        super.setUp();

        morphoCredit = IMorphoCredit(address(morpho));
        markdownManager = new MarkdownManagerMock(address(protocolConfig), OWNER);

        _setupActors();

        Id[] memory localMarketIds = new Id[](MARKET_COUNT);
        address[] memory localCreditLines = new address[](MARKET_COUNT);
        uint256[] memory initialCycleEnds = new uint256[](MARKET_COUNT);

        for (uint256 i; i < MARKET_COUNT; ++i) {
            uint256 lltv = i == 0 ? DEFAULT_TEST_LLTV : i == 1 ? DEFAULT_TEST_LLTV / 2 : DEFAULT_TEST_LLTV / 3;
            CreditLineMock creditLine = new CreditLineMock(morphoAddress);
            creditLine.setMm(address(markdownManager));

            MarketParams memory coreMarketParams = MarketParams({
                loanToken: address(loanToken),
                collateralToken: address(collateralToken),
                oracle: address(oracle),
                irm: address(irm),
                lltv: lltv,
                creditLine: address(creditLine)
            });
            Id marketId = coreMarketParams.id();

            vm.startPrank(OWNER);
            if (!morpho.isLltvEnabled(lltv)) morpho.enableLltv(lltv);
            morpho.createMarket(coreMarketParams);
            morpho.setFee(coreMarketParams, MAX_FEE / 10);
            vm.stopPrank();

            vm.warp(block.timestamp + CYCLE_DURATION);
            vm.roll(block.number + 1);
            vm.prank(address(creditLine));
            morphoCredit.closeCycleAndPostObligations(
                marketId, block.timestamp, new address[](0), new uint256[](0), new uint256[](0)
            );

            loanToken.setBalance(actors[0], INITIAL_SUPPLY_PER_MARKET);
            vm.prank(actors[0]);
            morpho.supply(coreMarketParams, INITIAL_SUPPLY_PER_MARKET, 0, actors[0], "");

            localMarketIds[i] = marketId;
            localCreditLines[i] = address(creditLine);
            initialCycleEnds[i] = block.timestamp;
            marketIds.push(marketId);
        }

        address[] memory actorList = _actorList();
        liquidityHandler = new CoreLiquidityHandler(address(morpho), address(loanToken), localMarketIds, actorList);
        creditLifecycleHandler = new CoreCreditLifecycleHandler(
            address(morpho),
            address(morphoCredit),
            address(protocolConfig),
            address(loanToken),
            localMarketIds,
            localCreditLines,
            initialCycleEnds,
            actorList
        );
        governanceHandler =
            new CoreGovernanceHandler(address(morpho), address(protocolConfig), OWNER, localMarketIds, actorList);

        _configureTargets();
    }

    function invariant_totalBorrowLeSupplyPlusMarkdown() public view {
        for (uint256 i; i < marketIds.length; ++i) {
            Market memory market = morpho.market(marketIds[i]);
            assertLe(
                uint256(market.totalBorrowAssets),
                uint256(market.totalSupplyAssets) + uint256(market.totalMarkdownAmount),
                vm.toString(Id.unwrap(marketIds[i]))
            );
        }
    }

    function invariant_morphoBalanceCoversSupply() public view {
        for (uint256 i; i < marketIds.length; ++i) {
            Market memory market = morpho.market(marketIds[i]);
            assertGe(
                loanToken.balanceOf(address(morpho)) + uint256(market.totalBorrowAssets),
                uint256(market.totalSupplyAssets),
                vm.toString(Id.unwrap(marketIds[i]))
            );
        }
    }

    function invariant_supplySharesMatchKnownActors() public view {
        for (uint256 i; i < marketIds.length; ++i) {
            Id id = marketIds[i];
            uint256 totalKnownSupplyShares = morpho.supplyShares(id, FEE_RECIPIENT);

            for (uint256 j; j < actors.length; ++j) {
                totalKnownSupplyShares += morpho.supplyShares(id, actors[j]);
            }

            assertEq(totalKnownSupplyShares, morpho.totalSupplyShares(id), vm.toString(Id.unwrap(id)));
        }
    }

    function invariant_borrowSharesMatchKnownActors() public view {
        for (uint256 i; i < marketIds.length; ++i) {
            Id id = marketIds[i];
            uint256 totalKnownBorrowShares;

            for (uint256 j; j < actors.length; ++j) {
                totalKnownBorrowShares += morpho.borrowShares(id, actors[j]);
            }

            assertEq(totalKnownBorrowShares, morpho.totalBorrowShares(id), vm.toString(Id.unwrap(id)));
        }
    }

    function invariant_unhealthyBorrowersCannotIncreaseDebt() public {
        uint256 cycleDuration = IProtocolConfig(address(protocolConfig)).getCycleDuration();

        for (uint256 i; i < marketIds.length; ++i) {
            Id id = marketIds[i];
            MarketParams memory marketParams = morpho.idToMarketParams(id);
            bool marketActive = _isMarketActive(id, cycleDuration);

            for (uint256 j; j < actors.length; ++j) {
                address borrower = actors[j];
                if (morpho.borrowShares(id, borrower) == 0) continue;

                uint256 debt = morpho.expectedBorrowAssets(marketParams, borrower);
                uint256 credit = morpho.collateral(id, borrower);
                if (debt <= credit) continue;

                (, uint128 amountDue,) = morphoCredit.repaymentObligation(id, borrower);
                if (amountDue != 0 || !marketActive) continue;

                vm.prank(borrower);
                try morpho.borrow(marketParams, 1, 0, borrower, borrower) {
                    assertTrue(false, vm.toString(borrower));
                } catch {}
            }
        }
    }

    function invariant_zeroDebtHasZeroMarkdown() public view {
        for (uint256 i; i < marketIds.length; ++i) {
            Id id = marketIds[i];

            for (uint256 j; j < actors.length; ++j) {
                address borrower = actors[j];
                if (morpho.borrowShares(id, borrower) != 0) continue;

                (uint128 cycleId, uint128 amountDue,) = morphoCredit.repaymentObligation(id, borrower);
                uint128 markdown = morphoCredit.markdownState(id, borrower);

                // If a borrower has no debt and no open obligations, markdown should be zero.
                if (amountDue == 0 && cycleId == 0) {
                    assertEq(markdown, 0, vm.toString(borrower));
                }
            }
        }
    }

    function invariant_markdownSumMatchesMarketTotal() public view {
        for (uint256 i; i < marketIds.length; ++i) {
            Id id = marketIds[i];
            uint256 sumMarkdown;

            for (uint256 j; j < actors.length; ++j) {
                sumMarkdown += morphoCredit.markdownState(id, actors[j]);
            }

            assertEq(sumMarkdown, morpho.market(id).totalMarkdownAmount, vm.toString(Id.unwrap(id)));
        }
    }

    function invariant_cyclesAreMonotonicAndSpaced() public view {
        uint256 cycleDuration = IProtocolConfig(address(protocolConfig)).getCycleDuration();

        for (uint256 i; i < marketIds.length; ++i) {
            Id id = marketIds[i];
            uint256 cycleLength = MorphoCreditLib.getPaymentCycleLength(morphoCredit, id);
            if (cycleLength <= 1) continue;

            (, uint256 previousEnd) = MorphoCreditLib.getCycleDates(morphoCredit, id, 0);

            for (uint256 cycleId = 1; cycleId < cycleLength; ++cycleId) {
                (, uint256 currentEnd) = MorphoCreditLib.getCycleDates(morphoCredit, id, cycleId);
                assertGe(currentEnd, previousEnd + cycleDuration, vm.toString(Id.unwrap(id)));
                previousEnd = currentEnd;
            }
        }
    }

    function invariant_obligationStatusMatchesTimeWindow() public view {
        MarketConfig memory terms = IProtocolConfig(address(protocolConfig)).getMarketConfig();

        for (uint256 i; i < marketIds.length; ++i) {
            Id id = marketIds[i];

            for (uint256 j; j < actors.length; ++j) {
                address borrower = actors[j];
                (uint128 cycleId, uint128 amountDue,) = morphoCredit.repaymentObligation(id, borrower);
                (RepaymentStatus status, uint256 statusStartTime) =
                    MorphoCreditLib.getRepaymentStatus(morphoCredit, id, borrower);

                if (amountDue == 0) {
                    assertEq(uint256(status), uint256(RepaymentStatus.Current), vm.toString(borrower));
                    assertEq(statusStartTime, 0, vm.toString(borrower));
                    continue;
                }

                uint256 cycleLength = MorphoCreditLib.getPaymentCycleLength(morphoCredit, id);
                assertLt(uint256(cycleId), cycleLength, vm.toString(borrower));

                (, uint256 cycleEnd) = MorphoCreditLib.getCycleDates(morphoCredit, id, uint256(cycleId));
                if (block.timestamp <= cycleEnd + terms.gracePeriod) {
                    assertEq(uint256(status), uint256(RepaymentStatus.GracePeriod), vm.toString(borrower));
                    assertEq(statusStartTime, cycleEnd, vm.toString(borrower));
                } else if (block.timestamp < cycleEnd + terms.gracePeriod + terms.delinquencyPeriod) {
                    assertEq(uint256(status), uint256(RepaymentStatus.Delinquent), vm.toString(borrower));
                    assertEq(statusStartTime, cycleEnd + terms.gracePeriod, vm.toString(borrower));
                } else {
                    assertEq(uint256(status), uint256(RepaymentStatus.Default), vm.toString(borrower));
                    assertEq(
                        statusStartTime, cycleEnd + terms.gracePeriod + terms.delinquencyPeriod, vm.toString(borrower)
                    );
                }
            }
        }
    }

    function invariant_unauthorizedActionsNeverSucceed() public view {
        assertEq(governanceHandler.unauthorizedSuccesses(), 0, "unauthorized governance action succeeded");
        assertEq(creditLifecycleHandler.unauthorizedSuccesses(), 0, "unauthorized credit-line action succeeded");
    }

    function _setupActors() internal {
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            address actor = makeAddr(string.concat("CoreInvariantActor", vm.toString(i)));
            actors.push(actor);

            vm.startPrank(actor);
            loanToken.approve(address(morpho), type(uint256).max);
            collateralToken.approve(address(morpho), type(uint256).max);
            vm.stopPrank();

            vm.prank(OWNER);
            markdownManager.setEnableMarkdown(actor, true);
        }
    }

    function _actorList() internal view returns (address[] memory actorList) {
        actorList = new address[](actors.length);
        for (uint256 i; i < actors.length; ++i) {
            actorList[i] = actors[i];
        }
    }

    function _configureTargets() internal {
        targetContract(address(liquidityHandler));
        targetContract(address(creditLifecycleHandler));
        targetContract(address(governanceHandler));

        bytes4[] memory liquiditySelectors = new bytes4[](5);
        liquiditySelectors[0] = CoreLiquidityHandler.supplyAssets.selector;
        liquiditySelectors[1] = CoreLiquidityHandler.supplyShares.selector;
        liquiditySelectors[2] = CoreLiquidityHandler.withdrawAssets.selector;
        liquiditySelectors[3] = CoreLiquidityHandler.withdrawShares.selector;
        liquiditySelectors[4] = CoreLiquidityHandler.accrueInterest.selector;
        targetSelector(FuzzSelector({addr: address(liquidityHandler), selectors: liquiditySelectors}));

        bytes4[] memory creditSelectors = new bytes4[](10);
        creditSelectors[0] = CoreCreditLifecycleHandler.setCreditLine.selector;
        creditSelectors[1] = CoreCreditLifecycleHandler.borrow.selector;
        creditSelectors[2] = CoreCreditLifecycleHandler.repay.selector;
        creditSelectors[3] = CoreCreditLifecycleHandler.postObligationCycle.selector;
        creditSelectors[4] = CoreCreditLifecycleHandler.postEmptyCycle.selector;
        creditSelectors[5] = CoreCreditLifecycleHandler.advanceTime.selector;
        creditSelectors[6] = CoreCreditLifecycleHandler.accruePremiumForBorrower.selector;
        creditSelectors[7] = CoreCreditLifecycleHandler.settleBorrower.selector;
        creditSelectors[8] = CoreCreditLifecycleHandler.unauthorizedSetCreditLineAttempt.selector;
        creditSelectors[9] = CoreCreditLifecycleHandler.unauthorizedCloseCycleAttempt.selector;
        targetSelector(FuzzSelector({addr: address(creditLifecycleHandler), selectors: creditSelectors}));

        bytes4[] memory governanceSelectors = new bytes4[](5);
        governanceSelectors[0] = CoreGovernanceHandler.setFee.selector;
        governanceSelectors[1] = CoreGovernanceHandler.setFeeRecipient.selector;
        governanceSelectors[2] = CoreGovernanceHandler.setDebtCap.selector;
        governanceSelectors[3] = CoreGovernanceHandler.unauthorizedSetFeeAttempt.selector;
        governanceSelectors[4] = CoreGovernanceHandler.unauthorizedSetFeeRecipientAttempt.selector;
        targetSelector(FuzzSelector({addr: address(governanceHandler), selectors: governanceSelectors}));
    }

    function _isMarketActive(Id id, uint256 cycleDuration) internal view returns (bool) {
        uint256 cycleLength = MorphoCreditLib.getPaymentCycleLength(morphoCredit, id);
        if (cycleLength == 0 || cycleDuration == 0) return false;

        (, uint256 lastCycleEnd) = MorphoCreditLib.getCycleDates(morphoCredit, id, cycleLength - 1);
        return block.timestamp < lastCycleEnd + cycleDuration;
    }
}
