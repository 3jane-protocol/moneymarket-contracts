// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MainnetForkBase
 * @notice Base contract for mainnet fork tests with opt-in mechanism
 * @dev Fork tests are skipped unless ETH_RPC_URL environment variable is set
 */
abstract contract MainnetForkBase is Test {
    // Mainnet addresses
    address constant USD3_PROXY = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address constant WAUSDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant MORPHO_CREDIT = address(0); // TODO: Add actual MorphoCredit address when deployed

    // Fork configuration
    uint256 public mainnetFork;
    uint256 constant FORK_BLOCK = 23400200; // Fixed block for reproducibility

    // Test state
    bool public isForkTest;

    /**
     * @dev Modifier to skip tests when ETH_RPC_URL is not set
     */
    modifier requiresFork() {
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        _;
    }

    /**
     * @dev Sets up the fork if ETH_RPC_URL is provided
     */
    function setUp() public virtual {
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string(""));

        if (bytes(rpcUrl).length == 0) {
            // Skip all fork tests if no RPC URL provided
            vm.skip(true);
            return;
        }

        // Create and select fork
        mainnetFork = vm.createFork(rpcUrl, FORK_BLOCK);
        vm.selectFork(mainnetFork);
        isForkTest = true;

        // Label addresses for better trace output
        vm.label(USD3_PROXY, "USD3_PROXY");
        vm.label(WAUSDC, "waUSDC");
        vm.label(USDC, "USDC");
    }

    /**
     * @dev Helper to get USDC token interface
     */
    function usdc() internal pure returns (IERC20) {
        return IERC20(USDC);
    }

    /**
     * @dev Helper to get waUSDC token interface
     */
    function waUSDC() internal pure returns (IERC20) {
        return IERC20(WAUSDC);
    }

    /**
     * @dev Helper to deal USDC to an address for testing
     * @param to Address to receive USDC
     * @param amount Amount of USDC (6 decimals)
     */
    function dealUSDC(address to, uint256 amount) internal {
        // Find a whale or use deal cheat code
        deal(USDC, to, amount);
    }

    /**
     * @dev Helper to deal waUSDC to an address for testing
     * @param to Address to receive waUSDC
     * @param amount Amount of waUSDC (6 decimals)
     */
    function dealWaUSDC(address to, uint256 amount) internal {
        deal(WAUSDC, to, amount);
    }

    /**
     * @dev Helper to impersonate an account
     * @param account Address to impersonate
     */
    function impersonate(address account) internal {
        vm.startPrank(account);
    }

    /**
     * @dev Helper to stop impersonating
     */
    function stopImpersonate() internal {
        vm.stopPrank();
    }

    /**
     * @dev Helper to advance time
     * @param secondsToAdvance Number of seconds to advance
     */
    function advanceTime(uint256 secondsToAdvance) internal {
        vm.warp(block.timestamp + secondsToAdvance);
    }

    /**
     * @dev Helper to advance blocks
     * @param blocksToAdvance Number of blocks to advance
     */
    function advanceBlocks(uint256 blocksToAdvance) internal {
        vm.roll(block.number + blocksToAdvance);
    }
}
