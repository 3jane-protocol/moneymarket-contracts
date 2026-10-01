// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";

import {ITimelockController} from "../../src/interfaces/ITimelockController.sol";
import {LCCVaultFactory} from "../../src/lcc/LCCVaultFactory.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";

/// @title RotateLCCFactoryOwnerSafe
/// @notice Rotates LCCVaultFactory ownership from the Safe to the 24-hour parameters timelock through the factory's
///         two-step transfer: one Safe batch sets the pending owner and schedules the timelock's `acceptOwnership`;
///         a second Safe transaction executes it after the delay.
/// @dev Ownership re-keys every family vault (calls, risk setters, unpause, shutdown, oracle recovery, role
///      administration, vault creation). Do not start or accept a rotation while any family vault has a pending
///      auction slot with a missing call-open price snapshot (docs/operations-runbook.md, "LCC factory ownership
///      rotation"). Every Safe-routed factory operation must be re-issued through the timelock after acceptance.
///
///      Usage:
///      1. --sig "schedule(uint256,bool)" 0 false   (then true to propose)
///      2. After 24 hours, --sig "execute(uint256,bool)" 0 false   (then true to propose)
///      3. --sig "verify()"
///      With FOUNDRY_PROFILE=script, LCC_FACTORY, WALLET_TYPE and the Safe proposer credential, and a mainnet RPC.
contract RotateLCCFactoryOwnerSafe is Script, SafeHelper, TimelockHelper {
    address internal constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address internal constant PARAMS_TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    uint256 internal constant PARAMS_TIMELOCK_DELAY = 1 days;
    bytes32 internal constant SALT_DOMAIN = bytes32("3JANE_LCC_FACTORY_OWNER_V1");

    function schedule(uint256 attempt, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(PARAMS_TIMELOCK)
    {
        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        LCCVaultFactory factory = _factory();
        _requireTimelock();
        require(factory.owner() == safe, "Safe is not factory owner");
        require(factory.getRoleMemberCount(factory.OWNER_ROLE()) == 1, "factory owner count mismatch");
        _requireSafeProposer(safe);
        address pending = factory.pendingOwner();
        require(pending == address(0) || pending == PARAMS_TIMELOCK, "unexpected pending owner");

        console2.log("=== Rotate LCC Factory Owner: Safe -> 24-hour parameters timelock ===");
        console2.log("Factory:", address(factory));
        console2.log("Current owner (Safe):", safe);
        console2.log("New owner (timelock):", PARAMS_TIMELOCK);
        console2.log("Family vaults:", factory.numVaults());
        console2.log("Send to Safe:", send);

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) =
            _acceptOperation(factory, attempt);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, bytes32(0), salt);
        console2.log("Accept attempt:", attempt);
        console2.log("Accept operation ID:", vm.toString(operationId));
        console2.log("Accept operation salt:", vm.toString(salt));

        ITimelockController.OperationState state = getOperationState(PARAMS_TIMELOCK, operationId);
        require(state != ITimelockController.OperationState.Done, "accept already executed; use a fresh attempt");
        bool acceptPending =
            state == ITimelockController.OperationState.Waiting || state == ITimelockController.OperationState.Ready;

        if (pending != PARAMS_TIMELOCK) {
            console2.log("Batch: factory.transferOwnership(timelock)");
            addToBatch(address(factory), abi.encodeCall(factory.transferOwnership, (PARAMS_TIMELOCK)));
            require(factory.pendingOwner() == PARAMS_TIMELOCK, "simulated pending owner mismatch");
        }
        if (acceptPending) {
            logOperationState(PARAMS_TIMELOCK, operationId);
            console2.log("Accept operation is already scheduled");
        } else {
            uint256 snapshot = vm.snapshotState();
            simulateExecution(PARAMS_TIMELOCK, targets, values, datas);
            require(factory.owner() == PARAMS_TIMELOCK, "simulated acceptance did not rotate ownership");
            vm.revertToState(snapshot);
            console2.log("Batch: timelock.scheduleBatch(factory.acceptOwnership)");
            addToBatch(
                PARAMS_TIMELOCK, encodeScheduleBatch(targets, values, datas, bytes32(0), salt, PARAMS_TIMELOCK_DELAY)
            );
        }

        (uint256 txCount,) = getBatchInfo(0);
        if (txCount == 0) {
            console2.log("Nothing to propose");
            return;
        }
        require(getTotalBatches() == 1, "SafeHelper split the batch");
        _send(send);
        console2.log("Next: after the 24-hour delay, run execute with the same attempt nonce");
    }

    function execute(uint256 attempt, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(PARAMS_TIMELOCK)
    {
        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        LCCVaultFactory factory = _factory();
        _requireTimelock();
        require(factory.owner() == safe, "Safe is not factory owner");
        require(factory.pendingOwner() == PARAMS_TIMELOCK, "timelock is not the pending owner");

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) =
            _acceptOperation(factory, attempt);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, bytes32(0), salt);
        console2.log("=== Execute LCC Factory Owner Rotation ===");
        console2.log("Factory:", address(factory));
        console2.log("Accept operation ID:", vm.toString(operationId));
        logOperationState(PARAMS_TIMELOCK, operationId);
        require(!isOperationDone(PARAMS_TIMELOCK, operationId), "accept already executed");
        requireOperationReady(PARAMS_TIMELOCK, operationId);

        addToBatch(PARAMS_TIMELOCK, encodeExecuteBatch(targets, values, datas, bytes32(0), salt));
        _requireRotated(factory, safe);
        require(getTotalBatches() == 1, "SafeHelper split the batch");
        (uint256 txCount,) = getBatchInfo(0);
        require(txCount == 1, "execution must be one Safe call");
        _send(send);
        console2.log("Factory owner is now the 24-hour parameters timelock; route all factory operations through it");
    }

    /// @notice Print the factory's ownership state and require the rotation to be complete.
    function verify() external view {
        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        LCCVaultFactory factory = _factory();
        console2.log("Factory:", address(factory));
        console2.log("Owner:", factory.owner());
        console2.log("Pending owner:", factory.pendingOwner());
        console2.log("OWNER_ROLE members:", factory.getRoleMemberCount(factory.OWNER_ROLE()));
        _requireRotated(factory, safe);
        console2.log("PASS: factory owned by the 24-hour parameters timelock");
    }

    function _factory() internal view returns (LCCVaultFactory factory) {
        factory = LCCVaultFactory(vm.envAddress("LCC_FACTORY"));
        require(address(factory).code.length > 0, "factory has no code");
    }

    function _requireTimelock() internal view {
        require(PARAMS_TIMELOCK.code.length > 0, "parameters timelock has no code");
        require(getMinDelay(PARAMS_TIMELOCK) == PARAMS_TIMELOCK_DELAY, "parameters timelock delay is not 24 hours");
    }

    function _requireSafeProposer(address safe) internal view {
        bytes32 proposerRole = ITimelockController(PARAMS_TIMELOCK).PROPOSER_ROLE();
        (bool ok, bytes memory data) =
            PARAMS_TIMELOCK.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", proposerRole, safe));
        require(ok && data.length == 32 && abi.decode(data, (bool)), "Safe is not a parameters timelock proposer");
    }

    function _acceptOperation(LCCVaultFactory factory, uint256 attempt)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt)
    {
        targets = new address[](1);
        values = new uint256[](1);
        datas = new bytes[](1);
        targets[0] = address(factory);
        datas[0] = abi.encodeCall(factory.acceptOwnership, ());
        salt = keccak256(abi.encode(SALT_DOMAIN, address(factory), PARAMS_TIMELOCK, attempt));
    }

    function _requireRotated(LCCVaultFactory factory, address safe) internal view {
        require(factory.owner() == PARAMS_TIMELOCK, "factory owner is not the timelock");
        require(factory.pendingOwner() == address(0), "pending owner not cleared");
        require(factory.isOwner(PARAMS_TIMELOCK), "timelock lacks OWNER_ROLE");
        require(!factory.isOwner(safe), "Safe still holds OWNER_ROLE");
        require(factory.getRoleMemberCount(factory.OWNER_ROLE()) == 1, "factory owner count mismatch");
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
