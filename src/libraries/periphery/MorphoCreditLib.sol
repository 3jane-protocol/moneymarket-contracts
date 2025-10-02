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
import {IProtocolConfig, MarketConfig} from "../../interfaces/IProtocolConfig.sol";
import {ErrorsLib} from "../ErrorsLib.sol";
import {MorphoLib} from "./MorphoLib.sol";
import {MorphoCreditStorageLib} from "./MorphoCreditStorageLib.sol";
import {MorphoBalancesLib} from "./MorphoBalancesLib.sol";
import {SharesMathLib} from "../SharesMathLib.sol";
import {ICreditLine} from "../../interfaces/ICreditLine.sol";

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
        (RepaymentStatus status, uint256 statusStartTime) = getRepaymentStatus(morpho, id, borrower);

        // Only set defaultStartTime if actually in default status
        if (status == RepaymentStatus.Default) {
            defaultStartTime = statusStartTime;

            // Get markdown manager and calculate markdown if set
            address manager = getMarkdownManager(morpho, id);
            if (manager != address(0) && defaultStartTime > 0 && borrowAssets > 0) {
                uint256 timeInDefault = block.timestamp > defaultStartTime ? block.timestamp - defaultStartTime : 0;
                currentMarkdown = IMarkdownController(manager).calculateMarkdown(borrower, borrowAssets, timeInDefault);
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
        IMorpho morphoBase = _asIMorpho(morpho);
        MarketParams memory marketParams = morphoBase.idToMarketParams(id);
        manager = ICreditLine(marketParams.creditLine).mm();
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
        // - borrowAssetsAtLastAccrual: uint128 (next slot, lower 128 bits)
        premium.lastAccrualTime = uint128(uint256(data));
        premium.rate = uint128(uint256(data) >> 128);

        // Get borrowAssetsAtLastAccrual from next slot
        slots[0] = bytes32(uint256(MorphoCreditStorageLib.borrowerPremiumSlot(id, borrower)) + 1);
        premium.borrowAssetsAtLastAccrual = uint128(uint256(_asIMorpho(morpho).extSloads(slots)[0]));
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

        // RepaymentObligation struct layout:
        // - paymentCycleId: uint128 (lower 128 bits)
        // - amountDue: uint128 (upper 128 bits)
        // - endingBalance: uint128 (next slot, lower 128 bits)
        obligation.paymentCycleId = uint128(uint256(data));
        obligation.amountDue = uint128(uint256(data) >> 128);

        // Get endingBalance from next slot
        slots[0] = bytes32(uint256(MorphoCreditStorageLib.repaymentObligationSlot(id, borrower)) + 1);
        obligation.endingBalance = uint128(uint256(_asIMorpho(morpho).extSloads(slots)[0]));
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

    /// @notice Get repayment status for a borrower
    /// @param morpho The MorphoCredit instance
    /// @param id Market ID
    /// @param borrower Borrower address
    /// @return status The borrower's current repayment status
    /// @return statusStartTime The timestamp when the current status began
    function getRepaymentStatus(IMorphoCredit morpho, Id id, address borrower)
        internal
        view
        returns (RepaymentStatus status, uint256 statusStartTime)
    {
        // Get repayment obligation
        RepaymentObligation memory obligation = getRepaymentObligation(morpho, id, borrower);

        if (obligation.amountDue == 0) return (RepaymentStatus.Current, 0);

        // Get payment cycle length to validate cycleId
        uint256 cycleLength = getPaymentCycleLength(morpho, id);
        if (obligation.paymentCycleId >= cycleLength) return (RepaymentStatus.Current, 0); // Invalid cycle

        // Get cycle end date
        bytes32[] memory slots = new bytes32[](1);
        slots[0] = MorphoCreditStorageLib.paymentCycleElementSlot(id, obligation.paymentCycleId);
        uint256 cycleEndDate = uint256(_asIMorpho(morpho).extSloads(slots)[0]);
        statusStartTime = cycleEndDate;

        // Get market config for grace and delinquency periods
        IProtocolConfig protocolConfig = IProtocolConfig(morpho.protocolConfig());
        MarketConfig memory terms = protocolConfig.getMarketConfig();

        if (block.timestamp <= statusStartTime + terms.gracePeriod) {
            return (RepaymentStatus.GracePeriod, statusStartTime);
        }
        statusStartTime += terms.gracePeriod;
        if (block.timestamp < statusStartTime + terms.delinquencyPeriod) {
            return (RepaymentStatus.Delinquent, statusStartTime);
        }

        return (RepaymentStatus.Default, statusStartTime + terms.delinquencyPeriod);
    }

    /// @notice Get the total number of payment cycles for a market
    /// @param morpho The MorphoCredit instance
    /// @param id Market ID
    /// @return length The number of payment cycles
    function getPaymentCycleLength(IMorphoCredit morpho, Id id) internal view returns (uint256 length) {
        bytes32[] memory slots = new bytes32[](1);
        slots[0] = MorphoCreditStorageLib.paymentCycleLengthSlot(id);
        length = uint256(_asIMorpho(morpho).extSloads(slots)[0]);
    }

    /// @notice Get both start and end dates for a given cycle
    /// @param morpho The MorphoCredit instance
    /// @param id Market ID
    /// @param cycleId Cycle ID
    /// @return startDate The cycle start date
    /// @return endDate The cycle end date
    function getCycleDates(IMorphoCredit morpho, Id id, uint256 cycleId)
        internal
        view
        returns (uint256 startDate, uint256 endDate)
    {
        // Check bounds
        uint256 cycleLength = getPaymentCycleLength(morpho, id);
        if (cycleId >= cycleLength) revert ErrorsLib.InvalidCycleId();

        // Get end date for the requested cycle
        bytes32[] memory slots = new bytes32[](1);
        slots[0] = MorphoCreditStorageLib.paymentCycleElementSlot(id, cycleId);
        endDate = uint256(_asIMorpho(morpho).extSloads(slots)[0]);

        // Get start date (previous cycle's end date + 1 day, or 0 for first cycle)
        if (cycleId != 0) {
            slots[0] = MorphoCreditStorageLib.paymentCycleElementSlot(id, cycleId - 1);
            startDate = uint256(_asIMorpho(morpho).extSloads(slots)[0]) + 1 days;
        }
    }
}
