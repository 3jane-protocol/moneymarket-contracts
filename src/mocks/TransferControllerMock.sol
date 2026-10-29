// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ITransferController} from "../interfaces/ITransferController.sol";
import {IERC20} from "../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TransferControllerMock
/// @notice Configurable mock implementation of ITransferController for testing
contract TransferControllerMock is ITransferController {
    /// @notice When false, every transfer is denied
    bool public allowAll = true;

    /// @notice Senders denied by `canTransfer`
    mapping(address => bool) public deniedFrom;

    /// @notice Recipients denied by `canTransfer`
    mapping(address => bool) public deniedTo;

    /// @notice Maximum amount allowed per transfer (0 means no limit)
    uint256 public maxAmount;

    /// @notice When true, `canTransfer` reverts
    bool public revertOnCan;

    /// @notice When true, `didTransfer` reverts
    bool public revertOnDid;

    /// @notice Number of `didTransfer` calls
    uint256 public didTransferCount;

    /// @notice Caller (token) of the last `didTransfer` call
    address public lastToken;

    /// @notice `from` argument of the last `didTransfer` call
    address public lastFrom;

    /// @notice `to` argument of the last `didTransfer` call
    address public lastTo;

    /// @notice `amount` argument of the last `didTransfer` call
    uint256 public lastAmount;

    /// @notice Token balance of `from` observed during the last `didTransfer` call
    uint256 public lastFromBalance;

    /// @notice Token balance of `to` observed during the last `didTransfer` call
    uint256 public lastToBalance;

    error CanTransferReverted();
    error DidTransferReverted();

    function setAllowAll(bool allowed) external {
        allowAll = allowed;
    }

    function setDeniedFrom(address account, bool denied) external {
        deniedFrom[account] = denied;
    }

    function setDeniedTo(address account, bool denied) external {
        deniedTo[account] = denied;
    }

    function setMaxAmount(uint256 amount) external {
        maxAmount = amount;
    }

    function setRevertOnCan(bool shouldRevert) external {
        revertOnCan = shouldRevert;
    }

    function setRevertOnDid(bool shouldRevert) external {
        revertOnDid = shouldRevert;
    }

    /// @inheritdoc ITransferController
    function canTransfer(address from, address to, uint256 amount) external view returns (bool) {
        if (revertOnCan) revert CanTransferReverted();
        if (!allowAll) return false;
        if (deniedFrom[from] || deniedTo[to]) return false;
        if (maxAmount != 0 && amount > maxAmount) return false;
        return true;
    }

    /// @inheritdoc ITransferController
    function didTransfer(address from, address to, uint256 amount) external {
        if (revertOnDid) revert DidTransferReverted();
        didTransferCount++;
        lastToken = msg.sender;
        lastFrom = from;
        lastTo = to;
        lastAmount = amount;
        lastFromBalance = IERC20(msg.sender).balanceOf(from);
        lastToBalance = IERC20(msg.sender).balanceOf(to);
    }
}
