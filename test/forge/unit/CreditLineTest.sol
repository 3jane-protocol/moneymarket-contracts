// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {CreditLine} from "../../../src/CreditLine.sol";
import {ICreditLine} from "../../../src/interfaces/ICreditLine.sol";
import {IProver} from "../../../src/interfaces/IProver.sol";
import {IInsuranceFund} from "../../../src/interfaces/IInsuranceFund.sol";
import {IERC20} from "../../../src/interfaces/IERC20.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";
import {IMorpho, IMorphoCredit, Id, MarketParams} from "../../../src/interfaces/IMorpho.sol";
import {IProtocolConfig, CreditLineConfig, MarketConfig, IRMConfig} from "../../../src/interfaces/IProtocolConfig.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";

// Mock contracts for testing
contract MockMorphoCredit {
    mapping(Id => mapping(address => uint256)) public creditLines;
    mapping(Id => mapping(address => uint128)) public drpRates;
    address public protocolConfig;

    constructor(address _protocolConfig) {
        protocolConfig = _protocolConfig;
    }

    function setCreditLine(Id id, address borrower, uint256 credit, uint128 drp) external {
        creditLines[id][borrower] = credit;
        drpRates[id][borrower] = drp;
    }

    function closeCycleAndPostObligations(
        Id id,
        uint256 endDate,
        address[] calldata borrowers,
        uint256[] calldata repaymentBps,
        uint256[] calldata endingBalances
    ) external {}

    function addObligationsToLatestCycle(
        Id id,
        address[] calldata borrowers,
        uint256[] calldata repaymentBps,
        uint256[] calldata endingBalances
    ) external {}

    function settleAccount(MarketParams memory marketParams, address borrower)
        external
        pure
        returns (uint256 writtenOffAssets, uint256 writtenOffShares)
    {
        return (1000e18, 1000e18); // Mock values
    }

    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid) {
        // Mock implementation - return the input values
        return (assets, shares);
    }
}

contract MockProver is IProver {
    bool public shouldVerify = true;

    function setShouldVerify(bool _shouldVerify) external {
        shouldVerify = _shouldVerify;
    }

    function verify(Id id, address borrower, uint256 vv, uint256 credit, uint128 drp) external view returns (bool) {
        return shouldVerify;
    }
}

contract MockInsuranceFund is IInsuranceFund {
    address public CREDIT_LINE;

    function setCreditLine(address _creditLine) external {
        CREDIT_LINE = _creditLine;
    }

    function bring(address loanToken, uint256 amount) external {
        // Mock implementation - in real scenario would transfer tokens
    }
}

contract MockERC20 is IERC20 {
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    // Required IERC20 functions (stubs)
    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function name() external pure returns (string memory) {
        return "";
    }

    function symbol() external pure returns (string memory) {
        return "";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract MockProtocolConfig is IProtocolConfig {
    CreditLineConfig public creditLineConfig;

    function initialize(address owner) external {}

    function setCreditLineConfig(CreditLineConfig memory config) external {
        creditLineConfig = config;
    }

    function getCreditLineConfig() external view returns (CreditLineConfig memory) {
        return creditLineConfig;
    }

    // Required IProtocolConfig functions (stubs)
    function config(bytes32) external pure returns (uint256) {
        return 0;
    }

    function setConfig(bytes32, uint256) external {}

    function setEmergencyConfig(bytes32, uint256) external {}

    function getIsPaused() external pure returns (uint256) {
        return 0;
    }

    function getMaxOnCredit() external pure returns (uint256) {
        return 0;
    }

    function getMarketConfig() external pure returns (MarketConfig memory) {
        return MarketConfig(0, 0, 0, 0);
    }

    function getIRMConfig() external pure returns (IRMConfig memory) {
        return IRMConfig(0, 0, 0, 0, 0, 0);
    }

    function getTrancheRatio() external pure returns (uint256) {
        return 0;
    }

    function getTrancheShareVariant() external pure returns (uint256) {
        return 0;
    }

    function getSusd3LockDuration() external pure returns (uint256) {
        return 0;
    }

    function getSusd3CooldownPeriod() external pure returns (uint256) {
        return 0;
    }

    function getCycleDuration() external pure returns (uint256) {
        return 0;
    }

    function getUsd3CommitmentTime() external pure returns (uint256) {
        return 0;
    }

    function getSusd3WithdrawalWindow() external pure returns (uint256) {
        return 0;
    }

    function getUsd3SupplyCap() external pure returns (uint256) {
        return 0;
    }
}

contract CreditLineTest is Test {
    using MarketParamsLib for MarketParams;

    CreditLine internal creditLine;
    MockMorphoCredit internal mockMorphoCredit;
    MockProver internal mockProver;
    MockInsuranceFund internal mockInsuranceFund;
    MockERC20 internal mockERC20;
    MockProtocolConfig internal mockProtocolConfig;

    address internal owner;
    address internal ozd;
    address internal mm;
    address internal nonOwner;
    address internal borrower;

    Id internal testId;
    MarketParams internal testMarketParams;

    function setUp() public {
        owner = makeAddr("Owner");
        ozd = makeAddr("OZD");
        mm = makeAddr("MM");
        nonOwner = makeAddr("NonOwner");
        borrower = makeAddr("Borrower");

        // Deploy mock contracts
        mockProtocolConfig = new MockProtocolConfig();
        mockMorphoCredit = new MockMorphoCredit(address(mockProtocolConfig));
        mockProver = new MockProver();
        mockInsuranceFund = new MockInsuranceFund();
        mockERC20 = new MockERC20();

        // Set up test market parameters
        testMarketParams = MarketParams({
            loanToken: address(mockERC20),
            collateralToken: address(mockERC20),
            oracle: address(0),
            irm: address(0),
            lltv: 0,
            creditLine: address(creditLine)
        });
        testId = testMarketParams.id();

        // Deploy CreditLine contract
        creditLine = new CreditLine(address(mockMorphoCredit), owner, ozd, mm, address(mockProver));

        // Set up mock protocol config
        CreditLineConfig memory config = CreditLineConfig({
            maxLTV: 0.8 ether,
            maxVV: 1000e18,
            maxCreditLine: 10000e18,
            minCreditLine: 100e18,
            maxDRP: uint256(0.1 ether / int256(365 days))
        });
        mockProtocolConfig.setCreditLineConfig(config);

        // Set insurance fund
        vm.prank(owner);
        creditLine.setInsuranceFund(address(mockInsuranceFund));
    }

    // Constructor tests
    function test_Constructor_ValidAddresses() public {
        assertEq(creditLine.owner(), owner);
        assertEq(creditLine.ozd(), ozd);
        assertEq(creditLine.mm(), mm);
        assertEq(creditLine.prover(), address(mockProver));
        assertEq(creditLine.MORPHO(), address(mockMorphoCredit));
    }

    function test_Constructor_ZeroMorphoAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new CreditLine(address(0), owner, ozd, mm, address(mockProver));
    }

    function test_Constructor_ZeroOzdAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new CreditLine(address(mockMorphoCredit), owner, address(0), mm, address(mockProver));
    }

    function test_Constructor_ZeroMmAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new CreditLine(address(mockMorphoCredit), owner, ozd, address(0), address(mockProver));
    }

    // Setter function tests
    function test_SetOzd_Success() public {
        address newOzd = makeAddr("NewOZD");
        vm.prank(owner);
        creditLine.setOzd(newOzd);
        assertEq(creditLine.ozd(), newOzd);
    }

    function test_SetOzd_SameAddress() public {
        vm.prank(owner);
        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        creditLine.setOzd(ozd);
    }

    function test_SetMm_Success() public {
        address newMm = makeAddr("NewMM");
        vm.prank(owner);
        creditLine.setMm(newMm);
        assertEq(creditLine.mm(), newMm);
    }

    function test_SetMm_SameAddress() public {
        vm.prank(owner);
        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        creditLine.setMm(mm);
    }

    function test_SetProver_Success() public {
        address newProver = makeAddr("NewProver");
        vm.prank(owner);
        creditLine.setProver(newProver);
        assertEq(creditLine.prover(), newProver);
    }

    function test_SetProver_SameAddress() public {
        vm.prank(owner);
        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        creditLine.setProver(address(mockProver));
    }

    function test_SetProver_ZeroAddress() public {
        vm.prank(owner);
        creditLine.setProver(address(0));
        assertEq(creditLine.prover(), address(0));
    }

    function test_SetInsuranceFund_Success() public {
        address newInsuranceFund = makeAddr("NewInsuranceFund");
        vm.prank(owner);
        creditLine.setInsuranceFund(newInsuranceFund);
        // Note: insuranceFund is not public, so we can't directly test it
    }

    function test_SetInsuranceFund_SameAddress() public {
        vm.prank(owner);
        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        creditLine.setInsuranceFund(address(mockInsuranceFund));
    }

    // setCreditLines tests
    function test_SetCreditLines_Success() public {
        Id[] memory ids = new Id[](1);
        address[] memory borrowers = new address[](1);
        uint256[] memory vv = new uint256[](1);
        uint256[] memory credit = new uint256[](1);
        uint128[] memory drp = new uint128[](1);

        ids[0] = testId;
        borrowers[0] = borrower;
        vv[0] = 500e18; // Below maxVV
        credit[0] = 300e18; // Between min and max
        drp[0] = uint128(0.05 ether / int128(365 days)); // Below maxDRP

        vm.prank(owner);
        creditLine.setCreditLines(ids, borrowers, vv, credit, drp);

        // Verify credit line was set in mock
        assertEq(mockMorphoCredit.creditLines(testId, borrower), credit[0]);
        assertEq(mockMorphoCredit.drpRates(testId, borrower), drp[0]);
    }

    function test_SetCreditLines_InvalidArrayLength() public {
        Id[] memory ids = new Id[](1);
        address[] memory borrowers = new address[](2); // Different length
        uint256[] memory vv = new uint256[](1);
        uint256[] memory credit = new uint256[](1);
        uint128[] memory drp = new uint128[](1);

        vm.prank(owner);
        vm.expectRevert(ErrorsLib.InvalidArrayLength.selector);
        creditLine.setCreditLines(ids, borrowers, vv, credit, drp);
    }

    function test_SetCreditLines_ProverRejects() public {
        mockProver.setShouldVerify(false);

        Id[] memory ids = new Id[](1);
        address[] memory borrowers = new address[](1);
        uint256[] memory vv = new uint256[](1);
        uint256[] memory credit = new uint256[](1);
        uint128[] memory drp = new uint128[](1);

        ids[0] = testId;
        borrowers[0] = borrower;
        vv[0] = 500e18;
        credit[0] = 300e18;
        drp[0] = uint128(0.05 ether / int128(365 days));

        vm.prank(owner);
        vm.expectRevert(ErrorsLib.Unverified.selector);
        creditLine.setCreditLines(ids, borrowers, vv, credit, drp);
    }

    function test_SetCreditLines_NoProver() public {
        // Set prover to zero address
        vm.prank(owner);
        creditLine.setProver(address(0));

        Id[] memory ids = new Id[](1);
        address[] memory borrowers = new address[](1);
        uint256[] memory vv = new uint256[](1);
        uint256[] memory credit = new uint256[](1);
        uint128[] memory drp = new uint128[](1);

        ids[0] = testId;
        borrowers[0] = borrower;
        vv[0] = 500e18;
        credit[0] = 300e18;
        drp[0] = uint128(0.005 ether / int128(365 days));

        vm.prank(owner);
        creditLine.setCreditLines(ids, borrowers, vv, credit, drp);
        // Should not revert even with mockProver.setShouldVerify(false)
    }

    function test_SetCreditLines_MaxVvExceeded() public {
        Id[] memory ids = new Id[](1);
        address[] memory borrowers = new address[](1);
        uint256[] memory vv = new uint256[](1);
        uint256[] memory credit = new uint256[](1);
        uint128[] memory drp = new uint128[](1);

        ids[0] = testId;
        borrowers[0] = borrower;
        vv[0] = 2000e18; // Above maxVV (1000e18)
        credit[0] = 300e18;
        drp[0] = uint128(0.005 ether / int128(365 days));

        vm.prank(owner);
        vm.expectRevert(ErrorsLib.MaxVvExceeded.selector);
        creditLine.setCreditLines(ids, borrowers, vv, credit, drp);
    }

    function test_SetCreditLines_MaxCreditLineExceeded() public {
        Id[] memory ids = new Id[](1);
        address[] memory borrowers = new address[](1);
        uint256[] memory vv = new uint256[](1);
        uint256[] memory credit = new uint256[](1);
        uint128[] memory drp = new uint128[](1);

        ids[0] = testId;
        borrowers[0] = borrower;
        vv[0] = 500e18;
        credit[0] = 20000e18; // Above maxCreditLine (10000e18)
        drp[0] = uint128(0.005 ether / int128(365 days));

        vm.prank(owner);
        vm.expectRevert(ErrorsLib.MaxCreditLineExceeded.selector);
        creditLine.setCreditLines(ids, borrowers, vv, credit, drp);
    }

    function test_SetCreditLines_MinCreditLineExceeded() public {
        Id[] memory ids = new Id[](1);
        address[] memory borrowers = new address[](1);
        uint256[] memory vv = new uint256[](1);
        uint256[] memory credit = new uint256[](1);
        uint128[] memory drp = new uint128[](1);

        ids[0] = testId;
        borrowers[0] = borrower;
        vv[0] = 500e18;
        credit[0] = 50e18; // Below minCreditLine (100e18)
        drp[0] = 0.05 ether;

        vm.prank(owner);
        vm.expectRevert(ErrorsLib.MinCreditLineExceeded.selector);
        creditLine.setCreditLines(ids, borrowers, vv, credit, drp);
    }

    function test_SetCreditLines_MaxLtvExceeded() public {
        Id[] memory ids = new Id[](1);
        address[] memory borrowers = new address[](1);
        uint256[] memory vv = new uint256[](1);
        uint256[] memory credit = new uint256[](1);
        uint128[] memory drp = new uint128[](1);

        ids[0] = testId;
        borrowers[0] = borrower;
        vv[0] = 500e18;
        credit[0] = 500e18; // 100% LTV, above maxLTV (80%)
        drp[0] = 0.05 ether;

        vm.prank(owner);
        vm.expectRevert(ErrorsLib.MaxLtvExceeded.selector);
        creditLine.setCreditLines(ids, borrowers, vv, credit, drp);
    }

    function test_SetCreditLines_MaxDrpExceeded() public {
        Id[] memory ids = new Id[](1);
        address[] memory borrowers = new address[](1);
        uint256[] memory vv = new uint256[](1);
        uint256[] memory credit = new uint256[](1);
        uint128[] memory drp = new uint128[](1);

        ids[0] = testId;
        borrowers[0] = borrower;
        vv[0] = 500e18;
        credit[0] = 300e18;
        drp[0] = 0.2 ether; // Above maxDRP (0.1 ether)

        vm.prank(owner);
        vm.expectRevert(ErrorsLib.MaxDrpExceeded.selector);
        creditLine.setCreditLines(ids, borrowers, vv, credit, drp);
    }

    // closeCycleAndPostObligations tests
    function test_CloseCycleAndPostObligations_Success() public {
        uint256 endDate = block.timestamp + 30 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory endingBalances = new uint256[](1);

        borrowers[0] = borrower;
        repaymentBps[0] = 500; // 5%
        endingBalances[0] = 1000e18;

        vm.prank(owner);
        creditLine.closeCycleAndPostObligations(testId, endDate, borrowers, repaymentBps, endingBalances);
        // Should not revert
    }

    // addObligationsToLatestCycle tests
    function test_AddObligationsToLatestCycle_Success() public {
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory endingBalances = new uint256[](1);

        borrowers[0] = borrower;
        repaymentBps[0] = 500; // 5%
        endingBalances[0] = 1000e18;

        vm.prank(owner);
        creditLine.addObligationsToLatestCycle(testId, borrowers, repaymentBps, endingBalances);
        // Should not revert
    }

    // settle tests
    function test_Settle_Success() public {
        uint256 assets = 1000e18;
        uint256 cover = 500e18;

        vm.prank(owner);
        (uint256 writtenOffAssets, uint256 writtenOffShares) =
            creditLine.settle(testMarketParams, borrower, assets, cover);

        assertEq(writtenOffAssets, 1000e18);
        assertEq(writtenOffShares, 1000e18);
    }

    function test_Settle_InvalidCoverAmount() public {
        uint256 assets = 1000e18;
        uint256 cover = 1500e18; // Greater than assets

        vm.prank(owner);
        vm.expectRevert(ErrorsLib.InvalidCoverAmount.selector);
        creditLine.settle(testMarketParams, borrower, assets, cover);
    }

    function test_Settle_ZeroCover() public {
        uint256 assets = 1000e18;
        uint256 cover = 0;

        vm.prank(owner);
        (uint256 writtenOffAssets, uint256 writtenOffShares) =
            creditLine.settle(testMarketParams, borrower, assets, cover);

        assertEq(writtenOffAssets, 1000e18);
        assertEq(writtenOffShares, 1000e18);
    }

    // Integration tests
    function test_SetCreditLines_MultipleBorrowers() public {
        Id[] memory ids = new Id[](2);
        address[] memory borrowers = new address[](2);
        uint256[] memory vv = new uint256[](2);
        uint256[] memory credit = new uint256[](2);
        uint128[] memory drp = new uint128[](2);

        ids[0] = testId;
        ids[1] = testId;
        borrowers[0] = borrower;
        borrowers[1] = makeAddr("Borrower2");
        vv[0] = 500e18;
        vv[1] = 600e18;
        credit[0] = 300e18;
        credit[1] = 400e18;
        drp[0] = uint128(0.05 ether / int128(365 days));
        drp[1] = uint128(0.07 ether / int128(365 days));

        vm.prank(owner);
        creditLine.setCreditLines(ids, borrowers, vv, credit, drp);

        // Verify both credit lines were set
        assertEq(mockMorphoCredit.creditLines(testId, borrower), credit[0]);
        assertEq(mockMorphoCredit.creditLines(testId, borrowers[1]), credit[1]);
    }

    function test_Constants() public {
        // Test that MAX_DRP constant is accessible (though it's private, we can test its effect)
        // MAX_DRP should be ~31.7 billion per second for 100% APR
        // We can test this by trying to set a DRP above this limit
        Id[] memory ids = new Id[](1);
        address[] memory borrowers = new address[](1);
        uint256[] memory vv = new uint256[](1);
        uint256[] memory credit = new uint256[](1);
        uint128[] memory drp = new uint128[](1);

        ids[0] = testId;
        borrowers[0] = borrower;
        vv[0] = 500e18;
        credit[0] = 300e18;
        drp[0] = type(uint128).max; // Maximum possible DRP

        vm.prank(owner);
        vm.expectRevert(ErrorsLib.MaxDrpExceeded.selector);
        creditLine.setCreditLines(ids, borrowers, vv, credit, drp);
    }

    // Access control tests for privileged functions
    function test_SetCreditLines_NotOwnerOrOzd() public {
        Id[] memory ids = new Id[](1);
        address[] memory borrowers = new address[](1);
        uint256[] memory vv = new uint256[](1);
        uint256[] memory credit = new uint256[](1);
        uint128[] memory drp = new uint128[](1);

        ids[0] = testId;
        borrowers[0] = borrower;
        vv[0] = 500e18;
        credit[0] = 300e18;
        drp[0] = 0.05 ether;

        vm.prank(nonOwner);
        vm.expectRevert(ErrorsLib.NotOwnerOrOzd.selector);
        creditLine.setCreditLines(ids, borrowers, vv, credit, drp);
    }

    function test_CloseCycleAndPostObligations_NotOwnerOrOzd() public {
        uint256 endDate = block.timestamp + 30 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory endingBalances = new uint256[](1);

        borrowers[0] = borrower;
        repaymentBps[0] = 500; // 5%
        endingBalances[0] = 1000e18;

        vm.prank(nonOwner);
        vm.expectRevert(ErrorsLib.NotOwnerOrOzd.selector);
        creditLine.closeCycleAndPostObligations(testId, endDate, borrowers, repaymentBps, endingBalances);
    }

    function test_AddObligationsToLatestCycle_NotOwnerOrOzd() public {
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory endingBalances = new uint256[](1);

        borrowers[0] = borrower;
        repaymentBps[0] = 500; // 5%
        endingBalances[0] = 1000e18;

        vm.prank(nonOwner);
        vm.expectRevert(ErrorsLib.NotOwnerOrOzd.selector);
        creditLine.addObligationsToLatestCycle(testId, borrowers, repaymentBps, endingBalances);
    }

    function test_Settle_NotOwnerOrOzd() public {
        uint256 assets = 1000e18;
        uint256 cover = 500e18;

        vm.prank(nonOwner);
        vm.expectRevert(ErrorsLib.NotOwnerOrOzd.selector);
        creditLine.settle(testMarketParams, borrower, assets, cover);
    }
}
