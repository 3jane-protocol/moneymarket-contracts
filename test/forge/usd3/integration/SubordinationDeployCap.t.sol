// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {sUSD3} from "../../../../src/usd3/sUSD3.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {IMorpho, Id, MarketParams} from "../../../../src/interfaces/IMorpho.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {ProtocolConfigLib} from "../../../../src/libraries/ProtocolConfigLib.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {ErrorsLib} from "../../../../src/libraries/ErrorsLib.sol";
import {
    TransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract SubordinationDeployCapTest is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;
    MockProtocolConfig public protocolConfig;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public borrower = makeAddr("borrower");

    uint256 public constant DEPOSIT_AMOUNT = 1_000_000e6;

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        address morphoAddress = address(usd3Strategy.morphoCredit());
        protocolConfig = MockProtocolConfig(MorphoCredit(morphoAddress).protocolConfig());

        // Deploy and link sUSD3
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

        deal(address(underlyingAsset), alice, DEPOSIT_AMOUNT * 20);
        deal(address(underlyingAsset), bob, DEPOSIT_AMOUNT * 20);

        vm.prank(alice);
        asset.approve(address(strategy), type(uint256).max);
        vm.prank(bob);
        asset.approve(address(strategy), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _depositToSUSD3(address user, uint256 usd3Amount) internal returns (uint256) {
        vm.prank(user);
        strategy.approve(address(susd3Strategy), usd3Amount);
        vm.prank(user);
        return susd3Strategy.deposit(usd3Amount, user);
    }

    function _effectiveDeployCapWaUSDC() internal view returns (uint256) {
        uint256 totalWaUSDC = usd3Strategy.suppliedWaUSDC() + usd3Strategy.balanceOfWaUSDC();
        uint256 maxOnCreditCap = (totalWaUSDC * usd3Strategy.maxOnCredit()) / 10_000;
        uint256 backingRatio = protocolConfig.config(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO);
        if (backingRatio == 0) return maxOnCreditCap;

        uint256 susd3Shares = strategy.balanceOf(address(susd3Strategy));
        uint256 totalSupply = strategy.totalSupply();
        uint256 totalAssets = strategy.totalAssets();
        if (susd3Shares == 0 || totalSupply == 0 || totalAssets == 0) return 0;

        uint256 sUSD3ValueUSDC = (susd3Shares * totalAssets) / totalSupply;
        uint256 subCap = waUSDC.convertToShares((sUSD3ValueUSDC * 10_000) / backingRatio);
        return maxOnCreditCap < subCap ? maxOnCreditCap : subCap;
    }

    /// @dev Creates initial debt and sUSD3 backing WITHOUT the backing ratio constraint.
    /// Sets MIN_SUSD3_BACKING_RATIO after setup so the subordination cap can be tested.
    function _bootstrapDebtAndBacking(
        uint256 usd3DepositAmount,
        uint256 debtAmount,
        uint256 susd3DepositAmount,
        uint256 backingRatio
    ) internal {
        // Ensure TRANCHE_RATIO is set for sUSD3 deposit limits
        protocolConfig.setConfig(ProtocolConfigLib.TRANCHE_RATIO, 10_000);
        // No backing constraint during bootstrap
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 0);
        setMaxOnCredit(10_000);

        // Deposit USDC into USD3
        vm.prank(alice);
        strategy.deposit(usd3DepositAmount, alice);

        // Create debt (this calls report() internally, deploys to Morpho, then borrows)
        createMarketDebt(borrower, debtAmount);

        // Now deposit into sUSD3 (needs debt to exist for deposit limit > 0)
        if (susd3DepositAmount > 0) {
            vm.prank(bob);
            strategy.deposit(susd3DepositAmount, bob);

            uint256 bobUSD3 = strategy.balanceOf(bob);
            uint256 depositLimit = susd3Strategy.availableDepositLimit(bob);
            uint256 toDeposit = bobUSD3 > depositLimit ? depositLimit : bobUSD3;
            if (toDeposit > 0) {
                _depositToSUSD3(bob, toDeposit);
            }
        }

        // NOW enable the backing ratio constraint
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, backingRatio);
    }

    function _setupBorrower(uint256 creditAmount) internal {
        Id marketId = usd3Strategy.marketId();
        MarketParams memory marketParams = usd3Strategy.marketParams();
        IMorpho morpho = usd3Strategy.morphoCredit();

        address[] memory borrowers_ = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        vm.prank(marketParams.creditLine);
        MorphoCredit(address(morpho))
            .closeCycleAndPostObligations(marketId, block.timestamp, borrowers_, repaymentBps, endingBalances);

        vm.prank(marketParams.creditLine);
        MorphoCredit(address(morpho)).setCreditLine(marketId, borrower, creditAmount, 0);
    }

    function _setupSUSD3ExitRebalanceScenario() internal {
        protocolConfig.setConfig(ProtocolConfigLib.TRANCHE_RATIO, 10_000);
        protocolConfig.setConfig(ProtocolConfigLib.SUSD3_LOCK_DURATION, 0);
        protocolConfig.setConfig(ProtocolConfigLib.SUSD3_COOLDOWN_PERIOD, 0);
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 0);
        setMaxOnCredit(10_000);
        setMorphoDebtCap(10_000_000e6);

        vm.prank(alice);
        strategy.deposit(10_000_000e6, alice);

        createMarketDebt(borrower, 1_000_000e6);

        vm.prank(bob);
        strategy.deposit(2_000_000e6, bob);
        _depositToSUSD3(bob, strategy.balanceOf(bob));

        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 10_000);

        vm.prank(keeper);
        ITokenizedStrategy(address(strategy)).tend();
    }

    /*//////////////////////////////////////////////////////////////
                    BUG REGRESSION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_bugRegression_borrowHeadroomBoundedByBacking() public {
        // 10M USDC deposited, 500K debt, ~800K sUSD3 backing, 10M debt cap
        _bootstrapDebtAndBacking(10_000_000e6, 500_000e6, 800_000e6, 10_000);
        setMorphoDebtCap(10_000_000e6);

        // Tend to enforce subordination cap
        vm.prank(keeper);
        ITokenizedStrategy(address(strategy)).tend();

        uint256 suppliedAfterTend = usd3Strategy.suppliedWaUSDC();
        uint256 cap = _effectiveDeployCapWaUSDC();

        assertLe(suppliedAfterTend, cap + 1, "Deployment should respect subordination cap");

        // The deployed amount should be bounded by sUSD3 backing, NOT the 10M debt cap
        uint256 sUSD3ValueUSDC =
            ITokenizedStrategy(address(susd3Strategy)).convertToAssets(strategy.balanceOf(address(susd3Strategy)));
        assertLe(
            waUSDC.convertToAssets(suppliedAfterTend),
            sUSD3ValueUSDC + 1e6,
            "Deployment should be bounded by sUSD3 backing, not debt cap"
        );
    }

    function test_bugRegression_liveShape() public {
        // Mirror production: ~7.7M debt, ~7.8M sUSD3 backing, 10M cap
        _bootstrapDebtAndBacking(10_000_000e6, 7_700_000e6, 7_800_000e6, 10_000);
        setMorphoDebtCap(10_000_000e6);

        // Tend
        vm.prank(keeper);
        ITokenizedStrategy(address(strategy)).tend();

        uint256 sUSD3ValueUSDC =
            ITokenizedStrategy(address(susd3Strategy)).convertToAssets(strategy.balanceOf(address(susd3Strategy)));

        (,, uint256 totalBorrowAssets, uint256 liquidity) = usd3Strategy.getMarketLiquidity();
        uint256 borrowHeadroom = waUSDC.convertToAssets(liquidity);
        uint256 debtUSDC = waUSDC.convertToAssets(totalBorrowAssets);

        // Borrow headroom should be bounded by backing headroom
        uint256 maxNewBorrows = sUSD3ValueUSDC > debtUSDC ? sUSD3ValueUSDC - debtUSDC : 0;
        assertLe(
            borrowHeadroom, maxNewBorrows + 2e6, "Borrow headroom should be bounded by backing headroom, not debt cap"
        );
    }

    function test_susd3WithdrawRebalancesUsd3ToPostExitCap() public {
        _setupSUSD3ExitRebalanceScenario();

        uint256 suppliedBefore = usd3Strategy.suppliedWaUSDC();
        uint256 capBefore = _effectiveDeployCapWaUSDC();
        (,, uint256 debtBefore,) = usd3Strategy.getMarketLiquidity();
        uint256 withdrawLimit = susd3Strategy.availableWithdrawLimit(bob);

        assertApproxEqAbs(suppliedBefore, capBefore, 2, "pre-withdraw deployment should sit at cap");
        assertGt(suppliedBefore, debtBefore, "scenario should have unborrowed deployed liquidity");
        assertGt(withdrawLimit, 0, "sUSD3 should have debt-floor withdrawal capacity");

        vm.prank(bob);
        susd3Strategy.withdraw(withdrawLimit, bob, bob);

        uint256 suppliedAfter = usd3Strategy.suppliedWaUSDC();
        uint256 capAfter = _effectiveDeployCapWaUSDC();

        assertLt(suppliedAfter, suppliedBefore, "withdraw should pull excess USD3 supply");
        assertLe(suppliedAfter, capAfter + 2, "withdraw should finish within post-exit cap");
        assertApproxEqAbs(suppliedAfter, debtBefore, 2, "only borrowed liquidity should remain supplied");
    }

    function test_susd3WithdrawRemovesBorrowableOverCapLiquidity() public {
        _setupSUSD3ExitRebalanceScenario();

        uint256 withdrawLimit = susd3Strategy.availableWithdrawLimit(bob);

        vm.prank(bob);
        susd3Strategy.withdraw(withdrawLimit, bob, bob);

        (,,, uint256 liquidityAfter) = usd3Strategy.getMarketLiquidity();
        assertLe(liquidityAfter, 2, "over-cap liquidity should be pulled before another tx can borrow");

        MarketParams memory marketParams = usd3Strategy.marketParams();
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        vm.prank(borrower);
        helper.borrow(marketParams, 100_000e6, 0, borrower, borrower);
    }

    function test_susd3WithdrawSucceedsWhileWaUSDCPausedAndDefersPullback() public {
        _setupSUSD3ExitRebalanceScenario();

        uint256 suppliedBefore = usd3Strategy.suppliedWaUSDC();
        uint256 capBefore = _effectiveDeployCapWaUSDC();
        uint256 usd3BalanceBefore = strategy.balanceOf(address(susd3Strategy));
        uint256 bobUsd3Before = strategy.balanceOf(bob);
        uint256 withdrawLimit = susd3Strategy.availableWithdrawLimit(bob);

        assertApproxEqAbs(suppliedBefore, capBefore, 2, "pre-withdraw deployment should sit at cap");
        assertGt(withdrawLimit, 0, "sUSD3 should have debt-floor withdrawal capacity");

        waUSDC.setPaused(true);

        vm.prank(bob);
        susd3Strategy.withdraw(withdrawLimit, bob, bob);

        assertEq(usd3Strategy.suppliedWaUSDC(), suppliedBefore, "paused exit should defer the blocked pullback");
        assertLt(strategy.balanceOf(address(susd3Strategy)), usd3BalanceBefore, "paused exit should reduce backing");
        assertEq(strategy.balanceOf(bob), bobUsd3Before + withdrawLimit, "paused exit should return USD3 to the junior");
    }

    function test_composed_pausedReportThenSUSD3WithdrawSucceedsAndDefersPullback() public {
        _setupSUSD3ExitRebalanceScenario();

        uint256 suppliedBefore = usd3Strategy.suppliedWaUSDC();
        uint256 usd3BackingBefore = strategy.balanceOf(address(susd3Strategy));
        uint256 idleUSDC = 100;
        deal(address(asset), address(strategy), idleUSDC);

        waUSDC.setSharePrice(990_000);
        uint256 expectedNav = usd3Strategy.nav();
        assertLt(expectedNav, strategy.totalAssets(), "share-price loss setup failed");

        waUSDC.setPaused(true);
        vm.prank(keeper);
        (, uint256 loss) = ITokenizedStrategy(address(strategy)).report();

        assertGt(loss, 0, "paused report should realize the wrapper loss");
        assertEq(strategy.totalAssets(), expectedNav, "paused report should rebase totalAssets to NAV");
        assertLt(
            strategy.balanceOf(address(susd3Strategy)), usd3BackingBefore, "paused report should burn sUSD3 backing"
        );
        assertEq(usd3Strategy.suppliedWaUSDC(), suppliedBefore, "paused report tend must not move deployed waUSDC");
        assertEq(asset.balanceOf(address(strategy)), idleUSDC, "paused report must leave loose USDC unwrapped");
        assertTrue(waUSDC.paused(), "wrapper must remain paused through the composed scenario");

        vm.prank(keeper);
        ITokenizedStrategy(address(susd3Strategy)).report();
        uint256 withdrawLimit = susd3Strategy.availableWithdrawLimit(bob);
        assertGt(withdrawLimit, 0, "sUSD3 accounting sync should restore an actionable exit");

        uint256 bobSharesBefore = ITokenizedStrategy(address(susd3Strategy)).balanceOf(bob);
        uint256 usd3BackingAfterReport = strategy.balanceOf(address(susd3Strategy));
        vm.prank(bob);
        susd3Strategy.withdraw(withdrawLimit, bob, bob);

        assertEq(usd3Strategy.suppliedWaUSDC(), suppliedBefore, "paused exit should defer the blocked pullback");
        assertLt(
            strategy.balanceOf(address(susd3Strategy)), usd3BackingAfterReport, "paused exit should reduce backing"
        );
        assertLt(
            ITokenizedStrategy(address(susd3Strategy)).balanceOf(bob), bobSharesBefore, "paused exit should burn shares"
        );
    }

    function test_pendingLossGateBlocksSupplyIntoStaleSubordinationCap() public {
        protocolConfig.setConfig(ProtocolConfigLib.TRANCHE_RATIO, 10_000);
        protocolConfig.setConfig(ProtocolConfigLib.SUSD3_LOCK_DURATION, 0);
        protocolConfig.setConfig(ProtocolConfigLib.SUSD3_COOLDOWN_PERIOD, 0);
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 0);
        setMaxOnCredit(10_000);

        vm.prank(alice);
        strategy.deposit(1_000_000e6, alice);

        createMarketDebt(borrower, 300_000e6);

        vm.prank(bob);
        strategy.deposit(600_000e6, bob);
        _depositToSUSD3(bob, strategy.balanceOf(bob));

        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 10_000);

        vm.prank(keeper);
        ITokenizedStrategy(address(strategy)).tend();

        MarketParams memory params = usd3Strategy.marketParams();
        MorphoCredit morpho = MorphoCredit(address(usd3Strategy.morphoCredit()));
        vm.prank(params.creditLine);
        morpho.settleAccount(params, borrower);

        assertFalse(
            morpho.marketInWindDown(usd3Strategy.marketId()), "market must accept supplies so only the gate can block"
        );
        assertTrue(usd3Strategy.nav() + 2 < strategy.totalAssets(), "settlement must leave a pending loss");

        uint256 suppliedBefore = usd3Strategy.suppliedWaUSDC();
        uint256 localBefore = usd3Strategy.balanceOfWaUSDC();
        uint256 staleCap = _effectiveDeployCapWaUSDC();
        uint256 liveSubCapWaUSDC = waUSDC.convertToShares(
            (strategy.balanceOf(address(susd3Strategy)) * usd3Strategy.nav()) / strategy.totalSupply()
        );

        assertGt(staleCap, liveSubCapWaUSDC, "pending loss must inflate the stale subordination cap");
        assertGt(staleCap, suppliedBefore, "inflated cap must leave apparent supply headroom");
        assertGt(localBefore, 0, "scenario requires supplyable local waUSDC");

        (bool shouldTend,) = usd3Strategy.tendTrigger();
        assertFalse(shouldTend, "pending loss must suppress the supply-side keeper signal");

        vm.recordLogs();
        vm.prank(keeper);
        ITokenizedStrategy(address(strategy)).tend();

        assertEq(usd3Strategy.suppliedWaUSDC(), suppliedBefore, "pending-loss tend must not supply into the stale cap");
        assertEq(usd3Strategy.balanceOfWaUSDC(), localBefore, "pending-loss tend must leave local waUSDC untouched");
        Vm.Log[] memory tendLogs = vm.getRecordedLogs();
        for (uint256 i; i < tendLogs.length; ++i) {
            assertTrue(
                tendLogs[i].topics[0] != keccak256("RebalanceDeferred(uint256)"),
                "skip must come from the pending-loss gate, not a market rejection"
            );
        }

        address charlie = makeAddr("charlie");
        deal(address(underlyingAsset), charlie, 200_000e6);
        vm.prank(charlie);
        asset.approve(address(strategy), type(uint256).max);
        vm.prank(charlie);
        strategy.deposit(200_000e6, charlie);

        assertEq(
            usd3Strategy.suppliedWaUSDC(), suppliedBefore, "pending-loss deposit must not supply into the stale cap"
        );
        assertEq(usd3Strategy.balanceOfWaUSDC(), localBefore + 200_000e6, "pending-loss deposit must stay local");

        vm.prank(keeper);
        (, uint256 loss) = ITokenizedStrategy(address(strategy)).report();

        assertGt(loss, 0, "report must recognize the settlement loss");
        assertEq(strategy.totalAssets(), usd3Strategy.nav(), "report must rebase stored assets to NAV");
        uint256 capAfterReport = _effectiveDeployCapWaUSDC();
        assertLt(capAfterReport, staleCap, "recognition must deflate the subordination cap");
        assertLe(usd3Strategy.suppliedWaUSDC(), capAfterReport + 2, "post-report deployment must respect the live cap");
    }

    function test_susd3WithdrawDoesNotTendAfterUsd3Shutdown() public {
        _setupSUSD3ExitRebalanceScenario();

        uint256 suppliedBefore = usd3Strategy.suppliedWaUSDC();
        uint256 withdrawLimit = susd3Strategy.availableWithdrawLimit(bob);

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        vm.prank(bob);
        susd3Strategy.withdraw(withdrawLimit, bob, bob);

        assertEq(usd3Strategy.suppliedWaUSDC(), suppliedBefore, "USD3 shutdown should bypass transfer-hook tend");
    }

    function test_susd3WithdrawDoesNotDeployIdleWaUSDCWhenPaused() public {
        protocolConfig.setConfig(ProtocolConfigLib.TRANCHE_RATIO, 10_000);
        protocolConfig.setConfig(ProtocolConfigLib.SUSD3_LOCK_DURATION, 0);
        protocolConfig.setConfig(ProtocolConfigLib.SUSD3_COOLDOWN_PERIOD, 0);
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 0);
        setMaxOnCredit(0);

        vm.prank(alice);
        strategy.deposit(1_000_000e6, alice);

        vm.prank(bob);
        strategy.deposit(100_000e6, bob);
        _depositToSUSD3(bob, strategy.balanceOf(bob));

        assertEq(usd3Strategy.suppliedWaUSDC(), 0, "setup should be underdeployed");
        assertGt(usd3Strategy.balanceOfWaUSDC(), 0, "setup should have local waUSDC");

        setMaxOnCredit(10_000);
        protocolConfig.setConfig(keccak256("IS_PAUSED"), 1);

        uint256 localBefore = usd3Strategy.balanceOfWaUSDC();
        uint256 shares = ITokenizedStrategy(address(susd3Strategy)).balanceOf(bob);

        vm.prank(bob);
        susd3Strategy.redeem(shares, bob, bob);

        assertEq(usd3Strategy.suppliedWaUSDC(), 0, "sUSD3 exit hook should not deploy while paused");
        assertEq(usd3Strategy.balanceOfWaUSDC(), localBefore, "local waUSDC should remain local");
    }

    function test_reportRestoresBackingCapAfterLossAbsorption() public {
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 0);
        setMaxOnCredit(10_000);

        vm.prank(alice);
        strategy.deposit(1_000_000e6, alice);

        vm.prank(bob);
        strategy.deposit(500_000e6, bob);
        _depositToSUSD3(bob, strategy.balanceOf(bob));

        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 10_000);

        vm.prank(keeper);
        ITokenizedStrategy(address(strategy)).tend();

        uint256 suppliedBeforeLoss = usd3Strategy.suppliedWaUSDC();
        uint256 capBeforeLoss = _effectiveDeployCapWaUSDC();
        uint256 susd3BalanceBeforeLoss = strategy.balanceOf(address(susd3Strategy));
        uint256 localWaUSDC = usd3Strategy.balanceOfWaUSDC();
        uint256 lossWaUSDC = 400_000e6;

        assertApproxEqAbs(suppliedBeforeLoss, capBeforeLoss, 2, "pre-loss deployment should sit at cap");
        assertGe(localWaUSDC, lossWaUSDC, "test requires enough local waUSDC to remove");

        vm.prank(address(usd3Strategy));
        waUSDC.transfer(address(0xdead), lossWaUSDC);

        vm.prank(keeper);
        (, uint256 loss) = ITokenizedStrategy(address(strategy)).report();

        uint256 suppliedAfterReport = usd3Strategy.suppliedWaUSDC();
        uint256 capAfterReport = _effectiveDeployCapWaUSDC();
        uint256 susd3BalanceAfterReport = strategy.balanceOf(address(susd3Strategy));

        assertGt(loss, 0, "report should realize the local waUSDC loss");
        assertLt(susd3BalanceAfterReport, susd3BalanceBeforeLoss, "sUSD3 should absorb the loss");
        assertLe(suppliedAfterReport, capAfterReport + 2, "report should finish within post-burn cap");
        assertLt(suppliedAfterReport, suppliedBeforeLoss, "report should pull excess Morpho supply");
    }

    function test_reportStillDeploysLocalWaUSDCWhenNoLoss() public {
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 0);
        setMaxOnCredit(0);

        vm.prank(alice);
        strategy.deposit(100_000e6, alice);

        assertEq(usd3Strategy.suppliedWaUSDC(), 0, "maxOnCredit=0 should keep funds local");
        assertGt(usd3Strategy.balanceOfWaUSDC(), 0, "deposit should wrap into local waUSDC");

        setMaxOnCredit(10_000);

        vm.prank(keeper);
        ITokenizedStrategy(address(strategy)).report();

        assertGt(usd3Strategy.suppliedWaUSDC(), 0, "report should still rebalance after accounting");
        assertEq(usd3Strategy.balanceOfWaUSDC(), 0, "report should deploy local waUSDC");
    }

    /*//////////////////////////////////////////////////////////////
                    DEPLOYMENT CAP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_deploymentCappedByBacking() public {
        // 200K debt, 300K sUSD3 backing: after tend, deployment bounded by 300K cap
        _bootstrapDebtAndBacking(2_000_000e6, 200_000e6, 300_000e6, 10_000);

        // Tend to enforce cap
        vm.prank(keeper);
        ITokenizedStrategy(address(strategy)).tend();

        uint256 supplied = usd3Strategy.suppliedWaUSDC();
        uint256 sUSD3ValueUSDC =
            ITokenizedStrategy(address(susd3Strategy)).convertToAssets(strategy.balanceOf(address(susd3Strategy)));

        assertLe(waUSDC.convertToAssets(supplied), sUSD3ValueUSDC + 1e6, "Deployment should not exceed sUSD3 backing");
    }

    function test_tendWithdrawsWhenBackingDrops() public {
        _bootstrapDebtAndBacking(2_000_000e6, 500_000e6, 1_000_000e6, 10_000);

        vm.prank(keeper);
        ITokenizedStrategy(address(strategy)).tend();
        uint256 suppliedBefore = usd3Strategy.suppliedWaUSDC();

        // Simulate sUSD3 backing drop by burning half its USD3 balance
        uint256 susd3USD3Balance = strategy.balanceOf(address(susd3Strategy));
        deal(address(strategy), address(susd3Strategy), susd3USD3Balance / 2);

        // Tend should pull back deployment
        vm.prank(keeper);
        ITokenizedStrategy(address(strategy)).tend();
        uint256 suppliedAfter = usd3Strategy.suppliedWaUSDC();

        assertLt(suppliedAfter, suppliedBefore, "Deployment should decrease after backing drop");
    }

    function test_tendRedeploysWhenBackingRises() public {
        _bootstrapDebtAndBacking(2_000_000e6, 200_000e6, 200_000e6, 10_000);

        vm.prank(keeper);
        ITokenizedStrategy(address(strategy)).tend();
        uint256 suppliedBefore = usd3Strategy.suppliedWaUSDC();

        // Increase sUSD3 backing via actual deposit flow (preserves ERC20 invariants)
        address charlie = makeAddr("charlie");
        deal(address(underlyingAsset), charlie, 400_000e6);
        vm.prank(charlie);
        asset.approve(address(strategy), type(uint256).max);
        vm.prank(charlie);
        strategy.deposit(400_000e6, charlie);
        _depositToSUSD3(charlie, strategy.balanceOf(charlie));

        // Tend should redeploy idle funds
        vm.prank(keeper);
        ITokenizedStrategy(address(strategy)).tend();
        uint256 suppliedAfter = usd3Strategy.suppliedWaUSDC();

        assertGe(suppliedAfter, suppliedBefore, "Deployment should increase after backing rise");
    }

    /*//////////////////////////////////////////////////////////////
                    TEND TRIGGER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_tendTrigger_trueWhenOverDeployed() public {
        _bootstrapDebtAndBacking(2_000_000e6, 500_000e6, 500_000e6, 10_000);

        // Tend to reach equilibrium
        vm.prank(keeper);
        ITokenizedStrategy(address(strategy)).tend();

        // Drop sUSD3 backing significantly
        uint256 susd3USD3Balance = strategy.balanceOf(address(susd3Strategy));
        deal(address(strategy), address(susd3Strategy), susd3USD3Balance / 4);

        (bool shouldTend,) = usd3Strategy.tendTrigger();
        assertTrue(shouldTend, "Should trigger tend when over-deployed vs backing");
    }

    function test_tendTrigger_trueWhenUnderDeployedWithIdleFunds() public {
        _bootstrapDebtAndBacking(1_000_000e6, 200_000e6, 200_000e6, 10_000);

        vm.prank(keeper);
        ITokenizedStrategy(address(strategy)).tend();

        // Increase sUSD3 backing via actual deposit flow (preserves ERC20 invariants)
        address charlie = makeAddr("charlie");
        deal(address(underlyingAsset), charlie, 800_000e6);
        vm.prank(charlie);
        asset.approve(address(strategy), type(uint256).max);
        vm.prank(charlie);
        strategy.deposit(800_000e6, charlie);
        _depositToSUSD3(charlie, strategy.balanceOf(charlie));

        (bool shouldTend,) = usd3Strategy.tendTrigger();
        assertTrue(shouldTend, "Should trigger tend when under-deployed with headroom");
    }

    function test_tendTrigger_falseWithinThreshold() public {
        _bootstrapDebtAndBacking(1_000_000e6, 200_000e6, 500_000e6, 10_000);

        // Tend to reach equilibrium
        vm.prank(keeper);
        ITokenizedStrategy(address(strategy)).tend();

        (bool shouldTend,) = usd3Strategy.tendTrigger();
        assertFalse(shouldTend, "Should not trigger tend at equilibrium");
    }

    function test_tendTrigger_configurableDriftThreshold() public {
        _bootstrapDebtAndBacking(2_000_000e6, 500_000e6, 500_000e6, 10_000);

        // Tend to reach equilibrium
        vm.prank(keeper);
        ITokenizedStrategy(address(strategy)).tend();

        // Drop sUSD3 backing slightly (~5%) to create moderate drift
        uint256 susd3USD3Balance = strategy.balanceOf(address(susd3Strategy));
        deal(address(strategy), address(susd3Strategy), (susd3USD3Balance * 95) / 100);

        // With default 10 bps (0.1%), ~5% drift should trigger
        (bool shouldTendDefault,) = usd3Strategy.tendTrigger();
        assertTrue(shouldTendDefault, "Should trigger with default 0.1% threshold");

        // Set large threshold (50%) — ~5% drift should NOT trigger
        protocolConfig.setConfig(ProtocolConfigLib.TEND_DRIFT_THRESHOLD, 5000);
        (bool shouldTendLarge,) = usd3Strategy.tendTrigger();
        assertFalse(shouldTendLarge, "Should not trigger with 50% threshold");

        // Set small threshold (1 bp = 0.01%) — should trigger again
        protocolConfig.setConfig(ProtocolConfigLib.TEND_DRIFT_THRESHOLD, 1);
        (bool shouldTendSmall,) = usd3Strategy.tendTrigger();
        assertTrue(shouldTendSmall, "Should trigger with 0.01% threshold");
    }

    function test_tendTrigger_revertsWhenDriftThresholdTooHigh() public {
        _bootstrapDebtAndBacking(1_000_000e6, 200_000e6, 500_000e6, 10_000);

        // 100% threshold should revert
        protocolConfig.setConfig(ProtocolConfigLib.TEND_DRIFT_THRESHOLD, 10_000);
        vm.expectRevert();
        usd3Strategy.tendTrigger();

        // Above 100% should also revert
        protocolConfig.setConfig(ProtocolConfigLib.TEND_DRIFT_THRESHOLD, 15_000);
        vm.expectRevert();
        usd3Strategy.tendTrigger();
    }

    /*//////////////////////////////////////////////////////////////
                    PASSTHROUGH / EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_maxOnCreditStricterThanBacking() public {
        _bootstrapDebtAndBacking(2_000_000e6, 500_000e6, 1_000_000e6, 10_000);
        setMaxOnCredit(3000); // 30% — much stricter than subordination cap

        vm.prank(keeper);
        ITokenizedStrategy(address(strategy)).tend();

        uint256 supplied = usd3Strategy.suppliedWaUSDC();
        uint256 total = supplied + usd3Strategy.balanceOfWaUSDC();
        uint256 maxOnCreditTarget = (total * 3000) / 10_000;

        assertLe(supplied, maxOnCreditTarget + 1, "maxOnCredit should dominate when stricter");
    }

    function test_backingRatioZeroPassthrough() public {
        // MIN_SUSD3_BACKING_RATIO = 0 means no subordination constraint
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 0);
        setMaxOnCredit(8000);

        vm.prank(alice);
        strategy.deposit(2_000_000e6, alice);

        vm.prank(keeper);
        strategy.report();

        uint256 supplied = usd3Strategy.suppliedWaUSDC();
        uint256 total = supplied + usd3Strategy.balanceOfWaUSDC();
        uint256 expected = (total * 8000) / 10_000;

        assertApproxEqAbs(supplied, expected, 2, "Should deploy per maxOnCredit when backingRatio=0");
    }

    function test_noDeploymentWhenSUSD3Empty() public {
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 10_000);
        setMaxOnCredit(10_000);

        // sUSD3 is linked but holds nothing
        vm.prank(alice);
        strategy.deposit(1_000_000e6, alice);

        vm.prank(keeper);
        strategy.report();

        uint256 supplied = usd3Strategy.suppliedWaUSDC();
        assertEq(supplied, 0, "Should not deploy when sUSD3 has no backing");
    }

    function test_effectiveCapIsMin() public {
        _bootstrapDebtAndBacking(1_000_000e6, 200_000e6, 300_000e6, 10_000);
        setMaxOnCredit(5000); // 50%

        vm.prank(keeper);
        ITokenizedStrategy(address(strategy)).tend();

        uint256 cap = _effectiveDeployCapWaUSDC();
        uint256 supplied = usd3Strategy.suppliedWaUSDC();
        uint256 total = supplied + usd3Strategy.balanceOfWaUSDC();

        uint256 maxOnCreditCap = (total * 5000) / 10_000;
        uint256 sUSD3ValueUSDC =
            ITokenizedStrategy(address(susd3Strategy)).convertToAssets(strategy.balanceOf(address(susd3Strategy)));
        uint256 subCap = waUSDC.convertToShares(sUSD3ValueUSDC);

        uint256 expectedCap = maxOnCreditCap < subCap ? maxOnCreditCap : subCap;
        assertApproxEqAbs(cap, expectedCap, 2, "Effective cap should be min(maxOnCredit, subordination)");
    }
}
