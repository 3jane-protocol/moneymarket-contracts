// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2, VmSafe} from "forge-std/Script.sol";

import {ITimelockController} from "../../src/interfaces/ITimelockController.sol";
import {LCCVaultFactory} from "../../src/lcc/LCCVaultFactory.sol";
import {ILCCVault} from "../../src/lcc/interfaces/ILCCVault.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";

interface ILCCMarginOraclePrice {
    function price() external view returns (uint256);
}

/// @title SetLCCVaultRiskParamsSafe
/// @notice Routes LCC vault risk-parameter changes through the 24-hour parameters timelock.
/// @dev Schedule usage:
///      1. `--sig "schedule(uint256,bool)" <attempt> <send>` with `LCC_FACTORY`, `LCC_VAULT`, optional
///         `LCC_PROTOCOL_COMMITMENT_CAP`, `LCC_USER_COMMITMENT_CAP`, `LCC_EXIT_CAP_BPS`,
///         `LCC_MIN_DEPOSIT_ASSETS`, `LCC_MAX_AUCTION_AWARD_BPS`, `LCC_SLASH_FEE_BPS`, optional `SAFE_ADDRESS`,
///         `WALLET_TYPE`, the matching Safe proposer credential, and optional `SAFE_NONCE`.
///      2. Record the six fully explicit `LCC_*` assignments and `LCC_FIELDS_MASK` logged by `schedule`. Bits 0-5
///         select `protocolCommitmentCap`, `userCommitmentCap`, `exitCapBps`, `minDepositAssets`,
///         `maxAuctionAwardBps`, and `slashFeeBps`, respectively.
///      3. After 24 hours, `--sig "execute(uint256)" <attempt>` with `LCC_FACTORY`, `LCC_VAULT`, all six logged
///         risk-parameter assignments, `LCC_FIELDS_MASK`, and an executor selected by Forge's `--account`,
///         `--ledger`, or `--sender` broadcast options.
///      4. `--sig "verify()"` with `LCC_FACTORY`, `LCC_VAULT`, and any risk-parameter values to verify.
///
///      Unset schedule parameters resolve to live values. A field is selected only when its environment variable is
///      supplied and differs from live configuration. The explicit target and field mask are committed into the salt
///      so execute reconstructs the scheduled operation without consulting live configuration. Any pending auction
///      slot at execution reverts `setMaxAuctionAwardBps` and `setSlashFeeBps` regardless of the other selected fields,
///      and reverts `setRiskCaps` only when `protocolCommitmentCap` changes. The batch is atomic, so a slot opened
/// during the delay reverts the whole operation. `setMaxAuctionAwardBps` must land while the epoch is in Funding or
///      earlier (round-3 A/L-05), so schedule it accordingly. `setRiskCaps` rewrites all four cap fields; execute
///      refuses to restore a non-selected field that changed during the delay, so serialize overlapping risk-parameter
///      operations on the same vault. Any use of these setters is an M-02 loss-budget revalidation trigger; record the
///      review before sending.
contract SetLCCVaultRiskParamsSafe is Script, SafeHelper, TimelockHelper {
    address internal constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address internal constant PARAMS_TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    uint256 internal constant PARAMS_TIMELOCK_DELAY = 1 days;
    bytes32 internal constant SALT_DOMAIN = bytes32("3JANE_LCC_RISK_PARAMS_V1");
    uint256 internal constant FIELD_PROTOCOL_COMMITMENT_CAP = 1 << 0;
    uint256 internal constant FIELD_USER_COMMITMENT_CAP = 1 << 1;
    uint256 internal constant FIELD_EXIT_CAP_BPS = 1 << 2;
    uint256 internal constant FIELD_MIN_DEPOSIT_ASSETS = 1 << 3;
    uint256 internal constant FIELD_MAX_AUCTION_AWARD_BPS = 1 << 4;
    uint256 internal constant FIELD_SLASH_FEE_BPS = 1 << 5;
    uint256 internal constant RISK_CAP_FIELDS =
        FIELD_PROTOCOL_COMMITMENT_CAP | FIELD_USER_COMMITMENT_CAP | FIELD_EXIT_CAP_BPS | FIELD_MIN_DEPOSIT_ASSETS;
    uint256 internal constant ALL_FIELDS = RISK_CAP_FIELDS | FIELD_MAX_AUCTION_AWARD_BPS | FIELD_SLASH_FEE_BPS;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

    function schedule(uint256 attempt, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(PARAMS_TIMELOCK)
    {
        (LCCVaultFactory factory, ILCCVault vault) = _context();
        _requireScheduleTopology(factory, vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE));
        (ILCCVault.RiskConfig memory target, uint256 fieldsMask) = _prepareSchedule(factory, vault, attempt, send);
        if (fieldsMask == 0) return;
        _scheduleOperation(factory, vault, target, fieldsMask, attempt, send);
    }

    function _prepareSchedule(LCCVaultFactory factory, ILCCVault vault, uint256 attempt, bool send)
        private
        view
        returns (ILCCVault.RiskConfig memory target, uint256 fieldsMask)
    {
        (bool paused,,) = vault.pauseState();
        require(!paused, "vault is paused");
        require(!vault.shutdownState().active, "vault is shut down");

        ILCCVault.RiskConfig memory live = vault.riskConfig();
        target = _optionalTarget(live);
        fieldsMask = _fieldMask(live, target);

        console2.log("=== Schedule LCC Vault Risk Parameters ===");
        _logHeader(factory, vault, attempt);
        console2.log("Send to Safe:", send);
        _logConfig(vault, "Live", live);
        _logConfig(vault, "Target", target);
        _logRequiredExecutionEnv(target, fieldsMask);

        if (fieldsMask == 0) {
            console2.log("Every parameter already matches; nothing to propose");
            return (target, fieldsMask);
        }
    }

    function _scheduleOperation(
        LCCVaultFactory factory,
        ILCCVault vault,
        ILCCVault.RiskConfig memory target,
        uint256 fieldsMask,
        uint256 attempt,
        bool send
    ) private {
        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) =
            _operation(factory, vault, target, fieldsMask, attempt);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, bytes32(0), salt);
        _logOperation(attempt, operationId, salt);

        ITimelockController.OperationState state = getOperationState(PARAMS_TIMELOCK, operationId);
        if (state == ITimelockController.OperationState.Waiting || state == ITimelockController.OperationState.Ready) {
            logOperationState(PARAMS_TIMELOCK, operationId);
            console2.log("Operation is already pending");
            return;
        }
        require(state != ITimelockController.OperationState.Done, "operation already executed; use a fresh attempt");

        _requireNoPendingAuctionForChange(vault, fieldsMask);
        console2.log("M-02: record the loss-budget revalidation before sending this operation");

        uint256 snapshot = vm.snapshotState();
        simulateExecution(PARAMS_TIMELOCK, targets, values, datas);
        _requireConfig(vault, target);
        vm.revertToState(snapshot);

        addToBatch(
            PARAMS_TIMELOCK, encodeScheduleBatch(targets, values, datas, bytes32(0), salt, PARAMS_TIMELOCK_DELAY)
        );
        _requireSingleCall();
        _send(send);
        console2.log("Next: after 24 hours, run --sig \"execute(uint256)\" with attempt", attempt);
    }

    function execute(uint256 attempt) external isTimelock(PARAMS_TIMELOCK) {
        (LCCVaultFactory factory, ILCCVault vault) = _context();
        _requireExecutionTopology(factory);
        ILCCVault.RiskConfig memory target = _requiredTarget();
        uint256 fieldsMask = vm.envUint("LCC_FIELDS_MASK");
        _requireValidFieldsMask(fieldsMask);
        ILCCVault.RiskConfig memory live = vault.riskConfig();

        console2.log("=== Execute LCC Vault Risk Parameters ===");
        _logHeader(factory, vault, attempt);
        _logRawConfig("Live", live);
        _logRawConfig("Target", target);
        _logRequiredExecutionEnv(target, fieldsMask);

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) =
            _operation(factory, vault, target, fieldsMask, attempt);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, bytes32(0), salt);
        _logOperation(attempt, operationId, salt);
        logOperationState(PARAMS_TIMELOCK, operationId);
        require(!isOperationDone(PARAMS_TIMELOCK, operationId), "operation already executed");
        requireOperationReady(PARAMS_TIMELOCK, operationId);
        _requireUnselectedFieldsUnchanged(live, target, fieldsMask);
        _logIntendedChanges(live, target, fieldsMask);

        address broadcaster = _startExecutorBroadcast();
        console2.log("Timelock executor broadcaster:", broadcaster);
        ITimelockController(PARAMS_TIMELOCK).executeBatch(targets, values, datas, bytes32(0), salt);
        vm.stopBroadcast();
        _requireIncludedSetterConfig(vault, target, fieldsMask);
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

    function _optionalTarget(ILCCVault.RiskConfig memory live)
        private
        view
        returns (ILCCVault.RiskConfig memory target)
    {
        target = ILCCVault.RiskConfig({
            protocolCommitmentCap: vm.envOr("LCC_PROTOCOL_COMMITMENT_CAP", live.protocolCommitmentCap),
            userCommitmentCap: vm.envOr("LCC_USER_COMMITMENT_CAP", live.userCommitmentCap),
            exitCapBps: vm.envOr("LCC_EXIT_CAP_BPS", live.exitCapBps),
            minDepositAssets: vm.envOr("LCC_MIN_DEPOSIT_ASSETS", live.minDepositAssets),
            maxAuctionAwardBps: vm.envOr("LCC_MAX_AUCTION_AWARD_BPS", live.maxAuctionAwardBps),
            slashFeeBps: vm.envOr("LCC_SLASH_FEE_BPS", live.slashFeeBps)
        });
    }

    function _requiredTarget() private view returns (ILCCVault.RiskConfig memory target) {
        target = ILCCVault.RiskConfig({
            protocolCommitmentCap: vm.envUint("LCC_PROTOCOL_COMMITMENT_CAP"),
            userCommitmentCap: vm.envUint("LCC_USER_COMMITMENT_CAP"),
            exitCapBps: vm.envUint("LCC_EXIT_CAP_BPS"),
            minDepositAssets: vm.envUint("LCC_MIN_DEPOSIT_ASSETS"),
            maxAuctionAwardBps: vm.envUint("LCC_MAX_AUCTION_AWARD_BPS"),
            slashFeeBps: vm.envUint("LCC_SLASH_FEE_BPS")
        });
    }

    function _fieldMask(ILCCVault.RiskConfig memory live, ILCCVault.RiskConfig memory target)
        private
        view
        returns (uint256 fieldsMask)
    {
        if (vm.envExists("LCC_PROTOCOL_COMMITMENT_CAP") && target.protocolCommitmentCap != live.protocolCommitmentCap) fieldsMask |= FIELD_PROTOCOL_COMMITMENT_CAP;
        if (vm.envExists("LCC_USER_COMMITMENT_CAP") && target.userCommitmentCap != live.userCommitmentCap) {
            fieldsMask |= FIELD_USER_COMMITMENT_CAP;
        }
        if (vm.envExists("LCC_EXIT_CAP_BPS") && target.exitCapBps != live.exitCapBps) {
            fieldsMask |= FIELD_EXIT_CAP_BPS;
        }
        if (vm.envExists("LCC_MIN_DEPOSIT_ASSETS") && target.minDepositAssets != live.minDepositAssets) {
            fieldsMask |= FIELD_MIN_DEPOSIT_ASSETS;
        }
        if (vm.envExists("LCC_MAX_AUCTION_AWARD_BPS") && target.maxAuctionAwardBps != live.maxAuctionAwardBps) {
            fieldsMask |= FIELD_MAX_AUCTION_AWARD_BPS;
        }
        if (vm.envExists("LCC_SLASH_FEE_BPS") && target.slashFeeBps != live.slashFeeBps) {
            fieldsMask |= FIELD_SLASH_FEE_BPS;
        }
    }

    function _operation(
        LCCVaultFactory factory,
        ILCCVault vault,
        ILCCVault.RiskConfig memory target,
        uint256 fieldsMask,
        uint256 attempt
    ) private pure returns (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) {
        _requireValidFieldsMask(fieldsMask);
        uint256 callCount = (fieldsMask & RISK_CAP_FIELDS == 0 ? 0 : 1)
            + (fieldsMask & FIELD_MAX_AUCTION_AWARD_BPS == 0 ? 0 : 1) + (fieldsMask & FIELD_SLASH_FEE_BPS == 0 ? 0 : 1);
        targets = new address[](callCount);
        values = new uint256[](callCount);
        datas = new bytes[](callCount);

        uint256 index;
        if (fieldsMask & RISK_CAP_FIELDS != 0) {
            targets[index] = address(vault);
            datas[index] = abi.encodeCall(
                ILCCVault.setRiskCaps,
                (target.protocolCommitmentCap, target.userCommitmentCap, target.exitCapBps, target.minDepositAssets)
            );
            ++index;
        }
        if (fieldsMask & FIELD_MAX_AUCTION_AWARD_BPS != 0) {
            targets[index] = address(vault);
            datas[index] = abi.encodeCall(ILCCVault.setMaxAuctionAwardBps, (target.maxAuctionAwardBps));
            ++index;
        }
        if (fieldsMask & FIELD_SLASH_FEE_BPS != 0) {
            targets[index] = address(vault);
            datas[index] = abi.encodeCall(ILCCVault.setSlashFeeBps, (target.slashFeeBps));
        }

        salt = keccak256(abi.encode(SALT_DOMAIN, address(factory), address(vault), target, fieldsMask, attempt));
    }

    function _requireValidFieldsMask(uint256 fieldsMask) private pure {
        require(fieldsMask != 0 && fieldsMask & ~ALL_FIELDS == 0, "invalid LCC_FIELDS_MASK");
    }

    function _requireNoPendingAuctionForChange(ILCCVault vault, uint256 fieldsMask) private view {
        bool slotSensitiveChange =
            fieldsMask & (FIELD_PROTOCOL_COMMITMENT_CAP | FIELD_MAX_AUCTION_AWARD_BPS | FIELD_SLASH_FEE_BPS) != 0;
        if (!slotSensitiveChange) return;

        require(vault.syncState().pendingAuctionEpochPlusOne == 0, "vault has a pending auction slot");
        console2.log("WARNING: a default that opens an auction slot during the 24-hour delay will make any included");
        console2.log("protocol-cap, max-auction-award, or slash-fee change revert when the operation is executed");
    }

    function _requireScheduleTopology(LCCVaultFactory factory, address safe) private view {
        _requireExecutionTopology(factory);
        require(getMinDelay(PARAMS_TIMELOCK) == PARAMS_TIMELOCK_DELAY, "parameters timelock delay is not 24 hours");

        ITimelockController controller = ITimelockController(PARAMS_TIMELOCK);
        require(controller.hasRole(controller.PROPOSER_ROLE(), safe), "Safe is not a parameters timelock proposer");
    }

    function _requireExecutionTopology(LCCVaultFactory factory) private view {
        require(PARAMS_TIMELOCK.code.length > 0, "parameters timelock has no code");
        require(factory.owner() == PARAMS_TIMELOCK, "parameters timelock is not factory owner");
        require(factory.getRoleMemberCount(factory.OWNER_ROLE()) == 1, "factory owner count mismatch");
    }

    function _startExecutorBroadcast() private returns (address broadcaster) {
        vm.startBroadcast();
        (VmSafe.CallerMode mode, address sender,) = vm.readCallers();
        require(mode == VmSafe.CallerMode.RecurrentBroadcast, "Broadcast mode not active");
        broadcaster = sender;

        ITimelockController controller = ITimelockController(PARAMS_TIMELOCK);
        bytes32 executorRole = controller.EXECUTOR_ROLE();
        require(
            controller.hasRole(executorRole, address(0)) || controller.hasRole(executorRole, broadcaster),
            "broadcaster is not a parameters timelock executor"
        );
    }

    function _requireUnselectedFieldsUnchanged(
        ILCCVault.RiskConfig memory live,
        ILCCVault.RiskConfig memory target,
        uint256 fieldsMask
    ) private pure {
        if (fieldsMask & RISK_CAP_FIELDS == 0) return;

        if (fieldsMask & FIELD_PROTOCOL_COMMITMENT_CAP == 0) {
            require(
                live.protocolCommitmentCap == target.protocolCommitmentCap,
                "protocolCommitmentCap changed since scheduling; reschedule with a fresh attempt"
            );
        }
        if (fieldsMask & FIELD_USER_COMMITMENT_CAP == 0) {
            require(
                live.userCommitmentCap == target.userCommitmentCap,
                "userCommitmentCap changed since scheduling; reschedule with a fresh attempt"
            );
        }
        if (fieldsMask & FIELD_EXIT_CAP_BPS == 0) {
            require(
                live.exitCapBps == target.exitCapBps,
                "exitCapBps changed since scheduling; reschedule with a fresh attempt"
            );
        }
        if (fieldsMask & FIELD_MIN_DEPOSIT_ASSETS == 0) {
            require(
                live.minDepositAssets == target.minDepositAssets,
                "minDepositAssets changed since scheduling; reschedule with a fresh attempt"
            );
        }
    }

    function _requireIncludedSetterConfig(ILCCVault vault, ILCCVault.RiskConfig memory expected, uint256 fieldsMask)
        private
        view
    {
        ILCCVault.RiskConfig memory live = vault.riskConfig();
        if (fieldsMask & RISK_CAP_FIELDS != 0) {
            require(live.protocolCommitmentCap == expected.protocolCommitmentCap, "protocol commitment cap mismatch");
            require(live.userCommitmentCap == expected.userCommitmentCap, "user commitment cap mismatch");
            require(live.exitCapBps == expected.exitCapBps, "exit cap mismatch");
            require(live.minDepositAssets == expected.minDepositAssets, "minimum deposit mismatch");
        }
        if (fieldsMask & FIELD_MAX_AUCTION_AWARD_BPS != 0) {
            require(live.maxAuctionAwardBps == expected.maxAuctionAwardBps, "max auction award mismatch");
        }
        if (fieldsMask & FIELD_SLASH_FEE_BPS != 0) {
            require(live.slashFeeBps == expected.slashFeeBps, "slash fee mismatch");
        }
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

    function _logHeader(LCCVaultFactory factory, ILCCVault vault, uint256 attempt) private view {
        console2.log("Factory:", address(factory));
        console2.log("Factory owner (timelock):", factory.owner());
        console2.log("Vault:", address(vault));
        console2.log("Attempt:", attempt);
    }

    function _logRequiredExecutionEnv(ILCCVault.RiskConfig memory target, uint256 fieldsMask) private view {
        console2.log("Required execute environment:");
        console2.log(string.concat("LCC_PROTOCOL_COMMITMENT_CAP=", vm.toString(target.protocolCommitmentCap)));
        console2.log(string.concat("LCC_USER_COMMITMENT_CAP=", vm.toString(target.userCommitmentCap)));
        console2.log(string.concat("LCC_EXIT_CAP_BPS=", vm.toString(target.exitCapBps)));
        console2.log(string.concat("LCC_MIN_DEPOSIT_ASSETS=", vm.toString(target.minDepositAssets)));
        console2.log(string.concat("LCC_MAX_AUCTION_AWARD_BPS=", vm.toString(target.maxAuctionAwardBps)));
        console2.log(string.concat("LCC_SLASH_FEE_BPS=", vm.toString(target.slashFeeBps)));
        console2.log(string.concat("LCC_FIELDS_MASK=", vm.toString(fieldsMask)));
    }

    function _logIntendedChanges(
        ILCCVault.RiskConfig memory live,
        ILCCVault.RiskConfig memory target,
        uint256 fieldsMask
    ) private pure {
        console2.log("--- Intended field changes ---");
        if (fieldsMask & FIELD_PROTOCOL_COMMITMENT_CAP != 0) {
            console2.log(
                "protocolCommitmentCap from live -> to target:",
                live.protocolCommitmentCap,
                target.protocolCommitmentCap
            );
        }
        if (fieldsMask & FIELD_USER_COMMITMENT_CAP != 0) {
            console2.log("userCommitmentCap from live -> to target:", live.userCommitmentCap, target.userCommitmentCap);
        }
        if (fieldsMask & FIELD_EXIT_CAP_BPS != 0) {
            console2.log("exitCapBps from live -> to target:", live.exitCapBps, target.exitCapBps);
        }
        if (fieldsMask & FIELD_MIN_DEPOSIT_ASSETS != 0) {
            console2.log("minDepositAssets from live -> to target:", live.minDepositAssets, target.minDepositAssets);
        }
        if (fieldsMask & FIELD_MAX_AUCTION_AWARD_BPS != 0) {
            console2.log(
                "maxAuctionAwardBps from live -> to target:", live.maxAuctionAwardBps, target.maxAuctionAwardBps
            );
        }
        if (fieldsMask & FIELD_SLASH_FEE_BPS != 0) {
            console2.log("slashFeeBps from live -> to target:", live.slashFeeBps, target.slashFeeBps);
        }
    }

    function _logOperation(uint256 attempt, bytes32 operationId, bytes32 salt) private view {
        console2.log("Attempt:", attempt);
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Operation salt:", vm.toString(salt));
    }

    function _requireSingleCall() private view {
        require(getTotalBatches() == 1, "SafeHelper split the batch");
        (uint256 txCount,) = getBatchInfo(0);
        require(txCount == 1, "operation must be one Safe call");
    }

    function _send(bool send) private {
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

    /// @dev Values the deposit floor at the live oracle price so reviewers see its USDC margin value and the implied
    ///      minimum commitment alongside the raw units.
    function _logConfig(ILCCVault vault, string memory label, ILCCVault.RiskConfig memory config) internal view {
        _logRawConfig(label, config);
        uint256 price = ILCCMarginOraclePrice(vault.assetConfig().marginOracle).price();
        uint256 marginValue = config.minDepositAssets * price / ORACLE_PRICE_SCALE;
        console2.log("  Min deposit margin value (funding units):", marginValue);
        console2.log(
            "  Implied min commitment (funding units):", marginValue * BPS / vault.epochConfig().marginRatioBps
        );
    }

    function _logRawConfig(string memory label, ILCCVault.RiskConfig memory config) private pure {
        console2.log(string.concat("--- ", label, " risk parameters ---"));
        console2.log("Protocol commitment cap (funding units):", config.protocolCommitmentCap);
        console2.log("User commitment cap (funding units):", config.userCommitmentCap);
        console2.log("Exit cap (bps):", config.exitCapBps);
        console2.log("Min deposit (margin units):", config.minDepositAssets);
        console2.log("Max auction award (bps):", config.maxAuctionAwardBps);
        console2.log("Slash fee (bps):", config.slashFeeBps);
    }
}
