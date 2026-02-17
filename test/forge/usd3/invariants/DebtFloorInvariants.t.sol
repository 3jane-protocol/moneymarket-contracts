// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {sUSD3} from "../../../../src/usd3/sUSD3.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {
    TransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {DebtFloorHandler} from "./DebtFloorHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DebtFloorInvariantsTest
 * @notice Invariant tests specific to sUSD3 debt-floor behavior
 */
contract DebtFloorInvariantsTest is StdInvariant, Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;
    MockProtocolConfig public protocolConfig;
    DebtFloorHandler public handler;

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));
        protocolConfig = MockProtocolConfig(MorphoCredit(address(usd3Strategy.morphoCredit())).protocolConfig());

        sUSD3 susd3Implementation = new sUSD3();
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(management);
        TransparentUpgradeableProxy susd3Proxy = new TransparentUpgradeableProxy(
            address(susd3Implementation),
            address(susd3ProxyAdmin),
            abi.encodeCall(sUSD3.initialize, (address(usd3Strategy), management, keeper))
        );
        susd3Strategy = sUSD3(address(susd3Proxy));

        vm.prank(management);
        usd3Strategy.setSUSD3(address(susd3Strategy));

        // Configure floor/cap environment.
        setMaxOnCredit(8000);
        setMorphoDebtCap(20_000_000e6);
        protocolConfig.setConfig(keccak256("MIN_SUSD3_BACKING_RATIO"), 3000); // 30%

        // Seed liquidity and debt.
        address alice = makeAddr("debt-floor-alice");
        deal(address(underlyingAsset), alice, 10_000_000e6);
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), type(uint256).max);
        usd3Strategy.deposit(5_000_000e6, alice);
        vm.stopPrank();

        createMarketDebt(makeAddr("debt-floor-borrower"), 1_000_000e6);

        vm.startPrank(alice);
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 500_000e6);
        susd3Strategy.deposit(500_000e6, alice);
        vm.stopPrank();

        address[] memory handlerActors = new address[](4);
        handlerActors[0] = alice;
        for (uint256 i = 1; i < handlerActors.length; ++i) {
            handlerActors[i] = address(uint160(uint256(keccak256(abi.encode("debt-floor-actor", i - 1)))));
        }
        handler = new DebtFloorHandler(
            address(usd3Strategy), address(susd3Strategy), address(underlyingAsset), keeper, handlerActors
        );
        _configureTargets();

        excludeSender(address(0));
        excludeSender(address(this));
        excludeSender(management);
        excludeSender(emergencyAdmin);
    }

    function _configureTargets() internal {
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = DebtFloorHandler.depositUSD3.selector;
        selectors[1] = DebtFloorHandler.withdrawUSD3.selector;
        selectors[2] = DebtFloorHandler.depositSUSD3.selector;
        selectors[3] = DebtFloorHandler.startCooldown.selector;
        selectors[4] = DebtFloorHandler.cancelCooldown.selector;
        selectors[5] = DebtFloorHandler.withdrawSUSD3.selector;
        selectors[6] = DebtFloorHandler.reportUSD3.selector;
        selectors[7] = DebtFloorHandler.skipTime.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_debtFloorMatchesExpectedFormula() public view {
        (,, uint256 totalBorrowAssetsWaUSDC,) = usd3Strategy.getMarketLiquidity();
        uint256 debtUsdc = usd3Strategy.WAUSDC().convertToAssets(totalBorrowAssetsWaUSDC);
        uint256 backingRatio = susd3Strategy.minBackingRatio();
        uint256 expectedFloor = (debtUsdc * backingRatio) / 10_000;

        assertEq(susd3Strategy.getSubordinatedDebtFloorInUSDC(), expectedFloor, "debt floor formula mismatch");
    }

    function invariant_depositLimitTracksSubordinationCap() public view {
        uint256 capUsdc = susd3Strategy.getSubordinatedDebtCapInUSDC();
        uint256 holdingsUsdc = ITokenizedStrategy(address(usd3Strategy))
            .convertToAssets(IERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy)));

        uint256 expectedLimit;
        if (capUsdc > holdingsUsdc) {
            expectedLimit = ITokenizedStrategy(address(usd3Strategy)).convertToShares(capUsdc - holdingsUsdc);
        }

        uint256 actorCount = handler.actorCount();
        for (uint256 i; i < actorCount; ++i) {
            address actor = handler.actorAt(i);
            uint256 limit = susd3Strategy.availableDepositLimit(actor);
            if (expectedLimit == 0) {
                assertLe(limit, 1, "deposit limit should be blocked at cap");
            } else {
                assertApproxEqAbs(limit, expectedLimit, 2, "deposit limit mismatch");
            }
        }
    }

    function invariant_withdrawBlockedWhenAtOrBelowFloor() public view {
        if (ITokenizedStrategy(address(susd3Strategy)).isShutdown()) return;

        uint256 floorUsdc = susd3Strategy.getSubordinatedDebtFloorInUSDC();
        uint256 holdingsUsdc = ITokenizedStrategy(address(usd3Strategy))
            .convertToAssets(IERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy)));

        if (floorUsdc == 0 || holdingsUsdc > floorUsdc) return;

        uint256 actorCount = handler.actorCount();
        for (uint256 i; i < actorCount; ++i) {
            assertEq(
                susd3Strategy.availableWithdrawLimit(handler.actorAt(i)), 0, "withdraw must be blocked below floor"
            );
        }
    }

    function invariant_cooldownSharesNeverExceedBalance() public view {
        uint256 actorCount = handler.actorCount();
        for (uint256 i; i < actorCount; ++i) {
            address actor = handler.actorAt(i);
            (,, uint256 cooldownShares) = susd3Strategy.getCooldownStatus(actor);
            uint256 balance = IERC20(address(susd3Strategy)).balanceOf(actor);
            assertLe(cooldownShares, balance, "cooldown shares exceed balance");
        }
    }

    function invariant_handlersAreEffective() public view {
        if (handler.attemptedDepositUSD3() > 16 && _anyActorCanDepositUSD3()) {
            assertGt(handler.successfulDepositUSD3(), 0, "usd3 deposit handler no-op");
        }

        uint256 capUsdc = susd3Strategy.getSubordinatedDebtCapInUSDC();
        uint256 holdingsUsdc = ITokenizedStrategy(address(usd3Strategy))
            .convertToAssets(IERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy)));
        if (handler.attemptedDepositSUSD3() > 24 && capUsdc > holdingsUsdc && _anyActorCanDepositSUSD3()) {
            assertGt(handler.successfulDepositSUSD3(), 0, "susd3 deposit handler no-op");
        }

        if (handler.attemptedReport() > 8) {
            assertGt(handler.successfulReport(), 0, "report never succeeds");
        }

        if (handler.attemptedSkipTime() > 8) {
            assertGt(handler.successfulSkipTime(), 0, "time never advances");
        }

        if (handler.attemptedStartCooldown() > 48) {
            assertGt(handler.successfulStartCooldown(), 0, "cooldown starts are no-op");
        }

        if (handler.attemptedWithdrawSUSD3() > 64 && handler.successfulStartCooldown() > 0) {
            assertGt(handler.successfulWithdrawSUSD3(), 0, "susd3 withdrawals are no-op");
        }
    }

    function _anyActorCanDepositUSD3() internal view returns (bool) {
        uint256 actorCount = handler.actorCount();
        for (uint256 i; i < actorCount; ++i) {
            if (usd3Strategy.availableDepositLimit(handler.actorAt(i)) > 0) return true;
        }
        return false;
    }

    function _anyActorCanDepositSUSD3() internal view returns (bool) {
        uint256 actorCount = handler.actorCount();
        for (uint256 i; i < actorCount; ++i) {
            address actor = handler.actorAt(i);
            if (susd3Strategy.availableDepositLimit(actor) > 0 && IERC20(address(usd3Strategy)).balanceOf(actor) > 0) {
                return true;
            }
        }
        return false;
    }
}
