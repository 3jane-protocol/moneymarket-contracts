// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "../../../../lib/openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {LCCMainnetForkBase} from "./LCCMainnetForkBase.sol";
import {SetLCCVaultRiskParamsSafe} from "../../../../script/operations/SetLCCVaultRiskParamsSafe.s.sol";
import {ITimelockController} from "../../../../src/interfaces/ITimelockController.sol";
import {LCCMockNotificationVault, LCCMockToken, LCCMockUSD3} from "../LCCBase.t.sol";
import {LCCVault} from "../../../../src/lcc/LCCVault.sol";
import {LCCVaultFactory} from "../../../../src/lcc/LCCVaultFactory.sol";
import {ILCCVault} from "../../../../src/lcc/interfaces/ILCCVault.sol";
import {OracleMock} from "../../../../src/mocks/OracleMock.sol";
import {ORACLE_PRICE_SCALE} from "../../../../src/libraries/ConstantsLib.sol";
import {VmSafe} from "../../../../lib/forge-std/src/Vm.sol";

/// @dev This suite mutates process-global environment variables and must run single-threaded, as test:forge:fork:lcc
/// does.
contract SetLCCVaultRiskParamsTimelockForkTest is LCCMainnetForkBase {
    address internal constant PARAMS_TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address internal constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    bytes32 internal constant RISK_PARAMS_SALT_DOMAIN = bytes32("3JANE_LCC_RISK_PARAMS_V1");
    uint256 internal constant FIELD_PROTOCOL_COMMITMENT_CAP = 1 << 0;
    uint256 internal constant FIELD_USER_COMMITMENT_CAP = 1 << 1;
    uint256 internal constant FIELD_EXIT_CAP_BPS = 1 << 2;
    uint256 internal constant FIELD_MIN_DEPOSIT_ASSETS = 1 << 3;
    uint256 internal constant FIELD_MAX_AUCTION_AWARD_BPS = 1 << 4;
    uint256 internal constant FIELD_SLASH_FEE_BPS = 1 << 5;
    uint256 internal constant RISK_CAP_FIELDS =
        FIELD_PROTOCOL_COMMITMENT_CAP | FIELD_USER_COMMITMENT_CAP | FIELD_EXIT_CAP_BPS | FIELD_MIN_DEPOSIT_ASSETS;
    uint256 internal constant ALL_FIELDS = RISK_CAP_FIELDS | FIELD_MAX_AUCTION_AWARD_BPS | FIELD_SLASH_FEE_BPS;
    uint256 internal constant EPOCH = 100;
    uint256 internal constant NORMAL = 40;
    uint256 internal constant PRE_CALL = 20;
    uint256 internal constant FUNDING = 20;

    LCCMockToken internal margin;
    LCCMockToken internal fundingAsset;
    LCCVaultFactory internal factory;
    ILCCVault internal vault;
    uint256 internal startTimestamp;
    address internal alice = makeAddr("risk-script-alice");

    function setUp() public override {
        super.setUp();
        if (!forkEnabled) return;

        margin = new LCCMockToken("Margin", "MRG");
        fundingAsset = new LCCMockToken("USD Coin", "USDC");
        LCCMockUSD3 usd3 = new LCCMockUSD3(IERC20(address(fundingAsset)));
        LCCMockNotificationVault notificationVault = new LCCMockNotificationVault(IERC20(address(usd3)));
        LCCVault implementation = new LCCVault(address(notificationVault), makeAddr("risk-script-treasury"));
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(implementation), address(this));
        factory = new LCCVaultFactory(address(this), address(beacon));
        bytes32 listerRole = factory.LISTER_ROLE();
        factory.grantRole(listerRole, address(this));

        OracleMock oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE_SCALE);
        startTimestamp = block.timestamp;
        vault = ILCCVault(factory.createVault(_vaultParams(address(oracle)), keccak256("risk-script-vault")));

        address[] memory users = new address[](1);
        uint128[] memory caps = new uint128[](1);
        users[0] = alice;
        caps[0] = type(uint128).max;
        factory.setDepositorCaps(users, caps);
        margin.mint(alice, 1_000e18);
        vm.prank(alice);
        margin.approve(address(vault), type(uint256).max);
    }

    function testRiskParamScriptScenariosRunSequentially() public requiresFork {
        vm.setEnv("WALLET_TYPE", "local");
        vm.setEnv("SAFE_PROPOSER_PRIVATE_KEY", vm.toString(bytes32(uint256(1))));
        vm.setEnv("SAFE_NONCE", "1");
        vm.setEnv("SAFE_ADDRESS", vm.toString(SAFE_ADDRESS));
        vm.setEnv("LCC_FACTORY", vm.toString(address(factory)));
        vm.setEnv("LCC_VAULT", vm.toString(address(vault)));

        uint256 snapshot = vm.snapshotState();
        _assertScheduleExecuteAndOperationStateHandling();
        assertTrue(vm.revertToStateAndDelete(snapshot), "schedule-execute scenario restore failed");

        snapshot = vm.snapshotState();
        _assertNothingChangedProposesNothing();
        assertTrue(vm.revertToStateAndDelete(snapshot), "no-change scenario restore failed");

        snapshot = vm.snapshotState();
        _assertPendingAuctionRejectsSensitiveSchedule();
        assertTrue(vm.revertToStateAndDelete(snapshot), "pending-auction scenario restore failed");

        snapshot = vm.snapshotState();
        _assertUnselectedRiskCapChangeRejectsExecution();
        assertTrue(vm.revertToStateAndDelete(snapshot), "changed-field scenario restore failed");

        snapshot = vm.snapshotState();
        _assertZeroFieldsMaskRejectsExecution();
        assertTrue(vm.revertToStateAndDelete(snapshot), "zero-mask scenario restore failed");
    }

    function _assertScheduleExecuteAndOperationStateHandling() private {
        ILCCVault.RiskConfig memory live = vault.riskConfig();
        ILCCVault.RiskConfig memory target = _copyRiskConfig(live);
        target.protocolCommitmentCap = live.protocolCommitmentCap + 1;
        target.userCommitmentCap = live.userCommitmentCap + 2;
        target.exitCapBps = live.exitCapBps + 1;
        target.minDepositAssets = live.minDepositAssets + 1;
        target.maxAuctionAwardBps = live.maxAuctionAwardBps - 1;
        target.slashFeeBps = live.slashFeeBps + 1;
        _configureTarget(target, ALL_FIELDS);
        _moveFactoryToParametersTimelock();
        _authorizeDefaultBroadcaster();

        uint256 attempt = 11;
        SetLCCVaultRiskParamsSafe scheduled = new SetLCCVaultRiskParamsSafe();
        scheduled.schedule(attempt, false);
        (uint256 calls,) = scheduled.getBatchInfo(0);
        assertEq(calls, 1);
        _assertConfig(vault.riskConfig(), live);

        (bytes32 operationId, uint256 operationCalls) = _riskOperationId(target, ALL_FIELDS, attempt);
        assertEq(operationCalls, 3);
        ITimelockController controller = ITimelockController(PARAMS_TIMELOCK);
        assertTrue(controller.isOperationPending(operationId));
        uint256 readyAt = controller.getTimestamp(operationId);

        SetLCCVaultRiskParamsSafe pendingRerun = new SetLCCVaultRiskParamsSafe();
        pendingRerun.schedule(attempt, false);
        (calls,) = pendingRerun.getBatchInfo(0);
        assertEq(calls, 0);
        assertEq(controller.getTimestamp(operationId), readyAt);

        SetLCCVaultRiskParamsSafe earlyExecution = new SetLCCVaultRiskParamsSafe();
        vm.expectRevert(bytes("Operation still waiting. Time remaining: 86400 seconds"));
        earlyExecution.execute(attempt);

        vm.warp(block.timestamp + 1 days);
        SetLCCVaultRiskParamsSafe execution = new SetLCCVaultRiskParamsSafe();
        execution.execute(attempt);
        assertTrue(controller.isOperationDone(operationId));
        _assertConfig(vault.riskConfig(), target);
        execution.verify();

        _setConfigAsTimelock(live);
        _assertConfig(vault.riskConfig(), live);

        SetLCCVaultRiskParamsSafe doneAttempt = new SetLCCVaultRiskParamsSafe();
        vm.expectRevert(bytes("operation already executed; use a fresh attempt"));
        doneAttempt.schedule(attempt, false);
    }

    function _assertNothingChangedProposesNothing() private {
        ILCCVault.RiskConfig memory live = vault.riskConfig();
        ILCCVault.RiskConfig memory target = _copyRiskConfig(live);
        _configureTarget(target, 0);
        _moveFactoryToParametersTimelock();

        SetLCCVaultRiskParamsSafe noChange = new SetLCCVaultRiskParamsSafe();
        noChange.schedule(12, false);
        (uint256 calls,) = noChange.getBatchInfo(0);
        assertEq(calls, 0);
        _assertConfig(vault.riskConfig(), live);
    }

    function _assertPendingAuctionRejectsSensitiveSchedule() private {
        vm.prank(alice);
        uint256 commitment = vault.deposit(100e18, alice, 1, type(uint256).max, true, type(uint256).max);
        vm.warp(startTimestamp + NORMAL);
        vault.openEpochCall(0, commitment);
        vm.warp(startTimestamp + NORMAL + PRE_CALL + FUNDING);
        vault.finalizeEpochSlash(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);

        ILCCVault.RiskConfig memory target = _copyRiskConfig(vault.riskConfig());
        target.protocolCommitmentCap += 1;
        _configureTarget(target, FIELD_PROTOCOL_COMMITMENT_CAP);
        _moveFactoryToParametersTimelock();

        SetLCCVaultRiskParamsSafe rejected = new SetLCCVaultRiskParamsSafe();
        vm.expectRevert(bytes("vault has a pending auction slot"));
        rejected.schedule(13, false);
    }

    function _assertUnselectedRiskCapChangeRejectsExecution() private {
        ILCCVault.RiskConfig memory live = vault.riskConfig();
        ILCCVault.RiskConfig memory target = _copyRiskConfig(live);
        target.protocolCommitmentCap += 1;
        _configureTarget(target, FIELD_PROTOCOL_COMMITMENT_CAP);
        _moveFactoryToParametersTimelock();

        uint256 attempt = 14;
        SetLCCVaultRiskParamsSafe scheduled = new SetLCCVaultRiskParamsSafe();
        scheduled.schedule(attempt, false);

        ILCCVault.RiskConfig memory intervening = _copyRiskConfig(live);
        intervening.userCommitmentCap += 1;
        vm.prank(PARAMS_TIMELOCK);
        vault.setRiskCaps(
            intervening.protocolCommitmentCap,
            intervening.userCommitmentCap,
            intervening.exitCapBps,
            intervening.minDepositAssets
        );

        vm.warp(block.timestamp + 1 days);
        SetLCCVaultRiskParamsSafe execution = new SetLCCVaultRiskParamsSafe();
        vm.expectRevert(bytes("userCommitmentCap changed since scheduling; reschedule with a fresh attempt"));
        execution.execute(attempt);
        _assertConfig(vault.riskConfig(), intervening);
    }

    function _assertZeroFieldsMaskRejectsExecution() private {
        ILCCVault.RiskConfig memory live = vault.riskConfig();
        ILCCVault.RiskConfig memory target = _copyRiskConfig(live);
        _configureTarget(target, 0);
        _moveFactoryToParametersTimelock();

        SetLCCVaultRiskParamsSafe execution = new SetLCCVaultRiskParamsSafe();
        vm.expectRevert(bytes("invalid LCC_FIELDS_MASK"));
        execution.execute(15);
    }

    function _configureTarget(ILCCVault.RiskConfig memory target, uint256 fieldsMask) private {
        vm.setEnv("LCC_PROTOCOL_COMMITMENT_CAP", vm.toString(target.protocolCommitmentCap));
        vm.setEnv("LCC_USER_COMMITMENT_CAP", vm.toString(target.userCommitmentCap));
        vm.setEnv("LCC_EXIT_CAP_BPS", vm.toString(target.exitCapBps));
        vm.setEnv("LCC_MIN_DEPOSIT_ASSETS", vm.toString(target.minDepositAssets));
        vm.setEnv("LCC_MAX_AUCTION_AWARD_BPS", vm.toString(target.maxAuctionAwardBps));
        vm.setEnv("LCC_SLASH_FEE_BPS", vm.toString(target.slashFeeBps));
        vm.setEnv("LCC_FIELDS_MASK", vm.toString(fieldsMask));
    }

    function _moveFactoryToParametersTimelock() private {
        factory.transferOwnership(PARAMS_TIMELOCK);
        vm.prank(PARAMS_TIMELOCK);
        factory.acceptOwnership();
        assertEq(factory.owner(), PARAMS_TIMELOCK);
        assertEq(factory.getRoleMemberCount(factory.OWNER_ROLE()), 1);
    }

    function _setConfigAsTimelock(ILCCVault.RiskConfig memory config) private {
        vm.startPrank(PARAMS_TIMELOCK);
        vault.setRiskCaps(
            config.protocolCommitmentCap, config.userCommitmentCap, config.exitCapBps, config.minDepositAssets
        );
        vault.setMaxAuctionAwardBps(config.maxAuctionAwardBps);
        vault.setSlashFeeBps(config.slashFeeBps);
        vm.stopPrank();
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

    function _riskOperationId(ILCCVault.RiskConfig memory target, uint256 fieldsMask, uint256 attempt)
        private
        view
        returns (bytes32 operationId, uint256 callCount)
    {
        callCount = (fieldsMask & RISK_CAP_FIELDS == 0 ? 0 : 1)
            + (fieldsMask & FIELD_MAX_AUCTION_AWARD_BPS == 0 ? 0 : 1) + (fieldsMask & FIELD_SLASH_FEE_BPS == 0 ? 0 : 1);
        address[] memory targets = new address[](callCount);
        uint256[] memory values = new uint256[](callCount);
        bytes[] memory datas = new bytes[](callCount);

        uint256 index;
        if (fieldsMask & RISK_CAP_FIELDS != 0) {
            targets[index] = address(vault);
            datas[index] = abi.encodeCall(
                ILCCVault.setRiskCaps,
                (target.protocolCommitmentCap, target.userCommitmentCap, target.exitCapBps, target.minDepositAssets)
            );
            ++index;
        }
        if (fieldsMask & FIELD_MAX_AUCTION_AWARD_BPS != 0) {
            targets[index] = address(vault);
            datas[index] = abi.encodeCall(ILCCVault.setMaxAuctionAwardBps, (target.maxAuctionAwardBps));
            ++index;
        }
        if (fieldsMask & FIELD_SLASH_FEE_BPS != 0) {
            targets[index] = address(vault);
            datas[index] = abi.encodeCall(ILCCVault.setSlashFeeBps, (target.slashFeeBps));
        }

        bytes32 salt = keccak256(
            abi.encode(RISK_PARAMS_SALT_DOMAIN, address(factory), address(vault), target, fieldsMask, attempt)
        );
        operationId = ITimelockController(PARAMS_TIMELOCK).hashOperationBatch(targets, values, datas, bytes32(0), salt);
    }

    function _assertConfig(ILCCVault.RiskConfig memory actual, ILCCVault.RiskConfig memory expected) private pure {
        assertEq(actual.protocolCommitmentCap, expected.protocolCommitmentCap);
        assertEq(actual.userCommitmentCap, expected.userCommitmentCap);
        assertEq(actual.exitCapBps, expected.exitCapBps);
        assertEq(actual.minDepositAssets, expected.minDepositAssets);
        assertEq(actual.maxAuctionAwardBps, expected.maxAuctionAwardBps);
        assertEq(actual.slashFeeBps, expected.slashFeeBps);
    }

    function _copyRiskConfig(ILCCVault.RiskConfig memory source)
        private
        pure
        returns (ILCCVault.RiskConfig memory copy)
    {
        copy = ILCCVault.RiskConfig({
            protocolCommitmentCap: source.protocolCommitmentCap,
            userCommitmentCap: source.userCommitmentCap,
            exitCapBps: source.exitCapBps,
            minDepositAssets: source.minDepositAssets,
            maxAuctionAwardBps: source.maxAuctionAwardBps,
            slashFeeBps: source.slashFeeBps
        });
    }

    function _vaultParams(address oracle) private view returns (ILCCVault.VaultParams memory) {
        return ILCCVault.VaultParams({
            marginAsset: address(margin),
            marginOracle: oracle,
            startTimestamp: startTimestamp,
            maxEpochs: 0,
            epochLength: EPOCH,
            normalDuration: NORMAL,
            preCallDuration: PRE_CALL,
            fundingDuration: FUNDING,
            marginRatioBps: 5_000,
            protocolCommitmentCap: 1_000_000_000e18,
            userCommitmentCap: 1_000_000_000e18,
            exitCapBps: 2_000,
            exitDelayEpochs: 1,
            minCommitmentEpochs: 0,
            minDepositAssets: 0,
            auctionStepCount: 4,
            auctionStepDecayRateBps: 5_000,
            maxAuctionAwardBps: 10_000,
            slashFeeBps: 1_000
        });
    }
}
