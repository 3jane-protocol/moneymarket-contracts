// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2, VmSafe} from "forge-std/Script.sol";

import {ITimelockController} from "../../src/interfaces/ITimelockController.sol";
import {LCCLeveragedFundHelper} from "../../src/lcc/LCCLeveragedFundHelper.sol";
import {ILCCLeveragedFundHelper} from "../../src/lcc/interfaces/ILCCLeveragedFundHelper.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";

interface IManagedNotificationVault {
    function management() external view returns (address);
    function cooldownBypass(address account) external view returns (bool);
    function getCooldownStatus(address user)
        external
        view
        returns (uint256 cooldownEnd, uint256 windowEnd, uint256 shares);
    function setCooldownBypass(address account, bool allowed) external;
    function startCooldown(uint256 shares) external;
}

/// @title SetUSD3lCooldownBypassTimelock
/// @notice Routes a USD3l cooldown-bypass grant or revoke through the 24-hour parameters timelock.
/// @dev Schedule with `USD3L_BYPASS_ACCOUNT`, `USD3L_BYPASS_ALLOWED`, optional `SAFE_ADDRESS`, `WALLET_TYPE`,
///      the matching Safe proposer credential, and optional `SAFE_NONCE`. Grants also require
///      `USD3L_BYPASS_EXPECTED_CODEHASH`. An existing or funded EOA has `keccak256("")` as its code hash; an
///      otherwise nonexistent EOA address has zero. Pass the value observed for the account being reviewed.
///
///      Set `USD3L_BYPASS_LCC_HELPER_FACTORY` for an LCC leveraged-helper grant. The script then rebuilds the helper
///      with canonical Morpho Blue, that factory, and USD3l before broadcast, and checks its runtime and wiring.
///
///      Execute after 24 hours with the environment printed by `schedule` and an executor selected by Forge's
///      `--account`, `--ledger`, or `--sender` broadcast options, then run `verify()`. A bypass transition deletes an
///      existing vault cooldown. The script requires `USD3L_BYPASS_ACKNOWLEDGE_COOLDOWN_CLEAR=true` when that applies.
///
///      This script can also authorize Morpho Blue liquidation executors that seize USD3l collateral. A bypassed
///      liquidation executor is expected to call `ILCCLeveragedFundHelper.trimCooldowns` for the liquidated user and
///      market in the liquidation transaction, so the user's helper cooldown book does not cover departed collateral.
contract SetUSD3lCooldownBypassTimelock is Script, SafeHelper, TimelockHelper {
    address internal constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address internal constant PARAMS_TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address internal constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant USD3L = 0xDF697c55f0D696CA9E3E624cD52d8186C6745904;
    address internal constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 internal constant PARAMS_TIMELOCK_DELAY = 1 days;
    bytes32 internal constant SALT_DOMAIN = bytes32("3JANE_USD3L_BYPASS_V1");
    bytes32 internal constant EMPTY_CODE_HASH = keccak256("");

    function schedule(uint256 attempt, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(PARAMS_TIMELOCK)
    {
        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        (address account, bool allowed, bytes32 expectedCodeHash) = _context();
        _requireScheduleTopology(safe);

        console2.log("=== Schedule USD3l Cooldown Bypass ===");
        _logHeader(account, allowed, attempt);
        console2.log("Send to Safe:", send);
        if (allowed) _reviewGrant(account, expectedCodeHash);
        _logRequiredExecutionEnv(account, allowed, expectedCodeHash);

        bool live = IManagedNotificationVault(USD3L).cooldownBypass(account);
        _requireCooldownClearAcknowledged(account);
        if (live == allowed) {
            console2.log("USD3l cooldown bypass already matches the target; nothing to propose");
            return;
        }

        _scheduleOperation(account, allowed, expectedCodeHash, attempt, send);
    }

    function _scheduleOperation(address account, bool allowed, bytes32 expectedCodeHash, uint256 attempt, bool send)
        private
    {
        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) =
            _operation(account, allowed, expectedCodeHash, attempt);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, bytes32(0), salt);
        _logOperation(operationId, salt);

        ITimelockController.OperationState state = getOperationState(PARAMS_TIMELOCK, operationId);
        if (state == ITimelockController.OperationState.Waiting || state == ITimelockController.OperationState.Ready) {
            logOperationState(PARAMS_TIMELOCK, operationId);
            console2.log("Operation is already pending");
            return;
        }
        require(state != ITimelockController.OperationState.Done, "operation already executed; use a fresh attempt");

        uint256 snapshot = vm.snapshotState();
        simulateExecution(PARAMS_TIMELOCK, targets, values, datas);
        require(IManagedNotificationVault(USD3L).cooldownBypass(account) == allowed, "simulated bypass change failed");
        vm.revertToState(snapshot);

        addToBatch(
            PARAMS_TIMELOCK, encodeScheduleBatch(targets, values, datas, bytes32(0), salt, PARAMS_TIMELOCK_DELAY)
        );
        _requireSingleCall();
        _send(send);
        console2.log("Next: after 24 hours, run --sig \"execute(uint256)\" with attempt", attempt);
    }

    function execute(uint256 attempt) external isTimelock(PARAMS_TIMELOCK) {
        (address account, bool allowed, bytes32 expectedCodeHash) = _context();
        _requireExecutionTopology();

        console2.log("=== Execute USD3l Cooldown Bypass ===");
        _logHeader(account, allowed, attempt);
        if (allowed) _reviewGrant(account, expectedCodeHash);
        require(
            IManagedNotificationVault(USD3L).cooldownBypass(account) != allowed, "live bypass already matches target"
        );
        _requireCooldownClearAcknowledged(account);

        _executeOperation(account, allowed, expectedCodeHash, attempt);
    }

    function _executeOperation(address account, bool allowed, bytes32 expectedCodeHash, uint256 attempt) private {
        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) =
            _operation(account, allowed, expectedCodeHash, attempt);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, bytes32(0), salt);
        _logOperation(operationId, salt);
        logOperationState(PARAMS_TIMELOCK, operationId);
        require(!isOperationDone(PARAMS_TIMELOCK, operationId), "operation already executed");
        requireOperationReady(PARAMS_TIMELOCK, operationId);

        address broadcaster = _startExecutorBroadcast();
        console2.log("Timelock executor broadcaster:", broadcaster);
        ITimelockController(PARAMS_TIMELOCK).executeBatch(targets, values, datas, bytes32(0), salt);
        vm.stopBroadcast();
        require(IManagedNotificationVault(USD3L).cooldownBypass(account) == allowed, "timelock bypass change failed");
    }

    /// @notice Requires the configured account's live cooldown-bypass state to match the configured target.
    function verify() external view {
        address account = vm.envAddress("USD3L_BYPASS_ACCOUNT");
        bool allowed = vm.envBool("USD3L_BYPASS_ALLOWED");
        require(account != address(0), "USD3L_BYPASS_ACCOUNT is zero");
        bool live = IManagedNotificationVault(USD3L).cooldownBypass(account);
        console2.log("USD3l:", USD3L);
        console2.log("Account:", account);
        console2.log("Expected cooldown bypass:", allowed);
        console2.log("Live cooldown bypass:", live);
        require(live == allowed, "live bypass does not match target");
        console2.log("PASS");
    }

    function _context() private view returns (address account, bool allowed, bytes32 expectedCodeHash) {
        account = vm.envAddress("USD3L_BYPASS_ACCOUNT");
        require(account != address(0), "USD3L_BYPASS_ACCOUNT is zero");
        allowed = vm.envBool("USD3L_BYPASS_ALLOWED");
        expectedCodeHash = allowed ? vm.envBytes32("USD3L_BYPASS_EXPECTED_CODEHASH") : bytes32(0);
    }

    function _reviewGrant(address account, bytes32 expectedCodeHash) private {
        bytes32 actualCodeHash = account.codehash;
        console2.log("Expected account code hash:", vm.toString(expectedCodeHash));
        console2.log("Actual account code hash:", vm.toString(actualCodeHash));
        if (actualCodeHash == bytes32(0)) {
            console2.log("Account code classification: nonexistent account (zero EXTCODEHASH)");
        } else if (actualCodeHash == EMPTY_CODE_HASH) {
            console2.log("Account code classification: existing account with empty code");
        } else {
            console2.log("Account code classification: contract");
        }
        require(actualCodeHash == expectedCodeHash, "account runtime code hash mismatch");

        address factory = vm.envOr("USD3L_BYPASS_LCC_HELPER_FACTORY", address(0));
        if (factory == address(0)) return;
        require(factory.code.length > 0, "LCC helper factory has no code");

        LCCLeveragedFundHelper reviewed = new LCCLeveragedFundHelper(MORPHO_BLUE, factory, USD3L);
        require(address(reviewed).codehash == actualCodeHash, "LCC helper runtime code hash mismatch");
        _verifyHelperWiring(ILCCLeveragedFundHelper(account), factory);
        console2.log("LCC leveraged-helper factory:", factory);
        console2.log("LCC leveraged-helper runtime and wiring checks: PASS");
    }

    function _verifyHelperWiring(ILCCLeveragedFundHelper helper, address factory) private view {
        require(helper.morpho() == MORPHO_BLUE, "helper morpho mismatch");
        require(helper.factory() == factory, "helper factory mismatch");
        require(helper.usd3l() == USD3L, "helper USD3l mismatch");
        require(helper.usd3() == USD3, "helper USD3 mismatch");
        require(helper.usdc() == USDC, "helper USDC mismatch");
    }

    function _requireScheduleTopology(address safe) private view {
        _requireExecutionTopology();
        require(getMinDelay(PARAMS_TIMELOCK) == PARAMS_TIMELOCK_DELAY, "parameters timelock delay is not 24 hours");

        ITimelockController controller = ITimelockController(PARAMS_TIMELOCK);
        require(controller.hasRole(controller.PROPOSER_ROLE(), safe), "Safe is not a parameters timelock proposer");
    }

    function _requireExecutionTopology() private view {
        require(PARAMS_TIMELOCK.code.length > 0, "parameters timelock has no code");
        require(USD3L.code.length > 0, "USD3l has no code");
        require(
            IManagedNotificationVault(USD3L).management() == PARAMS_TIMELOCK,
            "parameters timelock is not USD3l management"
        );
    }

    function _requireCooldownClearAcknowledged(address account) private view {
        (uint256 cooldownEnd, uint256 windowEnd, uint256 shares) =
            IManagedNotificationVault(USD3L).getCooldownStatus(account);
        if (shares == 0) return;

        console2.log("Configured account has a vault cooldown; a bypass transition clears it");
        console2.log("  Cooldown end:", cooldownEnd);
        console2.log("  Window end:", windowEnd);
        console2.log("  Cooldown shares:", shares);
        require(
            vm.envOr("USD3L_BYPASS_ACKNOWLEDGE_COOLDOWN_CLEAR", false),
            "account has cooldown; set USD3L_BYPASS_ACKNOWLEDGE_COOLDOWN_CLEAR=true"
        );
    }

    function _operation(address account, bool allowed, bytes32 expectedCodeHash, uint256 attempt)
        private
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt)
    {
        targets = new address[](1);
        values = new uint256[](1);
        datas = new bytes[](1);
        targets[0] = USD3L;
        datas[0] = abi.encodeCall(IManagedNotificationVault.setCooldownBypass, (account, allowed));
        salt = keccak256(abi.encode(SALT_DOMAIN, USD3L, account, allowed, expectedCodeHash, attempt));
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

    function _logHeader(address account, bool allowed, uint256 attempt) private view {
        console2.log("USD3l:", USD3L);
        console2.log("USD3l management (timelock):", IManagedNotificationVault(USD3L).management());
        console2.log("Bypass account:", account);
        console2.log("Target bypass allowed:", allowed);
        console2.log("Live bypass allowed:", IManagedNotificationVault(USD3L).cooldownBypass(account));
        console2.log("Attempt:", attempt);
    }

    function _logRequiredExecutionEnv(address account, bool allowed, bytes32 expectedCodeHash) private view {
        console2.log("Required execute environment:");
        console2.log(string.concat("USD3L_BYPASS_ACCOUNT=", vm.toString(account)));
        console2.log(string.concat("USD3L_BYPASS_ALLOWED=", allowed ? "true" : "false"));
        if (allowed) {
            console2.log(string.concat("USD3L_BYPASS_EXPECTED_CODEHASH=", vm.toString(expectedCodeHash)));
            address factory = vm.envOr("USD3L_BYPASS_LCC_HELPER_FACTORY", address(0));
            console2.log(string.concat("USD3L_BYPASS_LCC_HELPER_FACTORY=", vm.toString(factory)));
        }
        bool acknowledged = vm.envOr("USD3L_BYPASS_ACKNOWLEDGE_COOLDOWN_CLEAR", false);
        console2.log(string.concat("USD3L_BYPASS_ACKNOWLEDGE_COOLDOWN_CLEAR=", acknowledged ? "true" : "false"));
    }

    function _logOperation(bytes32 operationId, bytes32 salt) private view {
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
}
