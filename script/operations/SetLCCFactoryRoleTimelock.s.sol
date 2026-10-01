// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";

import {ITimelockController} from "../../src/interfaces/ITimelockController.sol";
import {LCCVaultFactory} from "../../src/lcc/LCCVaultFactory.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";

/// @title SetLCCFactoryRoleTimelock
/// @notice Grants or revokes an LCCVaultFactory operational role while the factory is owned by the 24-hour
///         parameters timelock: the Safe proposes one timelock operation, executed after the delay.
/// @dev Covers LISTER_ROLE, BOUNCER_ROLE, and GUARDIAN_ROLE only. OWNER_ROLE moves solely through the factory's
///      two-step ownership transfer, and DEPOSIT_OPERATOR_ROLE is granted only through
///      AuthorizeLCCMarginDepositHelperSafe after a runtime code-hash review. Timelock-routed counterpart of
///      GrantLCCFactoryRoleSafe.
///
///      Usage:
///      1. --sig "schedule(bool,uint256,bool)" true 0 false   (grant; `false` revokes; then send with true)
///      2. After 24 hours, --sig "execute(bool,uint256,bool)" true 0 false   (then true)
///      3. --sig "verify(bool)" true
///      With FOUNDRY_PROFILE=script, LCC_FACTORY, LCC_ROLE=<LISTER|BOUNCER|GUARDIAN>, LCC_ROLE_ACCOUNT,
///      WALLET_TYPE and the Safe proposer credential, and a mainnet RPC.
contract SetLCCFactoryRoleTimelock is Script, SafeHelper, TimelockHelper {
    address internal constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address internal constant PARAMS_TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    uint256 internal constant PARAMS_TIMELOCK_DELAY = 1 days;
    bytes32 internal constant SALT_DOMAIN = bytes32("3JANE_LCC_FACTORY_ROLE_V1");

    function schedule(bool grant, uint256 attempt, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(PARAMS_TIMELOCK)
    {
        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        (LCCVaultFactory factory, bytes32 role, string memory roleName, address account) = _context();
        _requireTopology(factory, safe);

        console2.log(grant ? "=== Schedule LCC Factory Role Grant ===" : "=== Schedule LCC Factory Role Revoke ===");
        _logHeader(factory, role, roleName, account, send);
        if (factory.hasRole(role, account) == grant) {
            console2.log("Account already in the requested state; nothing to propose");
            return;
        }

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) =
            _operation(factory, role, account, grant, attempt);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, bytes32(0), salt);
        console2.log("Attempt:", attempt);
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Operation salt:", vm.toString(salt));

        ITimelockController.OperationState state = getOperationState(PARAMS_TIMELOCK, operationId);
        if (state == ITimelockController.OperationState.Waiting || state == ITimelockController.OperationState.Ready) {
            logOperationState(PARAMS_TIMELOCK, operationId);
            console2.log("Operation is already pending");
            return;
        }
        require(state != ITimelockController.OperationState.Done, "operation already executed; use a fresh attempt");

        uint256 snapshot = vm.snapshotState();
        simulateExecution(PARAMS_TIMELOCK, targets, values, datas);
        require(factory.hasRole(role, account) == grant, "simulated role change failed");
        vm.revertToState(snapshot);

        addToBatch(
            PARAMS_TIMELOCK, encodeScheduleBatch(targets, values, datas, bytes32(0), salt, PARAMS_TIMELOCK_DELAY)
        );
        _requireSingleCall();
        _send(send);
        console2.log("Next: after the 24-hour delay, run execute with the same direction and attempt nonce");
    }

    function execute(bool grant, uint256 attempt, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(PARAMS_TIMELOCK)
    {
        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        (LCCVaultFactory factory, bytes32 role, string memory roleName, address account) = _context();
        _requireTopology(factory, safe);

        console2.log(grant ? "=== Execute LCC Factory Role Grant ===" : "=== Execute LCC Factory Role Revoke ===");
        _logHeader(factory, role, roleName, account, send);

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) =
            _operation(factory, role, account, grant, attempt);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, bytes32(0), salt);
        console2.log("Operation ID:", vm.toString(operationId));
        logOperationState(PARAMS_TIMELOCK, operationId);
        require(!isOperationDone(PARAMS_TIMELOCK, operationId), "operation already executed");
        requireOperationReady(PARAMS_TIMELOCK, operationId);

        addToBatch(PARAMS_TIMELOCK, encodeExecuteBatch(targets, values, datas, bytes32(0), salt));
        require(factory.hasRole(role, account) == grant, "simulated role change failed");
        _requireSingleCall();
        _send(send);
    }

    /// @notice Report whether the configured account holds the configured role and require the expected state.
    function verify(bool grant) external view {
        (LCCVaultFactory factory, bytes32 role, string memory roleName, address account) = _context();
        bool held = factory.hasRole(role, account);
        console2.log(held ? "role held:" : "role not held:", roleName, account);
        require(held == grant, "role state mismatch");
        console2.log("PASS");
    }

    function _context()
        internal
        view
        returns (LCCVaultFactory factory, bytes32 role, string memory roleName, address account)
    {
        factory = LCCVaultFactory(vm.envAddress("LCC_FACTORY"));
        require(address(factory).code.length > 0, "factory has no code");

        roleName = vm.envString("LCC_ROLE");
        bytes32 key = keccak256(bytes(roleName));
        if (key == keccak256("LISTER")) role = factory.LISTER_ROLE();
        else if (key == keccak256("BOUNCER")) role = factory.BOUNCER_ROLE();
        else if (key == keccak256("GUARDIAN")) role = factory.GUARDIAN_ROLE();
        else revert("LCC_ROLE must be LISTER, BOUNCER, or GUARDIAN");

        account = vm.envAddress("LCC_ROLE_ACCOUNT");
        require(account != address(0), "LCC_ROLE_ACCOUNT not set");
    }

    function _requireTopology(LCCVaultFactory factory, address safe) internal view {
        require(PARAMS_TIMELOCK.code.length > 0, "parameters timelock has no code");
        require(getMinDelay(PARAMS_TIMELOCK) == PARAMS_TIMELOCK_DELAY, "parameters timelock delay is not 24 hours");
        require(factory.owner() == PARAMS_TIMELOCK, "parameters timelock is not factory owner");
        require(factory.getRoleMemberCount(factory.OWNER_ROLE()) == 1, "factory owner count mismatch");
        bytes32 proposerRole = ITimelockController(PARAMS_TIMELOCK).PROPOSER_ROLE();
        (bool ok, bytes memory data) =
            PARAMS_TIMELOCK.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", proposerRole, safe));
        require(ok && data.length == 32 && abi.decode(data, (bool)), "Safe is not a parameters timelock proposer");
    }

    function _operation(LCCVaultFactory factory, bytes32 role, address account, bool grant, uint256 attempt)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt)
    {
        targets = new address[](1);
        values = new uint256[](1);
        datas = new bytes[](1);
        targets[0] = address(factory);
        datas[0] = grant
            ? abi.encodeCall(factory.grantRole, (role, account))
            : abi.encodeCall(factory.revokeRole, (role, account));
        salt = keccak256(abi.encode(SALT_DOMAIN, address(factory), role, account, grant, attempt));
    }

    function _logHeader(LCCVaultFactory factory, bytes32 role, string memory roleName, address account, bool send)
        internal
        view
    {
        console2.log("Factory:", address(factory));
        console2.log("Factory owner (timelock):", factory.owner());
        console2.log("Role:", roleName);
        console2.log("Account:", account);
        console2.log("Current holders:", factory.getRoleMemberCount(role));
        console2.log("Send to Safe:", send);
    }

    function _requireSingleCall() internal view {
        require(getTotalBatches() == 1, "SafeHelper split the batch");
        (uint256 txCount,) = getBatchInfo(0);
        require(txCount == 1, "operation must be one Safe call");
    }

    function _send(bool send) internal {
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }
}
