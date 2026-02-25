// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.2 <0.9.0;

import {Script, console2} from "forge-std/Script.sol";
import {ITimelockController} from "../../src/interfaces/ITimelockController.sol";

/// @title TimelockHelper
/// @notice Helper contract for working with TimelockController operations
/// @dev Designed to work alongside SafeHelper for Safe multisig + Timelock workflows
abstract contract TimelockHelper is Script {
    /// @notice TimelockController address (mainnet)
    address public constant TIMELOCK_MAINNET = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;

    /// @notice Timelock address for the current session
    address public timelock;

    /// @notice Modifier to set the timelock address
    modifier isTimelock(address _timelock) {
        timelock = _timelock;
        _;
    }

    /// @notice Structure to store operation details for later reference
    struct TimelockOperation {
        address[] targets;
        uint256[] values;
        bytes[] datas;
        bytes32 predecessor;
        bytes32 salt;
        uint256 delay;
        bytes32 id;
    }

    /* ========== ENCODING FUNCTIONS ========== */

    /// @notice Encode a schedule call for a single operation
    function encodeSchedule(
        address target,
        uint256 value,
        bytes memory data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public pure returns (bytes memory) {
        return abi.encodeCall(ITimelockController.schedule, (target, value, data, predecessor, salt, delay));
    }

    /// @notice Encode a scheduleBatch call for multiple operations
    function encodeScheduleBatch(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory datas,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public pure returns (bytes memory) {
        return abi.encodeCall(ITimelockController.scheduleBatch, (targets, values, datas, predecessor, salt, delay));
    }

    /// @notice Encode an execute call for a single operation
    function encodeExecute(address target, uint256 value, bytes memory data, bytes32 predecessor, bytes32 salt)
        public
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(ITimelockController.execute, (target, value, data, predecessor, salt));
    }

    /// @notice Encode an executeBatch call for multiple operations
    function encodeExecuteBatch(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory datas,
        bytes32 predecessor,
        bytes32 salt
    ) public pure returns (bytes memory) {
        return abi.encodeCall(ITimelockController.executeBatch, (targets, values, datas, predecessor, salt));
    }

    /// @notice Encode a cancel call
    function encodeCancel(bytes32 operationId) public pure returns (bytes memory) {
        return abi.encodeCall(ITimelockController.cancel, (operationId));
    }

    /* ========== OPERATION ID CALCULATION ========== */

    /// @notice Calculate the operation ID for a single operation
    function calculateOperationId(address target, uint256 value, bytes memory data, bytes32 predecessor, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(target, value, data, predecessor, salt));
    }

    /// @notice Calculate the operation ID for a batch operation
    function calculateBatchOperationId(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory datas,
        bytes32 predecessor,
        bytes32 salt
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(targets, values, datas, predecessor, salt));
    }

    /* ========== STATE CHECKING FUNCTIONS ========== */

    /// @notice Check if an operation exists
    function isOperation(address _timelock, bytes32 id) public view returns (bool) {
        return ITimelockController(_timelock).isOperation(id);
    }

    /// @notice Check if an operation is ready for execution
    function isOperationReady(address _timelock, bytes32 id) public view returns (bool) {
        return ITimelockController(_timelock).isOperationReady(id);
    }

    /// @notice Check if an operation is done
    function isOperationDone(address _timelock, bytes32 id) public view returns (bool) {
        return ITimelockController(_timelock).isOperationDone(id);
    }

    /// @notice Check if an operation is pending (waiting or ready)
    function isOperationPending(address _timelock, bytes32 id) public view returns (bool) {
        return ITimelockController(_timelock).isOperationPending(id);
    }

    /// @notice Get the timestamp when an operation becomes ready
    function getOperationTimestamp(address _timelock, bytes32 id) public view returns (uint256) {
        return ITimelockController(_timelock).getTimestamp(id);
    }

    /// @notice Get the state of an operation
    function getOperationState(address _timelock, bytes32 id) public view returns (ITimelockController.OperationState) {
        return ITimelockController(_timelock).getOperationState(id);
    }

    /// @notice Get the minimum delay for the timelock
    function getMinDelay(address _timelock) public view returns (uint256) {
        return ITimelockController(_timelock).getMinDelay();
    }

    /* ========== UTILITY FUNCTIONS ========== */

    /// @notice Generate a unique salt based on description
    function generateSalt(string memory description) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(description));
    }

    /// @notice Log operation details
    function logOperation(TimelockOperation memory op) internal view {
        console2.log("=== Timelock Operation ===");
        console2.log("Operation ID:", vm.toString(op.id));
        console2.log("Targets:", op.targets.length);
        for (uint256 i = 0; i < op.targets.length; i++) {
            console2.log("  Target", i, ":", op.targets[i]);
            console2.log("  Value", i, ":", op.values[i]);
        }
        console2.log("Predecessor:", vm.toString(op.predecessor));
        console2.log("Salt:", vm.toString(op.salt));
        console2.log("Delay:", op.delay);
    }

    /// @notice Log operation state
    function logOperationState(address _timelock, bytes32 id) internal view {
        ITimelockController.OperationState state = getOperationState(_timelock, id);
        console2.log("Operation", vm.toString(id));

        if (state == ITimelockController.OperationState.Unset) {
            console2.log("  State: Unset (does not exist)");
        } else if (state == ITimelockController.OperationState.Waiting) {
            uint256 timestamp = getOperationTimestamp(_timelock, id);
            console2.log("  State: Waiting");
            console2.log("  Ready at:", timestamp);
            console2.log("  Current time:", block.timestamp);
            console2.log("  Time remaining:", timestamp - block.timestamp);
        } else if (state == ITimelockController.OperationState.Ready) {
            console2.log("  State: Ready (can be executed)");
        } else if (state == ITimelockController.OperationState.Done) {
            console2.log("  State: Done (already executed)");
        }
    }

    /// @notice Create a simple operation for testing or common patterns
    function createSimpleOperation(address target, bytes memory data, string memory description)
        public
        pure
        returns (TimelockOperation memory)
    {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);

        targets[0] = target;
        values[0] = 0;
        datas[0] = data;

        bytes32 salt = generateSalt(description);
        bytes32 id = calculateBatchOperationId(targets, values, datas, bytes32(0), salt);

        return TimelockOperation({
            targets: targets,
            values: values,
            datas: datas,
            predecessor: bytes32(0),
            salt: salt,
            delay: 0, // Will be set when scheduling
            id: id
        });
    }

    /// @notice Helper to check if we should proceed with execution
    function requireOperationReady(address _timelock, bytes32 id) internal view {
        ITimelockController.OperationState state = getOperationState(_timelock, id);

        if (state == ITimelockController.OperationState.Unset) {
            revert("Operation does not exist");
        } else if (state == ITimelockController.OperationState.Waiting) {
            uint256 timestamp = getOperationTimestamp(_timelock, id);
            uint256 remaining = timestamp - block.timestamp;
            revert(string.concat("Operation still waiting. Time remaining: ", vm.toString(remaining), " seconds"));
        } else if (state == ITimelockController.OperationState.Done) {
            revert("Operation already executed");
        }
        // State is Ready, can proceed
    }

    /* ========== SIMULATION FUNCTIONS ========== */

    /// @notice Simulate execution of a batch operation to verify it will succeed
    /// @dev Uses vm.prank to simulate being the timelock and executes each call
    function simulateExecution(
        address _timelock,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory datas
    ) internal {
        console2.log("=== Simulating Timelock Execution ===");

        for (uint256 i = 0; i < targets.length; i++) {
            console2.log("Simulating call %d of %d", i + 1, targets.length);
            console2.log("  Target:", targets[i]);

            vm.prank(_timelock);
            (bool success, bytes memory returnData) = targets[i].call{value: values[i]}(datas[i]);

            if (success) {
                console2.log("  Result: SUCCESS");
            } else {
                console2.log("  Result: FAILED");
                console2.log("  Revert reason:", _getRevertMsg(returnData));
                revert("Simulation failed - execution would revert");
            }
        }

        console2.log("=== All calls simulated successfully ===");
    }

    /// @notice Extract revert reason from return data
    function _getRevertMsg(bytes memory returnData) internal pure returns (string memory) {
        // If the return data is less than 68 bytes, it's not a standard revert
        if (returnData.length < 68) return "Unknown error";

        // Skip the selector (4 bytes) and decode the string
        assembly {
            returnData := add(returnData, 0x04)
        }
        return abi.decode(returnData, (string));
    }
}
