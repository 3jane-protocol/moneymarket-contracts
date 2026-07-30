// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {ReentrancyGuardTransient} from "../../../lib/openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {LCCBase, LCCMockToken} from "./LCCBase.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";

interface ILCCMarginTransferHook {
    function onMarginTransfer() external;
}

contract LCCReentrantMarginToken is LCCMockToken {
    address internal hook;
    bool internal armed;
    address internal transferHook;
    address internal transferHookRecipient;
    bool internal transferArmed;

    constructor() LCCMockToken("Reentrant Margin", "rMRG") {}

    function arm(address hook_) external {
        hook = hook_;
        armed = true;
    }

    function armTransfer(address recipient, address hook_) external {
        transferHook = hook_;
        transferHookRecipient = recipient;
        transferArmed = true;
    }

    function disarmTransfer() external {
        transferArmed = false;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            ILCCMarginTransferHook(hook).onMarginTransfer();
        }
        return super.transferFrom(from, to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (transferArmed && to == transferHookRecipient) {
            transferArmed = false;
            ILCCMarginTransferHook(transferHook).onMarginTransfer();
        }
        return super.transfer(to, amount);
    }
}

contract LCCReentryProbe is ILCCMarginTransferHook {
    LCCVault internal immutable lockedVault;
    LCCVault internal immutable otherVault;

    bool public lockedCallSucceeded;
    bytes public lockedCallResult;
    bool public otherCallSucceeded;

    constructor(LCCVault lockedVault_, LCCVault otherVault_) {
        lockedVault = lockedVault_;
        otherVault = otherVault_;
    }

    function onMarginTransfer() external {
        (lockedCallSucceeded, lockedCallResult) =
            address(lockedVault).call(abi.encodeCall(ILCCVault.materializeAccount, (address(this))));
        (otherCallSucceeded,) = address(otherVault).call(abi.encodeCall(ILCCVault.materializeAccount, (address(this))));
    }
}

contract LCCTreasurySweepReentryProbe is ILCCMarginTransferHook {
    error PendingTreasuryMarginNotCleared();

    LCCVault internal immutable vault;

    constructor(LCCVault vault_) {
        vault = vault_;
    }

    function onMarginTransfer() external {
        if (vault.pendingTreasuryMargin() != 0) revert PendingTreasuryMarginNotCleared();
        vault.sweepTreasury();
    }
}

contract LCCReentrancyTest is LCCBase {
    LCCReentrantMarginToken internal reentrantMargin;
    LCCVault internal otherVault;

    function setUp() public override {
        super.setUp();

        reentrantMargin = new LCCReentrantMarginToken();
        margin = reentrantMargin;
        vault = _newVault(_params(CAP, CAP));
        otherVault = _newVault(_params(CAP, CAP));
        _mintAndApprove(vault, alice, 100e18, 0);
    }

    function testCallbackReentryIsBlockedWithoutAffectingOuterCallOrOtherProxy() public {
        LCCReentryProbe probe = new LCCReentryProbe(vault, otherVault);
        reentrantMargin.arm(address(probe));

        vm.prank(alice);
        vault.deposit(10e18, 1, type(uint256).max, true, type(uint256).max);

        assertFalse(probe.lockedCallSucceeded());
        assertEq(bytes4(probe.lockedCallResult()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertTrue(probe.otherCallSucceeded());

        ILCCVault.Totals memory totals = vault.totals();
        assertEq(totals.activeMargin, 10e18);

        vault.materializeAccount(alice);
    }

    function testRevertedProtectedCallRollsBackTransientLock() public {
        vm.prank(alice);
        (bool success, bytes memory result) =
            address(vault).call(abi.encodeCall(ILCCVault.deposit, (0, 1, type(uint256).max, true, type(uint256).max)));

        assertFalse(success);
        assertEq(bytes4(result), LCCErrorsLib.InvalidAmount.selector);

        vm.prank(alice);
        vault.deposit(1e18, 1, type(uint256).max, true, type(uint256).max);
    }

    function testSweepTreasuryCallbackReentryIsBlockedAndRetrySucceeds() public {
        _deployAuctionVault();
        _deposit(alice, 100e18);
        oracle.setPrice(4_999e18);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        vm.prank(owner);
        vault.shutdown();

        uint256 amount = vault.pendingTreasuryMargin();
        uint256 vaultBalanceBefore = reentrantMargin.balanceOf(address(vault));
        uint256 treasuryBalanceBefore = reentrantMargin.balanceOf(treasury);
        assertEq(amount, 100e18);

        LCCTreasurySweepReentryProbe probe = new LCCTreasurySweepReentryProbe(vault);
        reentrantMargin.armTransfer(treasury, address(probe));

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vault.sweepTreasury();

        assertEq(vault.pendingTreasuryMargin(), amount);
        assertEq(reentrantMargin.balanceOf(address(vault)), vaultBalanceBefore);
        assertEq(reentrantMargin.balanceOf(treasury), treasuryBalanceBefore);

        reentrantMargin.disarmTransfer();
        vault.sweepTreasury();

        assertEq(vault.pendingTreasuryMargin(), 0);
        assertEq(reentrantMargin.balanceOf(address(vault)), vaultBalanceBefore - amount);
        assertEq(reentrantMargin.balanceOf(treasury), treasuryBalanceBefore + amount);
    }
}
