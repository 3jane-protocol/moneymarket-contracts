// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {EmergencyController} from "../../../src/EmergencyController.sol";
import {ProtocolConfig} from "../../../src/ProtocolConfig.sol";
import {CreditLine} from "../../../src/CreditLine.sol";
import {Id, MarketParams} from "../../../src/interfaces/IMorpho.sol";
import {ICreditLine} from "../../../src/interfaces/ICreditLine.sol";
import {
    TransparentUpgradeableProxy
} from "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {IAccessControl} from "../../../lib/openzeppelin/contracts/access/IAccessControl.sol";

// Mock contracts for testing
contract MockMorphoCredit {
    address public protocolConfig;
    mapping(Id => mapping(address => uint128)) public borrowerDrp;

    constructor(address _protocolConfig) {
        protocolConfig = _protocolConfig;
    }

    function setCreditLine(Id id, address borrower, uint256, uint128 drp) external {
        borrowerDrp[id][borrower] = drp;
    }

    function borrowerPremium(Id id, address borrower) external view returns (uint128, uint128, uint128) {
        // Return mock data: (lastAccrualTime, rate, borrowAssetsAtLastAccrual)
        return (uint128(block.timestamp), borrowerDrp[id][borrower], 0);
    }

    function closeCycleAndPostObligations(Id, uint256, address[] calldata, uint256[] calldata, uint256[] calldata)
        external {}
    function addObligationsToLatestCycle(Id, address[] calldata, uint256[] calldata, uint256[] calldata) external {}

    function settle(MarketParams memory, address) external pure returns (uint256, uint256) {
        return (100 ether, 50 ether);
    }

    function settleAccount(MarketParams memory, address) external pure returns (uint256, uint256) {
        return (100 ether, 50 ether);
    }
}

contract MockInsuranceFund {
    function bring(address, uint256) external {}
}

contract EmergencyControllerTest is Test {
    EmergencyController internal emergencyController;
    ProtocolConfig internal protocolConfig;
    CreditLine internal creditLine;
    MockMorphoCredit internal mockMorpho;
    MockInsuranceFund internal mockInsuranceFund;

    address internal protocolOwner;
    address internal emergencyMultisig;
    address internal randomUser;

    // Configuration keys
    bytes32 private constant IS_PAUSED = keccak256("IS_PAUSED");
    bytes32 private constant DEBT_CAP = keccak256("DEBT_CAP");
    bytes32 private constant MAX_ON_CREDIT = keccak256("MAX_ON_CREDIT");
    bytes32 private constant USD3_SUPPLY_CAP = keccak256("USD3_SUPPLY_CAP");

    function setUp() public {
        protocolOwner = makeAddr("ProtocolOwner");
        emergencyMultisig = makeAddr("EmergencyMultisig");
        randomUser = makeAddr("RandomUser");

        // Deploy ProtocolConfig as proxy
        ProtocolConfig protocolConfigImpl = new ProtocolConfig();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(protocolConfigImpl),
            address(this),
            abi.encodeWithSelector(ProtocolConfig.initialize.selector, protocolOwner)
        );
        protocolConfig = ProtocolConfig(address(proxy));

        // Deploy MockMorpho and CreditLine
        mockMorpho = new MockMorphoCredit(address(protocolConfig));
        mockInsuranceFund = new MockInsuranceFund();

        creditLine = new CreditLine(
            address(mockMorpho),
            protocolOwner,
            makeAddr("InitialOzd"), // ozd - will be set to EmergencyController
            makeAddr("MarkdownManager"), // mm
            address(0) // prover can be zero
        );

        // Set insurance fund separately
        vm.prank(protocolOwner);
        creditLine.setInsuranceFund(address(mockInsuranceFund));

        // Deploy EmergencyController
        address[] memory emergencyAuthorized = new address[](1);
        emergencyAuthorized[0] = emergencyMultisig;
        emergencyController = new EmergencyController(
            address(protocolConfig), address(creditLine), emergencyMultisig, emergencyAuthorized
        );

        // Setup protocol config values for CreditLine validation
        vm.startPrank(protocolOwner);
        protocolConfig.setConfig(keccak256("MAX_LTV"), 1e18); // 100%
        protocolConfig.setConfig(keccak256("MAX_VV"), 10000 ether);
        protocolConfig.setConfig(keccak256("MAX_CREDIT_LINE"), 5000 ether);
        protocolConfig.setConfig(keccak256("MIN_CREDIT_LINE"), 0);
        protocolConfig.setConfig(keccak256("MAX_DRP"), 1000000);

        // Setup: Set EmergencyController as emergencyAdmin in ProtocolConfig
        protocolConfig.setEmergencyAdmin(address(emergencyController));

        // Setup: Set EmergencyController as OZD in CreditLine
        creditLine.setOzd(address(emergencyController));
        vm.stopPrank();
    }

    // ============ Constructor Tests ============

    function test_Constructor_InvalidAddress() public {
        address[] memory emergencyAuthorized = new address[](1);
        emergencyAuthorized[0] = emergencyMultisig;

        // Test zero protocol config
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new EmergencyController(address(0), address(creditLine), emergencyMultisig, emergencyAuthorized);

        // Test zero credit line
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new EmergencyController(address(protocolConfig), address(0), emergencyMultisig, emergencyAuthorized);

        // Test zero owner
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new EmergencyController(address(protocolConfig), address(creditLine), address(0), emergencyAuthorized);
    }

    function test_Constructor_SetsCorrectValues() public {
        address[] memory emergencyAuthorized = new address[](1);
        emergencyAuthorized[0] = emergencyMultisig;

        EmergencyController controller = new EmergencyController(
            address(protocolConfig), address(creditLine), emergencyMultisig, emergencyAuthorized
        );

        assertEq(address(controller.protocolConfig()), address(protocolConfig));
        assertEq(address(controller.creditLine()), address(creditLine));
        assertEq(controller.owner(), emergencyMultisig);
        assertTrue(controller.hasRole(controller.EMERGENCY_AUTHORIZED_ROLE(), emergencyMultisig));
    }

    // ============ setConfig Tests ============

    function test_SetConfig_Pause_OnlyEmergencyAuthorized() public {
        // Emergency multisig can pause
        vm.prank(emergencyMultisig);
        emergencyController.setConfig(IS_PAUSED, 1);
        assertEq(protocolConfig.config(IS_PAUSED), 1);

        // Random user cannot pause
        bytes32 emergencyRole = emergencyController.EMERGENCY_AUTHORIZED_ROLE();
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", randomUser, emergencyRole)
        );
        vm.prank(randomUser);
        emergencyController.setConfig(IS_PAUSED, 1);
    }

    function test_SetConfig_Pause_OnlyOne() public {
        // Can set to 1 (pause)
        vm.prank(emergencyMultisig);
        emergencyController.setConfig(IS_PAUSED, 1);
        assertEq(protocolConfig.config(IS_PAUSED), 1);

        // Cannot set to 0 (unpause)
        vm.prank(emergencyMultisig);
        vm.expectRevert(ProtocolConfig.EmergencyCanOnlyPause.selector);
        emergencyController.setConfig(IS_PAUSED, 0);

        // Cannot set to other values
        vm.prank(emergencyMultisig);
        vm.expectRevert(ProtocolConfig.EmergencyCanOnlyPause.selector);
        emergencyController.setConfig(IS_PAUSED, 2);
    }

    function test_SetConfig_DebtCap_OnlyZero() public {
        // Can set to 0 (stop borrowing)
        vm.prank(emergencyMultisig);
        emergencyController.setConfig(DEBT_CAP, 0);
        assertEq(protocolConfig.config(DEBT_CAP), 0);

        // Cannot set to non-zero
        vm.prank(emergencyMultisig);
        vm.expectRevert(ProtocolConfig.EmergencyCanOnlySetToZero.selector);
        emergencyController.setConfig(DEBT_CAP, 1000);
    }

    function test_SetConfig_MaxOnCredit_OnlyZero() public {
        // Can set to 0 (stop deployments)
        vm.prank(emergencyMultisig);
        emergencyController.setConfig(MAX_ON_CREDIT, 0);
        assertEq(protocolConfig.config(MAX_ON_CREDIT), 0);

        // Cannot set to non-zero
        vm.prank(emergencyMultisig);
        vm.expectRevert(ProtocolConfig.EmergencyCanOnlySetToZero.selector);
        emergencyController.setConfig(MAX_ON_CREDIT, 1 ether);
    }

    function test_SetConfig_SupplyCap_OnlyZero() public {
        // Can set to 0 (stop deposits)
        vm.prank(emergencyMultisig);
        emergencyController.setConfig(USD3_SUPPLY_CAP, 0);
        assertEq(protocolConfig.config(USD3_SUPPLY_CAP), 0);

        // Cannot set to non-zero
        vm.prank(emergencyMultisig);
        vm.expectRevert(ProtocolConfig.EmergencyCanOnlySetToZero.selector);
        emergencyController.setConfig(USD3_SUPPLY_CAP, 1000000);
    }

    function test_SetConfig_UnauthorizedParameter() public {
        // Cannot set non-emergency parameters
        bytes32 randomParam = keccak256("RANDOM_PARAM");
        vm.prank(emergencyMultisig);
        vm.expectRevert(ProtocolConfig.UnauthorizedEmergencyConfig.selector);
        emergencyController.setConfig(randomParam, 0);
    }

    // ============ Credit Line Revocation Tests ============

    function test_EmergencyRevokeCreditLine_OnlyEmergencyAuthorized() public {
        Id marketId = Id.wrap(bytes32(uint256(1)));
        address borrower = makeAddr("Borrower");

        vm.prank(emergencyMultisig);
        emergencyController.emergencyRevokeCreditLine(marketId, borrower);

        bytes32 emergencyRole = emergencyController.EMERGENCY_AUTHORIZED_ROLE();
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", randomUser, emergencyRole)
        );
        vm.prank(randomUser);
        emergencyController.emergencyRevokeCreditLine(marketId, borrower);
    }

    function test_EmergencyRevokeCreditLine_InvalidAddress() public {
        Id marketId = Id.wrap(bytes32(uint256(1)));

        vm.prank(emergencyMultisig);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        emergencyController.emergencyRevokeCreditLine(marketId, address(0));
    }

    function test_EmergencyRevokeCreditLine_EmitsEvent() public {
        Id marketId = Id.wrap(bytes32(uint256(1)));
        address borrower = makeAddr("Borrower");

        vm.expectEmit(true, true, false, true);
        emit EmergencyController.CreditLineRevoked(borrower, emergencyMultisig);

        vm.prank(emergencyMultisig);
        emergencyController.emergencyRevokeCreditLine(marketId, borrower);
    }

    function test_EmergencyRevokeCreditLine_PreservesDRP() public {
        Id marketId = Id.wrap(bytes32(uint256(1)));
        address borrower = makeAddr("Borrower");
        uint128 originalDrp = 500; // 5% APR in bps

        // Set initial credit line with DRP
        Id[] memory ids = new Id[](1);
        address[] memory borrowers = new address[](1);
        uint256[] memory vv = new uint256[](1);
        uint256[] memory credit = new uint256[](1);
        uint128[] memory drp = new uint128[](1);

        ids[0] = marketId;
        borrowers[0] = borrower;
        vv[0] = 1000 ether;
        credit[0] = 500 ether;
        drp[0] = originalDrp;

        vm.prank(address(emergencyController)); // OZD can call setCreditLines
        creditLine.setCreditLines(ids, borrowers, vv, credit, drp);

        // Verify initial DRP is set
        (, uint128 currentDrp,) = mockMorpho.borrowerPremium(marketId, borrower);
        assertEq(currentDrp, originalDrp, "Initial DRP not set correctly");

        // Revoke credit line
        vm.prank(emergencyMultisig);
        emergencyController.emergencyRevokeCreditLine(marketId, borrower);

        // Verify DRP is preserved after revocation
        (, uint128 drpAfterRevoke,) = mockMorpho.borrowerPremium(marketId, borrower);
        assertEq(drpAfterRevoke, originalDrp, "DRP should be preserved after credit revocation");
    }

    // ============ Access Control Tests ============

    function test_Constructor_ZeroAddressInEmergencyAuthorized() public {
        address[] memory emergencyAuthorized = new address[](2);
        emergencyAuthorized[0] = emergencyMultisig;
        emergencyAuthorized[1] = address(0);

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new EmergencyController(address(protocolConfig), address(creditLine), emergencyMultisig, emergencyAuthorized);
    }

    function test_Constructor_MultipleEmergencyAuthorized() public {
        address operator1 = makeAddr("Operator1");
        address operator2 = makeAddr("Operator2");

        address[] memory emergencyAuthorized = new address[](2);
        emergencyAuthorized[0] = operator1;
        emergencyAuthorized[1] = operator2;

        EmergencyController controller = new EmergencyController(
            address(protocolConfig), address(creditLine), emergencyMultisig, emergencyAuthorized
        );

        assertTrue(controller.hasRole(controller.EMERGENCY_AUTHORIZED_ROLE(), operator1));
        assertTrue(controller.hasRole(controller.EMERGENCY_AUTHORIZED_ROLE(), operator2));
        assertEq(controller.getRoleMemberCount(controller.EMERGENCY_AUTHORIZED_ROLE()), 2);
    }

    function test_TransferOwnership_Success() public {
        address newOwner = makeAddr("NewOwner");

        vm.expectEmit(true, false, false, true);
        emit EventsLib.SetOwner(newOwner);

        vm.prank(emergencyMultisig);
        emergencyController.transferOwnership(newOwner);

        assertEq(emergencyController.owner(), newOwner);
        assertFalse(emergencyController.hasRole(emergencyController.OWNER_ROLE(), emergencyMultisig));
        assertTrue(emergencyController.hasRole(emergencyController.OWNER_ROLE(), newOwner));
    }

    function test_TransferOwnership_ZeroAddress() public {
        vm.prank(emergencyMultisig);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        emergencyController.transferOwnership(address(0));
    }

    function test_TransferOwnership_SelfTransfer() public {
        vm.prank(emergencyMultisig);
        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        emergencyController.transferOwnership(emergencyMultisig);
    }

    function test_TransferOwnership_OnlyOwner() public {
        address newOwner = makeAddr("NewOwner");
        bytes32 ownerRole = emergencyController.OWNER_ROLE();

        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", randomUser, ownerRole)
        );
        vm.prank(randomUser);
        emergencyController.transferOwnership(newOwner);
    }

    function test_TransferOwnership_EmergencyAuthorizedCannotTransfer() public {
        address operator = makeAddr("Operator");
        address newOwner = makeAddr("NewOwner");
        bytes32 emergencyRole = emergencyController.EMERGENCY_AUTHORIZED_ROLE();
        bytes32 ownerRole = emergencyController.OWNER_ROLE();

        vm.prank(emergencyMultisig);
        emergencyController.grantRole(emergencyRole, operator);

        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", operator, ownerRole)
        );
        vm.prank(operator);
        emergencyController.transferOwnership(newOwner);
    }

    function test_TransferOwnership_NewOwnerCanManageRoles() public {
        address newOwner = makeAddr("NewOwner");
        address newOperator = makeAddr("NewOperator");
        bytes32 emergencyRole = emergencyController.EMERGENCY_AUTHORIZED_ROLE();

        vm.prank(emergencyMultisig);
        emergencyController.transferOwnership(newOwner);

        vm.prank(newOwner);
        emergencyController.grantRole(emergencyRole, newOperator);
        assertTrue(emergencyController.hasRole(emergencyRole, newOperator));
    }

    function test_RenounceRole_BlockedForOwnerRole() public {
        bytes32 ownerRole = emergencyController.OWNER_ROLE();

        vm.prank(emergencyMultisig);
        vm.expectRevert(ErrorsLib.CannotRenounceOwnerRole.selector);
        emergencyController.renounceRole(ownerRole, emergencyMultisig);

        assertEq(emergencyController.owner(), emergencyMultisig);
    }

    function test_RenounceRole_AllowedForEmergencyRole() public {
        bytes32 emergencyRole = emergencyController.EMERGENCY_AUTHORIZED_ROLE();

        vm.prank(emergencyMultisig);
        emergencyController.renounceRole(emergencyRole, emergencyMultisig);

        assertFalse(emergencyController.hasRole(emergencyRole, emergencyMultisig));
    }

    function test_GrantRevokeEmergencyRole() public {
        address newOperator = makeAddr("NewOperator");
        bytes32 emergencyRole = emergencyController.EMERGENCY_AUTHORIZED_ROLE();

        vm.startPrank(emergencyMultisig);
        emergencyController.grantRole(emergencyRole, newOperator);
        assertTrue(emergencyController.hasRole(emergencyRole, newOperator));

        emergencyController.revokeRole(emergencyRole, newOperator);
        assertFalse(emergencyController.hasRole(emergencyRole, newOperator));
        vm.stopPrank();
    }

    function test_EmergencyAuthorizedCannotManageRoles() public {
        address operator = makeAddr("Operator");
        address anotherAddr = makeAddr("Another");
        bytes32 emergencyRole = emergencyController.EMERGENCY_AUTHORIZED_ROLE();
        bytes32 ownerRole = emergencyController.OWNER_ROLE();

        vm.prank(emergencyMultisig);
        emergencyController.grantRole(emergencyRole, operator);

        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", operator, ownerRole)
        );
        vm.prank(operator);
        emergencyController.grantRole(emergencyRole, anotherAddr);
    }

    function test_OwnerWithoutEmergencyRole_CannotCallSetConfig() public {
        address ownerOnly = makeAddr("OwnerOnly");
        address[] memory empty = new address[](0);

        EmergencyController controller =
            new EmergencyController(address(protocolConfig), address(creditLine), ownerOnly, empty);

        vm.prank(protocolOwner);
        protocolConfig.setEmergencyAdmin(address(controller));

        bytes32 emergencyRole = controller.EMERGENCY_AUTHORIZED_ROLE();
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", ownerOnly, emergencyRole)
        );
        vm.prank(ownerOnly);
        controller.setConfig(IS_PAUSED, 1);
    }

    // ============ Integration Tests ============

    function test_CompleteEmergencyScenario() public {
        // Scenario: Protocol under attack, need to pause everything

        vm.startPrank(emergencyMultisig);

        // 1. Pause the protocol
        emergencyController.setConfig(IS_PAUSED, 1);
        assertEq(protocolConfig.config(IS_PAUSED), 1);

        // 2. Stop all borrowing
        emergencyController.setConfig(DEBT_CAP, 0);
        assertEq(protocolConfig.config(DEBT_CAP), 0);

        // 3. Stop USD3 deposits
        emergencyController.setConfig(USD3_SUPPLY_CAP, 0);
        assertEq(protocolConfig.config(USD3_SUPPLY_CAP), 0);

        // 4. Revoke suspicious borrower's credit line
        Id marketId = Id.wrap(bytes32(uint256(1)));
        address suspiciousBorrower = makeAddr("SuspiciousBorrower");
        emergencyController.emergencyRevokeCreditLine(marketId, suspiciousBorrower);

        vm.stopPrank();

        // Now protocol owner can restore after investigation
        vm.startPrank(protocolOwner);
        protocolConfig.setConfig(IS_PAUSED, 0); // Unpause
        protocolConfig.setConfig(DEBT_CAP, 1000000 ether); // Restore debt cap
        protocolConfig.setConfig(USD3_SUPPLY_CAP, 10000000 ether); // Restore supply cap
        vm.stopPrank();

        // Verify restoration
        assertEq(protocolConfig.config(IS_PAUSED), 0);
        assertEq(protocolConfig.config(DEBT_CAP), 1000000 ether);
        assertEq(protocolConfig.config(USD3_SUPPLY_CAP), 10000000 ether);
    }
}
