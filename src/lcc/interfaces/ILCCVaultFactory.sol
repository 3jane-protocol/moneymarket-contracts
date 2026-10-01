// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

/// @title ILCCVaultFactory
/// @notice Minimal family authority and admission interface consumed by LCC vault implementations.
interface ILCCVaultFactory {
    /// @dev The admissions module gates only new opens and reopens, never same-vault top-ups. A RegisteredElsewhere
    /// result caused by incomplete bounded replay has the permissionless remedy `materializeAccount` on that vault.
    /// @param postDepositCommitment The beneficiary's complete post-credit active-plus-pending commitment, computed
    /// after account replay and after crediting the current deposit. Every vault implementation must report this full
    /// value so pending exposure remains subject to the non-upgradeable factory cap.
    function authorizeDeposit(address payer, address beneficiary, bool hadOpenExposure, uint256 postDepositCommitment)
        external;
    /// @dev Boolean-returning authority views are deliberate: ABI decoding is the fail-closed guard against malformed
    /// captured factories and must not be replaced with void authorization calls.
    function isOwner(address account) external view returns (bool);
    function isGuardian(address account) external view returns (bool);
    function isBouncer(address account) external view returns (bool);
}
