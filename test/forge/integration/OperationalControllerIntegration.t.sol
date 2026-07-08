// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {
    TransparentUpgradeableProxy
} from "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {CreditLine} from "../../../src/CreditLine.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {OperationalController} from "../../../src/OperationalController.sol";
import {ProtocolConfig} from "../../../src/ProtocolConfig.sol";
import {IProver} from "../../../src/interfaces/IProver.sol";
import {IMorpho, IMorphoCredit, Id, MarketParams, Position} from "../../../src/interfaces/IMorpho.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";
import {ERC20Mock} from "../../../src/mocks/ERC20Mock.sol";
import {IrmMock} from "../../../src/mocks/IrmMock.sol";
import {OracleMock} from "../../../src/mocks/OracleMock.sol";

contract RejectingProver is IProver {
    function verify(Id, address, uint256, uint256, uint128) external pure returns (bool) {
        return false;
    }
}

contract OperationalControllerIntegrationTest is Test {
    using MarketParamsLib for MarketParams;

    ProtocolConfig internal protocolConfig;
    IMorpho internal morpho;
    MorphoCredit internal morphoCredit;
    CreditLine internal creditLine;
    OperationalController internal controller;
    RejectingProver internal rejectingProver;

    ERC20Mock internal loanToken;
    ERC20Mock internal collateralToken;
    OracleMock internal oracle;
    IrmMock internal irm;

    address internal protocolOwner;
    address internal controllerOwner;
    address internal emergencyMultisig;
    address internal operator;
    address internal borrower;
    address internal secondBorrower;

    MarketParams internal marketParams;
    Id internal marketId;

    function setUp() public {
        protocolOwner = makeAddr("ProtocolOwner");
        controllerOwner = makeAddr("ControllerOwner");
        emergencyMultisig = makeAddr("EmergencyMultisig");
        operator = makeAddr("Operator");
        borrower = makeAddr("Borrower");
        secondBorrower = makeAddr("SecondBorrower");

        ProtocolConfig protocolConfigImpl = new ProtocolConfig();
        TransparentUpgradeableProxy protocolConfigProxy = new TransparentUpgradeableProxy(
            address(protocolConfigImpl),
            address(this),
            abi.encodeWithSelector(ProtocolConfig.initialize.selector, protocolOwner)
        );
        protocolConfig = ProtocolConfig(address(protocolConfigProxy));

        MorphoCredit morphoImpl = new MorphoCredit(address(protocolConfig));
        TransparentUpgradeableProxy morphoProxy = new TransparentUpgradeableProxy(
            address(morphoImpl), address(this), abi.encodeWithSelector(MorphoCredit.initialize.selector, protocolOwner)
        );
        morpho = IMorpho(address(morphoProxy));
        morphoCredit = MorphoCredit(address(morphoProxy));

        loanToken = new ERC20Mock();
        collateralToken = new ERC20Mock();
        oracle = new OracleMock();
        irm = new IrmMock();
        oracle.setPrice(1e36);

        creditLine = new CreditLine(
            address(morpho), protocolOwner, makeAddr("InitialOzd"), makeAddr("MarkdownManager"), address(0)
        );
        rejectingProver = new RejectingProver();

        address[] memory emergencyAuthorized = _singleAddress(emergencyMultisig);
        address[] memory operators = _singleAddress(operator);
        controller = new OperationalController(
            address(protocolConfig), address(creditLine), controllerOwner, emergencyAuthorized, operators
        );

        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.8 ether,
            creditLine: address(creditLine)
        });
        marketId = marketParams.id();

        vm.startPrank(protocolOwner);
        protocolConfig.setConfig(keccak256("MAX_LTV"), 0.8 ether);
        protocolConfig.setConfig(keccak256("MAX_VV"), 1000 ether);
        protocolConfig.setConfig(keccak256("MAX_CREDIT_LINE"), 500 ether);
        protocolConfig.setConfig(keccak256("MIN_CREDIT_LINE"), 0);
        protocolConfig.setConfig(keccak256("MAX_DRP"), 1_000_000);
        protocolConfig.setConfig(keccak256("CYCLE_DURATION"), 30 days);
        morpho.enableIrm(address(irm));
        morpho.enableLltv(0.8 ether);
        morpho.createMarket(marketParams);
        creditLine.setOzd(address(controller));
        vm.stopPrank();
    }

    function test_OperatorSetCreditLines_UsesRealCreditLineValidation() public {
        _operatorSetCreditLine(100 ether, 50 ether, 100);

        Position memory position = morpho.position(marketId, borrower);
        assertEq(position.collateral, 50 ether);

        (, uint128 drp,) = morphoCredit.borrowerPremium(marketId, borrower);
        assertEq(drp, 100);

        vm.expectRevert(ErrorsLib.MaxVvExceeded.selector);
        _operatorSetCreditLine(1000 ether + 1, 1 ether, 0);

        vm.expectRevert(ErrorsLib.MaxCreditLineExceeded.selector);
        _operatorSetCreditLine(1000 ether, 500 ether + 1, 0);

        vm.expectRevert(ErrorsLib.MaxLtvExceeded.selector);
        _operatorSetCreditLine(100 ether, 81 ether, 0);

        vm.expectRevert(ErrorsLib.MaxDrpExceeded.selector);
        _operatorSetCreditLine(100 ether, 50 ether, 1_000_001);

        vm.prank(protocolOwner);
        creditLine.setProver(address(rejectingProver));

        vm.expectRevert(ErrorsLib.Unverified.selector);
        _operatorSetCreditLine(100 ether, 50 ether, 0);
    }

    function test_OperatorCycleFunctions_UseRealMorphoCreditValidation() public {
        address[] memory borrowers = _singleAddress(borrower);
        uint256[] memory repaymentBps = _singleUint(500);
        uint256[] memory endingBalances = _singleUint(100 ether);

        vm.expectRevert(ErrorsLib.NoCyclesExist.selector);
        vm.prank(operator);
        controller.addObligationsToLatestCycle(marketId, borrowers, repaymentBps, endingBalances);

        vm.expectRevert(ErrorsLib.CannotCloseFutureCycle.selector);
        vm.prank(operator);
        controller.closeCycleAndPostObligations(marketId, block.timestamp + 1, borrowers, repaymentBps, endingBalances);

        vm.expectRevert(ErrorsLib.InconsistentInput.selector);
        vm.prank(operator);
        controller.closeCycleAndPostObligations(marketId, block.timestamp, borrowers, new uint256[](0), endingBalances);

        vm.prank(operator);
        controller.closeCycleAndPostObligations(marketId, block.timestamp, borrowers, repaymentBps, endingBalances);

        assertEq(morphoCredit.paymentCycle(marketId, 0), block.timestamp);
        (uint128 cycleId, uint128 amountDue, uint128 endingBalance) =
            morphoCredit.repaymentObligation(marketId, borrower);
        assertEq(cycleId, 0);
        assertEq(amountDue, 5 ether);
        assertEq(endingBalance, 100 ether);

        vm.expectRevert(ErrorsLib.RepaymentExceedsHundredPercent.selector);
        vm.prank(operator);
        controller.addObligationsToLatestCycle(marketId, borrowers, _singleUint(10001), endingBalances);

        address[] memory secondBorrowers = _singleAddress(secondBorrower);
        vm.prank(operator);
        controller.addObligationsToLatestCycle(marketId, secondBorrowers, _singleUint(250), _singleUint(200 ether));

        (cycleId, amountDue, endingBalance) = morphoCredit.repaymentObligation(marketId, secondBorrower);
        assertEq(cycleId, 0);
        assertEq(amountDue, 5 ether);
        assertEq(endingBalance, 200 ether);
    }

    function _operatorSetCreditLine(uint256 vv, uint256 credit, uint128 drp) internal {
        Id[] memory ids = new Id[](1);
        address[] memory borrowers = new address[](1);
        uint256[] memory vvs = new uint256[](1);
        uint256[] memory credits = new uint256[](1);
        uint128[] memory drps = new uint128[](1);

        ids[0] = marketId;
        borrowers[0] = borrower;
        vvs[0] = vv;
        credits[0] = credit;
        drps[0] = drp;

        vm.prank(operator);
        controller.setCreditLines(ids, borrowers, vvs, credits, drps);
    }

    function _singleAddress(address value) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _singleUint(uint256 value) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }
}
