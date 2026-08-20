// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Script, console2, VmSafe} from "forge-std/Script.sol";
import {LCCVaultFactory} from "../../src/lcc/LCCVaultFactory.sol";
import {ILCCVault} from "../../src/lcc/interfaces/ILCCVault.sol";
import {LCCWiringCheck} from "../utils/LCCWiringCheck.sol";

/**
 * @title CreateLCCTestVault
 * @notice Creates an active, unpermissioned LCC test vault through the isolated EOA-owned test factory.
 * @dev This script deliberately does not call USD3's supplyCapExempt or ringFenceConduit registry methods. The vault
 *      captures the test factory as its family-wide authority and is not paused or shut down: it begins in epoch
 *      zero's Normal phase and follows its configured lifecycle. Pre-start margin deposits are possible, while calls
 *      cannot open before the configured PreCall phase.
 *
 *      Usage:
 *      FOUNDRY_PROFILE=script LCC_TEST_FACTORY=<address> PRODUCTION_LCC_FACTORY=<address> TEST_OWNER=<address> \
 *        forge script script/operations/CreateLCCTestVault.s.sol \
 *        --sig "run(string)" data/lcc-test-vault-params.json --rpc-url mainnet --broadcast
 */
contract CreateLCCTestVault is Script, LCCWiringCheck {
    uint256 internal constant MAINNET_CHAIN_ID = 1;
    uint256 internal constant DEFAULT_MIN_START_LEAD_TIME = 1 days;
    address internal constant USD3_PROXY = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    bytes32 internal constant FACTORY_STORAGE_SLOT = bytes32(uint256(29));
    bytes32 internal constant SALT_DOMAIN = bytes32("3JANE_LCC_VAULT_V1");
    bytes internal constant TEST_FACILITY_PREFIX = bytes("TEST_ONLY:");

    function run(string memory jsonPath) external returns (address vaultAddress) {
        (
            LCCVaultFactory testFactory,
            LCCVaultFactory productionFactory,
            address testOwner,
            ILCCVault.VaultParams memory params,
            string memory facilityId
        ) = _deploymentContext(jsonPath);

        bytes32 salt = _facilitySalt(facilityId);
        address predictedVault = testFactory.predictVaultAddress(params, salt);
        uint256 vaultCountBefore = testFactory.numVaults();

        console2.log("=== Creating Active LCC Test Vault ===");
        console2.log("Test factory:", address(testFactory));
        console2.log("Production factory:", address(productionFactory));
        console2.log("Test owner:", testOwner);
        console2.log("Facility ID:", facilityId);
        console2.log("CREATE2 salt:", vm.toString(salt));
        console2.log("Predicted vault:", predictedVault);
        console2.log("Start timestamp:", params.startTimestamp);
        console2.log("");

        _startExpectedBroadcast(testOwner);
        vaultAddress = testFactory.createVault(params, salt);
        vm.stopBroadcast();

        require(vaultAddress == predictedVault, "LCC test vault prediction mismatch");
        require(testFactory.numVaults() == vaultCountBefore + 1, "LCC test factory count mismatch");
        _requireVault(vaultAddress, testFactory, productionFactory, testOwner, true);
        _requireConfiguredParams(vaultAddress, params);

        console2.log("=== Active LCC Test Vault Created ===");
        console2.log("Vault:", vaultAddress);
        console2.log("PASS: registered only in test factory");
        console2.log("PASS: active, unpaused, and not shut down");
        console2.log("WARNING: USD3 permissions were intentionally not granted");
    }

    /// @notice Verifies registry isolation, authority, wiring, and live state for a deployed test vault.
    function verify(address vaultAddress) external view {
        require(block.chainid == MAINNET_CHAIN_ID, "LCC test deployment is mainnet-only");

        address testFactoryAddress = vm.envAddress("LCC_TEST_FACTORY");
        address productionFactoryAddress = vm.envAddress("PRODUCTION_LCC_FACTORY");
        address testOwner = vm.envAddress("TEST_OWNER");
        _requireFactoryInputs(testFactoryAddress, productionFactoryAddress, testOwner);

        LCCVaultFactory testFactory = LCCVaultFactory(testFactoryAddress);
        LCCVaultFactory productionFactory = LCCVaultFactory(productionFactoryAddress);
        _requireSharedBeacon(testFactory, productionFactory);
        _requireVault(vaultAddress, testFactory, productionFactory, testOwner, false);

        console2.log("=== LCC Test Vault Verification ===");
        console2.log("Vault:", vaultAddress);
        console2.log("PASS: registered only in test factory");
        console2.log("PASS: factory authority and canonical USD3 wiring match");
        console2.log("PASS: vault is unpaused and not shut down");
    }

    function _deploymentContext(string memory jsonPath)
        internal
        view
        returns (
            LCCVaultFactory testFactory,
            LCCVaultFactory productionFactory,
            address testOwner,
            ILCCVault.VaultParams memory params,
            string memory facilityId
        )
    {
        require(block.chainid == MAINNET_CHAIN_ID, "LCC test deployment is mainnet-only");

        address testFactoryAddress = vm.envAddress("LCC_TEST_FACTORY");
        address productionFactoryAddress = vm.envAddress("PRODUCTION_LCC_FACTORY");
        testOwner = vm.envAddress("TEST_OWNER");
        _requireFactoryInputs(testFactoryAddress, productionFactoryAddress, testOwner);

        testFactory = LCCVaultFactory(testFactoryAddress);
        productionFactory = LCCVaultFactory(productionFactoryAddress);
        _requireSharedBeacon(testFactory, productionFactory);
        require(testFactory.owner() == testOwner, "TEST_OWNER is not test factory owner");
        require(testFactory.isOwner(testOwner), "TEST_OWNER lacks test factory owner role");
        require(testFactory.defaultDepositorCap() != 0, "Test factory default depositor cap must be open");
        require(testFactory.oneVaultPolicyEnabled(), "Test factory one-vault policy must remain enabled");

        (params, facilityId) = _parseDeploymentConfig(jsonPath);
        require(_hasTestFacilityPrefix(facilityId), "Facility ID must start with TEST_ONLY:");

        uint256 minStartLeadTime = vm.envOr("MIN_START_LEAD_TIME", DEFAULT_MIN_START_LEAD_TIME);
        require(minStartLeadTime != 0, "MIN_START_LEAD_TIME must be positive");
        require(params.startTimestamp >= block.timestamp + minStartLeadTime, "Vault start timestamp lead too short");
    }

    function _requireFactoryInputs(address testFactoryAddress, address productionFactoryAddress, address testOwner)
        internal
        view
    {
        require(testFactoryAddress != address(0) && testFactoryAddress.code.length > 0, "LCC_TEST_FACTORY invalid");
        require(
            productionFactoryAddress != address(0) && productionFactoryAddress.code.length > 0,
            "PRODUCTION_LCC_FACTORY invalid"
        );
        require(testFactoryAddress != productionFactoryAddress, "Test factory is production factory");
        require(testOwner != address(0), "TEST_OWNER not set");
    }

    function _requireSharedBeacon(LCCVaultFactory testFactory, LCCVaultFactory productionFactory) internal view {
        require(testFactory.beacon() == productionFactory.beacon(), "Factory beacon mismatch");
    }

    function _requireVault(
        address vaultAddress,
        LCCVaultFactory testFactory,
        LCCVaultFactory productionFactory,
        address testOwner,
        bool requireInitialPhase
    ) internal view {
        require(vaultAddress != address(0) && vaultAddress.code.length > 0, "LCC test vault invalid");
        require(testFactory.isVault(vaultAddress), "Vault missing from test factory");
        require(!productionFactory.isVault(vaultAddress), "Vault registered in production factory");
        require(
            address(uint160(uint256(vm.load(vaultAddress, FACTORY_STORAGE_SLOT)))) == address(testFactory),
            "LCC test vault captured factory mismatch"
        );
        require(testFactory.isOwner(testOwner), "LCC test vault authority mismatch");

        _requireLCCWiring(vaultAddress, USD3_PROXY);

        (bool paused,,) = ILCCVault(vaultAddress).pauseState();
        require(!paused, "LCC test vault is paused");
        require(!ILCCVault(vaultAddress).shutdownState().active, "LCC test vault is shut down");
        if (requireInitialPhase) {
            require(ILCCVault(vaultAddress).currentEpoch() == 0, "LCC test vault initial epoch mismatch");
            require(ILCCVault(vaultAddress).currentPhase() == ILCCVault.Phase.Normal, "LCC test vault not Normal");
        }
    }

    function _requireConfiguredParams(address vaultAddress, ILCCVault.VaultParams memory params) internal view {
        ILCCVault vault = ILCCVault(vaultAddress);
        ILCCVault.AssetConfig memory assets = vault.assetConfig();
        require(assets.marginAsset == params.marginAsset, "LCC margin asset mismatch");
        require(assets.marginOracle == params.marginOracle, "LCC margin oracle mismatch");

        ILCCVault.EpochConfig memory epoch = vault.epochConfig();
        require(epoch.startTimestamp == params.startTimestamp, "LCC start timestamp mismatch");
        require(epoch.maxEpochs == params.maxEpochs, "LCC max epochs mismatch");
        require(epoch.epochLength == params.epochLength, "LCC epoch length mismatch");
        require(epoch.normalDuration == params.normalDuration, "LCC normal duration mismatch");
        require(epoch.preCallDuration == params.preCallDuration, "LCC pre-call duration mismatch");
        require(epoch.fundingDuration == params.fundingDuration, "LCC funding duration mismatch");
        require(epoch.marginRatioBps == params.marginRatioBps, "LCC margin ratio mismatch");
        require(epoch.exitDelayEpochs == params.exitDelayEpochs, "LCC exit delay mismatch");
        require(epoch.minCommitmentEpochs == params.minCommitmentEpochs, "LCC minimum commitment mismatch");

        ILCCVault.RiskConfig memory risk = vault.riskConfig();
        require(risk.protocolCommitmentCap == params.protocolCommitmentCap, "LCC protocol cap mismatch");
        require(risk.userCommitmentCap == params.userCommitmentCap, "LCC user cap mismatch");
        require(risk.exitCapBps == params.exitCapBps, "LCC exit cap mismatch");
        require(risk.minDepositAssets == params.minDepositAssets, "LCC minimum deposit mismatch");
        require(risk.maxAuctionAwardBps == params.maxAuctionAwardBps, "LCC auction award mismatch");
        require(risk.slashFeeBps == params.slashFeeBps, "LCC slash fee mismatch");

        ILCCVault.AuctionConfig memory auction = vault.auctionConfig();
        require(auction.auctionStepCount == params.auctionStepCount, "LCC auction step count mismatch");
        require(auction.auctionStepDecayRateBps == params.auctionStepDecayRateBps, "LCC auction decay rate mismatch");
        uint256 expectedStepDuration;
        if (params.auctionStepCount != 0) {
            expectedStepDuration =
                (params.epochLength - params.normalDuration - params.preCallDuration - params.fundingDuration)
                    / params.auctionStepCount;
        }
        require(auction.auctionStepDuration == expectedStepDuration, "LCC auction step duration mismatch");
    }

    function _parseDeploymentConfig(string memory jsonPath)
        internal
        view
        returns (ILCCVault.VaultParams memory params, string memory facilityId)
    {
        string memory json = vm.readFile(jsonPath);
        facilityId = vm.parseJsonString(json, ".facilityId");
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
    }

    function _facilitySalt(string memory facilityId) internal view returns (bytes32) {
        bytes32 facilityKey = keccak256(bytes(facilityId));
        return keccak256(abi.encode(SALT_DOMAIN, block.chainid, facilityKey));
    }

    function _hasTestFacilityPrefix(string memory facilityId) internal pure returns (bool) {
        bytes memory value = bytes(facilityId);
        if (value.length <= TEST_FACILITY_PREFIX.length) return false;
        for (uint256 i; i < TEST_FACILITY_PREFIX.length; ++i) {
            if (value[i] != TEST_FACILITY_PREFIX[i]) return false;
        }
        return true;
    }

    function _startExpectedBroadcast(address expectedBroadcaster) internal {
        vm.startBroadcast(expectedBroadcaster);
        (VmSafe.CallerMode mode, address sender, address origin) = vm.readCallers();
        require(mode == VmSafe.CallerMode.RecurrentBroadcast, "Broadcast mode not active");
        require(sender == expectedBroadcaster && origin == expectedBroadcaster, "TEST_OWNER is not broadcaster");
    }
}
