// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title AaveRebateEventsLib
/// @notice Event signatures and borrower topic indexes used by the Aave rebate report script.
library AaveRebateEventsLib {
    bytes32 internal constant BORROW_EVENT_SIG = keccak256("Borrow(bytes32,address,address,address,uint256,uint256)");
    bytes32 internal constant REPAY_EVENT_SIG = keccak256("Repay(bytes32,address,address,uint256,uint256)");
    bytes32 internal constant PREMIUM_ACCRUED_EVENT_SIG = keccak256("PremiumAccrued(bytes32,address,uint256,uint256)");
    bytes32 internal constant ACCOUNT_SETTLED_EVENT_SIG =
        keccak256("AccountSettled(bytes32,address,address,uint256,uint256)");

    function borrowerTopicIndex(bytes32 eventSig) internal pure returns (uint256) {
        if (eventSig == BORROW_EVENT_SIG) return 2;
        if (eventSig == REPAY_EVENT_SIG) return 3;
        if (eventSig == PREMIUM_ACCRUED_EVENT_SIG) return 2;
        if (eventSig == ACCOUNT_SETTLED_EVENT_SIG) return 3;

        revert("unknown event");
    }
}
