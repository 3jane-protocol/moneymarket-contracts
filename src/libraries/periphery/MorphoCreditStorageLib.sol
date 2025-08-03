// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Id} from "../../interfaces/IMorpho.sol";
import {MorphoStorageLib} from "./MorphoStorageLib.sol";

/// @title MorphoCreditStorageLib
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice Helper library exposing getters to access MorphoCredit storage variables' slot.
/// @dev This library extends MorphoStorageLib functionality for MorphoCredit-specific storage.
library MorphoCreditStorageLib {
    /* MORPHO CREDIT STORAGE SLOTS */

    // MorphoCredit storage starts at slot 20 (after Morpho base storage and gap)
    uint256 internal constant HELPER_SLOT = 20;
    uint256 internal constant PROTOCOL_CONFIG_SLOT = 21;
    uint256 internal constant USD3_SLOT = 22;
    uint256 internal constant BORROWER_PREMIUM_SLOT = 23;
    uint256 internal constant PAYMENT_CYCLE_SLOT = 24;
    uint256 internal constant REPAYMENT_OBLIGATION_SLOT = 25;
    uint256 internal constant MARKDOWN_STATE_SLOT = 26;

    /* SLOT OFFSETS */

    // Market struct offsets (totalMarkdownAmount is added in slot 3)
    uint256 internal constant TOTAL_MARKDOWN_AMOUNT_OFFSET = 3;

    // BorrowerPremium struct offsets (within BORROWER_PREMIUM_SLOT mapping)
    uint256 internal constant BORROW_ASSETS_AT_LAST_ACCRUAL_OFFSET = 1;

    /* GETTERS */

    function helperSlot() internal pure returns (bytes32) {
        return bytes32(HELPER_SLOT);
    }

    function protocolConfigSlot() internal pure returns (bytes32) {
        return bytes32(PROTOCOL_CONFIG_SLOT);
    }

    function usd3Slot() internal pure returns (bytes32) {
        return bytes32(USD3_SLOT);
    }

    function borrowerPremiumSlot(Id id, address borrower) internal pure returns (bytes32) {
        return keccak256(abi.encode(borrower, keccak256(abi.encode(id, BORROWER_PREMIUM_SLOT))));
    }

    function paymentCycleLengthSlot(Id id) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, PAYMENT_CYCLE_SLOT));
    }

    function paymentCycleElementSlot(Id id, uint256 index) internal pure returns (bytes32) {
        // Array storage: keccak256(baseSlot) + index
        bytes32 baseSlot = keccak256(abi.encode(id, PAYMENT_CYCLE_SLOT));
        return bytes32(uint256(baseSlot) + index);
    }

    function repaymentObligationSlot(Id id, address borrower) internal pure returns (bytes32) {
        return keccak256(abi.encode(borrower, keccak256(abi.encode(id, REPAYMENT_OBLIGATION_SLOT))));
    }

    function markdownStateSlot(Id id, address borrower) internal pure returns (bytes32) {
        return keccak256(abi.encode(borrower, keccak256(abi.encode(id, MARKDOWN_STATE_SLOT))));
    }

    // Additional slot for accessing Market.totalMarkdownAmount
    function marketTotalMarkdownAmountSlot(Id id) internal pure returns (bytes32) {
        // Market struct is at MARKET_SLOT (3), totalMarkdownAmount is at offset 3 within the struct
        // Layout: slot 0: totalSupplyAssets + totalSupplyShares
        //         slot 1: totalBorrowAssets + totalBorrowShares
        //         slot 2: lastUpdate + fee
        //         slot 3: totalMarkdownAmount (uint128)
        return bytes32(uint256(keccak256(abi.encode(id, MorphoStorageLib.MARKET_SLOT))) + TOTAL_MARKDOWN_AMOUNT_OFFSET);
    }
}
