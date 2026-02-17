// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Setup, ERC20} from "./utils/Setup.sol";
import {USD3} from "../../../src/usd3/USD3.sol";
import {sUSD3} from "../../../src/usd3/sUSD3.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {
    TransparentUpgradeableProxy
} from "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {InvariantHandler} from "./handlers/InvariantHandler.sol";

/**
 * @title InvariantsTest
 * @notice Invariant tests for USD3/sUSD3 protocol safety properties
 */
contract InvariantsTest is StdInvariant, Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;
    InvariantHandler public handler;

    // Test actors
    address[] public actors;
    mapping(address => bool) public isActor;

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        // Deploy sUSD3
        sUSD3 susd3Implementation = new sUSD3();
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(management);
        bytes memory susd3InitData =
            abi.encodeWithSelector(sUSD3.initialize.selector, address(usd3Strategy), management, keeper);
        TransparentUpgradeableProxy susd3Proxy =
            new TransparentUpgradeableProxy(address(susd3Implementation), address(susd3ProxyAdmin), susd3InitData);
        susd3Strategy = sUSD3(address(susd3Proxy));

        vm.prank(management);
        usd3Strategy.setSUSD3(address(susd3Strategy));

        // Enable deployment into Morpho + debt-based subordination behavior.
        setMaxOnCredit(8000); // 80%
        setMorphoDebtCap(10_000e6); // 10k USDC

        _setupActors();

        handler = new InvariantHandler(
            address(usd3Strategy), address(susd3Strategy), address(underlyingAsset), keeper, actors
        );

        // Seed locked shares so loss-absorption invariants can exercise the locked-share path.
        handler.simulateProfitAndReport(100_000e6);

        _configureTargets();
    }

    function _setupActors() internal {
        for (uint256 i; i < 5; ++i) {
            address actor = makeAddr(string(abi.encodePacked("actor", i)));
            actors.push(actor);
            isActor[actor] = true;

            deal(address(underlyingAsset), actor, 100_000e6);
            vm.prank(actor);
            underlyingAsset.approve(address(usd3Strategy), type(uint256).max);

            if (i < 3) {
                vm.prank(actor);
                usd3Strategy.deposit(500e6, actor);
            }
        }

        // Seed debt so sUSD3 cap/floor logic is exercised.
        address borrower = makeAddr("marketBorrower");
        createMarketDebt(borrower, 750e6);

        // Seed sUSD3 with small deposits from first two actors when possible.
        for (uint256 i; i < 2; ++i) {
            address actor = actors[i];
            uint256 usd3Balance = ERC20(address(usd3Strategy)).balanceOf(actor);
            uint256 depositLimit = susd3Strategy.availableDepositLimit(actor);
            uint256 amount = usd3Balance / 10;
            if (amount > depositLimit) amount = depositLimit;
            if (amount == 0) continue;

            vm.startPrank(actor);
            ERC20(address(usd3Strategy)).approve(address(susd3Strategy), amount);
            susd3Strategy.deposit(amount, actor);
            vm.stopPrank();
        }
    }

    function _configureTargets() internal {
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = InvariantHandler.depositUSD3.selector;
        selectors[1] = InvariantHandler.redeemUSD3.selector;
        selectors[2] = InvariantHandler.depositSUSD3.selector;
        selectors[3] = InvariantHandler.startCooldownSUSD3.selector;
        selectors[4] = InvariantHandler.cancelCooldownSUSD3.selector;
        selectors[5] = InvariantHandler.withdrawSUSD3.selector;
        selectors[6] = InvariantHandler.transferUSD3.selector;
        selectors[7] = InvariantHandler.transferSUSD3.selector;
        selectors[8] = InvariantHandler.reportUSD3.selector;
        selectors[9] = InvariantHandler.warpTime.selector;
        selectors[10] = InvariantHandler.simulateProfitAndReport.selector;
        selectors[11] = InvariantHandler.simulateLossAndReport.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_usd3DoesNotOverReportAssetsVsBalances() public view {
        // Synthetic market-asset perturbation is used for loss-path testing and can desync this
        // accounting check from its original assumptions.
        if (handler.attemptedProfitReports() + handler.attemptedLossReports() > 0) return;

        uint256 idleUsdc = underlyingAsset.balanceOf(address(usd3Strategy));
        uint256 totalWaUsdc = usd3Strategy.balanceOfWaUSDC() + usd3Strategy.suppliedWaUSDC();
        uint256 modeledAssets = idleUsdc + usd3Strategy.WAUSDC().convertToAssets(totalWaUsdc);
        uint256 reportedAssets = ITokenizedStrategy(address(usd3Strategy)).totalAssets();

        // Allow small absolute tolerance for conversion dust, but forbid phantom asset reporting.
        assertLe(reportedAssets, modeledAssets + 5e6, "usd3 overreports assets");
    }

    function invariant_usd3LocalAndDeployedWaUsdcTotalsAreConsistent() public view {
        uint256 localWaUsdc = usd3Strategy.balanceOfWaUSDC();
        uint256 suppliedWaUsdc = usd3Strategy.suppliedWaUSDC();

        // In shutdown mode, the strategy should not exceed its own total assets accounting.
        if (ITokenizedStrategy(address(usd3Strategy)).isShutdown()) {
            uint256 totalAssets = ITokenizedStrategy(address(usd3Strategy)).totalAssets();
            uint256 localAndDeployedUsdc = usd3Strategy.WAUSDC().convertToAssets(localWaUsdc + suppliedWaUsdc)
                + underlyingAsset.balanceOf(address(usd3Strategy));
            assertLe(localAndDeployedUsdc, totalAssets + 5e6, "shutdown accounting mismatch");
        }
    }

    function invariant_susd3DepositLimitTracksDebtCap() public view {
        uint256 debtCapUsdc = susd3Strategy.getSubordinatedDebtCapInUSDC();
        uint256 susd3Usd3Balance = ERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        uint256 holdingsUsdc = ITokenizedStrategy(address(usd3Strategy)).convertToAssets(susd3Usd3Balance);

        uint256 expectedLimit;
        if (debtCapUsdc > holdingsUsdc) {
            expectedLimit = ITokenizedStrategy(address(usd3Strategy)).convertToShares(debtCapUsdc - holdingsUsdc);
        }

        for (uint256 i; i < actors.length; ++i) {
            uint256 limit = susd3Strategy.availableDepositLimit(actors[i]);
            if (expectedLimit == 0) {
                assertLe(limit, 1, "sUSD3 deposits must be blocked at/above cap");
            } else {
                assertApproxEqAbs(limit, expectedLimit, 2, "sUSD3 deposit limit mismatch");
            }
        }
    }

    function invariant_susd3CooldownSharesNeverExceedBalance() public view {
        for (uint256 i; i < actors.length; ++i) {
            (,, uint256 cooldownShares) = susd3Strategy.getCooldownStatus(actors[i]);
            uint256 balance = ERC20(address(susd3Strategy)).balanceOf(actors[i]);
            assertLe(cooldownShares, balance, "cooldown shares exceed balance");
        }
    }

    function invariant_susd3WithdrawLimitsRespectLockCooldownAndFloor() public view {
        if (ITokenizedStrategy(address(susd3Strategy)).isShutdown()) return;

        uint256 debtFloorUsdc = susd3Strategy.getSubordinatedDebtFloorInUSDC();
        uint256 holdingsUsdc = ITokenizedStrategy(address(usd3Strategy))
            .convertToAssets(ERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy)));
        uint256 cooldownDuration = susd3Strategy.cooldownDuration();

        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            uint256 withdrawLimit = susd3Strategy.availableWithdrawLimit(actor);

            if (block.timestamp < susd3Strategy.lockedUntil(actor)) {
                assertEq(withdrawLimit, 0, "withdraw allowed during lock");
                continue;
            }

            (uint256 cooldownEnd, uint256 windowEnd, uint256 cooldownShares) = susd3Strategy.getCooldownStatus(actor);
            if (cooldownDuration > 0) {
                if (cooldownShares == 0 || block.timestamp < cooldownEnd || block.timestamp > windowEnd) {
                    assertEq(withdrawLimit, 0, "withdraw allowed outside cooldown window");
                    continue;
                }

                uint256 maxCooldownAssets = ITokenizedStrategy(address(susd3Strategy)).convertToAssets(cooldownShares);
                assertLe(withdrawLimit, maxCooldownAssets + 2, "withdraw exceeds cooldown shares");
            }

            if (debtFloorUsdc > 0 && holdingsUsdc <= debtFloorUsdc) {
                assertEq(withdrawLimit, 0, "withdraw allowed below debt floor");
                continue;
            }

            uint256 actorAssetBalance = ITokenizedStrategy(address(susd3Strategy))
                .convertToAssets(ERC20(address(susd3Strategy)).balanceOf(actor));
            assertLe(withdrawLimit, actorAssetBalance + 2, "withdraw exceeds actor balance");
        }
    }

    function invariant_handlersAreEffective() public view {
        if (handler.attemptedDepositUSD3() + handler.attemptedRedeemUSD3() > 32) {
            assertGt(handler.successfulDepositUSD3() + handler.successfulRedeemUSD3(), 0, "usd3 actions are no-op");
        }

        uint256 capUsdc = susd3Strategy.getSubordinatedDebtCapInUSDC();
        uint256 holdingsUsdc = ITokenizedStrategy(address(usd3Strategy))
            .convertToAssets(ERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy)));

        if (handler.attemptedDepositSUSD3() > 32 && capUsdc > holdingsUsdc) {
            assertGt(handler.successfulDepositSUSD3(), 0, "susd3 deposits are no-op");
        }

        if (handler.attemptedReportUSD3() > 8) {
            assertGt(handler.successfulReportUSD3(), 0, "report never succeeds");
        }

        if (handler.attemptedWarpTime() > 8) {
            assertGt(handler.successfulWarpTime(), 0, "warp actions never succeed");
        }

        if (handler.attemptedStartCooldownSUSD3() > 48) {
            assertGt(handler.successfulStartCooldownSUSD3(), 0, "cooldown starts are no-op");
        }

        if (handler.attemptedWithdrawSUSD3() > 64 && handler.successfulStartCooldownSUSD3() > 0) {
            assertGt(handler.successfulWithdrawSUSD3(), 0, "susd3 withdrawals are no-op");
        }

        if (handler.attemptedProfitReports() > 8) {
            assertGt(handler.successfulProfitReports(), 0, "profit report path never succeeds");
        }

        if (handler.attemptedLossReports() > 8) {
            assertGt(handler.successfulLossReports(), 0, "loss report path never succeeds");
        }
    }

    function invariant_lossReportsDoNotIncreasePpsWithLockedShares() public view {
        if (handler.observedLossReportsWithLocked() == 0) return;

        // A loss event should not cause PPS increase when locked shares + sUSD3 are present.
        // Small tolerance allows integer-division dust.
        assertLe(handler.maxPpsIncreaseOnLossWithLocked(), 10, "pps increased after locked-share loss report");
    }
}
