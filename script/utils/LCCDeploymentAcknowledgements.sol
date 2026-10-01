// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {ILCCVault} from "../../src/lcc/interfaces/ILCCVault.sol";

/// @notice Deployment-only acknowledgement checks for deliberate LCC facility risk choices.
abstract contract LCCDeploymentAcknowledgements {
    function _requireHoldToMaturityAcknowledgement(ILCCVault.VaultParams memory params, bool acknowledgeHoldToMaturity)
        internal
        pure
    {
        require(
            !_isHoldToMaturity(params) || acknowledgeHoldToMaturity,
            "Hold-to-maturity requires explicit acknowledgement"
        );
    }

    function _isHoldToMaturity(ILCCVault.VaultParams memory params) internal pure returns (bool) {
        return params.maxEpochs != 0
            && (params.minCommitmentEpochs >= params.maxEpochs
                || params.exitDelayEpochs >= params.maxEpochs - params.minCommitmentEpochs);
    }
}
