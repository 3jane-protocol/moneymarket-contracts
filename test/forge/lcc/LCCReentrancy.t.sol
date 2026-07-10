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

    constructor() LCCMockToken("Reentrant Margin", "rMRG") {}

    function arm(address hook_) external {
        hook = hook_;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            ILCCMarginTransferHook(hook).onMarginTransfer();
        }
        return super.transferFrom(from, to, amount);
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
        vault.deposit(10e18);

        assertFalse(probe.lockedCallSucceeded());
        assertEq(bytes4(probe.lockedCallResult()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertTrue(probe.otherCallSucceeded());

        ILCCVault.Totals memory totals = vault.totals();
        assertEq(totals.activeMargin, 10e18);

        vault.materializeAccount(alice);
    }

    function testRevertedProtectedCallRollsBackTransientLock() public {
        vm.prank(alice);
        (bool success, bytes memory result) = address(vault).call(abi.encodeCall(ILCCVault.deposit, (0)));

        assertFalse(success);
        assertEq(bytes4(result), LCCErrorsLib.InvalidAmount.selector);

        vm.prank(alice);
        vault.deposit(1e18);
    }
}
