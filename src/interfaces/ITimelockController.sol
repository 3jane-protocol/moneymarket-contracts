// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title ITimelockController
/// @notice Interface for OpenZeppelin's TimelockController
interface ITimelockController {
    /// @notice Role identifiers
    function PROPOSER_ROLE() external view returns (bytes32);
    function EXECUTOR_ROLE() external view returns (bytes32);
    function CANCELLER_ROLE() external view returns (bytes32);

    /// @notice Operation states
    enum OperationState {
        Unset,
        Waiting,
        Ready,
        Done
    }

    /// @notice Events
    event CallScheduled(
        bytes32 indexed id,
        uint256 indexed index,
        address target,
        uint256 value,
        bytes data,
        bytes32 predecessor,
        uint256 delay
    );

    event CallExecuted(bytes32 indexed id, uint256 indexed index, address target, uint256 value, bytes data);

    event CallSalt(bytes32 indexed id, bytes32 salt);
    event Cancelled(bytes32 indexed id);
    event MinDelayChange(uint256 oldDuration, uint256 newDuration);

    /// @notice Schedule a single operation
    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external;

    /// @notice Schedule a batch of operations
    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external;

    /// @notice Execute a single operation
    function execute(address target, uint256 value, bytes calldata payload, bytes32 predecessor, bytes32 salt)
        external
        payable;

    /// @notice Execute a batch of operations
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external payable;

    /// @notice Cancel an operation
    function cancel(bytes32 id) external;

    /// @notice Get the identifier of a single operation
    function hashOperation(address target, uint256 value, bytes calldata data, bytes32 predecessor, bytes32 salt)
        external
        pure
        returns (bytes32);

    /// @notice Get the identifier of a batch operation
    function hashOperationBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external pure returns (bytes32);

    /// @notice Get timestamp for an operation
    function getTimestamp(bytes32 id) external view returns (uint256);

    /// @notice Get minimum delay
    function getMinDelay() external view returns (uint256);

    /// @notice Get operation state
    function getOperationState(bytes32 id) external view returns (OperationState);

    /// @notice Check if operation exists
    function isOperation(bytes32 id) external view returns (bool);

    /// @notice Check if operation is pending
    function isOperationPending(bytes32 id) external view returns (bool);

    /// @notice Check if operation is ready
    function isOperationReady(bytes32 id) external view returns (bool);

    /// @notice Check if operation is done
    function isOperationDone(bytes32 id) external view returns (bool);

    /// @notice Update delay (only callable by timelock itself)
    function updateDelay(uint256 newDelay) external;
}
