// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "./utils/Setup.sol";
import {USD3} from "../../../src/usd3/USD3.sol";
import {IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {ProtocolConfigLib} from "../../../src/libraries/ProtocolConfigLib.sol";
import {MockProtocolConfig} from "./mocks/MockProtocolConfig.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

/**
 * @title USD3CommittedLiquidityTest
 * @notice Tests the ProtocolConfig-driven committed liquidity reserve for USD3 withdrawals.
 */
contract USD3CommittedLiquidityTest is Setup {
    USD3 public usd3Strategy;
    MockProtocolConfig public protocolConfig;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public facility = makeAddr("facility");
    address public payer = makeAddr("payer");
    address public susd3Holder = makeAddr("susd3Holder");

    uint256 private constant DEPOSIT = 10_000e6;
    uint256 private constant RESERVE = 2_500e6;
    uint256 private constant COMMITMENT_TIME = 7 days;

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));
        protocolConfig = MockProtocolConfig(IMorphoCredit(address(usd3Strategy.morphoCredit())).protocolConfig());
    }

    function _setCommittedLiquidity(uint256 amount) internal {
        vm.prank(protocolConfig.owner());
        protocolConfig.setConfig(ProtocolConfigLib.COMMITTED_LIQUIDITY, amount);
    }

    function _setFacility(address facility_) internal {
        vm.prank(protocolConfig.owner());
        protocolConfig.setConfig(ProtocolConfigLib.COMMITTED_LIQUIDITY_FACILITY, uint256(uint160(facility_)));
    }

    function _setCommitmentTime(uint256 duration) internal {
        vm.prank(protocolConfig.owner());
        protocolConfig.setConfig(ProtocolConfigLib.USD3_COMMITMENT_TIME, duration);
    }

    function _setProtocolPause(uint256 paused) internal {
        vm.prank(protocolConfig.owner());
        protocolConfig.setConfig(ProtocolConfigLib.IS_PAUSED, paused);
    }

    function _draw(uint256 amount) internal {
        vm.prank(facility);
        usd3Strategy.drawCommittedLiquidity(amount);
    }

    function _pricePerShare() internal view returns (uint256) {
        uint256 totalSupply = strategy.totalSupply();
        if (totalSupply == 0) return 0;
        return strategy.totalAssets() * 1e18 / totalSupply;
    }

    function test_committedLiquidity_defaultZeroPreservesWithdrawalBehavior() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);

        uint256 shares = strategy.balanceOf(alice);

        assertEq(usd3Strategy.committedLiquidity(), 0, "reserve should default to zero");
        assertEq(usd3Strategy.availableCommittedLiquidity(), 0, "undrawn reserve should default to zero");
        assertEq(usd3Strategy.maxCommittedLiquidityDraw(), 0, "draw limit should default to zero");
        assertEq(usd3Strategy.availableWithdrawLimit(alice), DEPOSIT, "withdraw limit should be unchanged");
        assertEq(strategy.maxWithdraw(alice), DEPOSIT, "maxWithdraw should be unchanged");
        assertEq(strategy.maxRedeem(alice), shares, "maxRedeem should be unchanged");
    }

    function test_committedLiquidity_reducesWithdrawAndRedeemLimits() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);

        uint256 expectedWithdraw = DEPOSIT - RESERVE;
        uint256 expectedRedeem = strategy.convertToShares(expectedWithdraw);

        assertEq(usd3Strategy.committedLiquidity(), RESERVE, "reserve should be set");
        assertEq(usd3Strategy.availableCommittedLiquidity(), RESERVE, "undrawn reserve should equal reserve");
        assertEq(usd3Strategy.maxCommittedLiquidityDraw(), RESERVE, "draw limit should equal liquid reserve");
        assertEq(usd3Strategy.availableWithdrawLimit(alice), expectedWithdraw, "withdraw limit should net reserve");
        assertEq(strategy.maxWithdraw(alice), expectedWithdraw, "maxWithdraw should net reserve");
        assertEq(strategy.maxRedeem(alice), expectedRedeem, "maxRedeem should net reserve");
    }

    function test_committedLiquidity_equalOrAboveLiquidityBlocksWithdrawals() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(DEPOSIT);

        assertEq(usd3Strategy.availableWithdrawLimit(alice), 0, "reserve should consume available liquidity");
        assertEq(strategy.maxWithdraw(alice), 0, "maxWithdraw should be zero");
        assertEq(strategy.maxRedeem(alice), 0, "maxRedeem should be zero");

        vm.prank(alice);
        vm.expectRevert("ERC4626: withdraw more than max");
        strategy.withdraw(1, alice, alice);

        vm.prank(alice);
        vm.expectRevert("ERC4626: redeem more than max");
        strategy.redeem(1, alice, alice);
    }

    function test_committedLiquidity_aboveTotalAssetsClampsToZero() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(DEPOSIT + 1);

        assertEq(usd3Strategy.availableWithdrawLimit(alice), 0, "withdraw limit should clamp to zero");
        assertEq(strategy.maxWithdraw(alice), 0, "maxWithdraw should clamp to zero");
        assertEq(strategy.maxRedeem(alice), 0, "maxRedeem should clamp to zero");
    }

    function test_committedLiquidity_shutdownStillEnforcesReserveButBypassesCommitment() public {
        _setCommitmentTime(COMMITMENT_TIME);
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);

        vm.prank(alice);
        vm.expectRevert("ERC4626: withdraw more than max");
        strategy.withdraw(1, alice, alice);

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        uint256 availableAfterShutdown = DEPOSIT - RESERVE;

        assertEq(
            usd3Strategy.availableWithdrawLimit(alice),
            availableAfterShutdown,
            "shutdown should bypass commitment but keep reserve"
        );
        assertEq(strategy.maxWithdraw(alice), availableAfterShutdown, "shutdown maxWithdraw should keep reserve");

        vm.prank(alice);
        uint256 sharesBurned = strategy.withdraw(availableAfterShutdown, alice, alice);
        assertEq(sharesBurned, strategy.convertToShares(availableAfterShutdown), "withdraw should burn expected shares");

        assertEq(usd3Strategy.availableWithdrawLimit(alice), 0, "remaining liquidity should be reserved");
    }

    function test_committedLiquidity_doesNotAffectDepositLimit() public {
        uint256 limitBefore = usd3Strategy.availableDepositLimit(bob);
        _setCommittedLiquidity(type(uint256).max);

        assertEq(usd3Strategy.availableDepositLimit(bob), limitBefore, "deposit limit should ignore reserve");

        mintAndDepositIntoStrategy(strategy, bob, DEPOSIT);
        assertEq(strategy.balanceOf(bob), DEPOSIT, "deposit should still mint shares");
    }

    function test_committedLiquidity_doesNotAffectTendDeployment() public {
        setMaxOnCredit(5000);
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);

        uint256 deployedBefore = usd3Strategy.suppliedWaUSDC();
        _setCommittedLiquidity(RESERVE);

        vm.prank(keeper);
        ITokenizedStrategy(address(strategy)).tend();

        uint256 deployedAfter = usd3Strategy.suppliedWaUSDC();
        assertEq(deployedAfter, deployedBefore, "reserve should not change tend deployment target");
        assertEq(deployedAfter, DEPOSIT / 2, "deployment should still follow maxOnCredit");
    }

    function test_facility_unsetReverts() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);

        vm.prank(facility);
        vm.expectRevert("USD3/not-facility");
        usd3Strategy.drawCommittedLiquidity(1);
    }

    function test_facility_unauthorizedCallerReverts() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);

        vm.prank(bob);
        vm.expectRevert("USD3/not-facility");
        usd3Strategy.drawCommittedLiquidity(1);
    }

    function test_facility_drawTransfersUsdcAndIncrementsDrawn() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);

        uint256 facilityBalanceBefore = underlyingAsset.balanceOf(facility);

        vm.prank(facility);
        vm.expectEmit(true, true, true, true);
        emit USD3.CommittedLiquidityDrawn(facility, RESERVE, RESERVE);
        usd3Strategy.drawCommittedLiquidity(RESERVE);

        assertEq(underlyingAsset.balanceOf(facility), facilityBalanceBefore + RESERVE, "facility should receive USDC");
        assertEq(usd3Strategy.committedLiquidityDrawn(), RESERVE, "drawn should increase");
        assertEq(usd3Strategy.availableCommittedLiquidity(), 0, "undrawn commitment should be consumed");
        assertEq(usd3Strategy.maxCommittedLiquidityDraw(), 0, "draw limit should be consumed");
    }

    function test_facility_drawUsesIdleUsdcBeforeUnwindingMorpho() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);

        airdrop(underlyingAsset, address(usd3Strategy), 1_000e6);
        uint256 suppliedBefore = usd3Strategy.suppliedWaUSDC();

        _draw(1_000e6);

        assertEq(usd3Strategy.suppliedWaUSDC(), suppliedBefore, "idle USDC draw should not unwind Morpho");
        assertEq(underlyingAsset.balanceOf(facility), 1_000e6, "facility should receive idle USDC");
    }

    function test_facility_drawUnwindsFromMorpho() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);

        uint256 suppliedBefore = usd3Strategy.suppliedWaUSDC();
        assertGt(suppliedBefore, 0, "setup should deploy to Morpho");

        _draw(RESERVE);

        assertLt(usd3Strategy.suppliedWaUSDC(), suppliedBefore, "draw should unwind Morpho supply");
        assertEq(underlyingAsset.balanceOf(facility), RESERVE, "facility should receive USDC");
    }

    function test_facility_drawExceedingCommitmentReverts() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);

        vm.prank(facility);
        vm.expectRevert("USD3/exceeds-commitment");
        usd3Strategy.drawCommittedLiquidity(RESERVE + 1);
    }

    function test_facility_drawAboveLiquidFundsReverts() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        createMarketDebt(makeAddr("borrower"), DEPOSIT - 1_000e6);
        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);

        assertLt(usd3Strategy.maxCommittedLiquidityDraw(), RESERVE, "liquidity should be below commitment");

        vm.prank(facility);
        vm.expectRevert("USD3/insufficient-liquid");
        usd3Strategy.drawCommittedLiquidity(RESERVE);
    }

    function test_facility_drawBlockedDuringShutdown() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        vm.prank(facility);
        vm.expectRevert("USD3/shutdown");
        usd3Strategy.drawCommittedLiquidity(1);
    }

    function test_facility_drawBlockedWhenPaused() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);
        _setProtocolPause(1);

        vm.prank(facility);
        vm.expectRevert("USD3/paused");
        usd3Strategy.drawCommittedLiquidity(1);
    }

    function test_facility_drawBypassesCommitmentTime() public {
        _setCommitmentTime(COMMITMENT_TIME);
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);

        assertEq(usd3Strategy.availableWithdrawLimit(alice), 0, "alice should be locked by commitment time");

        _draw(RESERVE);

        assertEq(underlyingAsset.balanceOf(facility), RESERVE, "facility draw should bypass commitment time");
    }

    function test_facility_withdrawLimitUsesUndrawnOnly() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);

        uint256 beforeDrawLimit = usd3Strategy.availableWithdrawLimit(alice);

        _draw(1_000e6);

        assertEq(usd3Strategy.availableCommittedLiquidity(), RESERVE - 1_000e6, "undrawn should decrease");
        assertEq(usd3Strategy.availableWithdrawLimit(alice), beforeDrawLimit, "draw should not reduce withdraw limit");
    }

    function test_facility_loweredCommitmentBelowDrawnBlocksFurtherDraws() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);

        _draw(RESERVE);
        _setCommittedLiquidity(RESERVE - 1);

        assertEq(usd3Strategy.availableCommittedLiquidity(), 0, "undrawn commitment should clamp to zero");
        assertEq(usd3Strategy.maxCommittedLiquidityDraw(), 0, "draw limit should clamp to zero");

        vm.prank(facility);
        vm.expectRevert("USD3/exceeds-commitment");
        usd3Strategy.drawCommittedLiquidity(1);
    }

    function test_facility_maxCommittedLiquidityDrawUsesLiquidityAndUndrawn() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        createMarketDebt(makeAddr("borrower"), DEPOSIT - 1_000e6);
        _setCommittedLiquidity(RESERVE);

        assertEq(usd3Strategy.availableCommittedLiquidity(), RESERVE, "undrawn should equal reserve");
        assertApproxEqAbs(usd3Strategy.maxCommittedLiquidityDraw(), 1_000e6, 2, "draw max should be liquidity-bound");
    }

    function test_facility_repayDecreasesDrawn() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);
        _draw(RESERVE);

        airdrop(underlyingAsset, payer, 1_000e6);
        vm.startPrank(payer);
        underlyingAsset.approve(address(usd3Strategy), 1_000e6);
        usd3Strategy.repayCommittedLiquidity(1_000e6);
        vm.stopPrank();

        assertEq(usd3Strategy.committedLiquidityDrawn(), RESERVE - 1_000e6, "drawn should decrease");
        assertEq(usd3Strategy.availableCommittedLiquidity(), 1_000e6, "repaid amount should reopen capacity");
    }

    function test_facility_repayMaxRepaysFull() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);
        _draw(RESERVE);

        airdrop(underlyingAsset, payer, RESERVE);
        vm.startPrank(payer);
        underlyingAsset.approve(address(usd3Strategy), RESERVE);
        usd3Strategy.repayCommittedLiquidity(type(uint256).max);
        vm.stopPrank();

        assertEq(usd3Strategy.committedLiquidityDrawn(), 0, "max sentinel should repay full drawn amount");
        assertEq(usd3Strategy.availableCommittedLiquidity(), RESERVE, "full capacity should reopen");
    }

    function test_facility_repayOverpaymentReverts() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);
        _draw(1_000e6);

        airdrop(underlyingAsset, payer, 1_001e6);
        vm.startPrank(payer);
        underlyingAsset.approve(address(usd3Strategy), 1_001e6);
        vm.expectRevert("USD3/overpayment");
        usd3Strategy.repayCommittedLiquidity(1_001e6);
        vm.stopPrank();
    }

    function test_facility_repayByAnyoneAllowed() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);
        _draw(1_000e6);

        airdrop(underlyingAsset, bob, 1_000e6);
        vm.startPrank(bob);
        underlyingAsset.approve(address(usd3Strategy), 1_000e6);
        usd3Strategy.repayCommittedLiquidity(1_000e6);
        vm.stopPrank();

        assertEq(usd3Strategy.committedLiquidityDrawn(), 0, "third-party repayment should clear drawn amount");
    }

    function test_facility_repaidCapacityCanBeRedrawn() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);
        _draw(RESERVE);

        airdrop(underlyingAsset, payer, RESERVE);
        vm.startPrank(payer);
        underlyingAsset.approve(address(usd3Strategy), RESERVE);
        usd3Strategy.repayCommittedLiquidity(RESERVE);
        vm.stopPrank();

        _draw(RESERVE);

        assertEq(usd3Strategy.committedLiquidityDrawn(), RESERVE, "repaid capacity should be drawable again");
    }

    function test_facility_reportAfterDrawPreservesSharePrice() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);

        uint256 ppsBefore = _pricePerShare();

        _draw(RESERVE);

        vm.prank(keeper);
        strategy.report();

        assertEq(_pricePerShare(), ppsBefore, "draw receivable should preserve PPS");
        assertEq(strategy.totalAssets(), DEPOSIT, "drawn principal should remain in totalAssets");
    }

    function test_facility_writeDownReducesDrawnAndRealizesLossOnReport() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);

        vm.prank(management);
        usd3Strategy.setSUSD3(susd3Holder);

        vm.prank(alice);
        usd3Strategy.transfer(susd3Holder, 1_000e6);

        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);
        _draw(1_000e6);

        vm.prank(keeper);
        strategy.report();

        uint256 susd3BalanceBefore = strategy.balanceOf(susd3Holder);
        assertEq(susd3BalanceBefore, 1_000e6, "setup should seed sUSD3 protection");

        vm.prank(management);
        usd3Strategy.writeDownCommittedLiquidity(1_000e6);

        vm.prank(keeper);
        (, uint256 loss) = strategy.report();

        assertEq(loss, 1_000e6, "write-down should realize loss on report");
        assertEq(usd3Strategy.committedLiquidityDrawn(), 0, "write-down should reduce drawn amount");
        assertEq(strategy.balanceOf(susd3Holder), 0, "sUSD3 balance should absorb loss first");
    }

    function test_facility_writeDownAboveSusd3CushionDropsUsd3Pps() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);

        vm.prank(management);
        usd3Strategy.setSUSD3(susd3Holder);

        vm.prank(alice);
        usd3Strategy.transfer(susd3Holder, 500e6);

        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);
        _draw(1_000e6);

        vm.prank(keeper);
        strategy.report();

        uint256 ppsBefore = _pricePerShare();
        uint256 totalSupplyBefore = strategy.totalSupply();

        vm.prank(management);
        usd3Strategy.writeDownCommittedLiquidity(1_000e6);

        vm.prank(keeper);
        (, uint256 loss) = strategy.report();

        assertEq(loss, 1_000e6, "write-down should realize full loss");
        assertEq(strategy.balanceOf(susd3Holder), 0, "sUSD3 cushion should be exhausted");
        assertEq(totalSupplyBefore - strategy.totalSupply(), 500e6, "only available sUSD3 shares should burn");
        assertLt(_pricePerShare(), ppsBefore, "residual loss should reduce USD3 PPS");
    }

    function test_facility_writeDownAboveDrawnReverts() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);
        _draw(1_000e6);

        vm.prank(management);
        vm.expectRevert("USD3/bad-writedown");
        usd3Strategy.writeDownCommittedLiquidity(1_001e6);
    }

    function test_facility_writeDownByNonManagementReverts() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);
        _setCommittedLiquidity(RESERVE);
        _setFacility(facility);
        _draw(1_000e6);

        vm.prank(bob);
        vm.expectRevert();
        usd3Strategy.writeDownCommittedLiquidity(1);
    }
}
