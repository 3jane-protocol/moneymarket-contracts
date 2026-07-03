// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

import {ILCCVault} from "../interfaces/ILCCVault.sol";

/// @title LCCAccountLib
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Pure memory-account helpers for the LCC vault.
library LCCAccountLib {
    function activatePendingForEpoch(ILCCVault.Account memory account, uint256 epoch) internal pure {
        if (account.pendingActivationEpoch != 0 && account.pendingActivationEpoch <= epoch) {
            activatePending(account);
        }
    }

    function activatePending(ILCCVault.Account memory account) internal pure {
        account.activeMargin += account.pendingMargin;
        account.activeCommitment += account.pendingCommitment;
        account.pendingMargin = 0;
        account.pendingCommitment = 0;
        account.pendingActivationEpoch = 0;
    }

    function matureExitForEpoch(ILCCVault.Account memory account, uint256 epoch) internal pure {
        if (account.exitRequested && !account.exitMatured && !account.exitClaimed && account.exitMaturityEpoch <= epoch)
        {
            matureExit(account);
        }
    }

    function matureExit(ILCCVault.Account memory account) internal pure {
        account.claimableExitMargin += account.activeMargin;
        account.activeMargin = 0;
        account.activeCommitment = 0;
        account.exitBucketMargin = 0;
        account.exitBucketCommitment = 0;
        account.exitMatured = true;
    }

    function defaultAccount(ILCCVault.Account memory account) internal pure {
        account.activeMargin = 0;
        account.activeCommitment = 0;
        account.exitBucketMargin = 0;
        account.exitBucketCommitment = 0;
        account.claimableExitMargin = 0;
        if (account.exitRequested && !account.exitClaimed) clearExit(account);
    }

    function isZeroExposure(ILCCVault.Account memory account) internal pure returns (bool) {
        return account.activeMargin == 0 && account.activeCommitment == 0 && account.pendingMargin == 0
            && account.pendingCommitment == 0 && account.claimableExitMargin == 0
            && (!account.exitRequested || account.exitClaimed);
    }

    function clearExit(ILCCVault.Account memory account) internal pure {
        account.exitRequested = false;
        account.exitMaturityEpoch = 0;
        account.exitClaimed = true;
        account.exitMatured = false;
        account.exitBucketMargin = 0;
        account.exitBucketCommitment = 0;
    }
}
