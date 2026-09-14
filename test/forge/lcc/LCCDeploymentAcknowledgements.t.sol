// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test} from "../../../lib/forge-std/src/Test.sol";

import {LCCDeploymentAcknowledgements} from "../../../script/utils/LCCDeploymentAcknowledgements.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";

contract LCCDeploymentAcknowledgementsHarness is LCCDeploymentAcknowledgements {
    function requireHoldToMaturityAcknowledgement(ILCCVault.VaultParams memory params, bool acknowledge) external pure {
        _requireHoldToMaturityAcknowledgement(params, acknowledge);
    }
}

contract LCCDeploymentAcknowledgementsTest is Test {
    LCCDeploymentAcknowledgementsHarness internal harness = new LCCDeploymentAcknowledgementsHarness();

    function test_HoldToMaturityConfigurationRequiresExplicitAcknowledgement() public {
        ILCCVault.VaultParams memory params = _params(4, 3, 1);

        vm.expectRevert(bytes("Hold-to-maturity requires explicit acknowledgement"));
        harness.requireHoldToMaturityAcknowledgement(params, false);

        harness.requireHoldToMaturityAcknowledgement(params, true);
    }

    function test_HoldToMaturityWhenMinimumCommitmentExceedsTenorRequiresExplicitAcknowledgement() public {
        ILCCVault.VaultParams memory params = _params(1, 64, 1);

        vm.expectRevert(bytes("Hold-to-maturity requires explicit acknowledgement"));
        harness.requireHoldToMaturityAcknowledgement(params, false);

        harness.requireHoldToMaturityAcknowledgement(params, true);
    }

    function test_EarlyExitConfigurationDoesNotRequireHoldToMaturityAcknowledgement() public view {
        harness.requireHoldToMaturityAcknowledgement(_params(4, 2, 1), false);
    }

    function test_PerpetualConfigurationDoesNotRequireHoldToMaturityAcknowledgement() public view {
        harness.requireHoldToMaturityAcknowledgement(_params(0, 64, 64), false);
    }

    function _params(uint256 maxEpochs, uint256 minCommitmentEpochs, uint256 exitDelayEpochs)
        internal
        pure
        returns (ILCCVault.VaultParams memory params)
    {
        params.maxEpochs = maxEpochs;
        params.minCommitmentEpochs = minCommitmentEpochs;
        params.exitDelayEpochs = exitDelayEpochs;
    }
}
