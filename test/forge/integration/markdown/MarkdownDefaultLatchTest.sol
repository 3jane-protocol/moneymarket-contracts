// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.sol";
import {Jane} from "../../../../src/jane/Jane.sol";
import {MarkdownController} from "../../../../src/MarkdownController.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {Market} from "../../../../src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {MorphoCreditLib} from "../../../../src/libraries/periphery/MorphoCreditLib.sol";
import {MorphoCreditStorageLib} from "../../../../src/libraries/periphery/MorphoCreditStorageLib.sol";
import {SharesMathLib} from "../../../../src/libraries/SharesMathLib.sol";
import {ProtocolConfigLib} from "../../../../src/libraries/ProtocolConfigLib.sol";

/// @title MarkdownDefaultLatchTest
/// @notice Regression tests for default-entry tracking with the real MarkdownController + Jane stack.
/// The supply-share price floor can truncate a markdown increase to zero, so the stored applied markdown
/// cannot be used to infer whether a borrower already entered default.
contract MarkdownDefaultLatchTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    uint256 internal constant SUPPLY_SHARE_PRICE_FLOOR_RATIO = 1e15;
    uint256 internal constant SUPPLY_AMOUNT = 1 ether;
    uint256 internal constant DUST_DEBT = 5e8;
    uint256 internal constant JANE_BALANCE = 10_000e18;

    bytes32 internal constant DEFAULT_STARTED_TOPIC = keccak256("DefaultStarted(bytes32,address,uint256)");
    bytes32 internal constant DEFAULT_CLEARED_TOPIC = keccak256("DefaultCleared(bytes32,address)");
    bytes32 internal constant MARKDOWN_UPDATED_TOPIC =
        keccak256("BorrowerMarkdownUpdated(bytes32,address,uint256,uint256)");
    bytes32 internal constant MARKDOWN_TRUNCATED_TOPIC =
        keccak256("MarkdownTruncated(bytes32,address,uint256,uint256)");

    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");

    Jane internal jane;
    MarkdownController internal markdownController;
    CreditLineMock internal creditLine;
    IMorphoCredit internal morphoCredit;

    address internal janeOwner;
    address internal janeMinter;
    address internal janeDistributor;

    function setUp() public override {
        super.setUp();

        morphoCredit = IMorphoCredit(morphoAddress);

        janeOwner = makeAddr("janeOwner");
        janeMinter = makeAddr("janeMinter");
        janeDistributor = makeAddr("janeDistributor");
        jane = new Jane(janeOwner, janeDistributor);
        vm.prank(janeOwner);
        jane.grantRole(MINTER_ROLE, janeMinter);

        creditLine = new CreditLineMock(morphoAddress);

        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(0),
            lltv: DEFAULT_TEST_LLTV,
            creditLine: address(creditLine)
        });
        id = marketParams.id();

        vm.prank(OWNER);
        morpho.createMarket(marketParams);

        markdownController = new MarkdownController(address(protocolConfig), OWNER, address(jane), morphoAddress, id);
        creditLine.setMm(address(markdownController));

        vm.prank(janeOwner);
        jane.setMarkdownController(address(markdownController));

        vm.startPrank(OWNER);
        protocolConfig.setConfig(ProtocolConfigLib.FULL_MARKDOWN_DURATION, 100 days);
        protocolConfig.setConfig(keccak256("IRP"), 0);
        markdownController.setEnableMarkdown(BORROWER, true);
        markdownController.setEnableMarkdown(ONBEHALF, true);
        vm.stopPrank();

        _ensureMarketActive(id);

        loanToken.setBalance(SUPPLIER, SUPPLY_AMOUNT);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, SUPPLY_AMOUNT, 0, SUPPLIER, hex"");

        vm.prank(janeMinter);
        jane.mint(ONBEHALF, JANE_BALANCE);
        vm.prank(janeOwner);
        jane.setTransferable();
    }

    /// @notice BORROWER's full markdown drives the market to the supply-share floor, then ONBEHALF's markdown
    /// increase is fully truncated: ONBEHALF is 50 days into default (50% intended slash) with zero stored markdown.
    function _floorTruncatedDefault() internal {
        _setupBorrowerWithLoan(ONBEHALF, DUST_DEBT);
        _setupBorrowerWithLoan(BORROWER, SUPPLY_AMOUNT - DUST_DEBT);

        uint256 cycleEndA = _closeCycleWithObligation(BORROWER, SUPPLY_AMOUNT - DUST_DEBT, CYCLE_DURATION + 1 days);
        uint256 cycleEndB = _closeCycleWithObligation(ONBEHALF, DUST_DEBT, 61 days);
        assertEq(cycleEndB, cycleEndA + 61 days, "cycle spacing");

        uint256 defaultStartB = cycleEndB + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION;
        vm.warp(defaultStartB + 50 days);

        // BORROWER is 111 days into default: full markdown, truncated at the floor, market winds down.
        morphoCredit.accruePremiumsForBorrowers(id, _toArray(BORROWER));

        Market memory atFloor = morpho.market(id);
        uint256 minAssets = _minSupplyAssets(atFloor.totalSupplyShares);
        assertEq(atFloor.totalSupplyAssets, minAssets, "market not at floor");
        assertTrue(morphoCredit.marketInWindDown(id), "floor markdown did not wind down market");
    }

    function _closeCycleWithObligation(address borrower, uint256 endingBalance, uint256 gap)
        internal
        returns (uint256 cycleEnd)
    {
        uint256 cycleCount = MorphoCreditLib.getPaymentCycleLength(morphoCredit, id);
        uint256 lastCycleEnd = MorphoCredit(address(morpho)).paymentCycle(id, cycleCount - 1);
        cycleEnd = lastCycleEnd + gap;

        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        uint256[] memory repaymentBps = new uint256[](1);
        repaymentBps[0] = 10_000;
        uint256[] memory endingBalances = new uint256[](1);
        endingBalances[0] = endingBalance;

        vm.warp(cycleEnd);
        vm.prank(address(creditLine));
        MorphoCredit(address(morpho))
            .closeCycleAndPostObligations(id, cycleEnd, borrowers, repaymentBps, endingBalances);
    }

    function _countLogs(Vm.Log[] memory logs, bytes32 topic, address borrower)
        internal
        view
        returns (uint256 count, bytes memory data)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != morphoAddress) continue;
            if (logs[i].topics[0] != topic) continue;
            if (address(uint160(uint256(logs[i].topics[2]))) != borrower) continue;
            count++;
            data = logs[i].data;
        }
    }

    function _minSupplyAssets(uint256 totalSupplyShares) internal pure returns (uint256) {
        return (totalSupplyShares + SharesMathLib.VIRTUAL_SHARES - 1) / SUPPLY_SHARE_PRICE_FLOOR_RATIO;
    }

    /// @notice Finding 1: repeated touches of a fully-truncated defaulted borrower at one timestamp must slash
    /// exactly the intended fraction once, not compound it per touch.
    function testRepeatedTouchOfFullyTruncatedBorrowerSlashesIntendedFractionOnce() public {
        _floorTruncatedDefault();

        // Three permissionless touches in the same block.
        for (uint256 i = 0; i < 3; i++) {
            morphoCredit.accruePremiumsForBorrowers(id, _toArray(ONBEHALF));
        }

        assertEq(morphoCredit.markdownState(id, ONBEHALF), 0, "truncated markdown was stored");
        assertEq(jane.balanceOf(ONBEHALF), JANE_BALANCE / 2, "cumulative slash exceeds intended 50%");
        assertEq(jane.balanceOf(janeDistributor), JANE_BALANCE / 2, "distributor received more than intended 50%");
        assertEq(markdownController.janeSlashed(ONBEHALF), JANE_BALANCE / 2, "slash tracking diverged");
        assertEq(markdownController.initialJaneBalance(ONBEHALF), JANE_BALANCE, "initial balance was re-initialised");
    }

    /// @notice Full truncation must stay observable: DefaultStarted fires once, refused markdown emits a
    /// truncation event on every refused increase, and no BorrowerMarkdownUpdated fires for an unchanged store.
    function testFullTruncationEventBehaviour() public {
        _floorTruncatedDefault();

        uint256 requested = DUST_DEBT * 50 / 100;

        vm.recordLogs();
        morphoCredit.accruePremiumsForBorrowers(id, _toArray(ONBEHALF));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 started,) = _countLogs(logs, DEFAULT_STARTED_TOPIC, ONBEHALF);
        (uint256 updated,) = _countLogs(logs, MARKDOWN_UPDATED_TOPIC, ONBEHALF);
        (uint256 truncated, bytes memory truncData) = _countLogs(logs, MARKDOWN_TRUNCATED_TOPIC, ONBEHALF);
        assertEq(started, 1, "first touch must emit DefaultStarted once");
        assertEq(updated, 0, "unchanged store must not emit BorrowerMarkdownUpdated");
        assertEq(truncated, 1, "refused markdown must emit a truncation event");
        assertEq(truncData, abi.encode(requested, uint256(0)), "truncation event payload");

        vm.recordLogs();
        morphoCredit.accruePremiumsForBorrowers(id, _toArray(ONBEHALF));
        logs = vm.getRecordedLogs();

        (started,) = _countLogs(logs, DEFAULT_STARTED_TOPIC, ONBEHALF);
        (updated,) = _countLogs(logs, MARKDOWN_UPDATED_TOPIC, ONBEHALF);
        (truncated, truncData) = _countLogs(logs, MARKDOWN_TRUNCATED_TOPIC, ONBEHALF);
        assertEq(started, 0, "repeat touch must not re-emit DefaultStarted");
        assertEq(updated, 0, "repeat touch must not emit BorrowerMarkdownUpdated");
        assertEq(truncated, 1, "still-refused markdown must stay observable");
        assertEq(truncData, abi.encode(requested, uint256(0)), "repeat truncation event payload");
    }

    /// @notice Upgrade boundary, common case: a borrower mid-default with nonzero stored markdown (all live
    /// pre-upgrade state that entered default and was touched) must not be reset or re-slashed when the
    /// default latch bits are still zero.
    function testUpgradeBoundaryMidDefaultWithStoredMarkdownIsNotReslashed() public {
        _setupBorrowerWithLoan(ONBEHALF, DUST_DEBT);
        uint256 cycleEnd = _closeCycleWithObligation(ONBEHALF, DUST_DEBT, CYCLE_DURATION + 1 days);
        uint256 defaultStart = cycleEnd + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION;

        vm.warp(defaultStart + 30 days);
        morphoCredit.accruePremiumsForBorrowers(id, _toArray(ONBEHALF));

        uint256 stored = morphoCredit.markdownState(id, ONBEHALF);
        assertEq(stored, DUST_DEBT * 30 / 100, "expected applied markdown at 30 days");
        assertEq(jane.balanceOf(ONBEHALF), JANE_BALANCE * 70 / 100, "expected 30% slash at 30 days");

        // Model the upgrade boundary: live storage predates the latch, so its upper 128 bits are zero.
        bytes32 slot = MorphoCreditStorageLib.markdownStateSlot(id, ONBEHALF);
        vm.store(morphoAddress, slot, bytes32(stored));

        vm.warp(defaultStart + 50 days);
        vm.recordLogs();
        morphoCredit.accruePremiumsForBorrowers(id, _toArray(ONBEHALF));

        (uint256 started,) = _countLogs(vm.getRecordedLogs(), DEFAULT_STARTED_TOPIC, ONBEHALF);
        assertEq(started, 0, "legacy mid-default borrower re-entered default");
        assertEq(jane.balanceOf(ONBEHALF), JANE_BALANCE / 2, "cumulative slash must continue, not restart");
        assertEq(markdownController.janeSlashed(ONBEHALF), JANE_BALANCE / 2, "slash tracking was reset");
        assertEq(morphoCredit.markdownState(id, ONBEHALF), DUST_DEBT / 2, "markdown did not continue from 30%");
    }

    /// @notice Upgrade boundary, degenerate case: a live borrower mid-default whose stored markdown is zero
    /// (markdown rounded to zero on every pre-upgrade touch) is indistinguishable from a fresh default. The
    /// first post-upgrade touch re-enters default once — accepted behaviour — but must latch afterwards.
    function testUpgradeBoundaryZeroStoredMarkdownReslashesAtMostOnce() public {
        _floorTruncatedDefault();

        morphoCredit.accruePremiumsForBorrowers(id, _toArray(ONBEHALF));
        assertEq(jane.balanceOf(ONBEHALF), JANE_BALANCE / 2, "expected 50% slash on first touch");

        // Model the upgrade boundary: wipe the whole slot (stored markdown is already zero, latch predates upgrade).
        bytes32 slot = MorphoCreditStorageLib.markdownStateSlot(id, ONBEHALF);
        vm.store(morphoAddress, slot, bytes32(0));

        // First post-upgrade touch may re-enter default once and re-slash from the reduced balance.
        morphoCredit.accruePremiumsForBorrowers(id, _toArray(ONBEHALF));
        assertEq(jane.balanceOf(ONBEHALF), JANE_BALANCE / 4, "expected one accepted re-slash");

        // Every further touch must be latched.
        morphoCredit.accruePremiumsForBorrowers(id, _toArray(ONBEHALF));
        morphoCredit.accruePremiumsForBorrowers(id, _toArray(ONBEHALF));
        assertEq(jane.balanceOf(ONBEHALF), JANE_BALANCE / 4, "re-slash repeated after the first touch");
        assertEq(markdownController.janeSlashed(ONBEHALF), JANE_BALANCE / 4, "slash tracking kept resetting");
    }
}
