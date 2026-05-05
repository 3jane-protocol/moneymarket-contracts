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

    function _setCommitmentTime(uint256 duration) internal {
        vm.prank(protocolConfig.owner());
        protocolConfig.setConfig(ProtocolConfigLib.USD3_COMMITMENT_TIME, duration);
    }

    function test_committedLiquidity_defaultZeroPreservesWithdrawalBehavior() public {
        mintAndDepositIntoStrategy(strategy, alice, DEPOSIT);

        uint256 shares = strategy.balanceOf(alice);

        assertEq(usd3Strategy.committedLiquidity(), 0, "reserve should default to zero");
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
}
