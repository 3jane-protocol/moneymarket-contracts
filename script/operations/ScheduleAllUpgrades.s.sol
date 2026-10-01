// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";
import {ITimelockController} from "../../src/interfaces/ITimelockController.sol";
import {
    ITransparentUpgradeableProxy,
    ProxyAdmin
} from "../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title ScheduleAllUpgrades
 * @notice Schedule all v1.1 upgrades (MorphoCredit, IRM, USD3, sUSD3) in single Timelock batch
 * @dev Part of v1.1 upgrade process - combines all 4 ProxyAdmin upgrades into one operation
 *
 *      Single Timelock Operation:
 *      - MorphoCredit ProxyAdmin.upgradeAndCall()
 *      - IRM ProxyAdmin.upgradeAndCall()
 *      - USD3 ProxyAdmin.upgradeAndCall()
 *      - sUSD3 ProxyAdmin.upgradeAndCall()
 *
 *      Usage:
 *      1. Deploy all 4 new implementations (scripts 10-13)
 *      2. Run this script to schedule all upgrades
 *      3. Wait 2 days for timelock delay
 *      4. Execute via ExecuteAllUpgrades.s.sol
 *
 *      Advantages:
 *      - Single operation ID to track
 *      - All upgrades happen atomically
 *      - Simpler workflow than individual scheduling
 */
contract ScheduleAllUpgrades is Script, SafeHelper, TimelockHelper {
    /// @notice TimelockController address (mainnet)
    address private constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;

    /// @notice Proxy addresses (mainnet)
    address private constant MORPHO_CREDIT_PROXY = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;
    address private constant IRM_PROXY = 0x1d434D2899f81F3C3fdf52C814A6E23318f9C7Df;
    address private constant USD3_PROXY = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address private constant SUSD3_PROXY = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;

    /// @notice ProxyAdmin addresses (mainnet) - each proxy has its own ProxyAdmin
    address private constant MORPHO_PROXY_ADMIN = 0x0b0dA0C2D0e21C43C399c09f830e46E3341fe1D4;
    address private constant IRM_PROXY_ADMIN = 0x5B7961DaFce9e412d26d6B92d06A9e0db3E3c7CF;
    address private constant USD3_PROXY_ADMIN = 0x41C838664a9C64905537fF410333B9f5964cC596;
    address private constant SUSD3_PROXY_ADMIN = 0xecda55c32966B00592Ed3922E386063e1Bc752c2;

    /// @notice EIP-1967 admin slot
    bytes32 private constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    /// @notice Main execution function
    /// @param morphoCreditImpl Address of new MorphoCredit implementation
    /// @param irmImpl Address of new AdaptiveCurveIrm implementation
    /// @param usd3Impl Address of new USD3 implementation
    /// @param susd3Impl Address of new sUSD3 implementation
    /// @param send Whether to send transaction to Safe API (true) or just simulate (false)
    function run(address morphoCreditImpl, address irmImpl, address usd3Impl, address susd3Impl, bool send)
        public
        isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF))
        isTimelock(TIMELOCK)
    {
        console2.log("=== Scheduling All v1.1 Upgrades via Safe + Timelock ===");
        console2.log("");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("Timelock address:", TIMELOCK);
        console2.log("");

        // Verify all ProxyAdmin addresses
        console2.log("Verifying ProxyAdmin addresses...");
        require(getProxyAdmin(MORPHO_CREDIT_PROXY) == MORPHO_PROXY_ADMIN, "MorphoCredit ProxyAdmin mismatch");
        require(getProxyAdmin(IRM_PROXY) == IRM_PROXY_ADMIN, "IRM ProxyAdmin mismatch");
        require(getProxyAdmin(USD3_PROXY) == USD3_PROXY_ADMIN, "USD3 ProxyAdmin mismatch");
        require(getProxyAdmin(SUSD3_PROXY) == SUSD3_PROXY_ADMIN, "sUSD3 ProxyAdmin mismatch");
        console2.log("All ProxyAdmin addresses verified");
        console2.log("");

        // Log implementation addresses
        console2.log("New Implementations:");
        console2.log("  MorphoCredit:", morphoCreditImpl);
        console2.log("  IRM:         ", irmImpl);
        console2.log("  USD3:        ", usd3Impl);
        console2.log("  sUSD3:       ", susd3Impl);
        console2.log("");

        // Validate inputs
        require(morphoCreditImpl != address(0), "MorphoCredit implementation cannot be zero");
        require(irmImpl != address(0), "IRM implementation cannot be zero");
        require(usd3Impl != address(0), "USD3 implementation cannot be zero");
        require(susd3Impl != address(0), "sUSD3 implementation cannot be zero");

        uint256 delay = getMinDelay(TIMELOCK);
        console2.log("Timelock delay:", delay / 1 days, "days");
        console2.log("Send to Safe:", send);
        console2.log("");

        // Prepare single batch operation with all 4 upgrades
        address[] memory targets = new address[](4);
        uint256[] memory values = new uint256[](4);
        bytes[] memory datas = new bytes[](4);

        // 1. MorphoCredit upgrade
        targets[0] = MORPHO_PROXY_ADMIN;
        values[0] = 0;
        datas[0] = abi.encodeCall(
            ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(MORPHO_CREDIT_PROXY), morphoCreditImpl, "")
        );

        // 2. IRM upgrade
        targets[1] = IRM_PROXY_ADMIN;
        values[1] = 0;
        datas[1] = abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(IRM_PROXY), irmImpl, ""));

        // 3. USD3 upgrade (with reinitialize)
        targets[2] = USD3_PROXY_ADMIN;
        values[2] = 0;
        datas[2] = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(USD3_PROXY), usd3Impl, abi.encodeWithSignature("reinitialize()"))
        );

        // 4. sUSD3 upgrade
        targets[3] = SUSD3_PROXY_ADMIN;
        values[3] = 0;
        datas[3] = abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(SUSD3_PROXY), susd3Impl, ""));

        // Generate salt and predecessor
        bytes32 salt = generateSalt("All v1.1 Upgrades (MorphoCredit, IRM, USD3, sUSD3)");
        bytes32 predecessor = bytes32(0);

        // Calculate operation ID
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("=== Timelock Batch Operation ===");
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Salt:", vm.toString(salt));
        console2.log("");
        console2.log("Batch includes 4 ProxyAdmin upgrades:");
        console2.log("  1. MorphoCredit ProxyAdmin.upgradeAndCall()");
        console2.log("  2. IRM ProxyAdmin.upgradeAndCall()");
        console2.log("  3. USD3 ProxyAdmin.upgradeAndCall()");
        console2.log("  4. sUSD3 ProxyAdmin.upgradeAndCall()");
        console2.log("");

        // Check if operation already exists
        if (isOperation(TIMELOCK, operationId)) {
            console2.log("[WARNING] Operation already exists!");
            logOperationState(TIMELOCK, operationId);
            revert("Operation already scheduled");
        }

        // Encode the scheduleBatch call
        bytes memory scheduleCalldata = encodeScheduleBatch(targets, values, datas, predecessor, salt, delay);

        // Add to Safe batch
        console2.log("Adding scheduleBatch call to Safe transaction...");
        addToBatch(TIMELOCK, scheduleCalldata);

        // Execute via Safe
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
        console2.log("=== IMPORTANT: Save this information ===");
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Ready for execution at:", block.timestamp + delay);
        console2.log("Execution timestamp (unix):", block.timestamp + delay);
        console2.log("");
        console2.log("=== NEXT STEP: Execute after 2-day delay ===");
        console2.log("");
        console2.log("Use ExecuteAllUpgrades.s.sol to execute all upgrades atomically:");
        console2.log("  yarn script:forge script/operations/ExecuteAllUpgrades.s.sol \\");
        console2.log("    --sig \"run(bytes32,uint256,bool)\" \\");
        console2.log("    ", vm.toString(operationId), "<prevUnlockTime> false");
        console2.log("");
        console2.log("CRITICAL: ExecuteAllUpgrades wraps Timelock execution in USD3 atomic batch");
        console2.log("CRITICAL: This prevents user losses during waUSDC -> USDC migration");
    }

    /// @notice Retrieve the ProxyAdmin address from a proxy contract
    function getProxyAdmin(address proxyContract) internal view returns (address) {
        bytes32 adminSlot = vm.load(proxyContract, ADMIN_SLOT);
        return address(uint160(uint256(adminSlot)));
    }

    /// @notice Dry run example
    function run(bool send) external {
        address morphoImpl = vm.envAddress("MORPHO_CREDIT_IMPL");
        address irmImplAddr = vm.envAddress("IRM_IMPL");
        address usd3ImplAddr = vm.envAddress("USD3_IMPL");
        address susd3ImplAddr = vm.envAddress("SUSD3_IMPL");
        run(morphoImpl, irmImplAddr, usd3ImplAddr, susd3ImplAddr, send);
    }
}
