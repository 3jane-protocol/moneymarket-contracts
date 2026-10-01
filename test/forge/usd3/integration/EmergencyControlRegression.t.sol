// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {ProtocolConfigLib} from "../../../../src/libraries/ProtocolConfigLib.sol";
import {ErrorsLib} from "../../../../src/libraries/ErrorsLib.sol";
import {IMorpho, Id, MarketParams} from "../../../../src/interfaces/IMorpho.sol";
import {EmergencyController} from "../../../../src/EmergencyController.sol";

/**
 * @title Emergency Control Regression Test
 * @notice Tests that emergency controls actually block operations, not just set config values.
 * @dev This fills a gap in EmergencyIntegration.t.sol which only verifies config is set
 *      but never tests downstream behavior (borrowing/deposits blocked).
 */
contract EmergencyControlRegressionTest is Setup {
    USD3 public usd3Strategy;
    MockProtocolConfig public protocolConfig;
    EmergencyController public emergencyController;

    address public alice = makeAddr("alice");
    address public borrower = makeAddr("borrower");
    address public emergencyMultisig = makeAddr("emergencyMultisig");

    uint256 public constant DEPOSIT_AMOUNT = 1_000_000e6;

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        address morphoAddress = address(usd3Strategy.morphoCredit());
        protocolConfig = MockProtocolConfig(MorphoCredit(morphoAddress).protocolConfig());

        // Get creditLine from the market params
        MarketParams memory marketParams = usd3Strategy.marketParams();

        // Deploy EmergencyController
        address[] memory emergencyAuthorized = new address[](1);
        emergencyAuthorized[0] = emergencyMultisig;
        emergencyController = new EmergencyController(
            address(protocolConfig), marketParams.creditLine, emergencyMultisig, emergencyAuthorized
        );

        // Set EmergencyController as emergencyAdmin
        protocolConfig.setEmergencyAdmin(address(emergencyController));

        // Fund alice
        deal(address(underlyingAsset), alice, DEPOSIT_AMOUNT * 2);
    }

    function test_emergencyDebtCapZero_blocksBorrowing() public {
        // Setup: Alice deposits liquidity
        vm.prank(alice);
        asset.approve(address(strategy), DEPOSIT_AMOUNT);
        vm.prank(alice);
        strategy.deposit(DEPOSIT_AMOUNT, alice);

        setMaxOnCredit(8000);

        // Deploy funds
        vm.prank(keeper);
        strategy.report();

        // Emergency action: set debt cap to 0 via EmergencyController
        vm.prank(emergencyMultisig);
        emergencyController.setConfig(ProtocolConfigLib.DEBT_CAP, 0);

        // Setup borrower credit line
        IMorpho morpho = USD3(address(strategy)).morphoCredit();
        Id marketId = USD3(address(strategy)).marketId();
        MarketParams memory marketParams = USD3(address(strategy)).marketParams();

        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);
        vm.prank(marketParams.creditLine);
        MorphoCredit(address(morpho))
            .closeCycleAndPostObligations(marketId, block.timestamp, borrowers, repaymentBps, endingBalances);

        vm.prank(marketParams.creditLine);
        MorphoCredit(address(morpho)).setCreditLine(marketId, borrower, DEPOSIT_AMOUNT, 0);

        // Verify borrowing is blocked
        vm.expectRevert(ErrorsLib.DebtCapExceeded.selector);
        vm.prank(borrower);
        helper.borrow(marketParams, 1_000e6, 0, borrower, borrower);
    }

    function test_emergencySupplyCapZero_blocksDeposits() public {
        // Setup: initial deposit
        vm.prank(alice);
        asset.approve(address(strategy), DEPOSIT_AMOUNT);
        vm.prank(alice);
        strategy.deposit(100_000e6, alice);

        // Emergency action: set supply cap to 0 via EmergencyController
        vm.prank(emergencyMultisig);
        emergencyController.setConfig(ProtocolConfigLib.USD3_SUPPLY_CAP, 0);

        // Verify deposits return 0 available
        uint256 available = strategy.availableDepositLimit(alice);
        assertEq(available, 0, "Should block deposits when supply cap is 0");
    }
}
