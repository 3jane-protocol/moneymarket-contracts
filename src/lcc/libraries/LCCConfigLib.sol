// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

import {IERC4626} from "../../../lib/openzeppelin/contracts/interfaces/IERC4626.sol";

import {BPS} from "../../libraries/ConstantsLib.sol";
import {ILCCVault} from "../interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "./LCCErrorsLib.sol";

/// @title LCCConfigLib
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Constructor configuration validation for LCC vaults.
library LCCConfigLib {
    function validate(ILCCVault.VaultParams memory params) internal view {
        if (
            params.owner == address(0) || params.marginAsset == address(0) || params.fundingAsset == address(0)
                || params.notificationVault == address(0) || params.marginOracle == address(0)
                || params.treasury == address(0)
        ) revert LCCErrorsLib.ZeroAddress();
        address usd3 = IERC4626(params.notificationVault).asset();
        if (params.fundingAsset != IERC4626(usd3).asset()) revert LCCErrorsLib.InvalidParams();
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
        if (params.exitCapBps == 0 || params.exitCapBps > BPS) revert LCCErrorsLib.InvalidParams();
        if (params.exitDelayEpochs == 0) revert LCCErrorsLib.InvalidParams();
        if (params.slashFeeBps > BPS) revert LCCErrorsLib.InvalidParams();

        if (params.auctionStepCount == 0) {
            if (params.auctionStepDecayRateBps != 0 || params.maxAuctionAwardBps != 0) {
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
