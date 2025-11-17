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

// Mock contracts for testing
contract MockMorphoCredit {
    address public protocolConfig;

    constructor(address _protocolConfig) {
        protocolConfig = _protocolConfig;
    }

    function setCreditLine(Id, address, uint256, uint128) external {}
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
        emergencyController = new EmergencyController(address(protocolConfig), address(creditLine), emergencyMultisig);

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
        // Test zero protocol config
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new EmergencyController(address(0), address(creditLine), emergencyMultisig);

        // Test zero credit line
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new EmergencyController(address(protocolConfig), address(0), emergencyMultisig);

        // Test zero owner - Ownable throws OwnableInvalidOwner
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new EmergencyController(address(protocolConfig), address(creditLine), address(0));
    }

    function test_Constructor_SetsCorrectValues() public {
        EmergencyController controller =
            new EmergencyController(address(protocolConfig), address(creditLine), emergencyMultisig);

        assertEq(address(controller.protocolConfig()), address(protocolConfig));
        assertEq(address(controller.creditLine()), address(creditLine));
        assertEq(controller.owner(), emergencyMultisig);
    }

    // ============ Emergency Pause Tests ============

    function test_EmergencyPause_OnlyOwner() public {
        // Emergency multisig can pause
        vm.prank(emergencyMultisig);
        emergencyController.emergencyPause();
        assertEq(protocolConfig.config(IS_PAUSED), 1);

        // Random user cannot pause
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", randomUser));
        emergencyController.emergencyPause();
    }

    function test_EmergencyPause_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit EmergencyController.EmergencyPauseActivated(emergencyMultisig);

        vm.prank(emergencyMultisig);
        emergencyController.emergencyPause();
    }

    // ============ Emergency Stop Borrowing Tests ============

    function test_EmergencyStopBorrowing_OnlyOwner() public {
        // Emergency multisig can stop borrowing
        vm.prank(emergencyMultisig);
        emergencyController.emergencyStopBorrowing();
        assertEq(protocolConfig.config(DEBT_CAP), 0);

        // Random user cannot stop borrowing
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", randomUser));
        emergencyController.emergencyStopBorrowing();
    }

    function test_EmergencyStopBorrowing_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit EmergencyController.BorrowingStopped(emergencyMultisig);

        vm.prank(emergencyMultisig);
        emergencyController.emergencyStopBorrowing();
    }

    // ============ Emergency Stop Credit Tests ============

    function test_EmergencyStopDeployments_OnlyOwner() public {
        // Emergency multisig can stop credit
        vm.prank(emergencyMultisig);
        emergencyController.emergencyStopDeployments();
        assertEq(protocolConfig.config(MAX_ON_CREDIT), 0);

        // Random user cannot stop credit
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", randomUser));
        emergencyController.emergencyStopDeployments();
    }

    function test_EmergencyStopDeployments_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit EmergencyController.DeploymentsStopped(emergencyMultisig);

        vm.prank(emergencyMultisig);
        emergencyController.emergencyStopDeployments();
    }

    // ============ Emergency Stop Deposits Tests ============

    function test_EmergencyStopUsd3Deposits_OnlyOwner() public {
        vm.prank(emergencyMultisig);
        emergencyController.emergencyStopUsd3Deposits();
        assertEq(protocolConfig.config(USD3_SUPPLY_CAP), 0);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", randomUser));
        emergencyController.emergencyStopUsd3Deposits();
    }

    function test_EmergencyStopDeposits_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit EmergencyController.DepositsStopped(emergencyMultisig);

        vm.prank(emergencyMultisig);
        emergencyController.emergencyStopUsd3Deposits();
    }

    // ============ Credit Line Revocation Tests ============

    function test_EmergencyRevokeCreditLine_OnlyOwner() public {
        Id marketId = Id.wrap(bytes32(uint256(1)));
        address borrower = makeAddr("Borrower");

        vm.prank(emergencyMultisig);
        emergencyController.emergencyRevokeCreditLine(marketId, borrower);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", randomUser));
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

    // ============ Integration Tests ============

    function test_CompleteEmergencyScenario() public {
        // Scenario: Protocol under attack, need to pause everything

        vm.startPrank(emergencyMultisig);

        // 1. Pause the protocol
        emergencyController.emergencyPause();
        assertEq(protocolConfig.config(IS_PAUSED), 1);

        // 2. Stop all borrowing
        emergencyController.emergencyStopBorrowing();
        assertEq(protocolConfig.config(DEBT_CAP), 0);

        // 3. Stop USD3 deposits
        emergencyController.emergencyStopUsd3Deposits();
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
