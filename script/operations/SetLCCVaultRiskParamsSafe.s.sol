// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";

import {LCCVaultFactory} from "../../src/lcc/LCCVaultFactory.sol";
import {ILCCVault} from "../../src/lcc/interfaces/ILCCVault.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";

interface ILCCMarginOraclePrice {
    function price() external view returns (uint256);
}

/// @title SetLCCVaultRiskParamsSafe
/// @notice Proposes one Safe batch that updates an LCC vault's mutable risk parameters. Every parameter is an optional
///         environment variable; any parameter left unset is read from the vault's live configuration and passed
///         through unchanged, and setters whose values do not change are omitted from the batch.
/// @dev All three setters are owner-gated through the factory and `synced`, so the batch must come from the
///      factory-owning Safe and cannot run while the vault is paused. Changing `protocolCommitmentCap`,
///      `maxAuctionAwardBps`, or `slashFeeBps` is rejected by the vault while an auction slot is pending, and any
///      use of these setters is an M-02 loss-budget revalidation trigger; record the review before sending.
///
///      Usage:
///      FOUNDRY_PROFILE=script LCC_FACTORY=<address> LCC_VAULT=<address> \
///        [LCC_PROTOCOL_COMMITMENT_CAP=<funding units>] [LCC_USER_COMMITMENT_CAP=<funding units>] \
///        [LCC_EXIT_CAP_BPS=<bps>] [LCC_MIN_DEPOSIT_ASSETS=<margin units>] \
///        [LCC_MAX_AUCTION_AWARD_BPS=<bps>] [LCC_SLASH_FEE_BPS=<bps>] \
///        WALLET_TYPE=local SAFE_PROPOSER_PRIVATE_KEY=<private-key> forge script \
///        script/operations/SetLCCVaultRiskParamsSafe.s.sol --sig "run(bool)" false --rpc-url mainnet
contract SetLCCVaultRiskParamsSafe is Script, SafeHelper {
    address internal constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

    function run(bool send) external isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE)) {
        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        (LCCVaultFactory factory, ILCCVault vault) = _context();
        require(factory.owner() == safe, "Safe is not factory owner");
        require(factory.isOwner(safe), "Safe lacks factory owner role");
        (bool paused,,) = vault.pauseState();
        require(!paused, "vault is paused");
        require(!vault.shutdownState().active, "vault is shut down");

        ILCCVault.RiskConfig memory live = vault.riskConfig();
        ILCCVault.RiskConfig memory target = ILCCVault.RiskConfig({
            protocolCommitmentCap: vm.envOr("LCC_PROTOCOL_COMMITMENT_CAP", live.protocolCommitmentCap),
            userCommitmentCap: vm.envOr("LCC_USER_COMMITMENT_CAP", live.userCommitmentCap),
            exitCapBps: vm.envOr("LCC_EXIT_CAP_BPS", live.exitCapBps),
            minDepositAssets: vm.envOr("LCC_MIN_DEPOSIT_ASSETS", live.minDepositAssets),
            maxAuctionAwardBps: vm.envOr("LCC_MAX_AUCTION_AWARD_BPS", live.maxAuctionAwardBps),
            slashFeeBps: vm.envOr("LCC_SLASH_FEE_BPS", live.slashFeeBps)
        });

        console2.log("=== Set LCC Vault Risk Parameters via Safe ===");
        console2.log("Factory:", address(factory));
        console2.log("Vault:", address(vault));
        console2.log("Send to Safe:", send);
        _logConfig(vault, "Live", live);
        _logConfig(vault, "Target", target);

        uint256 calls;
        bool riskCapsChanged = target.protocolCommitmentCap != live.protocolCommitmentCap
            || target.userCommitmentCap != live.userCommitmentCap || target.exitCapBps != live.exitCapBps
            || target.minDepositAssets != live.minDepositAssets;
        if (riskCapsChanged) {
            console2.log("Batch: setRiskCaps");
            addToBatch(
                address(vault),
                abi.encodeCall(
                    ILCCVault.setRiskCaps,
                    (target.protocolCommitmentCap, target.userCommitmentCap, target.exitCapBps, target.minDepositAssets)
                )
            );
            ++calls;
        }
        if (target.maxAuctionAwardBps != live.maxAuctionAwardBps) {
            console2.log("Batch: setMaxAuctionAwardBps");
            addToBatch(address(vault), abi.encodeCall(ILCCVault.setMaxAuctionAwardBps, (target.maxAuctionAwardBps)));
            ++calls;
        }
        if (target.slashFeeBps != live.slashFeeBps) {
            console2.log("Batch: setSlashFeeBps");
            addToBatch(address(vault), abi.encodeCall(ILCCVault.setSlashFeeBps, (target.slashFeeBps)));
            ++calls;
        }

        if (calls == 0) {
            console2.log("Every parameter already matches; nothing to propose");
            return;
        }
        _requireConfig(vault, target);
        require(getTotalBatches() == 1, "SafeHelper split the batch");
        (uint256 txCount,) = getBatchInfo(0);
        require(txCount == calls, "batch call count mismatch");

        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    function run() external {
        this.run(false);
    }

    /// @notice Print the vault's live risk parameters and require any configured overrides to be live.
    function verify() external view {
        (, ILCCVault vault) = _context();
        ILCCVault.RiskConfig memory live = vault.riskConfig();
        _logConfig(vault, "Live", live);
        ILCCVault.RiskConfig memory expected = ILCCVault.RiskConfig({
            protocolCommitmentCap: vm.envOr("LCC_PROTOCOL_COMMITMENT_CAP", live.protocolCommitmentCap),
            userCommitmentCap: vm.envOr("LCC_USER_COMMITMENT_CAP", live.userCommitmentCap),
            exitCapBps: vm.envOr("LCC_EXIT_CAP_BPS", live.exitCapBps),
            minDepositAssets: vm.envOr("LCC_MIN_DEPOSIT_ASSETS", live.minDepositAssets),
            maxAuctionAwardBps: vm.envOr("LCC_MAX_AUCTION_AWARD_BPS", live.maxAuctionAwardBps),
            slashFeeBps: vm.envOr("LCC_SLASH_FEE_BPS", live.slashFeeBps)
        });
        _requireConfig(vault, expected);
        console2.log("PASS: live risk parameters match the configured values");
    }

    function _context() internal view returns (LCCVaultFactory factory, ILCCVault vault) {
        factory = LCCVaultFactory(vm.envAddress("LCC_FACTORY"));
        require(address(factory).code.length > 0, "factory has no code");
        vault = ILCCVault(vm.envAddress("LCC_VAULT"));
        require(factory.isVault(address(vault)), "vault is not factory registered");
    }

    function _requireConfig(ILCCVault vault, ILCCVault.RiskConfig memory expected) internal view {
        ILCCVault.RiskConfig memory live = vault.riskConfig();
        require(live.protocolCommitmentCap == expected.protocolCommitmentCap, "protocol commitment cap mismatch");
        require(live.userCommitmentCap == expected.userCommitmentCap, "user commitment cap mismatch");
        require(live.exitCapBps == expected.exitCapBps, "exit cap mismatch");
        require(live.minDepositAssets == expected.minDepositAssets, "minimum deposit mismatch");
        require(live.maxAuctionAwardBps == expected.maxAuctionAwardBps, "max auction award mismatch");
        require(live.slashFeeBps == expected.slashFeeBps, "slash fee mismatch");
    }

    /// @dev Values the deposit floor at the live oracle price so reviewers see its USDC margin value and the implied
    ///      minimum commitment alongside the raw units.
    function _logConfig(ILCCVault vault, string memory label, ILCCVault.RiskConfig memory config) internal view {
        console2.log(string.concat("--- ", label, " risk parameters ---"));
        console2.log("Protocol commitment cap (funding units):", config.protocolCommitmentCap);
        console2.log("User commitment cap (funding units):", config.userCommitmentCap);
        console2.log("Exit cap (bps):", config.exitCapBps);
        console2.log("Min deposit (margin units):", config.minDepositAssets);
        uint256 price = ILCCMarginOraclePrice(vault.assetConfig().marginOracle).price();
        uint256 marginValue = config.minDepositAssets * price / ORACLE_PRICE_SCALE;
        console2.log("  = margin value (funding units):", marginValue);
        console2.log(
            "  = implied min commitment (funding units):", marginValue * BPS / vault.epochConfig().marginRatioBps
        );
        console2.log("Max auction award (bps):", config.maxAuctionAwardBps);
        console2.log("Slash fee (bps):", config.slashFeeBps);
    }
}
