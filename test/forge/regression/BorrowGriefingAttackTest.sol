// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {SharesMathLib} from "../../../src/libraries/SharesMathLib.sol";

contract BorrowGriefingAttackTest is BaseTest {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;

    address attacker = makeAddr("Attacker");
    address victim = makeAddr("Victim");

    function setUp() public override {
        super.setUp();
    }

    function testBorrowGriefingAttack_SingleAttackPrevented() public {
        // Setup: Supply liquidity to the market
        uint256 supplyAmount = 1000e18;
        _supply(supplyAmount);

        // Setup credit line for attacker
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, attacker, 1e18, 0);

        // Attack: Try to borrow VIRTUAL_SHARES - 1 shares when market has no borrows
        uint256 attackShares = SharesMathLib.VIRTUAL_SHARES - 1;

        // This should now revert with InsufficientBorrowAmount error
        vm.prank(attacker);
        vm.expectRevert(ErrorsLib.InsufficientBorrowAmount.selector);
        morpho.borrow(
            marketParams,
            0, // assets
            attackShares, // shares
            attacker,
            attacker
        );

        // Verify market state remains clean
        assertEq(morpho.totalBorrowAssets(id), 0, "Total borrow assets should remain 0");
        assertEq(morpho.totalBorrowShares(id), 0, "Total borrow shares should remain 0");
        assertEq(morpho.borrowShares(id, attacker), 0, "Attacker should have 0 shares");
    }

    function testBorrowGriefingAttack_RepeatedAttacksPrevented() public {
        // Setup: Supply liquidity to the market
        uint256 supplyAmount = 1000e18;
        _supply(supplyAmount);

        // Setup credit line for attacker with high limit
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, attacker, 1e30, 0);

        // First attack attempt: Try to borrow VIRTUAL_SHARES - 1 shares (would result in 0 assets)
        uint256 firstAttackShares = SharesMathLib.VIRTUAL_SHARES - 1;
        vm.prank(attacker);
        vm.expectRevert(ErrorsLib.InsufficientBorrowAmount.selector);
        morpho.borrow(marketParams, 0, firstAttackShares, attacker, attacker);

        // Verify market remains clean after first attempt
        assertEq(morpho.totalBorrowAssets(id), 0, "Total borrow assets should remain 0");
        assertEq(morpho.totalBorrowShares(id), 0, "Total borrow shares should remain 0");

        // Even smaller attacks that would result in 0 assets are prevented
        uint256 smallAttackShares = SharesMathLib.VIRTUAL_SHARES / 2;
        vm.prank(attacker);
        vm.expectRevert(ErrorsLib.InsufficientBorrowAmount.selector);
        morpho.borrow(marketParams, 0, smallAttackShares, attacker, attacker);

        // Market should still be clean
        assertEq(morpho.totalBorrowAssets(id), 0, "Total borrow assets should still be 0");
        assertEq(morpho.totalBorrowShares(id), 0, "Total borrow shares should still be 0");

        // The fix ensures the griefing attack vector is closed - borrowing shares must result in at least 1 asset
    }

    function testBorrowGriefingAttack_LegitimateUsersProtected() public {
        // Setup: Supply liquidity to the market
        uint256 supplyAmount = 1000e18;
        _supply(supplyAmount);

        // Setup credit line for attacker
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, attacker, 1e30, 0);

        // Attack attempts should fail
        uint256 attackShares = SharesMathLib.VIRTUAL_SHARES - 1;

        // Attack attempts that would result in 0 assets are prevented
        vm.prank(attacker);
        vm.expectRevert(ErrorsLib.InsufficientBorrowAmount.selector);
        morpho.borrow(marketParams, 0, attackShares, attacker, attacker);

        // Verify market is still clean
        assertEq(morpho.totalBorrowAssets(id), 0, "Market should have no borrows");
        assertEq(morpho.totalBorrowShares(id), 0, "Market should have no shares");

        // Now a legitimate user can borrow normally
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, victim, 100e18, 0);

        // Legitimate user borrows a normal amount
        uint256 legitimateBorrowAmount = 10e18;
        vm.prank(victim);
        (uint256 assets, uint256 shares) = morpho.borrow(marketParams, legitimateBorrowAmount, 0, victim, victim);

        // Verify legitimate borrow worked correctly
        assertEq(assets, legitimateBorrowAmount, "Should borrow requested amount");
        assertGt(shares, 0, "Should receive shares");
        assertEq(morpho.totalBorrowAssets(id), legitimateBorrowAmount, "Market should track borrowed assets");
    }

    function testBorrowGriefingAttack_OverflowPrevented() public {
        // Setup: Supply liquidity to the market
        uint256 supplyAmount = 1000e18;
        _supply(supplyAmount);

        // Setup credit line for attacker
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, attacker, 1e30, 0);

        // Try various attack patterns - all should fail
        uint256 baseShares = SharesMathLib.VIRTUAL_SHARES;

        // Try attack that would result in 0 assets
        vm.prank(attacker);
        vm.expectRevert(ErrorsLib.InsufficientBorrowAmount.selector);
        morpho.borrow(marketParams, 0, baseShares - 1, attacker, attacker);

        // Try another attack that would result in 0 assets
        vm.prank(attacker);
        vm.expectRevert(ErrorsLib.InsufficientBorrowAmount.selector);
        morpho.borrow(marketParams, 0, baseShares / 2, attacker, attacker);

        // Verify market remains clean
        assertEq(morpho.totalBorrowAssets(id), 0, "Total assets should be 0");
        assertEq(morpho.totalBorrowShares(id), 0, "Total shares should be 0");

        // Legitimate users can still use the market normally
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, victim, 100e18, 0);

        vm.prank(victim);
        (uint256 assets,) = morpho.borrow(marketParams, 10e18, 0, victim, victim);
        assertEq(assets, 10e18, "Legitimate borrow should work");
    }
}
