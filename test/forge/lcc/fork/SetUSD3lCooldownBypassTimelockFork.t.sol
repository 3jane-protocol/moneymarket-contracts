// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {LCCMainnetForkBase} from "./LCCMainnetForkBase.sol";
import {
    IManagedNotificationVault,
    SetUSD3lCooldownBypassTimelock
} from "../../../../script/operations/SetUSD3lCooldownBypassTimelock.s.sol";
import {ITimelockController} from "../../../../src/interfaces/ITimelockController.sol";
import {LCCLeveragedFundHelper} from "../../../../src/lcc/LCCLeveragedFundHelper.sol";
import {VmSafe} from "../../../../lib/forge-std/src/Vm.sol";

/// @dev This suite mutates process-global environment variables and must run single-threaded, as test:forge:fork:lcc
/// does.
contract SetUSD3lCooldownBypassTimelockForkTest is LCCMainnetForkBase {
    address internal constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant USD3L = 0xDF697c55f0D696CA9E3E624cD52d8186C6745904;
    address internal constant PARAMS_TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address internal constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    bytes32 internal constant BYPASS_SALT_DOMAIN = bytes32("3JANE_USD3L_BYPASS_V1");
    bytes32 internal constant EMPTY_CODE_HASH = keccak256("");
    uint256 internal constant BYPASS_FORK_BLOCK = 26_129_000;

    IManagedNotificationVault internal constant USD3L_VAULT = IManagedNotificationVault(USD3L);

    function _forkBlock() internal pure override returns (uint256) {
        return BYPASS_FORK_BLOCK;
    }

    function setUp() public override {
        super.setUp();
        if (!forkEnabled) return;

        vm.setEnv("WALLET_TYPE", "local");
        vm.setEnv("SAFE_PROPOSER_PRIVATE_KEY", vm.toString(bytes32(uint256(1))));
        vm.setEnv("SAFE_NONCE", "1");
        vm.setEnv("SAFE_ADDRESS", vm.toString(SAFE_ADDRESS));
    }

    function testCooldownBypassScriptScenariosRunSequentially() public requiresFork {
        uint256 snapshot = vm.snapshotState();
        _assertHelperGrantLifecycle();
        assertTrue(vm.revertToStateAndDelete(snapshot), "helper-grant scenario restore failed");

        snapshot = vm.snapshotState();
        _assertCodeHashMismatchRejectedAtScheduleAndExecute();
        assertTrue(vm.revertToStateAndDelete(snapshot), "code-hash scenario restore failed");

        snapshot = vm.snapshotState();
        _assertLccHelperModeRejectsWrongFactory();
        assertTrue(vm.revertToStateAndDelete(snapshot), "helper-factory scenario restore failed");

        snapshot = vm.snapshotState();
        _assertRevokeLifecycle();
        assertTrue(vm.revertToStateAndDelete(snapshot), "revoke scenario restore failed");

        snapshot = vm.snapshotState();
        _assertNoOpWhenTargetIsLive();
        assertTrue(vm.revertToStateAndDelete(snapshot), "no-op scenario restore failed");

        snapshot = vm.snapshotState();
        _assertCooldownClearRequiresAcknowledgement();
        assertTrue(vm.revertToStateAndDelete(snapshot), "cooldown scenario restore failed");

        snapshot = vm.snapshotState();
        _assertEoaLiquidatorGrant();
        assertTrue(vm.revertToStateAndDelete(snapshot), "EOA scenario restore failed");

        snapshot = vm.snapshotState();
        _assertDoneAttemptRequiresFreshAttempt();
        assertTrue(vm.revertToStateAndDelete(snapshot), "done-attempt scenario restore failed");
    }

    function _assertHelperGrantLifecycle() private {
        LCCLeveragedFundHelper helper = new LCCLeveragedFundHelper(MORPHO_BLUE, address(this), USD3L);
        bytes32 expectedCodeHash = address(helper).codehash;
        _configure(address(helper), true, expectedCodeHash, address(this), false);
        _authorizeDefaultBroadcaster();

        uint256 attempt;
        SetUSD3lCooldownBypassTimelock scheduled = new SetUSD3lCooldownBypassTimelock();
        scheduled.schedule(attempt, false);
        (uint256 calls,) = scheduled.getBatchInfo(0);
        assertEq(calls, 1);
        assertFalse(USD3L_VAULT.cooldownBypass(address(helper)));

        bytes32 operationId = _operationId(address(helper), true, expectedCodeHash, attempt);
        ITimelockController controller = ITimelockController(PARAMS_TIMELOCK);
        assertTrue(controller.isOperationPending(operationId));
        uint256 readyAt = controller.getTimestamp(operationId);

        SetUSD3lCooldownBypassTimelock pending = new SetUSD3lCooldownBypassTimelock();
        pending.schedule(attempt, false);
        (calls,) = pending.getBatchInfo(0);
        assertEq(calls, 0);
        assertEq(controller.getTimestamp(operationId), readyAt);

        SetUSD3lCooldownBypassTimelock early = new SetUSD3lCooldownBypassTimelock();
        vm.expectRevert(bytes("Operation still waiting. Time remaining: 86400 seconds"));
        early.execute(attempt);

        vm.warp(block.timestamp + 1 days);
        SetUSD3lCooldownBypassTimelock execution = new SetUSD3lCooldownBypassTimelock();
        execution.execute(attempt);
        assertTrue(controller.isOperationDone(operationId));
        assertTrue(USD3L_VAULT.cooldownBypass(address(helper)));
        execution.verify();
    }

    function _assertCodeHashMismatchRejectedAtScheduleAndExecute() private {
        LCCLeveragedFundHelper scheduleAccount = new LCCLeveragedFundHelper(MORPHO_BLUE, address(this), USD3L);
        _configure(address(scheduleAccount), true, keccak256("wrong runtime"), address(0), false);

        SetUSD3lCooldownBypassTimelock rejectedSchedule = new SetUSD3lCooldownBypassTimelock();
        vm.expectRevert(bytes("account runtime code hash mismatch"));
        rejectedSchedule.schedule(1, false);

        LCCLeveragedFundHelper executeAccount = new LCCLeveragedFundHelper(MORPHO_BLUE, address(this), USD3L);
        bytes32 expectedCodeHash = address(executeAccount).codehash;
        _configure(address(executeAccount), true, expectedCodeHash, address(0), false);
        _authorizeDefaultBroadcaster();

        SetUSD3lCooldownBypassTimelock scheduled = new SetUSD3lCooldownBypassTimelock();
        scheduled.schedule(2, false);
        vm.etch(address(executeAccount), hex"00");
        vm.warp(block.timestamp + 1 days);

        SetUSD3lCooldownBypassTimelock rejectedExecution = new SetUSD3lCooldownBypassTimelock();
        vm.expectRevert(bytes("account runtime code hash mismatch"));
        rejectedExecution.execute(2);
    }

    function _assertLccHelperModeRejectsWrongFactory() private {
        LCCLeveragedFundHelper helper = new LCCLeveragedFundHelper(MORPHO_BLUE, address(this), USD3L);
        _configure(address(helper), true, address(helper).codehash, PARAMS_TIMELOCK, false);

        SetUSD3lCooldownBypassTimelock rejected = new SetUSD3lCooldownBypassTimelock();
        vm.expectRevert(bytes("LCC helper runtime code hash mismatch"));
        rejected.schedule(3, false);
    }

    function _assertRevokeLifecycle() private {
        address account = address(new LCCLeveragedFundHelper(MORPHO_BLUE, address(this), USD3L));
        vm.prank(PARAMS_TIMELOCK);
        USD3L_VAULT.setCooldownBypass(account, true);
        _configure(account, false, bytes32(0), address(0), false);
        _authorizeDefaultBroadcaster();

        uint256 attempt = 4;
        SetUSD3lCooldownBypassTimelock scheduled = new SetUSD3lCooldownBypassTimelock();
        scheduled.schedule(attempt, false);
        (uint256 calls,) = scheduled.getBatchInfo(0);
        assertEq(calls, 1);
        assertTrue(USD3L_VAULT.cooldownBypass(account));
        bytes32 operationId = _operationId(account, false, bytes32(0), attempt);
        assertTrue(ITimelockController(PARAMS_TIMELOCK).isOperationPending(operationId));

        vm.etch(account, hex"00");
        vm.warp(block.timestamp + 1 days);
        SetUSD3lCooldownBypassTimelock execution = new SetUSD3lCooldownBypassTimelock();
        execution.execute(attempt);
        assertFalse(USD3L_VAULT.cooldownBypass(account));
        execution.verify();
    }

    function _assertNoOpWhenTargetIsLive() private {
        address account = makeAddr("bypass-no-op-account");
        _configure(account, false, bytes32(0), address(0), false);

        SetUSD3lCooldownBypassTimelock noOp = new SetUSD3lCooldownBypassTimelock();
        noOp.schedule(5, false);
        (uint256 calls,) = noOp.getBatchInfo(0);
        assertEq(calls, 0);
        noOp.verify();
    }

    function _assertCooldownClearRequiresAcknowledgement() private {
        address account = makeAddr("bypass-cooldown-account");
        vm.deal(account, 1 ether);
        uint256 cooldownShares = 1e18;
        deal(USD3L, account, cooldownShares, true);
        vm.prank(account);
        USD3L_VAULT.startCooldown(cooldownShares);
        (,, uint256 sharesBefore) = USD3L_VAULT.getCooldownStatus(account);
        assertEq(sharesBefore, cooldownShares);
        assertEq(account.codehash, EMPTY_CODE_HASH);

        _configure(account, true, EMPTY_CODE_HASH, address(0), false);
        SetUSD3lCooldownBypassTimelock rejectedSchedule = new SetUSD3lCooldownBypassTimelock();
        vm.expectRevert(bytes("account has cooldown; set USD3L_BYPASS_ACKNOWLEDGE_COOLDOWN_CLEAR=true"));
        rejectedSchedule.schedule(6, false);

        vm.setEnv("USD3L_BYPASS_ACKNOWLEDGE_COOLDOWN_CLEAR", "true");
        _authorizeDefaultBroadcaster();
        SetUSD3lCooldownBypassTimelock scheduled = new SetUSD3lCooldownBypassTimelock();
        scheduled.schedule(6, false);

        vm.setEnv("USD3L_BYPASS_ACKNOWLEDGE_COOLDOWN_CLEAR", "false");
        vm.warp(block.timestamp + 1 days);
        SetUSD3lCooldownBypassTimelock rejectedExecution = new SetUSD3lCooldownBypassTimelock();
        vm.expectRevert(bytes("account has cooldown; set USD3L_BYPASS_ACKNOWLEDGE_COOLDOWN_CLEAR=true"));
        rejectedExecution.execute(6);

        vm.setEnv("USD3L_BYPASS_ACKNOWLEDGE_COOLDOWN_CLEAR", "true");
        SetUSD3lCooldownBypassTimelock execution = new SetUSD3lCooldownBypassTimelock();
        execution.execute(6);
        (,, uint256 sharesAfter) = USD3L_VAULT.getCooldownStatus(account);
        assertEq(sharesAfter, 0);
        assertTrue(USD3L_VAULT.cooldownBypass(account));
        execution.verify();
    }

    function _assertEoaLiquidatorGrant() private {
        address liquidator = makeAddr("bypass-eoa-liquidator");
        vm.deal(liquidator, 1 ether);
        assertEq(liquidator.codehash, EMPTY_CODE_HASH);
        _configure(liquidator, true, EMPTY_CODE_HASH, address(0), false);
        _authorizeDefaultBroadcaster();

        SetUSD3lCooldownBypassTimelock scheduled = new SetUSD3lCooldownBypassTimelock();
        scheduled.schedule(7, false);
        vm.warp(block.timestamp + 1 days);
        SetUSD3lCooldownBypassTimelock execution = new SetUSD3lCooldownBypassTimelock();
        execution.execute(7);
        assertTrue(USD3L_VAULT.cooldownBypass(liquidator));
        execution.verify();
    }

    function _assertDoneAttemptRequiresFreshAttempt() private {
        address account = makeAddr("bypass-done-attempt-account");
        vm.deal(account, 1 ether);
        _configure(account, true, EMPTY_CODE_HASH, address(0), false);
        _authorizeDefaultBroadcaster();

        uint256 attempt = 8;
        SetUSD3lCooldownBypassTimelock scheduled = new SetUSD3lCooldownBypassTimelock();
        scheduled.schedule(attempt, false);
        vm.warp(block.timestamp + 1 days);
        SetUSD3lCooldownBypassTimelock execution = new SetUSD3lCooldownBypassTimelock();
        execution.execute(attempt);

        vm.prank(PARAMS_TIMELOCK);
        USD3L_VAULT.setCooldownBypass(account, false);
        assertFalse(USD3L_VAULT.cooldownBypass(account));

        SetUSD3lCooldownBypassTimelock repeated = new SetUSD3lCooldownBypassTimelock();
        vm.expectRevert(bytes("operation already executed; use a fresh attempt"));
        repeated.schedule(attempt, false);
    }

    function _configure(
        address account,
        bool allowed,
        bytes32 expectedCodeHash,
        address helperFactory,
        bool acknowledgeCooldownClear
    ) private {
        vm.setEnv("USD3L_BYPASS_ACCOUNT", vm.toString(account));
        vm.setEnv("USD3L_BYPASS_ALLOWED", allowed ? "true" : "false");
        vm.setEnv("USD3L_BYPASS_EXPECTED_CODEHASH", vm.toString(expectedCodeHash));
        vm.setEnv("USD3L_BYPASS_LCC_HELPER_FACTORY", vm.toString(helperFactory));
        vm.setEnv("USD3L_BYPASS_ACKNOWLEDGE_COOLDOWN_CLEAR", acknowledgeCooldownClear ? "true" : "false");
    }

    function _authorizeDefaultBroadcaster() private returns (address broadcaster) {
        vm.startBroadcast();
        (VmSafe.CallerMode mode, address sender,) = vm.readCallers();
        vm.stopBroadcast();
        assertEq(uint256(mode), uint256(VmSafe.CallerMode.RecurrentBroadcast));
        broadcaster = sender;

        ITimelockController controller = ITimelockController(PARAMS_TIMELOCK);
        bytes32 executorRole = controller.EXECUTOR_ROLE();
        vm.prank(PARAMS_TIMELOCK);
        controller.grantRole(executorRole, broadcaster);
        assertTrue(controller.hasRole(executorRole, broadcaster));
    }

    function _operationId(address account, bool allowed, bytes32 expectedCodeHash, uint256 attempt)
        private
        view
        returns (bytes32)
    {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);
        targets[0] = USD3L;
        datas[0] = abi.encodeCall(IManagedNotificationVault.setCooldownBypass, (account, allowed));
        bytes32 salt = keccak256(abi.encode(BYPASS_SALT_DOMAIN, USD3L, account, allowed, expectedCodeHash, attempt));
        return ITimelockController(PARAMS_TIMELOCK).hashOperationBatch(targets, values, datas, bytes32(0), salt);
    }
}
