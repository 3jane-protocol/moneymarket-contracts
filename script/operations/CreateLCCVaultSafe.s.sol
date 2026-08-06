// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {LCCWiringCheck} from "../utils/LCCWiringCheck.sol";
import {LCCVaultFactory} from "../../src/lcc/LCCVaultFactory.sol";
import {ILCCVault} from "../../src/lcc/interfaces/ILCCVault.sol";

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

/**
 * @title CreateLCCVaultSafe
 * @notice Atomically create an owner-vetted LCC vault and register its two required USD3 permissions via Safe.
 * @dev The three calls must remain in one MultiSend batch: CREATE2 makes the vault address execution-stable, and USD3
 *      permissions are granted to that address in the same Safe tx. The JSON `facilityId` is encoded as
 *      `facilityKey = keccak256(bytes(facilityId))`, then the factory salt is
 *      `keccak256(abi.encode(bytes32("3JANE_LCC_VAULT_V1"), block.chainid, facilityKey))`. This UTF-8 byte encoding
 *      and ABI formula are the off-repo reproduction convention.
 *      This script intentionally uses a local USD3 interface and imports no src/usd3 source.
 *
 *      Usage:
 *      FOUNDRY_PROFILE=script WALLET_TYPE=local SAFE_PROPOSER_PRIVATE_KEY=<private-key> forge script \
 *        script/operations/CreateLCCVaultSafe.s.sol \
 *        --sig "run(string,bool)" data/lcc-vault-params.json false --rpc-url mainnet
 *      The JSON must include a durable, governance-assigned `facilityId` recorded in the deployment manifest.
 *      Use WALLET_TYPE=account with SAFE_PROPOSER_ACCOUNT, or WALLET_TYPE=ledger with MNEMONIC_INDEX, instead.
 */
contract CreateLCCVaultSafe is Script, SafeHelper, LCCWiringCheck {
    address internal constant USD3_PROXY = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address internal constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    bytes32 internal constant SALT_DOMAIN = bytes32("3JANE_LCC_VAULT_V1");

    function run(string memory jsonPath, bool send) external isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE)) {
        require(_baseFeeOkay(), "Base fee too high");

        address safeAddress = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        address factoryAddress = vm.envAddress("LCC_FACTORY");
        require(factoryAddress != address(0), "LCC_FACTORY not set");
        require(factoryAddress.code.length > 0, "LCC_FACTORY has no code");

        LCCVaultFactory factory = LCCVaultFactory(factoryAddress);
        IUSD3Registry usd3 = IUSD3Registry(USD3_PROXY);
        (ILCCVault.VaultParams memory params, string memory facilityId) = _parseDeploymentConfig(jsonPath);

        require(bytes(facilityId).length != 0, "Facility ID not set");
        require(params.marginAsset != address(0), "Margin asset not set");
        require(params.marginOracle != address(0), "Margin oracle not set");
        require(params.startTimestamp > block.timestamp, "Vault start timestamp must be in the future");
        require(factory.owner() == safeAddress, "Safe is not LCC factory owner");
        require(usd3.management() == safeAddress, "Safe is not USD3 management");

        (bool live, bytes memory liveData) =
            USD3_PROXY.staticcall(abi.encodeCall(IUSD3Registry.ringFencedLiquidity, ()));
        require(live && liveData.length == 32, "USD3 v1.2 registry is not live");
        uint256 ringFencedLiquidity = abi.decode(liveData, (uint256));

        console2.log("=== Create and Register LCC Vault via Safe ===");
        console2.log("Safe address:", safeAddress);
        console2.log("LCC factory:", factoryAddress);
        console2.log("USD3 proxy:", USD3_PROXY);
        console2.log("Current ring-fenced liquidity:", ringFencedLiquidity);
        console2.log("Facility ID:", facilityId);
        console2.log("JSON file:", jsonPath);
        console2.log("Send to Safe:", send);
        console2.log("");

        bytes32 facilityKey = keccak256(bytes(facilityId));
        bytes32 salt = keccak256(abi.encode(SALT_DOMAIN, block.chainid, facilityKey));
        console2.log("CREATE2 salt:", vm.toString(salt));

        bytes memory createReturndata =
            addToBatch(factoryAddress, abi.encodeCall(ILCCVaultFactoryCreate2.createVault, (params, salt)));
        address vault = abi.decode(createReturndata, (address));
        require(vault == factory.predictVaultAddress(params, salt), "Simulated vault address mismatch");
        require(factory.isVault(vault), "Simulated vault is not registered");
        _requireLCCWiring(vault, USD3_PROXY);

        addToBatch(USD3_PROXY, abi.encodeCall(IUSD3Registry.setSupplyCapExempt, (vault, true)));
        addToBatch(USD3_PROXY, abi.encodeCall(IUSD3Registry.setRingFenceConduit, (vault, true)));

        require(usd3.supplyCapExempt(vault), "Simulated supply-cap exemption missing");
        require(usd3.ringFenceConduit(vault), "Simulated ring-fence conduit missing");
        require(getTotalBatches() == 1, "SafeHelper split the atomic batch");
        (uint256 txCount,) = getBatchInfo(0);
        require(txCount == 3, "Atomic LCC batch must contain three calls");

        console2.log("Prepared one atomic Safe batch with three calls");
        console2.log("Simulated vault:", vault);
        console2.log("Simulated factory count:", factory.numVaults());
        console2.log("");

        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully!");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }

        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Safe signers approve and execute the single batch");
        console2.log("  2. Verify the deployed vault with --sig \"verify(address)\" %s", vault);
    }

    function run(string memory jsonPath) external {
        this.run(jsonPath, false);
    }

    /// @notice Print factory and USD3 registration status for a deployed vault.
    function verify(address vault) external view {
        address factoryAddress = vm.envAddress("LCC_FACTORY");
        require(factoryAddress != address(0), "LCC_FACTORY not set");
        require(factoryAddress.code.length > 0, "LCC_FACTORY has no code");

        LCCVaultFactory factory = LCCVaultFactory(factoryAddress);
        IUSD3Registry usd3 = IUSD3Registry(USD3_PROXY);

        bool registered = factory.isVault(vault);
        bool supplyCapEnabled = usd3.supplyCapExempt(vault);
        bool ringFenceEnabled = usd3.ringFenceConduit(vault);

        console2.log("=== Verifying LCC Vault Registration ===");
        console2.log("Vault:", vault);
        console2.log(registered ? "PASS: factory registry" : "FAIL: factory registry");
        console2.log(supplyCapEnabled ? "PASS: USD3 supply-cap exemption" : "FAIL: USD3 supply-cap exemption");
        console2.log(ringFenceEnabled ? "PASS: USD3 ring-fence conduit" : "FAIL: USD3 ring-fence conduit");
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
