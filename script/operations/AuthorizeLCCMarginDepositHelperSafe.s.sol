// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2, VmSafe} from "forge-std/Script.sol";

import {ITimelockController} from "../../src/interfaces/ITimelockController.sol";
import {LCCMarginDepositHelper} from "../../src/lcc/LCCMarginDepositHelper.sol";
import {LCCVaultFactory} from "../../src/lcc/LCCVaultFactory.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";

/// @title AuthorizeLCCMarginDepositHelperSafe
/// @notice Routes each LCC deposit-operator grant or revoke through the 24-hour parameters timelock.
/// @dev Grant usage:
///      1. `--sig "schedule(uint256,bool)" <attempt> <send>` with `LCC_FACTORY`,
///         `LCC_MARGIN_DEPOSIT_HELPER`, optional `SAFE_ADDRESS`, `WALLET_TYPE`, the matching Safe proposer
///         credential, and optional `SAFE_NONCE`.
///      2. After 24 hours, `--sig "execute(uint256)" <attempt>` with `LCC_FACTORY`,
///         `LCC_MARGIN_DEPOSIT_HELPER`, and an executor selected by Forge's `--account`, `--ledger`, or
///         `--sender` broadcast options.
///      3. `--sig "verify()"` with `LCC_FACTORY` and `LCC_MARGIN_DEPOSIT_HELPER`.
///
///      Revoke usage:
///      1. `--sig "scheduleRevoke(uint256,bool)" <attempt> <send>` with `LCC_FACTORY`,
///         `LCC_DEPOSIT_OPERATOR_TO_REVOKE`, optional `LCC_MARGIN_DEPOSIT_HELPER`, optional `SAFE_ADDRESS`,
///         `WALLET_TYPE`, the matching Safe proposer credential, and optional `SAFE_NONCE`.
///      2. After 24 hours, `--sig "executeRevoke(uint256)" <attempt>` with `LCC_FACTORY`,
///         `LCC_DEPOSIT_OPERATOR_TO_REVOKE`, optional `LCC_MARGIN_DEPOSIT_HELPER`, and an executor selected by
///         Forge's `--account`, `--ledger`, or `--sender` broadcast options.
///      3. `--sig "verifyRevoke()"` with `LCC_FACTORY` and `LCC_DEPOSIT_OPERATOR_TO_REVOKE`.
///
///      Grant and revoke are distinct one-call timelock operations. A replaced operator remains authorized until
///      its revoke operation executes.
contract AuthorizeLCCMarginDepositHelperSafe is Script, SafeHelper, TimelockHelper {
    address internal constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address internal constant PARAMS_TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    uint256 internal constant PARAMS_TIMELOCK_DELAY = 1 days;
    bytes32 internal constant SALT_DOMAIN = bytes32("3JANE_LCC_DEPOSIT_OPERATOR_V1");
    address internal constant WA_ETH_USDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;
    address internal constant WA_ETH_USDT = 0x7Bc3485026Ac48b6cf9BaF0A377477Fff5703Af8;

    function schedule(uint256 attempt, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(PARAMS_TIMELOCK)
    {
        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        (LCCVaultFactory factory, address helperAddress, bytes32 reviewedCodeHash) = _grantContext();
        _requireScheduleTopology(factory, safe);

        console2.log("=== Schedule LCC Deposit Operator Grant ===");
        _logHeader(factory, helperAddress, true, attempt);
        console2.log("Send to Safe:", send);
        console2.log("Reviewed helper runtime code hash:", vm.toString(reviewedCodeHash));
        if (factory.isDepositOperator(helperAddress)) {
            console2.log("LCC margin deposit helper is already a deposit operator; nothing to propose");
            return;
        }

        _schedule(factory, helperAddress, true, attempt, send);
    }

    function execute(uint256 attempt) external isTimelock(PARAMS_TIMELOCK) {
        (LCCVaultFactory factory, address helperAddress, bytes32 reviewedCodeHash) = _grantContext();
        _requireExecutionTopology(factory);

        console2.log("=== Execute LCC Deposit Operator Grant ===");
        _logHeader(factory, helperAddress, true, attempt);
        console2.log("Reviewed helper runtime code hash:", vm.toString(reviewedCodeHash));
        _execute(factory, helperAddress, true, attempt);
        require(factory.isDepositOperator(helperAddress), "helper is not a deposit operator");
        _logDepositOperators(factory);
    }

    /// @notice Logs the chain's deposit operators and requires the configured helper to be authorized.
    function verify() external view {
        LCCVaultFactory factory = _factory();
        address helperAddress = vm.envAddress("LCC_MARGIN_DEPOSIT_HELPER");
        _logDepositOperators(factory);
        require(factory.isDepositOperator(helperAddress), "helper is not a deposit operator");
        console2.log("PASS");
    }

    function scheduleRevoke(uint256 attempt, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(PARAMS_TIMELOCK)
    {
        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        (LCCVaultFactory factory, address operator) = _revokeContext();
        _requireScheduleTopology(factory, safe);
        require(factory.isDepositOperator(operator), "address is not a deposit operator");

        console2.log("=== Schedule LCC Deposit Operator Revoke ===");
        _logHeader(factory, operator, false, attempt);
        console2.log("Send to Safe:", send);
        _schedule(factory, operator, false, attempt, send);
    }

    function executeRevoke(uint256 attempt) external isTimelock(PARAMS_TIMELOCK) {
        (LCCVaultFactory factory, address operator) = _revokeContext();
        _requireExecutionTopology(factory);

        console2.log("=== Execute LCC Deposit Operator Revoke ===");
        _logHeader(factory, operator, false, attempt);
        _execute(factory, operator, false, attempt);
        require(!factory.isDepositOperator(operator), "deposit operator revoke failed");
        _logDepositOperators(factory);
    }

    /// @notice Logs the chain's deposit operators and requires the configured operator to be unauthorized.
    function verifyRevoke() external view {
        LCCVaultFactory factory = _factory();
        address operator = _revokeAccount();
        _logDepositOperators(factory);
        require(!factory.isDepositOperator(operator), "address is still a deposit operator");
        console2.log("PASS");
    }

    function _schedule(LCCVaultFactory factory, address account, bool grant, uint256 attempt, bool send) private {
        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) =
            _operation(factory, account, grant, attempt);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, bytes32(0), salt);
        _logOperation(attempt, operationId, salt);

        ITimelockController.OperationState state = getOperationState(PARAMS_TIMELOCK, operationId);
        if (state == ITimelockController.OperationState.Waiting || state == ITimelockController.OperationState.Ready) {
            logOperationState(PARAMS_TIMELOCK, operationId);
            console2.log("Operation is already pending");
            return;
        }
        require(state != ITimelockController.OperationState.Done, "operation already executed; use a fresh attempt");

        uint256 snapshot = vm.snapshotState();
        simulateExecution(PARAMS_TIMELOCK, targets, values, datas);
        require(factory.isDepositOperator(account) == grant, "simulated role change failed");
        vm.revertToState(snapshot);

        addToBatch(
            PARAMS_TIMELOCK, encodeScheduleBatch(targets, values, datas, bytes32(0), salt, PARAMS_TIMELOCK_DELAY)
        );
        _requireSingleCall();
        _send(send);
        if (grant) {
            console2.log("Next: after 24 hours, run --sig \"execute(uint256)\" with attempt", attempt);
        } else {
            console2.log("Next: after 24 hours, run --sig \"executeRevoke(uint256)\" with attempt", attempt);
        }
    }

    function _execute(LCCVaultFactory factory, address account, bool grant, uint256 attempt) private {
        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) =
            _operation(factory, account, grant, attempt);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, bytes32(0), salt);
        _logOperation(attempt, operationId, salt);
        logOperationState(PARAMS_TIMELOCK, operationId);
        require(!isOperationDone(PARAMS_TIMELOCK, operationId), "operation already executed");
        requireOperationReady(PARAMS_TIMELOCK, operationId);

        address broadcaster = _startExecutorBroadcast();
        console2.log("Timelock executor broadcaster:", broadcaster);
        ITimelockController(PARAMS_TIMELOCK).executeBatch(targets, values, datas, bytes32(0), salt);
        vm.stopBroadcast();
        require(factory.isDepositOperator(account) == grant, "timelock role change failed");
    }

    function _startExecutorBroadcast() private returns (address broadcaster) {
        vm.startBroadcast();
        (VmSafe.CallerMode mode, address sender,) = vm.readCallers();
        require(mode == VmSafe.CallerMode.RecurrentBroadcast, "Broadcast mode not active");
        broadcaster = sender;

        ITimelockController controller = ITimelockController(PARAMS_TIMELOCK);
        bytes32 executorRole = controller.EXECUTOR_ROLE();
        require(
            controller.hasRole(executorRole, address(0)) || controller.hasRole(executorRole, broadcaster),
            "broadcaster is not a parameters timelock executor"
        );
    }

    function _grantContext()
        private
        returns (LCCVaultFactory factory, address helperAddress, bytes32 reviewedCodeHash)
    {
        factory = _factory();
        helperAddress = vm.envAddress("LCC_MARGIN_DEPOSIT_HELPER");
        require(helperAddress.code.length > 0, "helper has no code");

        LCCMarginDepositHelper reviewed = new LCCMarginDepositHelper(address(factory), WA_ETH_USDC, WA_ETH_USDT);
        reviewedCodeHash = address(reviewed).codehash;
        require(helperAddress.codehash == reviewedCodeHash, "helper runtime code hash mismatch");
        _verifyWiring(LCCMarginDepositHelper(helperAddress), factory);
    }

    function _revokeContext() private view returns (LCCVaultFactory factory, address operator) {
        factory = _factory();
        operator = _revokeAccount();
    }

    function _revokeAccount() private view returns (address operator) {
        operator = vm.envAddress("LCC_DEPOSIT_OPERATOR_TO_REVOKE");
        require(operator != vm.envOr("LCC_MARGIN_DEPOSIT_HELPER", address(0)), "operator is LCC_MARGIN_DEPOSIT_HELPER");
    }

    function _factory() private view returns (LCCVaultFactory factory) {
        factory = LCCVaultFactory(vm.envAddress("LCC_FACTORY"));
        require(address(factory).code.length > 0, "factory has no code");
    }

    function _verifyWiring(LCCMarginDepositHelper helper, LCCVaultFactory factory) private view {
        require(helper.factory() == address(factory), "helper factory mismatch");
        require(helper.waEthUSDC() == WA_ETH_USDC, "helper waEthUSDC mismatch");
        require(helper.waEthUSDT() == WA_ETH_USDT, "helper waEthUSDT mismatch");
        require(helper.usdc() == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "helper USDC mismatch");
        require(helper.aEthUSDC() == 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c, "helper aEthUSDC mismatch");
        require(helper.usdt() == 0xdAC17F958D2ee523a2206206994597C13D831ec7, "helper USDT mismatch");
        require(helper.aEthUSDT() == 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a, "helper aEthUSDT mismatch");
    }

    function _requireScheduleTopology(LCCVaultFactory factory, address safe) private view {
        _requireExecutionTopology(factory);
        require(getMinDelay(PARAMS_TIMELOCK) == PARAMS_TIMELOCK_DELAY, "parameters timelock delay is not 24 hours");

        ITimelockController controller = ITimelockController(PARAMS_TIMELOCK);
        require(controller.hasRole(controller.PROPOSER_ROLE(), safe), "Safe is not a parameters timelock proposer");
    }

    function _requireExecutionTopology(LCCVaultFactory factory) private view {
        require(PARAMS_TIMELOCK.code.length > 0, "parameters timelock has no code");
        require(factory.owner() == PARAMS_TIMELOCK, "parameters timelock is not factory owner");
        require(factory.getRoleMemberCount(factory.OWNER_ROLE()) == 1, "factory owner count mismatch");
        require(
            factory.getRoleAdmin(factory.DEPOSIT_OPERATOR_ROLE()) == factory.OWNER_ROLE(),
            "deposit operator admin mismatch"
        );
    }

    function _operation(LCCVaultFactory factory, address account, bool grant, uint256 attempt)
        private
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt)
    {
        targets = new address[](1);
        values = new uint256[](1);
        datas = new bytes[](1);
        targets[0] = address(factory);
        datas[0] = grant
            ? abi.encodeCall(factory.grantRole, (factory.DEPOSIT_OPERATOR_ROLE(), account))
            : abi.encodeCall(factory.revokeRole, (factory.DEPOSIT_OPERATOR_ROLE(), account));
        salt = keccak256(abi.encode(SALT_DOMAIN, address(factory), account, grant, attempt));
    }

    function _logHeader(LCCVaultFactory factory, address account, bool grant, uint256 attempt) private view {
        console2.log("Factory:", address(factory));
        console2.log("Factory owner (timelock):", factory.owner());
        console2.log(grant ? "Grant account:" : "Revoke account:", account);
        console2.log("Attempt:", attempt);
        console2.log("Current deposit operators:", factory.getRoleMemberCount(factory.DEPOSIT_OPERATOR_ROLE()));
    }

    function _logOperation(uint256 attempt, bytes32 operationId, bytes32 salt) private view {
        console2.log("Attempt:", attempt);
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Operation salt:", vm.toString(salt));
    }

    function _requireSingleCall() private view {
        require(getTotalBatches() == 1, "SafeHelper split the batch");
        (uint256 txCount,) = getBatchInfo(0);
        require(txCount == 1, "operation must be one Safe call");
    }

    function _send(bool send) private {
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

    function _logDepositOperators(LCCVaultFactory factory) private view {
        bytes32 role = factory.DEPOSIT_OPERATOR_ROLE();
        uint256 count = factory.getRoleMemberCount(role);
        console2.log("Deposit operators in chain state:", count);
        for (uint256 i; i < count; ++i) {
            console2.log("  deposit operator:", factory.getRoleMember(role, i));
        }
    }
}
