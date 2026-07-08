pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IUSD3} from "./utils/Setup.sol";
import {USD3} from "../../../src/usd3/USD3.sol";

contract ShutdownTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_shutdownCanWithdraw(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // For USD3, check aToken balance instead of USDC
        address strategyAsset = strategy.asset();
        if (strategyAsset != address(asset)) {
            // Strategy uses aTokenVault, check aToken balance
            assertGe(ERC20(strategyAsset).balanceOf(user), _amount, "!final balance");
        } else {
            assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
        }
    }

    function test_emergencyWithdraw_maxUint(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // should be able to pass uint 256 max and not revert.
        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(type(uint256).max);

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // For USD3, check aToken balance instead of USDC
        address strategyAsset = strategy.asset();
        if (strategyAsset != address(asset)) {
            // Strategy uses aTokenVault, check aToken balance
            assertGe(ERC20(strategyAsset).balanceOf(user), _amount, "!final balance");
        } else {
            assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
        }
    }

    function test_reportDoesNotRedeployFreedFundsAfterShutdown() public {
        uint256 amount = 100_000e6;
        USD3 usd3Strategy = USD3(address(strategy));

        mintAndDepositIntoStrategy(strategy, user, amount);
        assertGt(usd3Strategy.suppliedWaUSDC(), 0, "funds should start deployed");

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(amount);

        uint256 idleBeforeReport = asset.balanceOf(address(strategy));
        assertEq(usd3Strategy.suppliedWaUSDC(), 0, "emergency withdraw should free Morpho supply");
        assertEq(usd3Strategy.balanceOfWaUSDC(), 0, "freed waUSDC should be unwrapped");
        assertGt(idleBeforeReport, 0, "strategy should hold idle USDC");

        vm.prank(keeper);
        strategy.report();

        assertEq(usd3Strategy.suppliedWaUSDC(), 0, "report should not redeploy during shutdown");
        assertEq(usd3Strategy.balanceOfWaUSDC(), 0, "report should not wrap idle USDC during shutdown");
        assertEq(asset.balanceOf(address(strategy)), idleBeforeReport, "idle USDC should remain idle");
    }

    function test_tendDoesNotRebalanceAfterShutdown() public {
        uint256 amount = 100_000e6;
        USD3 usd3Strategy = USD3(address(strategy));

        mintAndDepositIntoStrategy(strategy, user, amount);
        uint256 deployedBeforeShutdown = usd3Strategy.suppliedWaUSDC();
        assertGt(deployedBeforeShutdown, 0, "funds should start deployed");

        setMaxOnCredit(5000);

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        vm.prank(keeper);
        strategy.tend();

        assertEq(usd3Strategy.suppliedWaUSDC(), deployedBeforeShutdown, "tend should be a no-op during shutdown");
        assertEq(usd3Strategy.balanceOfWaUSDC(), 0, "tend should not pull funds during shutdown");
    }

    function test_tendTriggerFalseAfterShutdown() public {
        uint256 amount = 100_000e6;

        mintAndDepositIntoStrategy(strategy, user, amount);
        setMaxOnCredit(5000);

        (bool shouldTendBeforeShutdown,) = strategy.tendTrigger();
        assertTrue(shouldTendBeforeShutdown, "deployment drift should trigger tend before shutdown");

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        (bool shouldTendAfterShutdown,) = strategy.tendTrigger();
        assertFalse(shouldTendAfterShutdown, "shutdown should suppress tend trigger");
    }

    // TODO: Add tests for any emergency function added.
}
