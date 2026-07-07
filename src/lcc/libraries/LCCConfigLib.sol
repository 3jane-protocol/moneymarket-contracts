// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

import {BPS} from "../../libraries/ConstantsLib.sol";
import {ILCCVault} from "../interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "./LCCErrorsLib.sol";

/// @title LCCConfigLib
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Initializer configuration validation for LCC vaults.
library LCCConfigLib {
    uint256 internal constant MAX_EXIT_DELAY_EPOCHS = 64;
    uint256 internal constant MIN_EXIT_CAP_BPS = (2 * BPS + MAX_EXIT_DELAY_EPOCHS - 1) / MAX_EXIT_DELAY_EPOCHS;

    /// @dev Seconds per auction price step: the Closed window divided by the step count (0 when auctions are
    /// disabled). Kept next to `validate`'s window/step-count constraints so the formula and its bounds move
    /// together.
    function auctionStepDuration(ILCCVault.VaultParams memory params) internal pure returns (uint256) {
        if (params.auctionStepCount == 0) return 0;
        uint256 phaseDurations = params.normalDuration + params.preCallDuration + params.fundingDuration;
        return (params.epochLength - phaseDurations) / params.auctionStepCount;
    }

    function validate(ILCCVault.VaultParams memory params) internal pure {
        if (params.owner == address(0) || params.marginAsset == address(0) || params.marginOracle == address(0)) {
            revert LCCErrorsLib.ZeroAddress();
        }
        // Width bounds for the packed per-vault config. auctionStepCount and the derived auctionStepDuration are
        // transitively bounded below uint32 by `epochLength <= type(uint32).max` plus the step-count-vs-window
        // checks below.
        if (
            params.startTimestamp > type(uint64).max || params.maxEpochs > type(uint64).max
                || params.epochLength > type(uint32).max || params.normalDuration > type(uint32).max
                || params.preCallDuration > type(uint32).max || params.fundingDuration > type(uint32).max
        ) revert LCCErrorsLib.InvalidParams();
        if (params.marginRatioBps == 0 || params.marginRatioBps > BPS) revert LCCErrorsLib.InvalidParams();
        if (params.epochLength == 0 || params.normalDuration == 0 || params.preCallDuration == 0) {
            revert LCCErrorsLib.InvalidParams();
        }
        if (
            params.fundingDuration == 0
                || params.normalDuration + params.preCallDuration + params.fundingDuration > params.epochLength
        ) {
            revert LCCErrorsLib.InvalidParams();
        }
        if (params.protocolCommitmentCap == 0 || params.userCommitmentCap == 0) revert LCCErrorsLib.InvalidParams();
        // Commitment totals are bounded by the (historical) protocol cap; capping it at uint128 keeps the auction
        // kick's casts from ever reverting inside sync.
        if (params.protocolCommitmentCap > type(uint128).max) revert LCCErrorsLib.InvalidParams();
        // Floor exitCapBps so full-cap exit demand plus the max temporal spread fits within the maturity-bucket cap.
        if (params.exitCapBps < MIN_EXIT_CAP_BPS || params.exitCapBps > BPS) {
            revert LCCErrorsLib.InvalidParams();
        }
        if (params.exitDelayEpochs == 0 || params.exitDelayEpochs > MAX_EXIT_DELAY_EPOCHS) {
            revert LCCErrorsLib.InvalidParams();
        }
        if (params.slashFeeBps > BPS) revert LCCErrorsLib.InvalidParams();
        // maxEpochs has no lower bound; zero means perpetual.

        if (params.auctionStepCount == 0) {
            // With auctions disabled nothing is ever awarded, so a nonzero decay, award cap, or slash fee is dead
            // configuration; reject it like the other auction-only parameters.
            if (params.auctionStepDecayRateBps != 0 || params.maxAuctionAwardBps != 0 || params.slashFeeBps != 0) {
                revert LCCErrorsLib.InvalidParams();
            }
        } else {
            // Takes are only live strictly before the epoch end, so the step-N boundary is never reachable and a
            // one-step auction would offer zero collateral for its entire window; at least two steps are required.
            if (params.auctionStepCount == 1) revert LCCErrorsLib.InvalidParams();
            if (params.auctionStepDecayRateBps == 0 || params.auctionStepDecayRateBps > BPS) {
                revert LCCErrorsLib.InvalidParams();
            }
            if (params.maxAuctionAwardBps > BPS) revert LCCErrorsLib.InvalidParams();
            // The auction needs a nonzero Closed window, and at least one second per step so the full curve fits
            // inside every auction window.
            uint256 phaseDurations = params.normalDuration + params.preCallDuration + params.fundingDuration;
            if (phaseDurations >= params.epochLength) revert LCCErrorsLib.InvalidParams();
            if (params.auctionStepCount > params.epochLength - phaseDurations) revert LCCErrorsLib.InvalidParams();
        }
    }
}
