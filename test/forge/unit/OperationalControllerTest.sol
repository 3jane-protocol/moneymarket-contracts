// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {OperationalController} from "../../../src/OperationalController.sol";
import {ProtocolConfig} from "../../../src/ProtocolConfig.sol";
import {CreditLine} from "../../../src/CreditLine.sol";
import {Id, MarketParams} from "../../../src/interfaces/IMorpho.sol";
import {
    TransparentUpgradeableProxy
} from "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {ERC20Mock} from "../../../src/mocks/ERC20Mock.sol";

contract OperationalMockMorphoCredit {
    address public protocolConfig;

    mapping(Id => mapping(address => uint128)) public borrowerDrp;
    mapping(Id => mapping(address => uint256)) public borrowerCredit;

    Id public lastCreditId;
    address public lastCreditBorrower;
    uint256 public lastCredit;
    uint128 public lastDrp;

    Id public lastCloseId;
    uint256 public lastCloseEndDate;
    uint256 public lastCloseBorrowerCount;
    address public lastCloseFirstBorrower;
    uint256 public lastCloseFirstRepaymentBps;
    uint256 public lastCloseFirstEndingBalance;

    Id public lastAddId;
    uint256 public lastAddBorrowerCount;
    address public lastAddFirstBorrower;
    uint256 public lastAddFirstRepaymentBps;
    uint256 public lastAddFirstEndingBalance;

    MarketParams public lastSettledMarketParams;
    address public lastSettledBorrower;
    MarketParams public lastRepaidMarketParams;
    address public lastRepaidBorrower;
    uint256 public lastRepayAssets;

    constructor(address _protocolConfig) {
        protocolConfig = _protocolConfig;
    }

    function setCreditLine(Id id, address borrower, uint256 credit, uint128 drp) external {
        borrowerCredit[id][borrower] = credit;
        borrowerDrp[id][borrower] = drp;
        lastCreditId = id;
        lastCreditBorrower = borrower;
        lastCredit = credit;
        lastDrp = drp;
    }

    function borrowerPremium(Id id, address borrower) external view returns (uint128, uint128, uint128) {
        return (uint128(block.timestamp), borrowerDrp[id][borrower], 0);
    }

    function closeCycleAndPostObligations(
        Id id,
        uint256 endDate,
        address[] calldata borrowers,
        uint256[] calldata repaymentBps,
        uint256[] calldata endingBalances
    ) external {
        lastCloseId = id;
        lastCloseEndDate = endDate;
        lastCloseBorrowerCount = borrowers.length;
        if (borrowers.length > 0) {
            lastCloseFirstBorrower = borrowers[0];
            lastCloseFirstRepaymentBps = repaymentBps[0];
            lastCloseFirstEndingBalance = endingBalances[0];
        }
    }

    function addObligationsToLatestCycle(
        Id id,
        address[] calldata borrowers,
        uint256[] calldata repaymentBps,
        uint256[] calldata endingBalances
    ) external {
        lastAddId = id;
        lastAddBorrowerCount = borrowers.length;
        if (borrowers.length > 0) {
            lastAddFirstBorrower = borrowers[0];
            lastAddFirstRepaymentBps = repaymentBps[0];
            lastAddFirstEndingBalance = endingBalances[0];
        }
    }

    function repay(MarketParams memory marketParams, uint256 assets, uint256, address borrower, bytes memory)
        external
        returns (uint256, uint256)
    {
        lastRepaidMarketParams = marketParams;
        lastRepaidBorrower = borrower;
        lastRepayAssets = assets;
        return (assets, 0);
    }

    function settleAccount(MarketParams memory marketParams, address borrower) external returns (uint256, uint256) {
        lastSettledMarketParams = marketParams;
        lastSettledBorrower = borrower;
        return (100 ether, 50 ether);
    }
}

contract OperationalMockInsuranceFund {
    address public lastToken;
    uint256 public lastAmount;

    function bring(address loanToken, uint256 amount) external {
        lastToken = loanToken;
        lastAmount = amount;
    }
}

contract OperationalControllerTest is Test {
    OperationalController internal controller;
    ProtocolConfig internal protocolConfig;
    CreditLine internal creditLine;
    OperationalMockMorphoCredit internal mockMorpho;
    OperationalMockInsuranceFund internal mockInsuranceFund;

    address internal protocolOwner;
    address internal owner;
    address internal emergencyMultisig;
    address internal operator;
    address internal randomUser;

    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 private constant IS_PAUSED = keccak256("IS_PAUSED");
    bytes32 private constant DEBT_CAP = keccak256("DEBT_CAP");
    bytes32 private constant MAX_ON_CREDIT = keccak256("MAX_ON_CREDIT");
    bytes32 private constant USD3_SUPPLY_CAP = keccak256("USD3_SUPPLY_CAP");

    function setUp() public {
        protocolOwner = makeAddr("ProtocolOwner");
        owner = makeAddr("Owner");
        emergencyMultisig = makeAddr("EmergencyMultisig");
        operator = makeAddr("Operator");
        randomUser = makeAddr("RandomUser");

        ProtocolConfig protocolConfigImpl = new ProtocolConfig();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(protocolConfigImpl),
            address(this),
            abi.encodeWithSelector(ProtocolConfig.initialize.selector, protocolOwner)
        );
        protocolConfig = ProtocolConfig(address(proxy));

        mockMorpho = new OperationalMockMorphoCredit(address(protocolConfig));
        mockInsuranceFund = new OperationalMockInsuranceFund();

        creditLine = new CreditLine(
            address(mockMorpho), protocolOwner, makeAddr("InitialOzd"), makeAddr("MarkdownManager"), address(0)
        );

        vm.startPrank(protocolOwner);
        creditLine.setInsuranceFund(address(mockInsuranceFund));
        protocolConfig.setConfig(keccak256("MAX_LTV"), 1e18);
        protocolConfig.setConfig(keccak256("MAX_VV"), 10000 ether);
        protocolConfig.setConfig(keccak256("MAX_CREDIT_LINE"), 5000 ether);
        protocolConfig.setConfig(keccak256("MIN_CREDIT_LINE"), 0);
        protocolConfig.setConfig(keccak256("MAX_DRP"), 1000000);
        vm.stopPrank();

        address[] memory emergencyAuthorized = new address[](1);
        emergencyAuthorized[0] = emergencyMultisig;
        address[] memory operators = new address[](1);
        operators[0] = operator;

        controller = new OperationalController(
            address(protocolConfig), address(creditLine), owner, emergencyAuthorized, operators
        );

        vm.startPrank(protocolOwner);
        protocolConfig.setEmergencyAdmin(address(controller));
        creditLine.setOzd(address(controller));
        vm.stopPrank();
    }

    function test_Constructor_InvalidAddress() public {
        address[] memory emergencyAuthorized = _single(emergencyMultisig);
        address[] memory operators = _single(operator);

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new OperationalController(address(0), address(creditLine), owner, emergencyAuthorized, operators);

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new OperationalController(address(protocolConfig), address(0), owner, emergencyAuthorized, operators);

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new OperationalController(
            address(protocolConfig), address(creditLine), address(0), emergencyAuthorized, operators
        );
    }

    function test_Constructor_ZeroAddressInRoleArrays() public {
        address[] memory emergencyAuthorized = new address[](2);
        emergencyAuthorized[0] = emergencyMultisig;
        emergencyAuthorized[1] = address(0);
        address[] memory operators = _single(operator);

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new OperationalController(address(protocolConfig), address(creditLine), owner, emergencyAuthorized, operators);

        emergencyAuthorized = _single(emergencyMultisig);
        operators = new address[](2);
        operators[0] = operator;
        operators[1] = address(0);

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new OperationalController(address(protocolConfig), address(creditLine), owner, emergencyAuthorized, operators);
    }

    function test_Constructor_SetsCorrectValuesAndRoles() public {
        address operator2 = makeAddr("Operator2");
        address emergency2 = makeAddr("Emergency2");

        address[] memory emergencyAuthorized = new address[](2);
        emergencyAuthorized[0] = emergencyMultisig;
        emergencyAuthorized[1] = emergency2;
        address[] memory operators = new address[](2);
        operators[0] = operator;
        operators[1] = operator2;

        OperationalController fresh = new OperationalController(
            address(protocolConfig), address(creditLine), owner, emergencyAuthorized, operators
        );

        assertEq(address(fresh.protocolConfig()), address(protocolConfig));
        assertEq(address(fresh.creditLine()), address(creditLine));
        assertEq(fresh.owner(), owner);
        assertTrue(fresh.hasRole(fresh.EMERGENCY_AUTHORIZED_ROLE(), emergencyMultisig));
        assertTrue(fresh.hasRole(fresh.EMERGENCY_AUTHORIZED_ROLE(), emergency2));
        assertTrue(fresh.hasRole(fresh.OPERATOR_ROLE(), operator));
        assertTrue(fresh.hasRole(fresh.OPERATOR_ROLE(), operator2));
        assertEq(fresh.getRoleMemberCount(fresh.OWNER_ROLE()), 1);
        assertEq(fresh.getRoleMemberCount(fresh.EMERGENCY_AUTHORIZED_ROLE()), 2);
        assertEq(fresh.getRoleMemberCount(fresh.OPERATOR_ROLE()), 2);
        assertEq(fresh.getRoleAdmin(fresh.OWNER_ROLE()), DEFAULT_ADMIN_ROLE);
        assertEq(fresh.getRoleAdmin(fresh.EMERGENCY_AUTHORIZED_ROLE()), fresh.OWNER_ROLE());
        assertEq(fresh.getRoleAdmin(fresh.OPERATOR_ROLE()), fresh.OWNER_ROLE());
        assertEq(fresh.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 0);
    }

    function test_SetConfig_Pause_OnlyEmergencyAuthorized() public {
        vm.prank(emergencyMultisig);
        controller.setConfig(IS_PAUSED, 1);
        assertEq(protocolConfig.config(IS_PAUSED), 1);

        vm.expectRevert(_accessControlError(randomUser, controller.EMERGENCY_AUTHORIZED_ROLE()));
        vm.prank(randomUser);
        controller.setConfig(IS_PAUSED, 1);
    }

    function test_SetConfig_EnforcesEmergencyConfigConstraints() public {
        vm.prank(emergencyMultisig);
        controller.setConfig(IS_PAUSED, 1);

        vm.prank(emergencyMultisig);
        vm.expectRevert(ProtocolConfig.EmergencyCanOnlyPause.selector);
        controller.setConfig(IS_PAUSED, 0);

        vm.prank(emergencyMultisig);
        controller.setConfig(DEBT_CAP, 0);

        vm.prank(emergencyMultisig);
        vm.expectRevert(ProtocolConfig.EmergencyCanOnlySetToZero.selector);
        controller.setConfig(DEBT_CAP, 1000);

        vm.prank(emergencyMultisig);
        controller.setConfig(MAX_ON_CREDIT, 0);

        vm.prank(emergencyMultisig);
        controller.setConfig(USD3_SUPPLY_CAP, 0);

        vm.prank(emergencyMultisig);
        vm.expectRevert(ProtocolConfig.UnauthorizedEmergencyConfig.selector);
        controller.setConfig(keccak256("RANDOM_PARAM"), 0);
    }

    function test_EmergencyRevokeCreditLine_PreservesDrpAndEmits() public {
        Id marketId = Id.wrap(bytes32(uint256(1)));
        address borrower = makeAddr("Borrower");
        uint128 originalDrp = 500;

        _setCreditLine(marketId, borrower, 1000 ether, 500 ether, originalDrp);
        assertEq(mockMorpho.borrowerDrp(marketId, borrower), originalDrp);

        vm.expectEmit(true, true, false, true);
        emit OperationalController.CreditLineRevoked(borrower, emergencyMultisig);

        vm.prank(emergencyMultisig);
        controller.emergencyRevokeCreditLine(marketId, borrower);

        assertEq(mockMorpho.borrowerCredit(marketId, borrower), 0);
        assertEq(mockMorpho.borrowerDrp(marketId, borrower), originalDrp);
    }

    function test_EmergencyRevokeCreditLine_AccessAndZeroBorrower() public {
        Id marketId = Id.wrap(bytes32(uint256(1)));
        address borrower = makeAddr("Borrower");

        vm.expectRevert(_accessControlError(randomUser, controller.EMERGENCY_AUTHORIZED_ROLE()));
        vm.prank(randomUser);
        controller.emergencyRevokeCreditLine(marketId, borrower);

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(emergencyMultisig);
        controller.emergencyRevokeCreditLine(marketId, address(0));
    }

    function test_OperatorSetCreditLines_ForwardsArgs() public {
        Id marketId = Id.wrap(bytes32(uint256(2)));
        address borrower = makeAddr("Borrower");

        _operatorSetCreditLine(marketId, borrower, 2000 ether, 750 ether, 123);

        assertEq(Id.unwrap(mockMorpho.lastCreditId()), Id.unwrap(marketId));
        assertEq(mockMorpho.lastCreditBorrower(), borrower);
        assertEq(mockMorpho.lastCredit(), 750 ether);
        assertEq(mockMorpho.lastDrp(), 123);
    }

    function test_OperatorCloseCycle_ForwardsArgs() public {
        Id marketId = Id.wrap(bytes32(uint256(3)));
        address borrower = makeAddr("Borrower");
        address[] memory borrowers = _single(borrower);
        uint256[] memory repaymentBps = _singleUint(500);
        uint256[] memory endingBalances = _singleUint(1000 ether);

        vm.prank(operator);
        controller.closeCycleAndPostObligations(marketId, 123456, borrowers, repaymentBps, endingBalances);

        assertEq(Id.unwrap(mockMorpho.lastCloseId()), Id.unwrap(marketId));
        assertEq(mockMorpho.lastCloseEndDate(), 123456);
        assertEq(mockMorpho.lastCloseBorrowerCount(), 1);
        assertEq(mockMorpho.lastCloseFirstBorrower(), borrower);
        assertEq(mockMorpho.lastCloseFirstRepaymentBps(), 500);
        assertEq(mockMorpho.lastCloseFirstEndingBalance(), 1000 ether);
    }

    function test_OperatorAddObligations_ForwardsArgs() public {
        Id marketId = Id.wrap(bytes32(uint256(4)));
        address borrower = makeAddr("Borrower");
        address[] memory borrowers = _single(borrower);
        uint256[] memory repaymentBps = _singleUint(250);
        uint256[] memory endingBalances = _singleUint(400 ether);

        vm.prank(operator);
        controller.addObligationsToLatestCycle(marketId, borrowers, repaymentBps, endingBalances);

        assertEq(Id.unwrap(mockMorpho.lastAddId()), Id.unwrap(marketId));
        assertEq(mockMorpho.lastAddBorrowerCount(), 1);
        assertEq(mockMorpho.lastAddFirstBorrower(), borrower);
        assertEq(mockMorpho.lastAddFirstRepaymentBps(), 250);
        assertEq(mockMorpho.lastAddFirstEndingBalance(), 400 ether);
    }

    function test_OperatorSettle_ForwardsArgsAndReturnsValues() public {
        MarketParams memory marketParams = _marketParams();
        address borrower = makeAddr("Borrower");

        vm.prank(operator);
        (uint256 writtenOffAssets, uint256 writtenOffShares) = controller.settle(marketParams, borrower, 100 ether, 0);

        assertEq(writtenOffAssets, 100 ether);
        assertEq(writtenOffShares, 50 ether);
        assertEq(mockMorpho.lastSettledBorrower(), borrower);

        (address loanToken,,,,,) = mockMorpho.lastSettledMarketParams();
        assertEq(loanToken, marketParams.loanToken);
    }

    function test_OperatorSettle_WithNonzeroCover_UsesInsuranceFundPath() public {
        ERC20Mock loanToken = new ERC20Mock();
        MarketParams memory marketParams = _marketParams();
        marketParams.loanToken = address(loanToken);
        address borrower = makeAddr("Borrower");
        uint256 cover = 25 ether;

        vm.prank(operator);
        (uint256 writtenOffAssets, uint256 writtenOffShares) =
            controller.settle(marketParams, borrower, 100 ether, cover);

        assertEq(writtenOffAssets, 100 ether);
        assertEq(writtenOffShares, 50 ether);
        assertEq(mockInsuranceFund.lastToken(), address(loanToken));
        assertEq(mockInsuranceFund.lastAmount(), cover);
        assertEq(loanToken.allowance(address(creditLine), address(mockMorpho)), cover);
        assertEq(mockMorpho.lastRepaidBorrower(), borrower);
        assertEq(mockMorpho.lastRepayAssets(), cover);
        assertEq(mockMorpho.lastSettledBorrower(), borrower);

        (address repaidLoanToken,,,,,) = mockMorpho.lastRepaidMarketParams();
        assertEq(repaidLoanToken, address(loanToken));
    }

    function test_OperatorSettle_RevertsWhenCoverExceedsAssets() public {
        vm.prank(operator);
        vm.expectRevert(ErrorsLib.InvalidCoverAmount.selector);
        controller.settle(_marketParams(), makeAddr("Borrower"), 100 ether, 101 ether);
    }

    function test_OperatorFunctions_RejectNonOperators() public {
        Id marketId = Id.wrap(bytes32(uint256(5)));
        address borrower = makeAddr("Borrower");
        bytes memory operatorError = _accessControlError(randomUser, controller.OPERATOR_ROLE());

        vm.expectRevert(operatorError);
        vm.prank(randomUser);
        _callSetCreditLines(marketId, borrower);

        vm.expectRevert(operatorError);
        vm.prank(randomUser);
        controller.closeCycleAndPostObligations(marketId, 1, _single(borrower), _singleUint(1), _singleUint(1));

        vm.expectRevert(operatorError);
        vm.prank(randomUser);
        controller.addObligationsToLatestCycle(marketId, _single(borrower), _singleUint(1), _singleUint(1));

        vm.expectRevert(operatorError);
        vm.prank(randomUser);
        controller.settle(_marketParams(), borrower, 100 ether, 0);
    }

    function test_RoleIsolation() public {
        Id marketId = Id.wrap(bytes32(uint256(6)));
        address borrower = makeAddr("Borrower");
        bytes memory operatorMissingEmergencyRole =
            _accessControlError(operator, controller.EMERGENCY_AUTHORIZED_ROLE());
        bytes memory emergencyMissingOperatorRole = _accessControlError(emergencyMultisig, controller.OPERATOR_ROLE());
        bytes memory ownerMissingEmergencyRole = _accessControlError(owner, controller.EMERGENCY_AUTHORIZED_ROLE());
        bytes memory ownerMissingOperatorRole = _accessControlError(owner, controller.OPERATOR_ROLE());

        vm.expectRevert(operatorMissingEmergencyRole);
        vm.prank(operator);
        controller.setConfig(IS_PAUSED, 1);

        vm.expectRevert(operatorMissingEmergencyRole);
        vm.prank(operator);
        controller.emergencyRevokeCreditLine(marketId, borrower);

        vm.expectRevert(emergencyMissingOperatorRole);
        vm.prank(emergencyMultisig);
        _callSetCreditLines(marketId, borrower);

        vm.expectRevert(emergencyMissingOperatorRole);
        vm.prank(emergencyMultisig);
        controller.closeCycleAndPostObligations(marketId, 1, _single(borrower), _singleUint(1), _singleUint(1));

        vm.expectRevert(emergencyMissingOperatorRole);
        vm.prank(emergencyMultisig);
        controller.addObligationsToLatestCycle(marketId, _single(borrower), _singleUint(1), _singleUint(1));

        vm.expectRevert(emergencyMissingOperatorRole);
        vm.prank(emergencyMultisig);
        controller.settle(_marketParams(), borrower, 100 ether, 0);

        vm.expectRevert(ownerMissingEmergencyRole);
        vm.prank(owner);
        controller.setConfig(IS_PAUSED, 1);

        vm.expectRevert(ownerMissingEmergencyRole);
        vm.prank(owner);
        controller.emergencyRevokeCreditLine(marketId, borrower);

        vm.expectRevert(ownerMissingOperatorRole);
        vm.prank(owner);
        _callSetCreditLines(marketId, borrower);

        vm.expectRevert(ownerMissingOperatorRole);
        vm.prank(owner);
        controller.closeCycleAndPostObligations(marketId, 1, _single(borrower), _singleUint(1), _singleUint(1));

        vm.expectRevert(ownerMissingOperatorRole);
        vm.prank(owner);
        controller.addObligationsToLatestCycle(marketId, _single(borrower), _singleUint(1), _singleUint(1));

        vm.expectRevert(ownerMissingOperatorRole);
        vm.prank(owner);
        controller.settle(_marketParams(), borrower, 100 ether, 0);
    }

    function test_TransferOwnership_Success() public {
        address newOwner = makeAddr("NewOwner");

        vm.expectEmit(true, false, false, true);
        emit EventsLib.SetOwner(newOwner);

        vm.prank(owner);
        controller.transferOwnership(newOwner);

        assertEq(controller.owner(), newOwner);
        assertFalse(controller.hasRole(controller.OWNER_ROLE(), owner));
        assertTrue(controller.hasRole(controller.OWNER_ROLE(), newOwner));
        assertEq(controller.getRoleMemberCount(controller.OWNER_ROLE()), 1);
    }

    function test_TransferOwnership_Reverts() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(owner);
        controller.transferOwnership(address(0));

        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        vm.prank(owner);
        controller.transferOwnership(owner);

        vm.expectRevert(_accessControlError(randomUser, controller.OWNER_ROLE()));
        vm.prank(randomUser);
        controller.transferOwnership(makeAddr("NewOwner"));
    }

    function test_RenounceRole_BlockedForOwnerRoleAllowedForOthers() public {
        bytes32 ownerRole = controller.OWNER_ROLE();
        bytes32 operatorRole = controller.OPERATOR_ROLE();
        bytes32 emergencyRole = controller.EMERGENCY_AUTHORIZED_ROLE();

        vm.expectRevert(ErrorsLib.CannotRenounceOwnerRole.selector);
        vm.prank(owner);
        controller.renounceRole(ownerRole, owner);

        assertTrue(controller.hasRole(operatorRole, operator));

        vm.prank(operator);
        controller.renounceRole(operatorRole, operator);

        assertFalse(controller.hasRole(operatorRole, operator));

        assertTrue(controller.hasRole(emergencyRole, emergencyMultisig));

        vm.prank(emergencyMultisig);
        controller.renounceRole(emergencyRole, emergencyMultisig);

        assertFalse(controller.hasRole(emergencyRole, emergencyMultisig));
    }

    function test_OwnerRole_CannotBeManagedThroughAccessControl() public {
        address extraOwner = makeAddr("ExtraOwner");
        bytes32 ownerRole = controller.OWNER_ROLE();

        assertEq(controller.getRoleAdmin(ownerRole), DEFAULT_ADMIN_ROLE);
        assertEq(controller.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 0);

        vm.expectRevert(_accessControlError(owner, DEFAULT_ADMIN_ROLE));
        vm.prank(owner);
        controller.grantRole(ownerRole, extraOwner);

        vm.expectRevert(_accessControlError(owner, DEFAULT_ADMIN_ROLE));
        vm.prank(owner);
        controller.revokeRole(ownerRole, owner);

        assertEq(controller.owner(), owner);
        assertTrue(controller.hasRole(ownerRole, owner));
        assertFalse(controller.hasRole(ownerRole, extraOwner));
        assertEq(controller.getRoleMemberCount(ownerRole), 1);
    }

    function test_OwnerCanGrantAndRevokeRoles() public {
        address newEmergency = makeAddr("NewEmergency");
        address newOperator = makeAddr("NewOperator");

        vm.startPrank(owner);
        controller.grantRole(controller.EMERGENCY_AUTHORIZED_ROLE(), newEmergency);
        controller.grantRole(controller.OPERATOR_ROLE(), newOperator);
        assertTrue(controller.hasRole(controller.EMERGENCY_AUTHORIZED_ROLE(), newEmergency));
        assertTrue(controller.hasRole(controller.OPERATOR_ROLE(), newOperator));

        controller.revokeRole(controller.EMERGENCY_AUTHORIZED_ROLE(), newEmergency);
        controller.revokeRole(controller.OPERATOR_ROLE(), newOperator);
        vm.stopPrank();

        assertFalse(controller.hasRole(controller.EMERGENCY_AUTHORIZED_ROLE(), newEmergency));
        assertFalse(controller.hasRole(controller.OPERATOR_ROLE(), newOperator));
    }

    function test_NonOwnersCannotManageRoles() public {
        address target = makeAddr("Target");
        bytes32 ownerRole = controller.OWNER_ROLE();
        bytes32 operatorRole = controller.OPERATOR_ROLE();
        bytes32 emergencyRole = controller.EMERGENCY_AUTHORIZED_ROLE();

        vm.expectRevert(_accessControlError(emergencyMultisig, ownerRole));
        vm.prank(emergencyMultisig);
        controller.grantRole(operatorRole, target);

        vm.expectRevert(_accessControlError(operator, ownerRole));
        vm.prank(operator);
        controller.grantRole(emergencyRole, target);
    }

    function test_IntegrationScenario_OperatorCreditEmergencyRevokeOperatorSettle() public {
        Id marketId = Id.wrap(bytes32(uint256(7)));
        address borrower = makeAddr("Borrower");
        uint128 drp = 77;

        _operatorSetCreditLine(marketId, borrower, 1000 ether, 600 ether, drp);
        assertEq(mockMorpho.borrowerCredit(marketId, borrower), 600 ether);

        vm.prank(emergencyMultisig);
        controller.emergencyRevokeCreditLine(marketId, borrower);

        assertEq(mockMorpho.borrowerCredit(marketId, borrower), 0);
        assertEq(mockMorpho.borrowerDrp(marketId, borrower), drp);

        vm.prank(operator);
        (uint256 writtenOffAssets, uint256 writtenOffShares) =
            controller.settle(_marketParams(), borrower, 100 ether, 0);

        assertEq(writtenOffAssets, 100 ether);
        assertEq(writtenOffShares, 50 ether);
        assertEq(mockMorpho.lastSettledBorrower(), borrower);
    }

    function _operatorSetCreditLine(Id marketId, address borrower, uint256 vv, uint256 credit, uint128 drp) internal {
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

    function _setCreditLine(Id marketId, address borrower, uint256 vv, uint256 credit, uint128 drp) internal {
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

        vm.prank(address(controller));
        creditLine.setCreditLines(ids, borrowers, vvs, credits, drps);
    }

    function _callSetCreditLines(Id marketId, address borrower) internal {
        Id[] memory ids = new Id[](1);
        address[] memory borrowers = new address[](1);
        uint256[] memory vvs = new uint256[](1);
        uint256[] memory credits = new uint256[](1);
        uint128[] memory drps = new uint128[](1);

        ids[0] = marketId;
        borrowers[0] = borrower;
        vvs[0] = 1000 ether;
        credits[0] = 500 ether;
        drps[0] = 1;

        controller.setCreditLines(ids, borrowers, vvs, credits, drps);
    }

    function _marketParams() internal returns (MarketParams memory) {
        return MarketParams({
            loanToken: makeAddr("LoanToken"),
            collateralToken: makeAddr("CollateralToken"),
            oracle: makeAddr("Oracle"),
            irm: makeAddr("Irm"),
            lltv: 0,
            creditLine: address(creditLine)
        });
    }

    function _single(address value) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _singleUint(uint256 value) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function _accessControlError(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", account, role);
    }
}
