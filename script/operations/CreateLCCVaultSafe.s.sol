// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {ITimelockController} from "../../src/interfaces/ITimelockController.sol";
import {LCCVaultFactory} from "../../src/lcc/LCCVaultFactory.sol";
import {ILCCVault} from "../../src/lcc/interfaces/ILCCVault.sol";
import {LCCDeploymentAcknowledgements} from "../utils/LCCDeploymentAcknowledgements.sol";
import {LCCMarginOracleValidation} from "../utils/LCCMarginOracleValidation.sol";
import {LCCWiringCheck} from "../utils/LCCWiringCheck.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";

interface ILCCVaultFactoryCreate2 {
    function createVault(ILCCVault.VaultParams calldata params, bytes32 salt) external returns (address);
}

interface IUSD3Registry {
    function setSupplyCapExempt(address account, bool exempt) external;
    function setRingFenceConduit(address conduit, bool enabled) external;
    function supplyCapExempt(address account) external view returns (bool);
    function ringFenceConduit(address conduit) external view returns (bool);
    function ringFencedLiquidity() external view returns (uint256);
    function management() external view returns (address);
}

interface IOwnableView {
    function owner() external view returns (address);
}

/**
 * @title CreateLCCVaultSafe
 * @notice Pre-authorize a deterministic LCC vault through USD3 management, then create it through the factory Safe.
 * @dev The shipped authority split requires two governance phases. The 24-hour parameters timelock first schedules and
 *      executes the USD3 supply-cap exemption and ring-fence conduit writes for the predicted CREATE2 address. Only
 *      after both flags are live may the factory-owning Safe create the vault. The script separately verifies the
 *      beacon's 7-day-timelock owner and the factory's family-wide owner role.
 *
 *      The JSON `facilityId` is encoded as `facilityKey = keccak256(bytes(facilityId))`, then the factory salt is
 *      `keccak256(abi.encode(bytes32("3JANE_LCC_VAULT_V1"), block.chainid, facilityKey))`. This UTF-8 byte encoding
 *      and ABI formula are the off-repo reproduction convention. The JSON must explicitly acknowledge perpetual tenor
 *      when `maxEpochs == 0`, hold-to-maturity when `minCommitmentEpochs + exitDelayEpochs >= maxEpochs != 0`, and
 *      full-pool auction awards when `maxAuctionAwardBps == 10_000`.
 *
 *      Usage, in order:
 *      1. --sig "schedulePrerequisites(string,uint256,bool)" data/lcc-vault-params.json 0 false
 *      2. After 24 hours, --sig "executePrerequisites(string,uint256,bool)" data/lcc-vault-params.json 0 false
 *      3. --sig "run(string,bool)" data/lcc-vault-params.json false
 *      4. --sig "verify(string)" data/lcc-vault-params.json
 *
 *      Deferred order, when the vault must exist before the USD3 v1.2 upgrade: create with
 *      --sig "runDeferringPrerequisites(string,bool)" and check with --sig "verifyRegistration(string)", then run
 *      steps 1, 2, and 4 once the upgrade is live. No capital call may open until step 4 passes.
 *
 *      Use FOUNDRY_PROFILE=script, WALLET_TYPE and the corresponding Safe proposer credential, LCC_FACTORY, and a
 *      mainnet RPC URL for each phase. The JSON `facilityId` must be durable, governance-assigned, and recorded in the
 *      deployment manifest.
 */
contract CreateLCCVaultSafe is
    Script,
    SafeHelper,
    TimelockHelper,
    LCCWiringCheck,
    LCCDeploymentAcknowledgements,
    LCCMarginOracleValidation
{
    struct DeploymentConfig {
        ILCCVault.VaultParams params;
        string facilityId;
        uint256 minMarginOraclePrice;
        uint256 maxMarginOraclePrice;
        bool acknowledgeHoldToMaturity;
        bool acknowledgePerpetualTenor;
        bool acknowledgeFullAuctionAward;
    }

    address internal constant USD3_PROXY = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address internal constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address internal constant PARAMS_TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address internal constant BEACON_TIMELOCK = 0x3D3C41419Ab401cd25055E8f9421D7D96d887885;
    uint256 internal constant PARAMS_TIMELOCK_DELAY = 1 days;
    uint256 internal constant BEACON_TIMELOCK_DELAY = 7 days;
    uint256 internal constant BPS = 10_000;
    bytes32 internal constant SALT_DOMAIN = bytes32("3JANE_LCC_VAULT_V1");
    bytes32 internal constant PREREQUISITE_SALT_DOMAIN = bytes32("3JANE_LCC_USD3_AUTH_V1");

    /// @notice Schedule the two prerequisite USD3 permission writes through the 24-hour parameters timelock.
    function schedulePrerequisites(string memory jsonPath, uint256 attempt, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(PARAMS_TIMELOCK)
    {
        require(_baseFeeOkay(), "Base fee too high");

        address safeAddress = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        LCCVaultFactory factory = _factory();
        IUSD3Registry usd3 = IUSD3Registry(USD3_PROXY);
        DeploymentConfig memory config = _parseAndValidateDeploymentConfig(jsonPath);
        (bytes32 salt, address vault) = _validateAndPredict(factory, usd3, config, safeAddress);
        _requireFreshOrRegistered(factory, config, vault);

        console2.log("=== Schedule LCC USD3 Prerequisites ===");
        _logDeployment(jsonPath, safeAddress, factory, usd3, config, salt, vault, send);

        if (_permissionsLive(usd3, vault)) {
            console2.log("Prerequisite permissions are already live; do not schedule them again");
            return;
        }

        _requireSafeProposer(safeAddress);
        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 operationSalt) =
            _buildPrerequisiteOperation(vault, attempt);
        bytes32 predecessor = bytes32(0);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, operationSalt);

        console2.log("Parameters timelock:", PARAMS_TIMELOCK);
        console2.log("Prerequisite attempt:", attempt);
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Operation salt:", vm.toString(operationSalt));

        ITimelockController.OperationState operationState = getOperationState(PARAMS_TIMELOCK, operationId);
        if (
            operationState == ITimelockController.OperationState.Waiting
                || operationState == ITimelockController.OperationState.Ready
        ) {
            logOperationState(PARAMS_TIMELOCK, operationId);
            console2.log("Prerequisite operation is already pending");
            return;
        }
        require(
            operationState != ITimelockController.OperationState.Done,
            "Prerequisite operation already executed; use a fresh attempt nonce"
        );

        simulateExecution(PARAMS_TIMELOCK, targets, values, datas);
        bytes memory scheduleCalldata =
            encodeScheduleBatch(targets, values, datas, predecessor, operationSalt, PARAMS_TIMELOCK_DELAY);
        addToBatch(PARAMS_TIMELOCK, scheduleCalldata);
        _requireSingleCallBatch("Prerequisite schedule must be one Safe call");

        _executeSafeBatch(send);
        console2.log("Next: after the 24-hour delay, run executePrerequisites with the same JSON and attempt nonce");
    }

    /// @notice Execute the scheduled prerequisite writes after the 24-hour delay and verify both flags.
    function executePrerequisites(string memory jsonPath, uint256 attempt, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(PARAMS_TIMELOCK)
    {
        require(_baseFeeOkay(), "Base fee too high");

        address safeAddress = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        LCCVaultFactory factory = _factory();
        IUSD3Registry usd3 = IUSD3Registry(USD3_PROXY);
        DeploymentConfig memory config = _parseAndValidateDeploymentConfig(jsonPath);
        (bytes32 salt, address vault) = _validateAndPredict(factory, usd3, config, safeAddress);
        _requireFreshOrRegistered(factory, config, vault);

        console2.log("=== Execute LCC USD3 Prerequisites ===");
        _logDeployment(jsonPath, safeAddress, factory, usd3, config, salt, vault, send);

        if (_permissionsLive(usd3, vault)) {
            console2.log("Prerequisite permissions are already live; do not execute them again");
            return;
        }

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 operationSalt) =
            _buildPrerequisiteOperation(vault, attempt);
        bytes32 predecessor = bytes32(0);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, operationSalt);

        console2.log("Prerequisite attempt:", attempt);
        logOperationState(PARAMS_TIMELOCK, operationId);
        require(
            !isOperationDone(PARAMS_TIMELOCK, operationId),
            "Prerequisite operation already executed; use a fresh attempt nonce"
        );
        requireOperationReady(PARAMS_TIMELOCK, operationId);

        bytes memory executeCalldata = encodeExecuteBatch(targets, values, datas, predecessor, operationSalt);
        addToBatch(PARAMS_TIMELOCK, executeCalldata);
        require(_permissionsLive(usd3, vault), "Simulated prerequisite permissions missing");
        _requireSingleCallBatch("Prerequisite execution must be one Safe call");

        _executeSafeBatch(send);
        console2.log("Next: run the Safe-owned factory creation with the same JSON");
    }

    /// @notice Create the vault only after the predicted address has both prerequisite USD3 permissions.
    function run(string memory jsonPath, bool send) external isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE)) {
        require(_baseFeeOkay(), "Base fee too high");

        address safeAddress = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        LCCVaultFactory factory = _factory();
        IUSD3Registry usd3 = IUSD3Registry(USD3_PROXY);
        DeploymentConfig memory config = _parseAndValidateDeploymentConfig(jsonPath);
        (bytes32 salt, address vault) = _validateAndPredict(factory, usd3, config, safeAddress);
        _requireFutureStart(config);
        require(factory.owner() == safeAddress, "Safe is not LCC factory owner");

        require(vault.code.length == 0, "Predicted LCC vault already deployed");
        require(!factory.isVault(vault), "Predicted LCC vault already registered");
        require(usd3.supplyCapExempt(vault), "Predicted vault supply-cap exemption missing");
        require(usd3.ringFenceConduit(vault), "Predicted vault ring-fence conduit missing");

        console2.log("=== Create Pre-Authorized LCC Vault via Safe ===");
        _logDeployment(jsonPath, safeAddress, factory, usd3, config, salt, vault, send);

        bytes memory createReturndata =
            addToBatch(address(factory), abi.encodeCall(ILCCVaultFactoryCreate2.createVault, (config.params, salt)));
        address simulatedVault = abi.decode(createReturndata, (address));
        require(simulatedVault == vault, "Simulated vault address mismatch");
        _requireDeployedVault(factory, usd3, vault);
        _requireSingleCallBatch("LCC creation must be one Safe call");

        _executeSafeBatch(send);
        console2.log("Next: run --sig \"verify(string)\" with the same JSON after Safe execution");
    }

    function run(string memory jsonPath) external {
        this.run(jsonPath, false);
    }

    /// @notice Create the vault before its USD3 permissions exist, deferring the prerequisite phases until after the
    ///         USD3 v1.2 upgrade. The owner must not open a capital call until `verify(string)` passes: funding routes
    ///         through USD3 and fails without the supply-cap exemption, which would slash compelled funders.
    function runDeferringPrerequisites(string memory jsonPath, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
    {
        require(_baseFeeOkay(), "Base fee too high");

        address safeAddress = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        LCCVaultFactory factory = _factory();
        IUSD3Registry usd3 = IUSD3Registry(USD3_PROXY);
        DeploymentConfig memory config = _parseAndValidateDeploymentConfig(jsonPath);
        (bytes32 salt, address vault) = _validateAndPredict(factory, usd3, config, safeAddress);
        _requireFutureStart(config);
        require(factory.owner() == safeAddress, "Safe is not LCC factory owner");

        require(vault.code.length == 0, "Predicted LCC vault already deployed");
        require(!factory.isVault(vault), "Predicted LCC vault already registered");

        console2.log("=== Create LCC Vault via Safe, USD3 Prerequisites Deferred ===");
        _logDeployment(jsonPath, safeAddress, factory, usd3, config, salt, vault, send);
        console2.log(
            "WARNING: no USD3 permissions are granted; do not open a capital call before verify(string) passes"
        );

        bytes memory createReturndata =
            addToBatch(address(factory), abi.encodeCall(ILCCVaultFactoryCreate2.createVault, (config.params, salt)));
        address simulatedVault = abi.decode(createReturndata, (address));
        require(simulatedVault == vault, "Simulated vault address mismatch");
        _requireRegisteredVault(factory, vault);
        _requireSingleCallBatch("LCC creation must be one Safe call");

        _executeSafeBatch(send);
        console2.log(
            "Next: after the USD3 v1.2 upgrade, run schedulePrerequisites and executePrerequisites, then verify"
        );
    }

    /// @notice Verify factory provenance and wiring for a vault whose USD3 permissions are still deferred.
    function verifyRegistration(string memory jsonPath) external view {
        address safeAddress = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        LCCVaultFactory factory = _factory();
        IUSD3Registry usd3 = IUSD3Registry(USD3_PROXY);
        DeploymentConfig memory config = _parseAndValidateDeploymentConfig(jsonPath);
        (bytes32 salt, address vault) = _validateAndPredict(factory, usd3, config, safeAddress);

        console2.log("=== Verify Registered LCC Vault (USD3 permissions deferred) ===");
        console2.log("CREATE2 salt:", vm.toString(salt));
        console2.log("Predicted vault:", vault);
        _requireRegisteredVault(factory, vault);
        console2.log("PASS: provenance and wiring");
        console2.log(
            _permissionsLiveTolerant(vault)
                ? "USD3 permissions: live"
                : "USD3 permissions: NOT live; no capital call may open before they are"
        );
    }

    /// @notice Verify the predicted vault address, factory provenance, wiring, and both USD3 permissions.
    function verify(string memory jsonPath) external view {
        address safeAddress = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        LCCVaultFactory factory = _factory();
        IUSD3Registry usd3 = IUSD3Registry(USD3_PROXY);
        DeploymentConfig memory config = _parseAndValidateDeploymentConfig(jsonPath);
        (bytes32 salt, address vault) = _validateAndPredict(factory, usd3, config, safeAddress);

        console2.log("=== Verify Deployed LCC Vault ===");
        console2.log("CREATE2 salt:", vm.toString(salt));
        console2.log("Predicted vault:", vault);
        _requireDeployedVault(factory, usd3, vault);
        console2.log("PASS: provenance, wiring, supply-cap exemption, and ring-fence conduit");
    }

    /// @notice Verify a deployed vault when its deployment JSON is unavailable.
    function verify(address vault) external view {
        LCCVaultFactory factory = _factory();
        IUSD3Registry usd3 = IUSD3Registry(USD3_PROXY);

        console2.log("=== Verify Deployed LCC Vault ===");
        console2.log("Vault:", vault);
        _requireDeployedVault(factory, usd3, vault);
        ILCCVault.AssetConfig memory assets = ILCCVault(vault).assetConfig();
        _requireMarginOracleBinding(assets.marginAsset, assets.marginOracle);
        // Configured price bounds are not recoverable from vault state, so verify(string) remains authoritative.
        console2.log("PASS: provenance, wiring, supply-cap exemption, and ring-fence conduit");
    }

    function _factory() internal view returns (LCCVaultFactory factory) {
        address factoryAddress = vm.envAddress("LCC_FACTORY");
        require(factoryAddress != address(0), "LCC_FACTORY not set");
        require(factoryAddress.code.length > 0, "LCC_FACTORY has no code");
        return LCCVaultFactory(factoryAddress);
    }

    function _requireConfiguredMarginOracle(DeploymentConfig memory config) internal view {
        _requireMarginOracle(
            config.params.marginAsset,
            config.params.marginOracle,
            config.minMarginOraclePrice,
            config.maxMarginOraclePrice
        );
    }

    function _validateAndPredict(
        LCCVaultFactory factory,
        IUSD3Registry usd3,
        DeploymentConfig memory config,
        address safeAddress
    ) internal view returns (bytes32 salt, address vault) {
        require(bytes(config.facilityId).length != 0, "Facility ID not set");
        require(config.params.marginAsset != address(0), "Margin asset not set");
        _requireHoldToMaturityAcknowledgement(config.params, config.acknowledgeHoldToMaturity);
        require(
            config.params.maxEpochs != 0 || config.acknowledgePerpetualTenor,
            "Perpetual tenor requires explicit acknowledgement"
        );
        require(
            config.params.maxAuctionAwardBps != BPS || config.acknowledgeFullAuctionAward,
            "Full auction award requires explicit acknowledgement"
        );

        require(
            factory.owner() == safeAddress || factory.owner() == PARAMS_TIMELOCK,
            "LCC factory owner is neither the Safe nor the parameters timelock"
        );
        address beacon = factory.beacon();
        require(beacon.code.length > 0, "LCC beacon has no code");
        require(IOwnableView(beacon).owner() == BEACON_TIMELOCK, "LCC beacon owner is not expected 7-day timelock");
        require(BEACON_TIMELOCK.code.length > 0, "Beacon timelock has no code");
        require(getMinDelay(BEACON_TIMELOCK) == BEACON_TIMELOCK_DELAY, "Beacon timelock delay is not 7 days");
        require(PARAMS_TIMELOCK.code.length > 0, "Parameters timelock has no code");
        require(getMinDelay(PARAMS_TIMELOCK) == PARAMS_TIMELOCK_DELAY, "Parameters timelock delay is not 24 hours");
        require(usd3.management() == PARAMS_TIMELOCK, "USD3 management is not expected parameters timelock");

        bytes32 facilityKey = keccak256(bytes(config.facilityId));
        salt = keccak256(abi.encode(SALT_DOMAIN, block.chainid, facilityKey));
        vault = factory.predictVaultAddress(config.params, salt);
    }

    function _requireFutureStart(DeploymentConfig memory config) internal view {
        require(config.params.startTimestamp > block.timestamp, "Vault start timestamp must be in the future");
    }

    function _requireDeployedVault(LCCVaultFactory factory, IUSD3Registry usd3, address vault) internal view {
        _requireRegisteredVault(factory, vault);
        require(usd3.supplyCapExempt(vault), "LCC vault supply-cap exemption missing");
        require(usd3.ringFenceConduit(vault), "LCC vault ring-fence conduit missing");
    }

    function _requireRegisteredVault(LCCVaultFactory factory, address vault) internal view {
        require(vault != address(0) && vault.code.length > 0, "LCC vault is not deployed");
        require(factory.isVault(vault), "LCC vault is not factory registered");
        _requireLCCWiring(vault, USD3_PROXY);
    }

    /// @dev The prerequisite phases run either before creation (predicted address, future start) or after a deferred
    ///      creation (registered vault, start may already have passed).
    function _requireFreshOrRegistered(LCCVaultFactory factory, DeploymentConfig memory config, address vault)
        internal
        view
    {
        if (vault.code.length == 0) {
            require(!factory.isVault(vault), "Predicted LCC vault already registered");
            _requireFutureStart(config);
        } else {
            _requireRegisteredVault(factory, vault);
        }
    }

    function _permissionsLive(IUSD3Registry usd3, address vault) internal view returns (bool) {
        return usd3.supplyCapExempt(vault) && usd3.ringFenceConduit(vault);
    }

    /// @dev Reads both flags without reverting when the USD3 v1.2 registry is not live yet.
    function _permissionsLiveTolerant(address vault) internal view returns (bool) {
        (bool exemptOk, bytes memory exemptData) =
            USD3_PROXY.staticcall(abi.encodeCall(IUSD3Registry.supplyCapExempt, (vault)));
        (bool conduitOk, bytes memory conduitData) =
            USD3_PROXY.staticcall(abi.encodeCall(IUSD3Registry.ringFenceConduit, (vault)));
        return exemptOk && exemptData.length == 32 && abi.decode(exemptData, (bool)) && conduitOk
            && conduitData.length == 32 && abi.decode(conduitData, (bool));
    }

    function _logParams(DeploymentConfig memory config) internal pure {
        ILCCVault.VaultParams memory p = config.params;
        uint256 closedWindow = p.epochLength - p.normalDuration - p.preCallDuration - p.fundingDuration;
        console2.log("--- Facility parameters ---");
        console2.log("Margin asset:", p.marginAsset);
        console2.log("Margin oracle:", p.marginOracle);
        console2.log("Oracle price bounds (min, max):", config.minMarginOraclePrice, config.maxMarginOraclePrice);
        console2.log("Start timestamp:", p.startTimestamp);
        console2.log("Max epochs (0 = perpetual):", p.maxEpochs);
        console2.log("Epoch length (s, days):", p.epochLength, p.epochLength / 1 days);
        console2.log("  Normal (s, days):", p.normalDuration, p.normalDuration / 1 days);
        console2.log("  PreCall (s, days):", p.preCallDuration, p.preCallDuration / 1 days);
        console2.log("  Funding (s, days):", p.fundingDuration, p.fundingDuration / 1 days);
        console2.log("  Closed / auction (s, days):", closedWindow, closedWindow / 1 days);
        console2.log("Margin ratio (bps):", p.marginRatioBps);
        console2.log("Standby leverage (x, hundredths):", BPS * 100 / p.marginRatioBps);
        console2.log("Protocol commitment cap (funding units):", p.protocolCommitmentCap);
        console2.log("User commitment cap (funding units):", p.userCommitmentCap);
        console2.log("Min deposit (margin units):", p.minDepositAssets);
        console2.log("Exit cap (bps):", p.exitCapBps);
        console2.log("Exit delay (epochs):", p.exitDelayEpochs);
        console2.log("Min commitment (epochs):", p.minCommitmentEpochs);
        console2.log("Auction steps:", p.auctionStepCount);
        if (p.auctionStepCount != 0) console2.log("Auction step duration (s):", closedWindow / p.auctionStepCount);
        console2.log("Auction decay (bps per step):", p.auctionStepDecayRateBps);
        console2.log("Max auction award (bps):", p.maxAuctionAwardBps);
        console2.log("Slash fee (bps):", p.slashFeeBps);
    }

    function _requireSafeProposer(address safeAddress) internal view {
        bytes32 proposerRole = ITimelockController(PARAMS_TIMELOCK).PROPOSER_ROLE();
        (bool roleReadOk, bytes memory roleData) =
            PARAMS_TIMELOCK.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", proposerRole, safeAddress));
        require(
            roleReadOk && roleData.length == 32 && abi.decode(roleData, (bool)),
            "Safe is not a parameters timelock proposer"
        );
    }

    function _buildPrerequisiteOperation(address vault, uint256 attempt)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 operationSalt)
    {
        targets = new address[](2);
        values = new uint256[](2);
        datas = new bytes[](2);

        targets[0] = USD3_PROXY;
        datas[0] = abi.encodeCall(IUSD3Registry.setSupplyCapExempt, (vault, true));
        targets[1] = USD3_PROXY;
        datas[1] = abi.encodeCall(IUSD3Registry.setRingFenceConduit, (vault, true));

        operationSalt = keccak256(abi.encode(PREREQUISITE_SALT_DOMAIN, vault, attempt));
    }

    function _requireSingleCallBatch(string memory errorMessage) internal view {
        require(getTotalBatches() == 1, "SafeHelper split the batch");
        (uint256 txCount,) = getBatchInfo(0);
        require(txCount == 1, errorMessage);
    }

    function _executeSafeBatch(bool send) internal {
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

    function _logDeployment(
        string memory jsonPath,
        address safeAddress,
        LCCVaultFactory factory,
        IUSD3Registry usd3,
        DeploymentConfig memory config,
        bytes32 salt,
        address vault,
        bool send
    ) internal view {
        console2.log("Factory Safe:", safeAddress);
        console2.log("Parameters timelock / USD3 management:", PARAMS_TIMELOCK);
        console2.log("Factory owner:", factory.owner());
        console2.log("Beacon timelock:", BEACON_TIMELOCK);
        console2.log("LCC factory:", address(factory));
        console2.log("USD3 proxy:", USD3_PROXY);
        (bool registryLive, bytes memory liveData) =
            USD3_PROXY.staticcall(abi.encodeCall(IUSD3Registry.ringFencedLiquidity, ()));
        if (registryLive && liveData.length == 32) {
            console2.log("Current ring-fenced liquidity:", abi.decode(liveData, (uint256)));
        } else {
            console2.log("USD3 v1.2 registry not live; ring-fenced liquidity unavailable");
        }
        console2.log("Facility ID:", config.facilityId);
        console2.log("JSON file:", jsonPath);
        console2.log("CREATE2 salt:", vm.toString(salt));
        console2.log("Predicted vault:", vault);
        console2.log("Hold-to-maturity:", _isHoldToMaturity(config.params));
        console2.log("Hold-to-maturity acknowledgement:", config.acknowledgeHoldToMaturity);
        console2.log("Perpetual tenor:", config.params.maxEpochs == 0);
        console2.log("Perpetual-tenor acknowledgement:", config.acknowledgePerpetualTenor);
        console2.log("Full-pool auction award:", config.params.maxAuctionAwardBps == BPS);
        console2.log("Full-auction-award acknowledgement:", config.acknowledgeFullAuctionAward);
        console2.log("Send to Safe:", send);
        _logParams(config);
    }

    function _parseDeploymentConfig(string memory jsonPath) internal view returns (DeploymentConfig memory config) {
        string memory json = vm.readFile(jsonPath);
        config.facilityId = vm.parseJsonString(json, ".facilityId");
        config.acknowledgeHoldToMaturity = vm.parseJsonBool(json, ".acknowledgeHoldToMaturity");
        config.acknowledgePerpetualTenor = vm.parseJsonBool(json, ".acknowledgePerpetualTenor");
        config.acknowledgeFullAuctionAward = vm.parseJsonBool(json, ".acknowledgeFullAuctionAward");
        config.minMarginOraclePrice = vm.parseJsonUint(json, ".minMarginOraclePrice");
        config.maxMarginOraclePrice = vm.parseJsonUint(json, ".maxMarginOraclePrice");

        ILCCVault.VaultParams memory params;
        params.marginAsset = vm.parseJsonAddress(json, ".marginAsset");
        params.marginOracle = vm.parseJsonAddress(json, ".marginOracle");
        params.startTimestamp = vm.parseJsonUint(json, ".startTimestamp");
        params.maxEpochs = vm.parseJsonUint(json, ".maxEpochs");
        params.epochLength = vm.parseJsonUint(json, ".epochLength");
        params.normalDuration = vm.parseJsonUint(json, ".normalDuration");
        params.preCallDuration = vm.parseJsonUint(json, ".preCallDuration");
        params.fundingDuration = vm.parseJsonUint(json, ".fundingDuration");
        params.marginRatioBps = vm.parseJsonUint(json, ".marginRatioBps");
        params.protocolCommitmentCap = vm.parseJsonUint(json, ".protocolCommitmentCap");
        params.userCommitmentCap = vm.parseJsonUint(json, ".userCommitmentCap");
        params.exitCapBps = vm.parseJsonUint(json, ".exitCapBps");
        params.exitDelayEpochs = vm.parseJsonUint(json, ".exitDelayEpochs");
        params.minCommitmentEpochs = vm.parseJsonUint(json, ".minCommitmentEpochs");
        params.minDepositAssets = vm.parseJsonUint(json, ".minDepositAssets");
        params.auctionStepCount = vm.parseJsonUint(json, ".auctionStepCount");
        params.auctionStepDecayRateBps = vm.parseJsonUint(json, ".auctionStepDecayRateBps");
        params.maxAuctionAwardBps = vm.parseJsonUint(json, ".maxAuctionAwardBps");
        params.slashFeeBps = vm.parseJsonUint(json, ".slashFeeBps");
        config.params = params;
    }

    function _parseAndValidateDeploymentConfig(string memory jsonPath)
        internal
        view
        returns (DeploymentConfig memory config)
    {
        config = _parseDeploymentConfig(jsonPath);
        _requireConfiguredMarginOracle(config);
    }

    function _baseFeeOkay() private view returns (bool) {
        uint256 basefeeLimit = vm.envOr("BASE_FEE_LIMIT", uint256(50)) * 1e9;
        if (block.basefee >= basefeeLimit) {
            console2.log("Base fee too high: %d gwei > %d gwei limit", block.basefee / 1e9, basefeeLimit / 1e9);
            return false;
        }
        console2.log("Base fee OK: %d gwei", block.basefee / 1e9);
        return true;
    }
}
