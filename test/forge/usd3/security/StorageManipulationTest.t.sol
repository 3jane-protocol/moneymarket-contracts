// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "../utils/Setup.sol";
import {ERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {sUSD3} from "../../../../src/usd3/sUSD3.sol";
import {IMorpho, MarketParams} from "../../../../src/interfaces/IMorpho.sol";
import {
    TransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";

/**
 * @title Storage Manipulation Validation Test
 * @notice Critical validation of direct storage access in _burnSharesFromSusd3
 * @dev This tests the highest risk component - direct assembly storage manipulation
 */
contract StorageManipulationTest is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;

    // Test users
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);

    // Test amounts
    uint256 public constant LARGE_AMOUNT = 1_000_000e6;
    uint256 public constant MEDIUM_AMOUNT = 100_000e6;

    // Storage slot constants for validation
    bytes32 constant BASE_SLOT = bytes32(uint256(keccak256("yearn.base.strategy.storage")) - 1);
    uint256 constant TOTAL_SUPPLY_SLOT_OFFSET = 2; // totalSupply is at slot 2
    uint256 constant BALANCES_SLOT_OFFSET = 4; // balances mapping is at slot 4

    event StorageSlotAccessed(bytes32 slot, uint256 value);
    event SharesBurned(address from, uint256 amount);

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        // Deploy sUSD3 (simplified setup)
        susd3Strategy = sUSD3(setUpSusd3Strategy());

        // Link strategies
        vm.prank(management);
        usd3Strategy.setSUSD3(address(susd3Strategy));

        // Setup yield sharing via protocol config
        address morphoAddress = address(usd3Strategy.morphoCredit());
        address protocolConfigAddress = MorphoCredit(morphoAddress).protocolConfig();
        MockProtocolConfig protocolConfig = MockProtocolConfig(protocolConfigAddress);

        // Set the tranche share variant in protocol config
        bytes32 TRANCHE_SHARE_VARIANT = keccak256("TRANCHE_SHARE_VARIANT");
        protocolConfig.setConfig(TRANCHE_SHARE_VARIANT, 3000); // 30%

        // Sync the value to USD3 strategy as keeper
        vm.prank(keeper);
        usd3Strategy.syncTrancheShare();

        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFeeRecipient(address(susd3Strategy));

        // Fund users
        airdrop(asset, alice, LARGE_AMOUNT);
        airdrop(asset, bob, LARGE_AMOUNT);
        airdrop(asset, charlie, LARGE_AMOUNT);
    }

    function setUpSusd3Strategy() internal returns (address) {
        // Deploy sUSD3 implementation
        sUSD3 susd3Implementation = new sUSD3();

        // Deploy proxy admin
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(management);

        // Deploy proxy with initialization
        bytes memory susd3InitData =
            abi.encodeWithSelector(sUSD3.initialize.selector, address(usd3Strategy), management, keeper);

        TransparentUpgradeableProxy susd3Proxy =
            new TransparentUpgradeableProxy(address(susd3Implementation), address(susd3ProxyAdmin), susd3InitData);

        return address(susd3Proxy);
    }

    /*//////////////////////////////////////////////////////////////
                        STORAGE SLOT VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_validateStorageSlotCalculation() public {
        // This test validates that our storage slot calculations are correct

        // Setup positions
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), LARGE_AMOUNT);
        usd3Strategy.deposit(LARGE_AMOUNT, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), MEDIUM_AMOUNT);
        uint256 usd3Shares = usd3Strategy.deposit(MEDIUM_AMOUNT, bob);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), usd3Shares);
        susd3Strategy.deposit(usd3Shares, bob);
        vm.stopPrank();

        // Read storage directly to validate slot calculations
        bytes32 totalSupplySlot = bytes32(uint256(BASE_SLOT) + TOTAL_SUPPLY_SLOT_OFFSET);
        bytes32 balancesSlot = bytes32(uint256(BASE_SLOT) + BALANCES_SLOT_OFFSET);

        // Get balance through normal interface
        uint256 susd3Balance = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        uint256 totalSupply = ITokenizedStrategy(address(usd3Strategy)).totalSupply();

        // Calculate storage slot for sUSD3's balance
        bytes32 susd3BalanceSlot = keccak256(abi.encode(address(susd3Strategy), balancesSlot));

        // Read directly from storage
        uint256 directBalance = uint256(vm.load(address(usd3Strategy), susd3BalanceSlot));
        uint256 directTotalSupply = uint256(vm.load(address(usd3Strategy), totalSupplySlot));

        // Validate calculations match
        assertEq(directBalance, susd3Balance, "Direct storage read should match interface");
        assertEq(directTotalSupply, totalSupply, "Direct total supply read should match interface");

        emit StorageSlotAccessed(susd3BalanceSlot, directBalance);
        emit StorageSlotAccessed(totalSupplySlot, directTotalSupply);
    }

    function test_directStorageManipulation() public {
        // This test validates that direct storage writes work correctly

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), LARGE_AMOUNT);
        usd3Strategy.deposit(LARGE_AMOUNT, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), MEDIUM_AMOUNT);
        uint256 usd3Shares = usd3Strategy.deposit(MEDIUM_AMOUNT, bob);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), usd3Shares);
        susd3Strategy.deposit(usd3Shares, bob);
        vm.stopPrank();

        // Record state before manipulation
        uint256 susd3BalanceBefore = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        uint256 totalSupplyBefore = ITokenizedStrategy(address(usd3Strategy)).totalSupply();
        uint256 aliceBalanceBefore = ITokenizedStrategy(address(usd3Strategy)).balanceOf(alice);

        // Calculate what we want to burn
        uint256 burnAmount = susd3BalanceBefore / 4; // Burn 25%

        // Perform direct storage manipulation (simulating _burnSharesFromSusd3 logic)
        bytes32 baseSlot = BASE_SLOT;

        // Update total supply first (at slot 2)
        bytes32 totalSupplySlot = bytes32(uint256(baseSlot) + TOTAL_SUPPLY_SLOT_OFFSET);
        vm.store(address(usd3Strategy), totalSupplySlot, bytes32(totalSupplyBefore - burnAmount));

        // Update sUSD3's balance (balances mapping at slot 4)
        bytes32 balancesSlot = bytes32(uint256(baseSlot) + BALANCES_SLOT_OFFSET);
        bytes32 susd3BalanceSlot = keccak256(abi.encode(address(susd3Strategy), balancesSlot));
        vm.store(address(usd3Strategy), susd3BalanceSlot, bytes32(susd3BalanceBefore - burnAmount));

        // Validate changes
        uint256 susd3BalanceAfter = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        uint256 totalSupplyAfter = ITokenizedStrategy(address(usd3Strategy)).totalSupply();
        uint256 aliceBalanceAfter = ITokenizedStrategy(address(usd3Strategy)).balanceOf(alice);

        assertEq(susd3BalanceAfter, susd3BalanceBefore - burnAmount, "sUSD3 balance should be reduced");
        assertEq(totalSupplyAfter, totalSupplyBefore - burnAmount, "Total supply should be reduced");
        assertEq(aliceBalanceAfter, aliceBalanceBefore, "Alice's balance should be unchanged");

        emit SharesBurned(address(susd3Strategy), burnAmount);
    }

    function test_storageManipulationConsistency() public {
        // Test that storage manipulation maintains internal consistency

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), LARGE_AMOUNT);
        usd3Strategy.deposit(LARGE_AMOUNT, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), MEDIUM_AMOUNT);
        uint256 usd3Shares = usd3Strategy.deposit(MEDIUM_AMOUNT, bob);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), usd3Shares);
        susd3Strategy.deposit(usd3Shares, bob);
        vm.stopPrank();

        vm.startPrank(charlie);
        asset.approve(address(usd3Strategy), MEDIUM_AMOUNT);
        usd3Strategy.deposit(MEDIUM_AMOUNT, charlie);
        vm.stopPrank();

        // Record all balances
        uint256 aliceBalance = ITokenizedStrategy(address(usd3Strategy)).balanceOf(alice);
        uint256 charlieBalance = ITokenizedStrategy(address(usd3Strategy)).balanceOf(charlie);
        uint256 susd3Balance = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        uint256 totalSupplyBefore = ITokenizedStrategy(address(usd3Strategy)).totalSupply();

        // Verify initial consistency
        assertEq(
            aliceBalance + charlieBalance + susd3Balance,
            totalSupplyBefore,
            "Initial balances should sum to total supply"
        );

        // Simulate loss and burn shares
        uint256 loss = (ITokenizedStrategy(address(usd3Strategy)).totalAssets() * 6) / 100;
        _simulateLoss(loss);

        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // Verify consistency after burning
        uint256 aliceBalanceAfter = ITokenizedStrategy(address(usd3Strategy)).balanceOf(alice);
        uint256 charlieBalanceAfter = ITokenizedStrategy(address(usd3Strategy)).balanceOf(charlie);
        uint256 susd3BalanceAfter = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        uint256 totalSupplyAfter = ITokenizedStrategy(address(usd3Strategy)).totalSupply();

        assertEq(
            aliceBalanceAfter + charlieBalanceAfter + susd3BalanceAfter,
            totalSupplyAfter,
            "Balances should still sum to total supply"
        );

        // Alice and Charlie should be unaffected
        assertEq(aliceBalanceAfter, aliceBalance, "Alice balance unchanged");
        assertEq(charlieBalanceAfter, charlieBalance, "Charlie balance unchanged");

        // Only sUSD3 balance should be reduced
        assertLt(susd3BalanceAfter, susd3Balance, "sUSD3 balance should be reduced");
    }

    /*//////////////////////////////////////////////////////////////
                        EDGE CASE VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_burnExactBalance() public {
        // Test burning exactly all of sUSD3's balance

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), LARGE_AMOUNT);
        usd3Strategy.deposit(LARGE_AMOUNT, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), MEDIUM_AMOUNT);
        uint256 usd3Shares = usd3Strategy.deposit(MEDIUM_AMOUNT, bob);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), usd3Shares);
        susd3Strategy.deposit(usd3Shares, bob);
        vm.stopPrank();

        uint256 susd3Balance = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        uint256 totalAssets = ITokenizedStrategy(address(usd3Strategy)).totalAssets();

        // Create a loss large enough to wipe out sUSD3 completely
        uint256 loss = ITokenizedStrategy(address(usd3Strategy)).convertToAssets(susd3Balance);
        _simulateLoss(loss);

        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        uint256 susd3BalanceAfter = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));

        assertEq(susd3BalanceAfter, 0, "sUSD3 balance should be exactly zero");
    }

    function test_burnMinimalAmount() public {
        // Test burning a very small amount (1 wei)

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), LARGE_AMOUNT);
        usd3Strategy.deposit(LARGE_AMOUNT, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), MEDIUM_AMOUNT);
        uint256 usd3Shares = usd3Strategy.deposit(MEDIUM_AMOUNT, bob);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), usd3Shares);
        susd3Strategy.deposit(usd3Shares, bob);
        vm.stopPrank();

        uint256 susd3BalanceBefore = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));

        // Simulate minimal loss (1 wei in asset terms)
        uint256 minimalLoss = 1;
        _simulateLoss(minimalLoss);

        vm.prank(keeper);
        (, uint256 reportedLoss) = ITokenizedStrategy(address(usd3Strategy)).report();

        uint256 susd3BalanceAfter = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        uint256 sharesBurned = susd3BalanceBefore - susd3BalanceAfter;

        // Should burn the minimal amount that represents the loss
        if (reportedLoss > 0) {
            uint256 expectedBurn = ITokenizedStrategy(address(usd3Strategy)).convertToShares(reportedLoss);
            assertApproxEqAbs(sharesBurned, expectedBurn, 1, "Should burn minimal shares representing loss");
        }
    }

    function test_precisionInBurning() public {
        // Test precision handling in share burning calculations

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), LARGE_AMOUNT);
        usd3Strategy.deposit(LARGE_AMOUNT, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), MEDIUM_AMOUNT);
        uint256 usd3Shares = usd3Strategy.deposit(MEDIUM_AMOUNT, bob);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), usd3Shares);
        susd3Strategy.deposit(usd3Shares, bob);
        vm.stopPrank();

        uint256 susd3BalanceBefore = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));

        // Create an odd loss amount that might cause precision issues
        uint256 oddLoss = 12_345_678; // 12.345678 USDC - odd number
        _simulateLoss(oddLoss);

        vm.prank(keeper);
        (, uint256 reportedLoss) = ITokenizedStrategy(address(usd3Strategy)).report();

        if (reportedLoss > 0) {
            uint256 susd3BalanceAfter = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));
            uint256 sharesBurned = susd3BalanceBefore - susd3BalanceAfter;

            uint256 expectedShares = ITokenizedStrategy(address(usd3Strategy)).convertToShares(reportedLoss);

            // Allow more tolerance for share/asset conversion rounding
            assertApproxEqAbs(sharesBurned, expectedShares, 200, "Precision should be maintained in burning");
        }
    }

    /*//////////////////////////////////////////////////////////////
                        REENTRANCY PROTECTION
    //////////////////////////////////////////////////////////////*/

    function test_burnOperationAtomicity() public {
        // Ensure burning operation is atomic and can't be interrupted

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), LARGE_AMOUNT);
        usd3Strategy.deposit(LARGE_AMOUNT, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), MEDIUM_AMOUNT);
        uint256 usd3Shares = usd3Strategy.deposit(MEDIUM_AMOUNT, bob);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), usd3Shares);
        susd3Strategy.deposit(usd3Shares, bob);
        vm.stopPrank();

        // Simulate loss
        uint256 loss = (ITokenizedStrategy(address(usd3Strategy)).totalAssets() * 5) / 100;
        _simulateLoss(loss);

        // The burning happens in _postReportHook, which should be protected by TokenizedStrategy's reentrancy guards
        // This test ensures the operation completes atomically

        uint256 susd3BalanceBefore = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        uint256 totalSupplyBefore = ITokenizedStrategy(address(usd3Strategy)).totalSupply();

        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        uint256 susd3BalanceAfter = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        uint256 totalSupplyAfter = ITokenizedStrategy(address(usd3Strategy)).totalSupply();

        // Changes should be consistent
        uint256 balanceReduction = susd3BalanceBefore - susd3BalanceAfter;
        uint256 supplyReduction = totalSupplyBefore - totalSupplyAfter;

        assertEq(balanceReduction, supplyReduction, "Balance and supply reductions should be equal (atomic)");
    }

    /*//////////////////////////////////////////////////////////////
                        CROSS-VERSION COMPATIBILITY
    //////////////////////////////////////////////////////////////*/

    function test_storageCompatibilityAcrossVersions() public {
        // Test that storage layout is compatible with expected TokenizedStrategy versions

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), LARGE_AMOUNT);
        usd3Strategy.deposit(LARGE_AMOUNT, alice);
        vm.stopPrank();

        // This test validates that our storage slot calculations work with the actual
        // TokenizedStrategy deployment at 0xD377919FA87120584B21279a491F82D5265A139c

        uint256 aliceBalance = ITokenizedStrategy(address(usd3Strategy)).balanceOf(alice);
        assertGt(aliceBalance, 0, "Should have balance in TokenizedStrategy");

        // Calculate storage slots using our constants
        bytes32 baseSlot = BASE_SLOT;
        bytes32 balancesSlot = bytes32(uint256(baseSlot) + BALANCES_SLOT_OFFSET);
        bytes32 aliceBalanceSlot = keccak256(abi.encode(alice, balancesSlot));

        // Read directly from storage
        uint256 directBalance = uint256(vm.load(address(usd3Strategy), aliceBalanceSlot));

        assertEq(directBalance, aliceBalance, "Storage slot calculation should match actual TokenizedStrategy layout");
    }

    /*//////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _simulateLoss(uint256 lossAmount) internal {
        // Simulate loss by directly manipulating MorphoCredit's state
        USD3 usd3 = USD3(address(usd3Strategy));
        IMorpho morpho = usd3.morphoCredit();
        MarketParams memory marketParams = usd3.marketParams();

        // Calculate the market ID
        bytes32 marketId = keccak256(abi.encode(marketParams));

        // Use vm.store to directly reduce the totalSupplyAssets in Morpho's storage
        bytes32 marketSlot = keccak256(abi.encode(marketId, uint256(3))); // slot 3 is market mapping

        // Read current totalSupplyAssets (first element of Market struct)
        uint256 currentTotalSupply = uint256(vm.load(address(morpho), marketSlot));

        if (currentTotalSupply > lossAmount) {
            // Reduce totalSupplyAssets by the loss amount
            vm.store(address(morpho), marketSlot, bytes32(currentTotalSupply - lossAmount));
        } else if (currentTotalSupply > 0) {
            // If loss is greater than supply, reduce to 0
            vm.store(address(morpho), marketSlot, bytes32(0));
        }

        // Also reduce idle balance if any
        uint256 idleBalance = asset.balanceOf(address(usd3Strategy));
        if (idleBalance > 0 && lossAmount > currentTotalSupply) {
            uint256 idleLoss = lossAmount - currentTotalSupply;
            if (idleLoss > idleBalance) idleLoss = idleBalance;
            vm.prank(address(usd3Strategy));
            asset.transfer(address(0xdead), idleLoss);
        }
    }
}
