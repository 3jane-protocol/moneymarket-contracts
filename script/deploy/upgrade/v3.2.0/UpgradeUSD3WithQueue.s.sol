// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {
    TransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {USD3WithdrawQueue} from "../../../../src/usd3/queue/USD3WithdrawQueue.sol";

/// @title UpgradeUSD3WithQueue
/// @notice Deploys the USD3 withdraw queue and a queue-enabled USD3 implementation.
/// @dev The proxy upgrade itself should be batched through the production ProxyAdmin/Safe
/// after reviewing the logs. After the upgrade lands, management must call
/// `setEntriesPaused(false)` on the queue to open new entries (queues deploy paused).
contract UpgradeUSD3WithQueue is Script {
    /// @notice Deploy the withdraw-queue proxy and the queue-aware USD3 implementation.
    /// @dev Requires env vars:
    /// - `USD3_PROXY`: address of the existing USD3 transparent proxy.
    /// - `QUEUE_PROXY_OWNER`: address that will own the new queue's `ProxyAdmin`.
    /// @return queue Address of the deployed `USD3WithdrawQueue` proxy.
    /// @return implementation Address of the new USD3 implementation (with queue immutable set).
    function run() external returns (address queue, address implementation) {
        address usd3Proxy = vm.envAddress("USD3_PROXY");
        address queueProxyOwner = vm.envAddress("QUEUE_PROXY_OWNER");
        require(usd3Proxy != address(0), "USD3_PROXY not set");
        require(queueProxyOwner != address(0), "QUEUE_PROXY_OWNER not set");

        console2.log("=== Deploying USD3 Withdraw Queue Upgrade ===");
        console2.log("USD3 proxy:", usd3Proxy);

        vm.startBroadcast();

        USD3WithdrawQueue queueImplementation = new USD3WithdrawQueue(usd3Proxy);
        bytes memory queueInitData = abi.encodeWithSelector(USD3WithdrawQueue.initialize.selector);
        TransparentUpgradeableProxy withdrawQueueProxy =
            new TransparentUpgradeableProxy(address(queueImplementation), queueProxyOwner, queueInitData);
        USD3 usd3Implementation = new USD3(address(withdrawQueueProxy));

        vm.stopBroadcast();

        queue = address(withdrawQueueProxy);
        implementation = address(usd3Implementation);

        console2.log("USD3WithdrawQueue:", queue);
        console2.log("USD3WithdrawQueue implementation:", address(queueImplementation));
        console2.log("USD3 implementation:", implementation);
        console2.log("");
        console2.log("Next step: upgrade USD3 proxy to the new implementation through ProxyAdmin.");
        console2.log("After the upgrade, call setEntriesPaused(false) on the queue.");
    }
}
