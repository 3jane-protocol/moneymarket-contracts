// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";

import {ITimelockController} from "../../src/interfaces/ITimelockController.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";

interface IKeeperRelayer {
    function usd3() external view returns (address);
    function keepers(address keeper) external view returns (bool);
    function setKeeper(address keeper, bool authorized) external;
}

interface IManaged {
    function management() external view returns (address);
}

interface IFeeRecipient {
    function performanceFeeRecipient() external view returns (address);
    function setPerformanceFeeRecipient(address recipient) external;
}

/// @title RotateTimelockExecutorSafe
/// @notice Replaces one EXECUTOR_ROLE holder with another on the 24-hour parameters timelock or the 7-day upgrades
///         timelock. The Safe proposes one self-administered timelock batch, `grantRole(EXECUTOR_ROLE, successor)`
///         then `revokeRole(EXECUTOR_ROLE, retired)`, executed after the timelock's delay. On the parameters timelock,
///         which is USD3 and sUSD3 management and therefore the KeeperRelayer's administrator, the batch then calls
///         `KeeperRelayer.setKeeper(retired, false)` and `sUSD3.setPerformanceFeeRecipient(feeRecipient)`; the
///         successor is not made a keeper.
/// @dev The timelocks are their own admins, so role changes on them must pass through their own delay. The Safe
///      keeps PROPOSER_ROLE and EXECUTOR_ROLE throughout, and the retired executor remains authorized until the batch
///      executes, so either may send `executeBatch`. `execute` proposes it through the Safe and also logs the raw
///      `executeBatch` calldata for a direct send by any current executor.
///
///      Usage (TIMELOCK is 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2 or 0x3D3C41419Ab401cd25055E8f9421D7D96d887885):
///      1. --sig "schedule(address,uint256,bool)" <TIMELOCK> 0 false   (then send with true)
///      2. After the delay, --sig "execute(address,uint256,bool)" <TIMELOCK> 0 false   (then true)
///      3. --sig "verify(address)" <TIMELOCK>
///      With FOUNDRY_PROFILE=script, WALLET_TYPE and the Safe proposer credential, and a mainnet RPC. EXECUTOR_RETIRED
///      and EXECUTOR_SUCCESSOR override the default addresses; SUSD3_FEE_RECIPIENT overrides the default sUSD3
///      performance-fee recipient, the main Safe.
contract RotateTimelockExecutorSafe is Script, SafeHelper, TimelockHelper {
    address internal constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address internal constant PARAMS_TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address internal constant UPGRADES_TIMELOCK = 0x3D3C41419Ab401cd25055E8f9421D7D96d887885;
    address internal constant KEEPER_RELAYER = 0xc22158100B823e1Ef612fBA265941efE9E7d7975;
    address internal constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address internal constant SUSD3 = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;
    address internal constant DEFAULT_RETIRED = 0x1226858E04b9d077258F153275613734421cD06B;
    address internal constant DEFAULT_SUCCESSOR = 0x1B542b6Ab19f169204a7226b3a452C98038bd384;
    bytes32 internal constant SALT_DOMAIN = bytes32("3JANE_TL_EXECUTOR_ROTATE_V1");

    function schedule(address timelockAddress, uint256 attempt, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(timelockAddress)
    {
        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        uint256 delay = _requireTopology(timelockAddress, safe);
        (address retired, address successor) = _accounts();

        console2.log("=== Schedule Timelock Executor Rotation ===");
        _logHeader(timelockAddress, delay, retired, successor, send);
        if (_rotated(timelockAddress, retired, successor)) {
            console2.log("Executor already rotated; nothing to propose");
            return;
        }
        require(_isExecutor(timelockAddress, safe), "Safe is not a timelock executor");

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) =
            _operation(timelockAddress, retired, successor, attempt);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, bytes32(0), salt);
        console2.log("Attempt:", attempt);
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Operation salt:", vm.toString(salt));

        ITimelockController.OperationState state = getOperationState(timelockAddress, operationId);
        if (state == ITimelockController.OperationState.Waiting || state == ITimelockController.OperationState.Ready) {
            logOperationState(timelockAddress, operationId);
            console2.log("Operation is already pending");
            return;
        }
        require(state != ITimelockController.OperationState.Done, "operation already executed; use a fresh attempt");

        uint256 snapshot = vm.snapshotState();
        simulateExecution(timelockAddress, targets, values, datas);
        require(_rotated(timelockAddress, retired, successor), "simulated rotation failed");
        vm.revertToState(snapshot);

        addToBatch(timelockAddress, encodeScheduleBatch(targets, values, datas, bytes32(0), salt, delay));
        _requireSingleCall();
        _send(send);
        console2.log("Next: after the timelock delay, run execute with the same timelock and attempt nonce");
    }

    function execute(address timelockAddress, uint256 attempt, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(timelockAddress)
    {
        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        uint256 delay = _requireTopology(timelockAddress, safe);
        (address retired, address successor) = _accounts();
        require(_isExecutor(timelockAddress, safe), "Safe is not a timelock executor");

        console2.log("=== Execute Timelock Executor Rotation ===");
        _logHeader(timelockAddress, delay, retired, successor, send);

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) =
            _operation(timelockAddress, retired, successor, attempt);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, bytes32(0), salt);
        console2.log("Operation ID:", vm.toString(operationId));
        logOperationState(timelockAddress, operationId);
        requireOperationReady(timelockAddress, operationId);

        bytes memory executeCalldata = encodeExecuteBatch(targets, values, datas, bytes32(0), salt);
        console2.log("executeBatch calldata (direct send by a current executor):");
        console2.logBytes(executeCalldata);

        addToBatch(timelockAddress, executeCalldata);
        require(_rotated(timelockAddress, retired, successor), "simulated rotation failed");
        _requireSingleCall();
        _send(send);
    }

    /// @notice Require that the successor holds EXECUTOR_ROLE and the retired account does not, and on the parameters
    ///         timelock that the retired account is no longer a KeeperRelayer keeper and the sUSD3 performance-fee
    ///         recipient is the configured recipient.
    function verify(address timelockAddress) external view {
        _delayOf(timelockAddress);
        (address retired, address successor) = _accounts();
        console2.log("Timelock:", timelockAddress);
        console2.log("Successor is executor:", _isExecutor(timelockAddress, successor));
        console2.log("Retired is executor:", _isExecutor(timelockAddress, retired));
        if (timelockAddress == PARAMS_TIMELOCK) {
            console2.log("Retired is KeeperRelayer keeper:", IKeeperRelayer(KEEPER_RELAYER).keepers(retired));
            console2.log("sUSD3 performance-fee recipient:", IFeeRecipient(SUSD3).performanceFeeRecipient());
        }
        require(_rotated(timelockAddress, retired, successor), "executor rotation not applied");
        console2.log("PASS");
    }

    function _accounts() internal view returns (address retired, address successor) {
        retired = vm.envOr("EXECUTOR_RETIRED", DEFAULT_RETIRED);
        successor = vm.envOr("EXECUTOR_SUCCESSOR", DEFAULT_SUCCESSOR);
        require(retired != address(0) && successor != address(0), "zero executor address");
        require(retired != successor, "retired equals successor");
        require(_feeRecipient() != retired, "fee recipient is the retired account");
    }

    function _feeRecipient() internal view returns (address recipient) {
        recipient = vm.envOr("SUSD3_FEE_RECIPIENT", DEFAULT_SAFE);
        require(recipient != address(0) && recipient != SUSD3, "invalid sUSD3 fee recipient");
    }

    function _delayOf(address timelockAddress) internal pure returns (uint256) {
        if (timelockAddress == PARAMS_TIMELOCK) return 1 days;
        if (timelockAddress == UPGRADES_TIMELOCK) return 7 days;
        revert("timelock must be the parameters or upgrades timelock");
    }

    function _requireTopology(address timelockAddress, address safe) internal view returns (uint256 delay) {
        delay = _delayOf(timelockAddress);
        require(timelockAddress.code.length > 0, "timelock has no code");
        require(getMinDelay(timelockAddress) == delay, "timelock delay mismatch");
        ITimelockController tl = ITimelockController(timelockAddress);
        require(tl.hasRole(tl.PROPOSER_ROLE(), safe), "Safe is not a timelock proposer");
        require(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), timelockAddress), "timelock is not its own admin");
        require(!tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "timelock execution is open");
        if (timelockAddress == PARAMS_TIMELOCK) {
            require(IKeeperRelayer(KEEPER_RELAYER).usd3() == USD3, "KeeperRelayer USD3 mismatch");
            require(IManaged(USD3).management() == PARAMS_TIMELOCK, "parameters timelock is not USD3 management");
            require(IManaged(SUSD3).management() == PARAMS_TIMELOCK, "parameters timelock is not sUSD3 management");
        }
    }

    function _operation(address timelockAddress, address retired, address successor, uint256 attempt)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt)
    {
        bytes32 executorRole = ITimelockController(timelockAddress).EXECUTOR_ROLE();
        uint256 count = timelockAddress == PARAMS_TIMELOCK ? 4 : 2;
        targets = new address[](count);
        values = new uint256[](count);
        datas = new bytes[](count);
        targets[0] = timelockAddress;
        targets[1] = timelockAddress;
        datas[0] = abi.encodeCall(ITimelockController.grantRole, (executorRole, successor));
        datas[1] = abi.encodeCall(ITimelockController.revokeRole, (executorRole, retired));
        address feeRecipient;
        if (count == 4) {
            feeRecipient = _feeRecipient();
            targets[2] = KEEPER_RELAYER;
            datas[2] = abi.encodeCall(IKeeperRelayer.setKeeper, (retired, false));
            targets[3] = SUSD3;
            datas[3] = abi.encodeCall(IFeeRecipient.setPerformanceFeeRecipient, (feeRecipient));
        }
        salt = keccak256(abi.encode(SALT_DOMAIN, timelockAddress, retired, successor, feeRecipient, attempt));
    }

    function _isExecutor(address timelockAddress, address account) internal view returns (bool) {
        ITimelockController tl = ITimelockController(timelockAddress);
        return tl.hasRole(tl.EXECUTOR_ROLE(), account);
    }

    function _rotated(address timelockAddress, address retired, address successor) internal view returns (bool) {
        if (!_isExecutor(timelockAddress, successor) || _isExecutor(timelockAddress, retired)) return false;
        if (timelockAddress != PARAMS_TIMELOCK) return true;
        return !IKeeperRelayer(KEEPER_RELAYER).keepers(retired)
            && IFeeRecipient(SUSD3).performanceFeeRecipient() == _feeRecipient();
    }

    function _logHeader(address timelockAddress, uint256 delay, address retired, address successor, bool send)
        internal
        view
    {
        console2.log("Timelock:", timelockAddress);
        console2.log("Delay (seconds):", delay);
        console2.log("Retired executor:", retired);
        console2.log("  currently executor:", _isExecutor(timelockAddress, retired));
        console2.log("Successor executor:", successor);
        console2.log("  currently executor:", _isExecutor(timelockAddress, successor));
        if (timelockAddress == PARAMS_TIMELOCK) {
            console2.log("KeeperRelayer:", KEEPER_RELAYER);
            console2.log("  retired currently keeper:", IKeeperRelayer(KEEPER_RELAYER).keepers(retired));
            console2.log("sUSD3 performance-fee recipient:", IFeeRecipient(SUSD3).performanceFeeRecipient());
            console2.log("  target:", _feeRecipient());
        }
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
