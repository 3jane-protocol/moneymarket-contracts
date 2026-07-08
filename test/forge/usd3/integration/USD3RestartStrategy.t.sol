// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {IUSD3} from "../../../../src/usd3/interfaces/IUSD3.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {IMorpho} from "../../../../src/interfaces/IMorpho.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {TokenizedStrategyStorageLib} from "@periphery/libraries/TokenizedStrategyStorageLib.sol";
import {ERC1967Utils} from "../../../../lib/openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Initializable} from "../../../../lib/openzeppelin/contracts/proxy/utils/Initializable.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract USD3Restartable is USD3 {
    function restartStrategy() external reinitializer(3) {
        TokenizedStrategyStorageLib.getStrategyStorage().shutdown = false;
    }
}

contract USD3RestartStrategyTest is Setup {
    uint256 internal constant NOT_ENTERED = 1;
    uint256 internal constant ENTERED_OFFSET = 160;
    uint256 internal constant SHUTDOWN_OFFSET = 168;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function test_restartStrategyReopensShutdownStrategyAtomically() public {
        (USD3Restartable usd3, ProxyAdmin proxyAdmin) = _deployRestartableUSD3();
        ITokenizedStrategy tokenized = ITokenizedStrategy(address(usd3));

        _deposit(usd3, alice, 1_000e6);

        vm.prank(management);
        tokenized.shutdownStrategy();

        assertTrue(tokenized.isShutdown(), "strategy should be shutdown");
        _assertPackedStatusSlot(address(usd3), NOT_ENTERED, 1);

        _upgradeAndRestart(usd3, proxyAdmin);

        assertFalse(tokenized.isShutdown(), "strategy should be restarted");
        _assertPackedStatusSlot(address(usd3), NOT_ENTERED, 0);
        assertGt(tokenized.maxDeposit(bob), 0, "deposits should be available");

        uint256 shares = _deposit(usd3, bob, 500e6);
        assertGt(shares, 0, "deposit should succeed after restart");
    }

    function test_restartStrategyCanOnlyRunOnce() public {
        (USD3Restartable usd3, ProxyAdmin proxyAdmin) = _deployRestartableUSD3();
        ITokenizedStrategy tokenized = ITokenizedStrategy(address(usd3));

        _deposit(usd3, alice, 1_000e6);

        vm.prank(management);
        tokenized.shutdownStrategy();

        _upgradeAndRestart(usd3, proxyAdmin);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        usd3.restartStrategy();
    }

    function test_restartStrategySupportsEmergencyWithdrawRecoveryPath() public {
        (USD3Restartable usd3, ProxyAdmin proxyAdmin) = _deployRestartableUSD3();
        ITokenizedStrategy tokenized = ITokenizedStrategy(address(usd3));

        _deposit(usd3, alice, 1_000e6);

        vm.prank(management);
        tokenized.shutdownStrategy();

        vm.prank(management);
        tokenized.emergencyWithdraw(1_000e6);

        _upgradeAndRestart(usd3, proxyAdmin);

        uint256 shares = _deposit(usd3, bob, 500e6);

        vm.prank(bob);
        uint256 withdrawn = tokenized.redeem(shares, bob, bob);

        assertApproxEqAbs(withdrawn, 500e6, 1, "redeem should work after restart");
    }

    function _deployRestartableUSD3() internal returns (USD3Restartable usd3, ProxyAdmin proxyAdmin) {
        USD3Restartable implementation = new USD3Restartable();
        USD3 setupStrategy = USD3(address(strategy));

        bytes memory initData = abi.encodeWithSelector(
            USD3.initialize.selector,
            address(setupStrategy.morphoCredit()),
            setupStrategy.marketId(),
            management,
            keeper
        );

        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), address(this), initData);

        proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), ERC1967Utils.ADMIN_SLOT)))));
        usd3 = USD3Restartable(address(proxy));

        usd3.reinitialize();

        vm.prank(management);
        ITokenizedStrategy(address(usd3)).setEmergencyAdmin(emergencyAdmin);

        IMorpho morpho = setupStrategy.morphoCredit();
        vm.prank(morpho.owner());
        MorphoCredit(address(morpho)).setUsd3(address(usd3));
    }

    function _upgradeAndRestart(USD3Restartable usd3, ProxyAdmin proxyAdmin) internal {
        USD3Restartable newImplementation = new USD3Restartable();
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(usd3)),
            address(newImplementation),
            abi.encodeCall(USD3Restartable.restartStrategy, ())
        );
    }

    function _deposit(USD3 usd3, address account, uint256 amount) internal returns (uint256 shares) {
        mintAndDepositIntoStrategy(IUSD3(address(usd3)), account, amount);
        shares = ITokenizedStrategy(address(usd3)).balanceOf(account);
    }

    function _assertPackedStatusSlot(address usd3, uint256 expectedEntered, uint256 expectedShutdown) internal view {
        uint256 value = uint256(vm.load(usd3, TokenizedStrategyStorageLib.emergencyAdminSlot()));

        assertEq(address(uint160(value)), emergencyAdmin, "emergency admin mismatch");
        assertEq((value >> ENTERED_OFFSET) & 0xFF, expectedEntered, "entered mismatch");
        assertEq((value >> SHUTDOWN_OFFSET) & 0xFF, expectedShutdown, "shutdown mismatch");
    }
}
