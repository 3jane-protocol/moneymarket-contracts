// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {MathLib} from "./MathLib.sol";

/// @title DelayedRepaymentRebateLib
/// @notice Helpers for report-only rebates on borrower repayments delayed through an EOA.
library DelayedRepaymentRebateLib {
    using MathLib for uint256;

    bytes32 internal constant TRANSFER_EVENT_SIG = keccak256("Transfer(address,address,uint256)");

    function cappedPrincipal(uint256 receivedAssets, uint256 startDebtAssets) internal pure returns (uint256) {
        return receivedAssets < startDebtAssets ? receivedAssets : startDebtAssets;
    }

    function delayedInterest(uint256 principalAssets, uint256 startDebtAssets, uint256 endDebtAssets)
        internal
        pure
        returns (uint256)
    {
        if (principalAssets == 0 || startDebtAssets == 0 || endDebtAssets <= startDebtAssets) return 0;

        return principalAssets.mulDivDown(endDebtAssets - startDebtAssets, startDebtAssets);
    }

    function residualCleanup(uint256 postSafeDebtUsdc, uint256 thresholdUsdc) internal pure returns (uint256) {
        if (postSafeDebtUsdc == 0 || postSafeDebtUsdc >= thresholdUsdc) return 0;
        return postSafeDebtUsdc;
    }

    function addressTopic(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    function topicAddress(bytes32 topic) internal pure returns (address) {
        return address(uint160(uint256(topic)));
    }
}
