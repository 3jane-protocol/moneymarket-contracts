// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {
    IMorpho,
    IMorphoCredit,
    Id,
    MarketParams,
    BorrowerPremium,
    RepaymentObligation,
    RepaymentStatus,
    MarkdownState
} from "../../interfaces/IMorpho.sol";
import {IMarkdownManager} from "../../interfaces/IMarkdownManager.sol";
import {MorphoLib} from "./MorphoLib.sol";
import {MorphoCreditStorageLib} from "./MorphoCreditStorageLib.sol";
import {MorphoBalancesLib} from "./MorphoBalancesLib.sol";
import {SharesMathLib} from "../SharesMathLib.sol";

/// @title MorphoCreditLib
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice Helper library to access MorphoCredit storage variables and computed values.
/// @dev This library extends MorphoLib functionality for MorphoCredit-specific features.
library MorphoCreditLib {
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;

    /// @dev Casts IMorphoCredit to IMorpho for accessing base functionality
    function _asIMorpho(IMorphoCredit morpho) private pure returns (IMorpho) {
        return IMorpho(address(morpho));
    }

    /// @notice Get markdown information for a borrower
    /// @param morpho The MorphoCredit instance
    /// @param id Market ID
    /// @param borrower Borrower address
    /// @return currentMarkdown Current markdown amount (calculated if in default)
    /// @return defaultStartTime When the borrower entered default (0 if not defaulted)
    /// @return borrowAssets Current borrow amount
    function getBorrowerMarkdownInfo(IMorphoCredit morpho, Id id, address borrower)
        internal
        view
        returns (uint256 currentMarkdown, uint256 defaultStartTime, uint256 borrowAssets)
    {
        // Get borrow assets
        IMorpho morphoBase = _asIMorpho(morpho);
        borrowAssets = morphoBase.expectedBorrowAssets(morphoBase.idToMarketParams(id), borrower);

        // Get repayment status
        (RepaymentStatus status, uint256 statusStartTime) = morpho.getRepaymentStatus(id, borrower);

        // Only set defaultStartTime if actually in default status
        if (status == RepaymentStatus.Default) {
            defaultStartTime = statusStartTime;

            // Get markdown manager and calculate markdown if set
            address manager = getMarkdownManager(morpho, id);
            if (manager != address(0) && defaultStartTime > 0 && borrowAssets > 0) {
                uint256 timeInDefault = block.timestamp > defaultStartTime ? block.timestamp - defaultStartTime : 0;
                currentMarkdown = IMarkdownManager(manager).calculateMarkdown(borrowAssets, timeInDefault);
            }
        }
    }

    /// @notice Get total market markdown
    /// @param morpho The MorphoCredit instance
    /// @param id Market ID
    /// @return totalMarkdown Current total markdown across all borrowers (may be stale)
    function getMarketMarkdownInfo(IMorphoCredit morpho, Id id) internal view returns (uint256 totalMarkdown) {
        // Access totalMarkdownAmount directly from storage
        bytes32[] memory slots = new bytes32[](1);
        slots[0] = MorphoCreditStorageLib.marketTotalMarkdownAmountSlot(id);
        totalMarkdown = uint128(uint256(_asIMorpho(morpho).extSloads(slots)[0]));
    }

    /// @notice Get the markdown manager for a market
    /// @param morpho The MorphoCredit instance
    /// @param id Market ID
    /// @return manager Address of the markdown manager (0 if not set)
    function getMarkdownManager(IMorphoCredit morpho, Id id) internal view returns (address manager) {
        bytes32[] memory slots = new bytes32[](1);
        slots[0] = MorphoCreditStorageLib.markdownManagerSlot(id);
        manager = address(uint160(uint256(_asIMorpho(morpho).extSloads(slots)[0])));
    }

    /// @notice Get borrower premium details
    /// @param morpho The MorphoCredit instance
    /// @param id Market ID
    /// @param borrower Borrower address
    /// @return premium The borrower's premium details
    function getBorrowerPremium(IMorphoCredit morpho, Id id, address borrower)
        internal
        view
        returns (BorrowerPremium memory premium)
    {
        bytes32[] memory slots = new bytes32[](1);
        slots[0] = MorphoCreditStorageLib.borrowerPremiumSlot(id, borrower);
        bytes32 data = _asIMorpho(morpho).extSloads(slots)[0];

        // BorrowerPremium struct layout:
        // - lastAccrualTime: uint128 (lower 128 bits)
        // - rate: uint128 (upper 128 bits)
        // - borrowAssetsAtLastAccrual: uint256 (next slot)
        premium.lastAccrualTime = uint128(uint256(data));
        premium.rate = uint128(uint256(data) >> 128);

        // Get borrowAssetsAtLastAccrual from next slot
        slots[0] = bytes32(uint256(MorphoCreditStorageLib.borrowerPremiumSlot(id, borrower)) + 1);
        premium.borrowAssetsAtLastAccrual = uint256(_asIMorpho(morpho).extSloads(slots)[0]);
    }

    /// @notice Get repayment obligation for a borrower
    /// @param morpho The MorphoCredit instance
    /// @param id Market ID
    /// @param borrower Borrower address
    /// @return obligation The repayment obligation details
    function getRepaymentObligation(IMorphoCredit morpho, Id id, address borrower)
        internal
        view
        returns (RepaymentObligation memory obligation)
    {
        bytes32[] memory slots = new bytes32[](1);
        slots[0] = MorphoCreditStorageLib.repaymentObligationSlot(id, borrower);
        bytes32 data = _asIMorpho(morpho).extSloads(slots)[0];

        // RepaymentObligation struct layout (packed in one slot):
        // - paymentCycleId: uint128 (lower 128 bits)
        // - amountDue: uint128 (upper 128 bits)
        obligation.paymentCycleId = uint128(uint256(data));
        obligation.amountDue = uint128(uint256(data) >> 128);
    }

    /// @notice Get markdown state for a borrower
    /// @param morpho The MorphoCredit instance
    /// @param id Market ID
    /// @param borrower Borrower address
    /// @return lastCalculatedMarkdown The last calculated markdown amount
    function getMarkdownState(IMorphoCredit morpho, Id id, address borrower)
        internal
        view
        returns (uint128 lastCalculatedMarkdown)
    {
        bytes32[] memory slots = new bytes32[](1);
        slots[0] = MorphoCreditStorageLib.markdownStateSlot(id, borrower);
        lastCalculatedMarkdown = uint128(uint256(_asIMorpho(morpho).extSloads(slots)[0]));
    }

    /// @notice Get helper address
    /// @param morpho The MorphoCredit instance
    /// @return helper The helper contract address
    function getHelper(IMorphoCredit morpho) internal view returns (address helper) {
        bytes32[] memory slots = new bytes32[](1);
        slots[0] = MorphoCreditStorageLib.helperSlot();
        helper = address(uint160(uint256(_asIMorpho(morpho).extSloads(slots)[0])));
    }
}
