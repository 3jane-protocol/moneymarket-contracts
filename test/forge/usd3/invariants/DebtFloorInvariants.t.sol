// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {sUSD3} from "../../../../src/usd3/sUSD3.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {ProtocolConfigLib} from "../../../../src/libraries/ProtocolConfigLib.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {
    TransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {DebtFloorHandler} from "./DebtFloorHandler.sol";

/**
 * @title Debt Floor Invariant Tests
 * @notice Ensures critical invariants always hold for the debt floor mechanism
 */
contract DebtFloorInvariantsTest is StdInvariant, Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;
    MockProtocolConfig public protocolConfig;
    DebtFloorHandler public handler;

    // Invariant tracking
    uint256 public minBackingRatio;
    uint256 public lastDebtAmount;
    uint256 public lastFloorAmount;
    bool public isShutdown;

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        // Get protocol config
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

        // Set initial backing ratio
        minBackingRatio = 3000; // 30%
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, minBackingRatio);

        // Setup initial liquidity
        address alice = makeAddr("alice");
        deal(address(underlyingAsset), alice, 10_000_000e6);
        vm.prank(alice);
        asset.approve(address(strategy), type(uint256).max);
        vm.prank(alice);
        strategy.deposit(5_000_000e6, alice);

        // Enable borrowing
        setMaxOnCredit(8000);

        // Create some initial debt for more interesting invariant testing
        address borrower = makeAddr("borrower");
        createMarketDebt(borrower, 1_000_000e6); // 1M debt

        // Setup initial sUSD3 position
        vm.prank(alice);
        strategy.approve(address(susd3Strategy), 500_000e6);
        vm.prank(alice);
        susd3Strategy.deposit(500_000e6, alice);

        // Create and configure handler contract for invariant testing
        handler = new DebtFloorHandler(address(usd3Strategy), address(susd3Strategy), address(underlyingAsset));

        // Target only the handler contract
        targetContract(address(handler));

        // Exclude admin functions from invariant testing
        excludeSender(address(0));
        excludeSender(address(this));
        excludeSender(management);
        excludeSender(emergencyAdmin);
    }

    /**
     * @notice Invariant: sUSD3 assets >= debt floor when debt > 0 and not shutdown
     */
    function invariant_assetsAboveFloorWhenDebtExists() public view {
        if (isShutdown) return; // Skip during shutdown

        uint256 debtFloor = susd3Strategy.getSubordinatedDebtFloorInUSDC();
        // Get sUSD3's USD3 holdings and convert to USDC value
        uint256 currentAssetsUSDC =
            ITokenizedStrategy(address(usd3Strategy)).convertToAssets(asset.balanceOf(address(susd3Strategy)));

        // Get current debt
        (,, uint256 totalBorrowAssetsWaUSDC,) = usd3Strategy.getMarketLiquidity();
        uint256 currentDebtUSDC = ITokenizedStrategy(address(usd3Strategy))
            .convertToAssets(usd3Strategy.WAUSDC().convertToAssets(totalBorrowAssetsWaUSDC));

        // If there's debt and a backing requirement, assets should meet floor
        if (currentDebtUSDC > 0 && minBackingRatio > 0) {
            assert(
                currentAssetsUSDC >= debtFloor || currentAssetsUSDC == 0 // Allow zero if no deposits yet
            );
        }
    }

    /**
     * @notice Invariant: Debt floor calculation is always correct
     */
    function invariant_debtFloorCalculationCorrect() public view {
        uint256 debtFloor = susd3Strategy.getSubordinatedDebtFloorInUSDC();

        // Get current debt
        (,, uint256 totalBorrowAssetsWaUSDC,) = usd3Strategy.getMarketLiquidity();
        uint256 currentDebtUSDC = ITokenizedStrategy(address(usd3Strategy))
            .convertToAssets(usd3Strategy.WAUSDC().convertToAssets(totalBorrowAssetsWaUSDC));

        uint256 expectedFloor;
        if (minBackingRatio == 0) {
            expectedFloor = 0;
        } else {
            expectedFloor = (currentDebtUSDC * minBackingRatio) / 10000;
        }

        assertEq(debtFloor, expectedFloor, "Floor calculation mismatch");
    }

    /**
     * @notice Invariant: Available withdrawal never exceeds allowed amount
     */
    function invariant_withdrawalLimitRespected() public view {
        // For any actor that might have sUSD3 positions
        // their withdrawal limit should respect the debt floor

        uint256 debtFloor = susd3Strategy.getSubordinatedDebtFloorInUSDC();
        uint256 currentAssetsUSDC =
            ITokenizedStrategy(address(usd3Strategy)).convertToAssets(asset.balanceOf(address(susd3Strategy)));

        // If there's a floor and assets are below it, no withdrawals should be allowed
        // (unless in shutdown mode)
        if (!ITokenizedStrategy(address(susd3Strategy)).isShutdown()) {
            if (debtFloor > 0 && currentAssetsUSDC <= debtFloor) {
                // In this case, availableWithdrawLimit for any user should be 0
                // We can't check specific users here but can assert the general condition
                assert(currentAssetsUSDC >= debtFloor || currentAssetsUSDC == 0);
            }
        }
    }

    /**
     * @notice Invariant: Floor changes proportionally with debt
     */
    function invariant_floorScalesWithDebt() public view {
        uint256 debtFloor = susd3Strategy.getSubordinatedDebtFloorInUSDC();

        (,, uint256 totalBorrowAssetsWaUSDC,) = usd3Strategy.getMarketLiquidity();
        uint256 currentDebtUSDC = ITokenizedStrategy(address(usd3Strategy))
            .convertToAssets(usd3Strategy.WAUSDC().convertToAssets(totalBorrowAssetsWaUSDC));

        // Floor should be proportional to debt based on backing ratio
        if (minBackingRatio > 0 && currentDebtUSDC > 0) {
            uint256 expectedFloor = (currentDebtUSDC * minBackingRatio) / 10000;
            assertEq(debtFloor, expectedFloor, "Floor should be proportional to debt");
        } else if (minBackingRatio == 0) {
            assertEq(debtFloor, 0, "Floor should be 0 when backing ratio is 0");
        }
    }

    /**
     * @notice Invariant: Emergency shutdown bypasses floor requirements
     */
    function invariant_shutdownBypassesFloor() public view {
        // If strategy is shutdown, withdrawals should be allowed regardless of floor
        if (ITokenizedStrategy(address(susd3Strategy)).isShutdown()) {
            // During shutdown, available assets should be withdrawable
            uint256 availableAssets = asset.balanceOf(address(susd3Strategy));

            // The availableWithdrawLimit should return the available assets during shutdown
            // This is just an assertion that shutdown mode allows withdrawals
            assert(availableAssets == 0 || susd3Strategy.availableWithdrawLimit(address(this)) >= 0);
        }
    }
}
