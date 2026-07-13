// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase, LCCRevertingOracle} from "./LCCBase.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";

contract LCCDepositTest is LCCBase {
    function testDepositValuesMarginAndActivatesDuringNormal() public {
        uint256 commitment = _deposit(alice, 100e18);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(commitment, 200e18);
        assertEq(account.activeMargin, 100e18);
        assertEq(account.activeCommitment, 200e18);
        assertEq(vault.totals().activeMargin, 100e18);
        assertEq(vault.totals().activeCommitment, 200e18);
    }

    function testDepositBeforeStartActivatesImmediatelyInEpochZero() public {
        vm.warp(START - 1);
        uint256 assets = 100e18;

        uint256 commitment = _deposit(alice, assets);

        assertEq(uint256(vault.currentPhase()), uint256(ILCCVault.Phase.Normal));
        assertEq(vault.currentEpoch(), 0);
        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, assets);
        assertGt(account.activeCommitment, 0);
        assertEq(account.activeCommitment, commitment);
        assertEq(account.pendingMargin, 0);
    }

    function testDepositStagesOutsideNormalAndAggregateBucketActivates() public {
        vm.warp(START + NORMAL);
        uint256 commitment = _deposit(alice, 100e18);

        assertEq(commitment, 200e18);
        assertEq(vault.totals().pendingMargin, 100e18);
        assertEq(vault.pendingMarginByActivationEpoch(1), 100e18);

        vm.warp(START + EPOCH);
        _syncAs(bob);

        assertEq(vault.totals().pendingMargin, 0);
        assertEq(vault.totals().activeMargin, 100e18);

        ILCCVault.Account memory derived = vault.getAccount(alice);
        assertEq(derived.activeMargin, 100e18);
        assertEq(derived.pendingMargin, 0);
    }

    function testCapsIncludePendingCommitment() public {
        vault = _newVault(_params(400e18, 400e18));
        vm.startPrank(alice);
        margin.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.warp(START + NORMAL);
        _deposit(alice, 100e18);

        vm.expectRevert(LCCErrorsLib.CapExceeded.selector);
        _deposit(alice, 101e18);
    }

    function testMinDepositEnforced() public {
        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        params.minDepositAssets = 10e18;
        vault = _newVault(params);
        _mintAndApprove(alice, 0, 0);

        vm.expectRevert(LCCErrorsLib.InvalidAmount.selector);
        _deposit(alice, 10e18 - 1);

        _deposit(alice, 10e18);
        assertEq(vault.getAccount(alice).activeMargin, 10e18);
    }

    function testSetRiskCapsUpdatesMinDeposit() public {
        vm.prank(owner);
        vault.setRiskCaps(CAP, CAP, 2_000, 5e18);

        assertEq(vault.riskConfig().minDepositAssets, 5e18);

        vm.expectRevert(LCCErrorsLib.InvalidAmount.selector);
        _deposit(alice, 1e18);

        _deposit(alice, 5e18);
    }

    function testZeroOraclePriceReverts() public {
        oracle.setPrice(0);
        vm.expectRevert(LCCErrorsLib.OraclePriceInvalid.selector);
        _deposit(alice, 100e18);
    }

    function testRevertingOracleBubbles() public {
        LCCRevertingOracle badOracle = new LCCRevertingOracle();
        vault = _newVault(_params(address(badOracle), CAP, CAP, 2_000));

        vm.expectRevert("ORACLE_DOWN");
        _deposit(alice, 100e18);
    }
}

contract LCCPendingActivationOverflowPoC is LCCBase {
    function testAggregateMarginOverflowRevertsAtAdmission() public {
        uint256 maxPacked = type(uint128).max;
        _deployVaultWithParams(_params(maxPacked, maxPacked));
        oracle.setPrice(1e18);
        margin.mint(alice, maxPacked);

        uint256 pendingAmount = 1e18 + 1;
        _deposit(alice, maxPacked - 1e18);
        vm.warp(START + NORMAL);

        vm.expectRevert(LCCErrorsLib.CapExceeded.selector);
        _deposit(alice, pendingAmount);

        assertEq(vault.totals().pendingMargin, 0);
        assertEq(vault.pendingMarginByActivationEpoch(1), 0);
    }
}
