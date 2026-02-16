// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {ERC20Mock} from "../../../../../src/mocks/ERC20Mock.sol";
import {IMorpho, IMorphoCredit, Id, MarketParams} from "../../../../../src/interfaces/IMorpho.sol";
import {IProtocolConfig} from "../../../../../src/interfaces/IProtocolConfig.sol";
import {MorphoLib} from "../../../../../src/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "../../../../../src/libraries/periphery/MorphoBalancesLib.sol";

contract CoreCreditLifecycleHandler is Test {
    bytes4 internal constant BORROW_SELECTOR =
        bytes4(keccak256("borrow((address,address,address,address,uint256,address),uint256,uint256,address,address)"));
    bytes4 internal constant REPAY_SELECTOR =
        bytes4(keccak256("repay((address,address,address,address,uint256,address),uint256,uint256,address,bytes)"));
    bytes4 internal constant CLOSE_CYCLE_SELECTOR =
        bytes4(keccak256("closeCycleAndPostObligations(bytes32,uint256,address[],uint256[],uint256[])"));
    bytes4 internal constant ACCRUE_PREMIUM_SELECTOR =
        bytes4(keccak256("accruePremiumsForBorrowers(bytes32,address[])"));
    bytes4 internal constant SETTLE_ACCOUNT_SELECTOR =
        bytes4(keccak256("settleAccount((address,address,address,address,uint256,address),address)"));

    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant MAX_CREDIT = 1e24;
    uint256 internal constant MAX_PREMIUM_RATE = uint256(500000000000000000) / uint256(31_536_000);
    uint256 internal constant MAX_TIME_STEP = 12 hours;
    uint256 internal constant MAX_TIME_HORIZON = 10 * 365 days;

    IMorpho public immutable morpho;
    IMorphoCredit public immutable morphoCredit;
    IProtocolConfig public immutable protocolConfig;
    ERC20Mock public immutable loanToken;

    Id[] public marketIds;
    address[] public creditLines;
    uint256[] public lastCycleEndByMarket;
    address[] public actors;

    mapping(address => bool) public isKnownBorrower;
    address[] public knownBorrowers;

    uint256 public unauthorizedAttempts;
    uint256 public unauthorizedSuccesses;
    uint256 public immutable maxTimestamp;

    constructor(
        address _morpho,
        address _morphoCredit,
        address _protocolConfig,
        address _loanToken,
        Id[] memory _marketIds,
        address[] memory _creditLines,
        uint256[] memory _initialCycleEnds,
        address[] memory _actors
    ) {
        require(
            _marketIds.length == _creditLines.length && _marketIds.length == _initialCycleEnds.length,
            "invalid market arrays"
        );
        require(_actors.length > 0, "no actors");

        morpho = IMorpho(_morpho);
        morphoCredit = IMorphoCredit(_morphoCredit);
        protocolConfig = IProtocolConfig(_protocolConfig);
        loanToken = ERC20Mock(_loanToken);
        maxTimestamp = block.timestamp + MAX_TIME_HORIZON;

        for (uint256 i; i < _marketIds.length; ++i) {
            marketIds.push(_marketIds[i]);
            creditLines.push(_creditLines[i]);
            lastCycleEndByMarket.push(_initialCycleEnds[i]);
        }
        for (uint256 i; i < _actors.length; ++i) {
            actors.push(_actors[i]);
        }
    }

    function setCreditLine(uint256 marketSeed, uint256 borrowerSeed, uint256 creditSeed, uint256 premiumRateSeed)
        external
    {
        uint256 marketIndex = marketSeed % marketIds.length;
        Id id = marketIds[marketIndex];
        address borrower = _actor(borrowerSeed);
        uint256 credit = bound(creditSeed, 1e18, MAX_CREDIT);
        uint128 premiumRate = uint128(bound(premiumRateSeed, 0, MAX_PREMIUM_RATE));

        vm.prank(creditLines[marketIndex]);
        (bool ok,) =
            address(morphoCredit).call(abi.encodeCall(IMorphoCredit.setCreditLine, (id, borrower, credit, premiumRate)));
        if (ok) _registerBorrower(borrower);
    }

    function borrow(uint256 marketSeed, uint256 borrowerSeed, uint256 assetsSeed) external {
        uint256 marketIndex = marketSeed % marketIds.length;
        Id id = marketIds[marketIndex];
        address borrower = _actor(borrowerSeed);

        _ensureMarketActive(marketIndex);

        (, uint128 amountDue,) = morphoCredit.repaymentObligation(id, borrower);
        if (amountDue != 0) return;

        uint256 credit = morpho.collateral(id, borrower);
        if (credit <= 2) return;

        uint256 totalSupplyAssets = morpho.totalSupplyAssets(id);
        uint256 totalBorrowAssets = morpho.totalBorrowAssets(id);
        uint256 liquidity = totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;
        if (liquidity <= 2) return;

        uint256 maxBorrow = credit < liquidity ? credit : liquidity;
        if (maxBorrow <= 2) return;

        uint256 safeMax = maxBorrow / 2;
        if (safeMax == 0) return;
        uint256 assets = bound(assetsSeed, 1, safeMax);

        bool ok = _executeBorrow(id, borrower, assets);
        if (ok) _registerBorrower(borrower);
    }

    function repay(uint256 marketSeed, uint256 payerSeed, uint256 borrowerSeed, uint256 amountSeed) external {
        uint256 marketIndex = marketSeed % marketIds.length;
        Id id = marketIds[marketIndex];
        MarketParams memory marketParams = morpho.idToMarketParams(id);
        address payer = _actor(payerSeed);
        address borrower = _actor(borrowerSeed);

        _ensureMarketActive(marketIndex);

        if (morpho.borrowShares(id, borrower) == 0) return;

        (, uint128 amountDue,) = morphoCredit.repaymentObligation(id, borrower);
        uint256 amount = amountDue != 0 ? amountDue : bound(amountSeed, 1, MAX_CREDIT);

        loanToken.setBalance(payer, amount);
        vm.startPrank(payer);
        loanToken.approve(address(morpho), type(uint256).max);
        address(morpho).call(abi.encodeWithSelector(REPAY_SELECTOR, marketParams, amount, uint256(0), borrower, ""));
        vm.stopPrank();
    }

    function postObligationCycle(uint256 marketSeed, uint256 borrowerSeed, uint256 repaymentBpsSeed) external {
        uint256 marketIndex = marketSeed % marketIds.length;
        Id id = marketIds[marketIndex];
        address borrower = _actor(borrowerSeed);

        if (morpho.borrowShares(id, borrower) == 0) return;
        uint256 endingBalance = morpho.collateral(id, borrower);
        if (endingBalance == 0) return;

        uint256 repaymentBps = bound(repaymentBpsSeed, 100, 10_000);

        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        uint256[] memory repaymentBpsList = new uint256[](1);
        repaymentBpsList[0] = repaymentBps;
        uint256[] memory endingBalances = new uint256[](1);
        endingBalances[0] = endingBalance;

        if (_postCycle(marketIndex, borrowers, repaymentBpsList, endingBalances)) {
            _registerBorrower(borrower);
        }
    }

    function postEmptyCycle(uint256 marketSeed) external {
        uint256 marketIndex = marketSeed % marketIds.length;
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBpsList = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        _postCycle(marketIndex, borrowers, repaymentBpsList, endingBalances);
    }

    function advanceTime(uint256 timeSeed) external {
        if (block.timestamp >= maxTimestamp) return;

        uint256 remaining = maxTimestamp - block.timestamp;
        uint256 maxStep = remaining < MAX_TIME_STEP ? remaining : MAX_TIME_STEP;
        if (maxStep == 0) return;

        uint256 timeToAdvance = bound(timeSeed, 1 hours, maxStep);
        vm.warp(block.timestamp + timeToAdvance);
        vm.roll(block.number + 1);
    }

    function accruePremiumForBorrower(uint256 marketSeed, uint256 borrowerSeed) external {
        uint256 marketIndex = marketSeed % marketIds.length;
        Id id = marketIds[marketIndex];
        address borrower = _actor(borrowerSeed);

        if (morpho.borrowShares(id, borrower) == 0) return;

        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        address(morphoCredit).call(abi.encodeWithSelector(ACCRUE_PREMIUM_SELECTOR, id, borrowers));
    }

    function settleBorrower(uint256 marketSeed, uint256 borrowerSeed) external {
        uint256 marketIndex = marketSeed % marketIds.length;
        Id id = marketIds[marketIndex];
        MarketParams memory marketParams = morpho.idToMarketParams(id);
        address borrower = _actor(borrowerSeed);

        if (morpho.borrowShares(id, borrower) == 0) return;

        vm.prank(creditLines[marketIndex]);
        address(morphoCredit).call(abi.encodeWithSelector(SETTLE_ACCOUNT_SELECTOR, marketParams, borrower));
    }

    function unauthorizedSetCreditLineAttempt(
        uint256 marketSeed,
        uint256 borrowerSeed,
        uint256 creditSeed,
        uint256 premiumRateSeed
    ) external {
        Id id = marketIds[marketSeed % marketIds.length];
        address borrower = _actor(borrowerSeed);
        uint256 credit = bound(creditSeed, 1e18, MAX_CREDIT);
        uint128 premiumRate = uint128(bound(premiumRateSeed, 0, MAX_PREMIUM_RATE));

        unauthorizedAttempts++;
        (bool ok,) =
            address(morphoCredit).call(abi.encodeCall(IMorphoCredit.setCreditLine, (id, borrower, credit, premiumRate)));
        if (ok) unauthorizedSuccesses++;
    }

    function unauthorizedCloseCycleAttempt(uint256 marketSeed, uint256 borrowerSeed, uint256 repaymentBpsSeed)
        external
    {
        uint256 marketIndex = marketSeed % marketIds.length;
        Id id = marketIds[marketIndex];
        address borrower = _actor(borrowerSeed);

        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        uint256[] memory repaymentBpsList = new uint256[](1);
        repaymentBpsList[0] = bound(repaymentBpsSeed, 100, 10_000);
        uint256[] memory endingBalances = new uint256[](1);
        endingBalances[0] = 1e18;

        unauthorizedAttempts++;
        (bool ok,) = address(morphoCredit)
            .call(
                abi.encodeCall(
                    IMorphoCredit.closeCycleAndPostObligations,
                    (id, block.timestamp, borrowers, repaymentBpsList, endingBalances)
                )
            );
        if (ok) unauthorizedSuccesses++;
    }

    function _ensureMarketActive(uint256 marketIndex) internal {
        if (!_isFrozen(marketIndex)) return;
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBpsList = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);
        _postCycle(marketIndex, borrowers, repaymentBpsList, endingBalances);
    }

    function _postCycle(
        uint256 marketIndex,
        address[] memory borrowers,
        uint256[] memory repaymentBpsList,
        uint256[] memory endingBalances
    ) internal returns (bool ok) {
        if (!_advanceToNextCycleWindow(marketIndex)) return false;

        uint256 endDate = block.timestamp;
        vm.prank(creditLines[marketIndex]);
        (ok,) = address(morphoCredit)
            .call(
                abi.encodeWithSelector(
                    CLOSE_CYCLE_SELECTOR, marketIds[marketIndex], endDate, borrowers, repaymentBpsList, endingBalances
                )
            );
        if (ok) lastCycleEndByMarket[marketIndex] = endDate;
    }

    function _advanceToNextCycleWindow(uint256 marketIndex) internal returns (bool) {
        if (block.timestamp >= maxTimestamp) return false;

        uint256 cycleDuration = protocolConfig.getCycleDuration();
        if (cycleDuration == 0) return true;

        uint256 minNextEnd = lastCycleEndByMarket[marketIndex] + cycleDuration;
        if (minNextEnd > maxTimestamp) return false;

        if (block.timestamp < minNextEnd) {
            vm.warp(minNextEnd);
            vm.roll(block.number + 1);
        }
        return true;
    }

    function _isFrozen(uint256 marketIndex) internal view returns (bool) {
        uint256 cycleDuration = protocolConfig.getCycleDuration();
        if (cycleDuration == 0) return false;
        return block.timestamp >= lastCycleEndByMarket[marketIndex] + cycleDuration;
    }

    function _executeBorrow(Id id, address borrower, uint256 assets) internal returns (bool ok) {
        vm.prank(borrower);
        (ok,) = address(morpho)
            .call(
                abi.encodeWithSelector(
                    BORROW_SELECTOR, morpho.idToMarketParams(id), assets, uint256(0), borrower, borrower
                )
            );
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _registerBorrower(address borrower) internal {
        if (isKnownBorrower[borrower]) return;
        isKnownBorrower[borrower] = true;
        knownBorrowers.push(borrower);
    }
}
