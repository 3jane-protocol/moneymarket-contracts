// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";

/// @dev Focused gas probes for the synchronized user paths affected by LCCVault size cleanup.
contract LCCGasBenchmarkTest is LCCBase {
    function testGasDeposit() public {
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        vault.deposit(100e18);
        emit log_named_uint("deposit", gasBefore - gasleft());
    }

    function testGasSelfFundAmortizing() public {
        _deposit(alice, 100e18);
        _openCall(200e18);
        vm.warp(START + NORMAL + PRE_CALL);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        vault.fundCall(false);
        emit log_named_uint("self fund amortizing", gasBefore - gasleft());
    }

    function testGasSelfFundRolling() public {
        _deposit(alice, 100e18);
        _openCall(200e18);
        vm.warp(START + NORMAL + PRE_CALL);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        vault.fundCall(true);
        emit log_named_uint("self fund rolling", gasBefore - gasleft());
    }

    function testGasPushFunding() public {
        _deposit(alice, 100e18);
        _openCall(200e18);
        vm.warp(START + NORMAL + PRE_CALL);

        vm.prank(bob);
        uint256 gasBefore = gasleft();
        vault.fundCall(alice);
        emit log_named_uint("push funding", gasBefore - gasleft());
    }

    function testGasAuctionFill() public {
        _deployAuctionVault();
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _openCall(200e18);
        _fund(alice);
        _finishFunding();
        vault.finalizeEpochSlash(0);
        vm.warp(START + NORMAL + PRE_CALL + FUNDING + 5);

        vm.prank(carol);
        uint256 gasBefore = gasleft();
        vault.takeAuction(50e18);
        emit log_named_uint("auction fill", gasBefore - gasleft());
    }

    function testGasRequestExit() public {
        _deposit(alice, 100e18);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        vault.requestExit();
        emit log_named_uint("request exit", gasBefore - gasleft());
    }

    function testGasClaimExitedMargin() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit();
        vm.warp(START + EPOCH);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        vault.claimExitedMargin(alice);
        emit log_named_uint("claim exited margin", gasBefore - gasleft());
    }

    function testGasClaimRemainingMargin() public {
        _deposit(alice, 100e18);
        vm.prank(owner);
        vault.shutdown();

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        vault.claimRemainingMargin(alice);
        emit log_named_uint("claim remaining margin", gasBefore - gasleft());
    }

    function testGasSynchronizationWithDueActivation() public {
        vm.warp(START + NORMAL);
        _deposit(alice, 100e18);
        vm.warp(START + EPOCH);

        vm.prank(owner);
        uint256 gasBefore = gasleft();
        vault.setRiskCaps(CAP, CAP, 2_000, 0);
        emit log_named_uint("sync due activation", gasBefore - gasleft());
    }

    function testGasMaterializeChangedState() public {
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _openCall(200e18);
        _fund(bob);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        uint256 gasBefore = gasleft();
        vault.materializeAccount(alice);
        emit log_named_uint("materialize changed", gasBefore - gasleft());
    }

    function testGasMaterializeNoOp() public {
        _deposit(alice, 100e18);

        uint256 gasBefore = gasleft();
        vault.materializeAccount(alice);
        emit log_named_uint("materialize no-op", gasBefore - gasleft());
    }
}
