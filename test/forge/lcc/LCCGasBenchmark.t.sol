// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";

/// @dev Each benchmark establishes prerequisites in setUp so the measured call starts in a fresh transaction.
contract LCCGasDepositBenchmarkTest is LCCBase {
    function testGasDeposit() public {
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        vault.deposit(100e18, 1, type(uint256).max, true, type(uint256).max);
        emit log_named_uint("deposit", gasBefore - gasleft());
    }
}

contract LCCGasSelfFundAmortizingBenchmarkTest is LCCBase {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 100e18);
        _openCall(200e18);
        vm.warp(START + NORMAL + PRE_CALL);
    }

    function testGasSelfFundAmortizing() public {
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        vault.fundCall(false);
        emit log_named_uint("self fund amortizing", gasBefore - gasleft());
    }
}

contract LCCGasSelfFundRollingBenchmarkTest is LCCBase {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 100e18);
        _openCall(200e18);
        vm.warp(START + NORMAL + PRE_CALL);
    }

    function testGasSelfFundRolling() public {
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        vault.fundCall(true);
        emit log_named_uint("self fund rolling", gasBefore - gasleft());
    }
}

contract LCCGasPushFundingBenchmarkTest is LCCBase {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 100e18);
        _openCall(200e18);
        vm.warp(START + NORMAL + PRE_CALL);
    }

    function testGasPushFunding() public {
        vm.prank(bob);
        uint256 gasBefore = gasleft();
        vault.fundCall(alice);
        emit log_named_uint("push funding", gasBefore - gasleft());
    }
}

contract LCCGasAuctionFillBenchmarkTest is LCCBase {
    function setUp() public override {
        super.setUp();
        _deployAuctionVault();
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _openCall(200e18);
        _fund(alice);
        _finishFunding();
        vault.finalizeEpochSlash(0);
        vm.warp(START + NORMAL + PRE_CALL + FUNDING + 5);
    }

    function testGasAuctionFill() public {
        vm.prank(carol);
        uint256 gasBefore = gasleft();
        vault.takeAuction(50e18);
        emit log_named_uint("auction fill", gasBefore - gasleft());
    }
}

contract LCCGasRequestExitBenchmarkTest is LCCBase {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 100e18);
    }

    function testGasRequestExit() public {
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        vault.requestExit();
        emit log_named_uint("request exit", gasBefore - gasleft());
    }
}

contract LCCGasClaimExitedMarginBenchmarkTest is LCCBase {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit();
        vm.warp(START + EPOCH);
    }

    function testGasClaimExitedMargin() public {
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        vault.claimExitedMargin(alice);
        emit log_named_uint("claim exited margin", gasBefore - gasleft());
    }
}

contract LCCGasClaimRemainingMarginBenchmarkTest is LCCBase {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 100e18);
        vm.prank(owner);
        vault.shutdown();
    }

    function testGasClaimRemainingMargin() public {
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        vault.claimRemainingMargin(alice);
        emit log_named_uint("claim remaining margin", gasBefore - gasleft());
    }
}

contract LCCGasFinalizeSlashBenchmarkTest is LCCBase {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _openCall(200e18);
        _fund(bob);
        _finishFunding();
    }

    function testGasFinalizeSlash() public {
        uint256 gasBefore = gasleft();
        vault.finalizeEpochSlash(0);
        emit log_named_uint("finalize slash", gasBefore - gasleft());
    }
}

contract LCCGasSynchronizationBenchmarkTest is LCCBase {
    function setUp() public override {
        super.setUp();
        vm.warp(START + NORMAL + PRE_CALL);
        _deposit(alice, 100e18);
        vm.warp(START + EPOCH);
    }

    function testGasSynchronizationWithDueActivation() public {
        vm.prank(owner);
        uint256 gasBefore = gasleft();
        vault.setRiskCaps(CAP, CAP, 2_000, 0);
        emit log_named_uint("sync due activation", gasBefore - gasleft());
    }
}

contract LCCGasMaterializeChangedBenchmarkTest is LCCBase {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _openCall(200e18);
        _fund(bob);
        _finishFunding();
        vault.finalizeEpochSlash(0);
    }

    function testGasMaterializeChangedState() public {
        uint256 gasBefore = gasleft();
        vault.materializeAccount(alice);
        emit log_named_uint("materialize changed", gasBefore - gasleft());
    }
}

contract LCCGasMaterializeNoOpBenchmarkTest is LCCBase {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 100e18);
    }

    function testGasMaterializeNoOp() public {
        uint256 gasBefore = gasleft();
        vault.materializeAccount(alice);
        emit log_named_uint("materialize no-op", gasBefore - gasleft());
    }
}
