// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title ITransferController
/// @notice External transfer policy consulted by the JANE token on `transfer` and `transferFrom`
interface ITransferController {
    /// @notice Pre-check, called before balances change
    /// @dev Return false to block the transfer; may also revert with a specific reason
    /// @param from Token owner whose balance is debited
    /// @param to Recipient whose balance is credited
    /// @param amount Amount being transferred
    /// @return True if the transfer is allowed
    function canTransfer(address from, address to, uint256 amount) external view returns (bool);

    /// @notice Post-notification, called after balances change in the same call
    /// @dev A revert reverts the whole transfer
    /// @param from Token owner whose balance was debited
    /// @param to Recipient whose balance was credited
    /// @param amount Amount transferred
    function didTransfer(address from, address to, uint256 amount) external;
}
