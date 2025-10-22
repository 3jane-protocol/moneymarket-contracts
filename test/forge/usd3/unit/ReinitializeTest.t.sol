// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    TransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {console2} from "forge-std/console2.sol";
import {IMorpho, IMorphoCredit} from "../../../../src/interfaces/IMorpho.sol";

/**
 * @title Reinitialize Test
 * @notice Tests the reinitialize function for upgrading from waUSDC to USDC
 * @dev Verifies proper initialization, state preservation, and access control
 */
contract ReinitializeTest is Setup {
    USD3 public usd3Strategy;
    address public alice = makeAddr("alice");
    address public proxyAdmin;
    address public usd3Proxy;

    // Storage slot for asset in TokenizedStrategy
    bytes32 constant ASSET_SLOT = bytes32(uint256(keccak256("yearn.base.strategy.storage")) - 1);

    function setUp() public override {
        super.setUp();
        usd3Strategy = USD3(address(strategy));
        usd3Proxy = address(strategy);

        // Fund test user with USDC
        airdrop(asset, alice, 10000e6);
    }

    function test_reinitializeUpdatesAsset() public {
        // Deploy a fresh USD3 without reinitialize being called
        USD3 freshImpl = new USD3();
        ProxyAdmin freshProxyAdmin = new ProxyAdmin(address(this));

        // Initialize with waUSDC as asset (simulating old version)
        bytes memory initData = abi.encodeWithSelector(
            USD3.initialize.selector, address(usd3Strategy.morphoCredit()), usd3Strategy.marketId(), management, keeper
        );

        TransparentUpgradeableProxy freshProxy =
            new TransparentUpgradeableProxy(address(freshImpl), address(freshProxyAdmin), initData);

        USD3 freshUSD3 = USD3(address(freshProxy));

        // Before reinitialize, asset should be waUSDC (from initialize)
        // Note: initialize doesn't set asset, so we need to check after reinitialize

        // Call reinitialize
        freshUSD3.reinitialize();

        // After reinitialize, asset should be USDC
        address expectedUSDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        assertEq(address(ITokenizedStrategy(address(freshUSD3)).asset()), expectedUSDC, "Asset not updated to USDC");

        // Check TokenizedStrategy storage slot is also updated
        bytes32 storedAsset = vm.load(address(freshProxy), ASSET_SLOT);
        assertEq(address(uint160(uint256(storedAsset))), expectedUSDC, "TokenizedStrategy slot not updated");
    }

    function test_reinitializeApprovesWaUSDC() public {
        // Deploy fresh instance
        USD3 freshImpl = new USD3();
        ProxyAdmin freshProxyAdmin = new ProxyAdmin(address(this));

        bytes memory initData = abi.encodeWithSelector(
            USD3.initialize.selector, address(usd3Strategy.morphoCredit()), usd3Strategy.marketId(), management, keeper
        );

        TransparentUpgradeableProxy freshProxy =
            new TransparentUpgradeableProxy(address(freshImpl), address(freshProxyAdmin), initData);

        USD3 freshUSD3 = USD3(address(freshProxy));

        // Check allowance before reinitialize
        uint256 allowanceBefore = IERC20(address(asset)).allowance(address(freshUSD3), address(waUSDC));
        assertEq(allowanceBefore, 0, "Should have no allowance before reinitialize");

        // Call reinitialize
        freshUSD3.reinitialize();

        // Check waUSDC has max approval for USDC
        uint256 allowanceAfter = IERC20(address(asset)).allowance(address(freshUSD3), address(waUSDC));
        assertEq(allowanceAfter, type(uint256).max, "waUSDC should have max approval");
    }

    function test_reinitializeOnlyOnce() public {
        // Deploy fresh instance
        USD3 freshImpl = new USD3();
        ProxyAdmin freshProxyAdmin = new ProxyAdmin(address(this));

        bytes memory initData = abi.encodeWithSelector(
            USD3.initialize.selector, address(usd3Strategy.morphoCredit()), usd3Strategy.marketId(), management, keeper
        );

        TransparentUpgradeableProxy freshProxy =
            new TransparentUpgradeableProxy(address(freshImpl), address(freshProxyAdmin), initData);

        USD3 freshUSD3 = USD3(address(freshProxy));

        // First reinitialize should work
        freshUSD3.reinitialize();

        // Second reinitialize should fail
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        freshUSD3.reinitialize();
    }

    function test_reinitializePreservesState() public {
        // Note: The reinitialize function was already called in Setup.sol
        // This test verifies that state was preserved during that upgrade

        // First deposit some USDC to verify the strategy is working
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        uint256 shares = ITokenizedStrategy(address(usd3Strategy)).deposit(1000e6, alice);
        vm.stopPrank();

        // Verify the strategy is functioning correctly after reinitialize
        assertGt(shares, 0, "Should receive shares");
        assertEq(ITokenizedStrategy(address(usd3Strategy)).balanceOf(alice), shares, "Alice should have shares");

        // Verify asset is USDC (not waUSDC)
        address expectedUSDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        assertEq(address(ITokenizedStrategy(address(usd3Strategy)).asset()), expectedUSDC, "Asset should be USDC");

        // Verify management and keeper are preserved
        assertEq(ITokenizedStrategy(address(usd3Strategy)).management(), management, "Management preserved");
        assertEq(ITokenizedStrategy(address(usd3Strategy)).keeper(), keeper, "Keeper preserved");

        // Verify waUSDC has max approval
        uint256 allowance = IERC20(address(asset)).allowance(address(usd3Strategy), address(waUSDC));
        assertEq(allowance, type(uint256).max, "waUSDC should have max approval");

        // Verify withdrawals work correctly
        vm.startPrank(alice);
        ITokenizedStrategy(address(usd3Strategy)).approve(address(usd3Strategy), shares);
        uint256 withdrawn = ITokenizedStrategy(address(usd3Strategy)).redeem(shares, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(withdrawn, 1000e6, 1, "Should withdraw deposited amount");
    }

    function test_reinitializeUpdatesTokenizedStrategySlot() public {
        // Deploy fresh instance
        USD3 freshImpl = new USD3();
        ProxyAdmin freshProxyAdmin = new ProxyAdmin(address(this));

        bytes memory initData = abi.encodeWithSelector(
            USD3.initialize.selector, address(usd3Strategy.morphoCredit()), usd3Strategy.marketId(), management, keeper
        );

        TransparentUpgradeableProxy freshProxy =
            new TransparentUpgradeableProxy(address(freshImpl), address(freshProxyAdmin), initData);

        USD3 freshUSD3 = USD3(address(freshProxy));

        // Call reinitialize
        freshUSD3.reinitialize();

        // Check that the asset in TokenizedStrategy storage is updated
        address expectedUSDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

        // Read storage slot 1 (asset slot in TokenizedStrategy)
        bytes32 slot1 = vm.load(address(freshProxy), ASSET_SLOT);
        address storedAsset = address(uint160(uint256(slot1)));

        assertEq(storedAsset, expectedUSDC, "TokenizedStrategy asset slot not updated");
        assertEq(
            address(ITokenizedStrategy(address(freshUSD3)).asset()), expectedUSDC, "Asset getter returns wrong value"
        );
    }

    function test_cannotReinitializeAgain() public {
        // The main strategy should already have reinitialize called in Setup
        // Trying to call it again should fail
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        usd3Strategy.reinitialize();
    }

    function test_reinitializeWithExistingWaUSDCPosition() public {
        // Deploy fresh instance
        USD3 freshImpl = new USD3();
        ProxyAdmin freshProxyAdmin = new ProxyAdmin(address(this));

        bytes memory initData = abi.encodeWithSelector(
            USD3.initialize.selector, address(usd3Strategy.morphoCredit()), usd3Strategy.marketId(), management, keeper
        );

        TransparentUpgradeableProxy freshProxy =
            new TransparentUpgradeableProxy(address(freshImpl), address(freshProxyAdmin), initData);

        USD3 freshUSD3 = USD3(address(freshProxy));

        // Simulate existing waUSDC position by giving the contract some waUSDC
        deal(address(asset), address(this), 1000e6);
        asset.approve(address(waUSDC), 1000e6);
        waUSDC.deposit(1000e6, address(freshUSD3));

        uint256 waUSDCBalanceBefore = waUSDC.balanceOf(address(freshUSD3));
        assertGt(waUSDCBalanceBefore, 0, "Should have waUSDC before reinitialize");

        // Call reinitialize
        freshUSD3.reinitialize();

        // waUSDC balance should be unchanged
        uint256 waUSDCBalanceAfter = waUSDC.balanceOf(address(freshUSD3));
        assertEq(waUSDCBalanceAfter, waUSDCBalanceBefore, "waUSDC balance should be preserved");

        // Asset should now be USDC
        address expectedUSDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        assertEq(address(ITokenizedStrategy(address(freshUSD3)).asset()), expectedUSDC, "Asset should be USDC");
    }

    function test_reinitializeEnablesNewDeposits() public {
        // The main strategy already has reinitialize called in Setup.sol
        // This test verifies that USDC deposits work correctly after reinitialize

        // Verify asset is USDC after reinitialize
        address expectedUSDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        assertEq(address(ITokenizedStrategy(address(usd3Strategy)).asset()), expectedUSDC, "Asset should be USDC");

        // Verify waUSDC has max approval
        uint256 allowance = IERC20(address(asset)).allowance(address(usd3Strategy), address(waUSDC));
        assertEq(allowance, type(uint256).max, "waUSDC should have max approval");

        // Test depositing USDC
        deal(address(asset), alice, 1000e6);

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        uint256 shares = ITokenizedStrategy(address(usd3Strategy)).deposit(1000e6, alice);
        vm.stopPrank();

        assertGt(shares, 0, "Should receive shares after deposit");
        assertEq(asset.balanceOf(alice), 0, "All USDC should be deposited");

        // Check that it was wrapped to waUSDC internally
        uint256 totalWaUSDC = usd3Strategy.balanceOfWaUSDC() + usd3Strategy.suppliedWaUSDC();
        assertEq(totalWaUSDC, 1000e6, "Should have wrapped to waUSDC");

        // Test withdrawal to ensure round-trip works
        vm.startPrank(alice);
        ITokenizedStrategy(address(usd3Strategy)).approve(address(usd3Strategy), shares);
        uint256 withdrawn = ITokenizedStrategy(address(usd3Strategy)).redeem(shares, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(withdrawn, 1000e6, 1, "Should withdraw original amount");
        assertEq(asset.balanceOf(alice), withdrawn, "Should receive USDC back");
    }
}
