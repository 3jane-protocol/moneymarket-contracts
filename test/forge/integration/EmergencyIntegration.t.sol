// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {EmergencyController} from "../../../src/EmergencyController.sol";
import {ProtocolConfig} from "../../../src/ProtocolConfig.sol";
import {CreditLine} from "../../../src/CreditLine.sol";
import {Id, MarketParams} from "../../../src/interfaces/IMorpho.sol";
import {
    TransparentUpgradeableProxy
} from "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// Mock contracts
contract MockMorphoCredit {
    address public protocolConfig;
    mapping(Id => mapping(address => uint256)) public creditLines;
    mapping(Id => mapping(address => uint128)) public drpRates;

    constructor(address _protocolConfig) {
        protocolConfig = _protocolConfig;
    }

    function setCreditLine(Id id, address borrower, uint256 credit, uint128 drp) external {
        creditLines[id][borrower] = credit;
        drpRates[id][borrower] = drp;
    }

    function borrowerPremium(Id id, address borrower) external view returns (uint128, uint128, uint128) {
        // Return mock data: (lastAccrualTime, rate, borrowAssetsAtLastAccrual)
        return (uint128(block.timestamp), drpRates[id][borrower], 0);
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

contract MockTimelock {
    uint256 public constant DELAY = 2 days;

    struct Transaction {
        address target;
        bytes data;
        uint256 executeTime;
    }

    mapping(bytes32 => Transaction) public queuedTransactions;

    event TransactionQueued(bytes32 indexed txHash, address indexed target, bytes data, uint256 executeTime);
    event TransactionExecuted(bytes32 indexed txHash, address indexed target, bytes data);

    function queueTransaction(address target, bytes memory data) external returns (bytes32) {
        bytes32 txHash = keccak256(abi.encode(target, data, block.timestamp));
        uint256 executeTime = block.timestamp + DELAY;

        queuedTransactions[txHash] = Transaction({target: target, data: data, executeTime: executeTime});

        emit TransactionQueued(txHash, target, data, executeTime);
        return txHash;
    }

    function executeTransaction(bytes32 txHash) external {
        Transaction memory tx = queuedTransactions[txHash];
        require(tx.target != address(0), "Transaction not queued");
        require(block.timestamp >= tx.executeTime, "Timelock not expired");

        delete queuedTransactions[txHash];

        (bool success,) = tx.target.call(tx.data);
        require(success, "Transaction execution failed");

        emit TransactionExecuted(txHash, tx.target, tx.data);
    }
}

/// @title EmergencyIntegration
/// @notice Integration tests for the emergency system with timelock simulation
contract EmergencyIntegration is Test {
    EmergencyController internal emergencyController;
    ProtocolConfig internal protocolConfig;
    CreditLine internal creditLine;
    MockMorphoCredit internal morpho;
    MockInsuranceFund internal insuranceFund;
    MockTimelock internal timelock;

    address internal protocolOwner;
    address internal emergencyMultisig;
    address internal attacker;
    address internal normalUser;

    // Configuration keys
    bytes32 private constant IS_PAUSED = keccak256("IS_PAUSED");
    bytes32 private constant CC_FROZEN = keccak256("CC_FROZEN");
    bytes32 private constant DEBT_CAP = keccak256("DEBT_CAP");
    bytes32 private constant MAX_ON_CREDIT = keccak256("MAX_ON_CREDIT");
    bytes32 private constant USD3_SUPPLY_CAP = keccak256("USD3_SUPPLY_CAP");

    function setUp() public {
        // Create actors
        protocolOwner = makeAddr("ProtocolOwner");
        emergencyMultisig = makeAddr("EmergencyMultisig");
        attacker = makeAddr("Attacker");
        normalUser = makeAddr("NormalUser");

        // Deploy timelock to simulate real deployment
        timelock = new MockTimelock();

        // Deploy ProtocolConfig with timelock as owner
        ProtocolConfig protocolConfigImpl = new ProtocolConfig();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(protocolConfigImpl),
            address(this),
            abi.encodeWithSelector(ProtocolConfig.initialize.selector, address(timelock))
        );
        protocolConfig = ProtocolConfig(address(proxy));

        // Deploy supporting contracts
        morpho = new MockMorphoCredit(address(protocolConfig));
        insuranceFund = new MockInsuranceFund();

        creditLine = new CreditLine(
            address(morpho),
            address(timelock), // Timelock owns CreditLine
            makeAddr("InitialOzd"), // ozd - will be set to EmergencyController
            makeAddr("MarkdownManager"), // mm
            address(0) // prover can be zero
        );

        // Deploy EmergencyController
        emergencyController = new EmergencyController(address(protocolConfig), address(creditLine), emergencyMultisig);

        // Initial configuration (simulating post-deployment setup)
        _setupInitialConfiguration();
    }

    function _setupInitialConfiguration() internal {
        // Create array to hold transaction hashes
        bytes32[] memory txHashes = new bytes32[](9);

        // 1. Set EmergencyController as emergencyAdmin in ProtocolConfig
        txHashes[0] = timelock.queueTransaction(
            address(protocolConfig),
            abi.encodeWithSelector(ProtocolConfig.setEmergencyAdmin.selector, address(emergencyController))
        );

        // 2. Set EmergencyController as OZD in CreditLine
        txHashes[1] = timelock.queueTransaction(
            address(creditLine), abi.encodeWithSelector(CreditLine.setOzd.selector, address(emergencyController))
        );

        // 3. Set initial protocol parameters
        txHashes[2] = timelock.queueTransaction(
            address(protocolConfig), abi.encodeWithSelector(ProtocolConfig.setConfig.selector, DEBT_CAP, 1000000 ether)
        );

        txHashes[3] = timelock.queueTransaction(
            address(protocolConfig),
            abi.encodeWithSelector(ProtocolConfig.setConfig.selector, MAX_ON_CREDIT, 500000 ether)
        );

        txHashes[4] = timelock.queueTransaction(
            address(protocolConfig),
            abi.encodeWithSelector(ProtocolConfig.setConfig.selector, USD3_SUPPLY_CAP, 10000000 ether)
        );

        // Set credit line configuration parameters
        txHashes[5] = timelock.queueTransaction(
            address(protocolConfig),
            abi.encodeWithSelector(ProtocolConfig.setConfig.selector, keccak256("MAX_LTV"), 1e18)
        );

        txHashes[6] = timelock.queueTransaction(
            address(protocolConfig),
            abi.encodeWithSelector(ProtocolConfig.setConfig.selector, keccak256("MAX_VV"), 10000 ether)
        );

        txHashes[7] = timelock.queueTransaction(
            address(protocolConfig),
            abi.encodeWithSelector(ProtocolConfig.setConfig.selector, keccak256("MAX_CREDIT_LINE"), 5000 ether)
        );

        txHashes[8] = timelock.queueTransaction(
            address(protocolConfig),
            abi.encodeWithSelector(ProtocolConfig.setConfig.selector, keccak256("MAX_DRP"), 1000000)
        );

        // Fast forward time to execute
        vm.warp(block.timestamp + 2 days + 1);

        // Execute all transactions
        for (uint256 i = 0; i < txHashes.length; i++) {
            timelock.executeTransaction(txHashes[i]);
        }

        // Verify setup
        assertEq(protocolConfig.emergencyAdmin(), address(emergencyController));
        assertEq(creditLine.ozd(), address(emergencyController));
        assertEq(protocolConfig.config(DEBT_CAP), 1000000 ether);
        assertEq(protocolConfig.config(MAX_ON_CREDIT), 500000 ether);
        assertEq(protocolConfig.config(USD3_SUPPLY_CAP), 10000000 ether);
    }

    // ============ Scenario 1: Attack Response ============

    function test_Scenario_AttackResponse() public {
        // Initial state: Protocol is operating normally
        assertEq(protocolConfig.config(IS_PAUSED), 0);
        assertEq(protocolConfig.config(DEBT_CAP), 1000000 ether);

        // ATTACK DETECTED: Emergency multisig responds immediately
        vm.startPrank(emergencyMultisig);

        // Immediate response - no delay needed
        emergencyController.setConfig(IS_PAUSED, 1);
        emergencyController.setConfig(DEBT_CAP, 0);
        emergencyController.setConfig(USD3_SUPPLY_CAP, 0);

        // Revoke credit line of compromised account
        Id marketId = Id.wrap(bytes32(uint256(1)));
        emergencyController.emergencyRevokeCreditLine(marketId, attacker);

        vm.stopPrank();

        // Verify immediate protection is in place
        assertEq(protocolConfig.config(IS_PAUSED), 1);
        assertEq(protocolConfig.config(DEBT_CAP), 0);
        assertEq(protocolConfig.config(USD3_SUPPLY_CAP), 0);

        // After investigation, protocol owner queues restoration through timelock
        bytes memory unpauseData = abi.encodeWithSelector(ProtocolConfig.setConfig.selector, IS_PAUSED, 0);
        bytes32 restoreTxHash1 = timelock.queueTransaction(address(protocolConfig), unpauseData);

        bytes memory restoreDebtCapData =
            abi.encodeWithSelector(ProtocolConfig.setConfig.selector, DEBT_CAP, 1000000 ether);
        bytes32 restoreTxHash2 = timelock.queueTransaction(address(protocolConfig), restoreDebtCapData);

        // Community has 2 days to review restoration
        vm.warp(block.timestamp + 2 days + 1);

        // Execute restoration
        timelock.executeTransaction(restoreTxHash1);
        timelock.executeTransaction(restoreTxHash2);

        // Verify restoration
        assertEq(protocolConfig.config(IS_PAUSED), 0);
        assertEq(protocolConfig.config(DEBT_CAP), 1000000 ether);
    }

    // ============ Scenario 2: Compromised Emergency Multisig ============

    function test_Scenario_CompromisedEmergencyMultisig() public {
        // Scenario: Emergency multisig is compromised
        // Attacker gains control of emergency multisig
        vm.startPrank(emergencyMultisig); // Simulating compromised multisig

        // Attacker can only make protocol MORE restrictive
        emergencyController.setConfig(IS_PAUSED, 1);
        emergencyController.setConfig(DEBT_CAP, 0);
        emergencyController.setConfig(MAX_ON_CREDIT, 0);
        emergencyController.setConfig(USD3_SUPPLY_CAP, 0);

        // Attacker CANNOT unpause or raise limits
        // These would fail if EmergencyController tried them
        vm.stopPrank();

        // Verify attacker's damage is limited to DoS
        assertEq(protocolConfig.config(IS_PAUSED), 1);
        assertEq(protocolConfig.config(DEBT_CAP), 0);
        assertEq(protocolConfig.config(MAX_ON_CREDIT), 0);
        assertEq(protocolConfig.config(USD3_SUPPLY_CAP), 0);

        // Protocol owner can replace compromised EmergencyController through timelock
        address newEmergencyController = makeAddr("NewEmergencyController");

        bytes memory replaceEmergencyAdminData =
            abi.encodeWithSelector(ProtocolConfig.setEmergencyAdmin.selector, newEmergencyController);
        bytes32 replaceTxHash = timelock.queueTransaction(address(protocolConfig), replaceEmergencyAdminData);

        // Also queue restoration of normal operations
        bytes memory unpauseData = abi.encodeWithSelector(ProtocolConfig.setConfig.selector, IS_PAUSED, 0);
        bytes32 unpauseTxHash = timelock.queueTransaction(address(protocolConfig), unpauseData);

        // Wait for timelock
        vm.warp(block.timestamp + 2 days + 1);

        // Execute replacement and restoration
        timelock.executeTransaction(replaceTxHash);
        timelock.executeTransaction(unpauseTxHash);

        // Verify recovery
        assertEq(protocolConfig.emergencyAdmin(), newEmergencyController);
        assertEq(protocolConfig.config(IS_PAUSED), 0);
    }

    // ============ Scenario 3: Operational Emergency ============

    function test_Scenario_OperationalEmergency() public {
        // Scenario: Multiple borrowers need credit lines revoked

        // Setup: Create some credit lines
        Id marketId = Id.wrap(bytes32(uint256(1)));
        address[] memory defaulters = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            defaulters[i] = makeAddr(string(abi.encodePacked("Defaulter", i)));
        }

        // Emergency multisig can revoke credit lines
        vm.startPrank(emergencyMultisig);

        // Revoke credit lines individually to prevent further borrowing
        for (uint256 i = 0; i < defaulters.length; i++) {
            emergencyController.emergencyRevokeCreditLine(marketId, defaulters[i]);
        }

        vm.stopPrank();
    }

    // ============ Scenario 4: Partial Emergency Response ============

    function test_Scenario_PartialEmergency() public {
        // Scenario: Only need to stop new borrows, not pause entire protocol

        // Initial state
        assertEq(protocolConfig.config(IS_PAUSED), 0);
        assertEq(protocolConfig.config(DEBT_CAP), 1000000 ether);
        assertEq(protocolConfig.config(USD3_SUPPLY_CAP), 10000000 ether);

        // Emergency: Stop new borrowing but allow withdrawals
        vm.prank(emergencyMultisig);
        emergencyController.setConfig(DEBT_CAP, 0);

        // Verify selective restriction
        assertEq(protocolConfig.config(IS_PAUSED), 0); // Not paused
        assertEq(protocolConfig.config(DEBT_CAP), 0); // Borrowing stopped
        assertEq(protocolConfig.config(USD3_SUPPLY_CAP), 10000000 ether); // Deposits still allowed

        // Later, also stop deposits if needed
        vm.prank(emergencyMultisig);
        emergencyController.setConfig(USD3_SUPPLY_CAP, 0);

        assertEq(protocolConfig.config(USD3_SUPPLY_CAP), 0);
    }

    // ============ Scenario 5: Emergency During Timelock Queue ============

    function test_Scenario_EmergencyDuringTimelockQueue() public {
        // Scenario: Malicious upgrade queued, emergency response needed

        // Attacker somehow queues a malicious transaction
        address maliciousContract = makeAddr("MaliciousContract");
        bytes memory maliciousData = abi.encodeWithSelector(ProtocolConfig.setOwner.selector, maliciousContract);
        bytes32 maliciousTxHash = timelock.queueTransaction(address(protocolConfig), maliciousData);

        // Community detects the malicious transaction
        // Emergency multisig immediately pauses protocol
        vm.prank(emergencyMultisig);
        emergencyController.setConfig(IS_PAUSED, 1);

        // Protocol is protected during the 2-day timelock period
        assertEq(protocolConfig.config(IS_PAUSED), 1);

        // Even if timelock expires and someone tries to execute
        vm.warp(block.timestamp + 2 days + 1);

        // The protocol remains paused, limiting damage
        assertEq(protocolConfig.config(IS_PAUSED), 1);

        // Protocol team can queue a fix through timelock
        // (In reality, would need to address the malicious transaction first)
    }

    // ============ Scenario 6: Callable Credit Emergency Freeze ============

    function test_Scenario_CallableCreditFreeze() public {
        // Initial state: CC is not frozen
        assertEq(protocolConfig.config(CC_FROZEN), 0);
        assertEq(protocolConfig.getCcFrozen(), 0);

        // Emergency: Freeze callable credit operations
        vm.prank(emergencyMultisig);
        emergencyController.setConfig(CC_FROZEN, 1);

        // Verify freeze
        assertEq(protocolConfig.config(CC_FROZEN), 1);
        assertEq(protocolConfig.getCcFrozen(), 1);

        // Protocol owner can unfreeze through timelock
        bytes memory unfreezeData = abi.encodeWithSelector(ProtocolConfig.setConfig.selector, CC_FROZEN, 0);
        bytes32 unfreezeTxHash = timelock.queueTransaction(address(protocolConfig), unfreezeData);

        // Wait for timelock
        vm.warp(block.timestamp + 2 days + 1);

        // Execute unfreeze
        timelock.executeTransaction(unfreezeTxHash);

        // Verify unfreeze
        assertEq(protocolConfig.getCcFrozen(), 0);
    }

    function test_Scenario_CallableCreditFreezeCanOnlySetToOne() public {
        // Emergency controller can only freeze (set to 1), not set arbitrary values
        vm.startPrank(emergencyMultisig);

        // Can freeze
        emergencyController.setConfig(CC_FROZEN, 1);
        assertEq(protocolConfig.getCcFrozen(), 1);

        // Cannot set to other values (would revert with EmergencyCanOnlyPause)
        vm.expectRevert(ProtocolConfig.EmergencyCanOnlyPause.selector);
        emergencyController.setConfig(CC_FROZEN, 0);

        vm.expectRevert(ProtocolConfig.EmergencyCanOnlyPause.selector);
        emergencyController.setConfig(CC_FROZEN, 2);

        vm.stopPrank();
    }

    function test_Scenario_CallableCreditFreezeWithAttackResponse() public {
        // Scenario: Attack on callable credit detected
        assertEq(protocolConfig.config(CC_FROZEN), 0);
        assertEq(protocolConfig.config(IS_PAUSED), 0);

        // Emergency multisig freezes CC immediately, but keeps rest of protocol running
        vm.prank(emergencyMultisig);
        emergencyController.setConfig(CC_FROZEN, 1);

        // CC is frozen but protocol is not paused
        assertEq(protocolConfig.getCcFrozen(), 1);
        assertEq(protocolConfig.getIsPaused(), 0);

        // Normal lending operations can continue (simulated by checking other params)
        assertGt(protocolConfig.config(DEBT_CAP), 0);
        assertGt(protocolConfig.config(USD3_SUPPLY_CAP), 0);
    }
}
