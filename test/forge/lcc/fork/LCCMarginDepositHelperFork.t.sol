// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "../../../../lib/openzeppelin/contracts/interfaces/IERC4626.sol";
import {UpgradeableBeacon} from "../../../../lib/openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {LCCMainnetForkBase} from "./LCCMainnetForkBase.sol";
import {
    AuthorizeLCCMarginDepositHelperSafe
} from "../../../../script/operations/AuthorizeLCCMarginDepositHelperSafe.s.sol";
import {ITimelockController} from "../../../../src/interfaces/ITimelockController.sol";
import {LCCMockNotificationVault, LCCMockUSD3} from "../LCCBase.t.sol";
import {LCCMarginDepositHelper} from "../../../../src/lcc/LCCMarginDepositHelper.sol";
import {LCCVault} from "../../../../src/lcc/LCCVault.sol";
import {LCCVaultFactory} from "../../../../src/lcc/LCCVaultFactory.sol";
import {ILCCMarginDepositHelper} from "../../../../src/lcc/interfaces/ILCCMarginDepositHelper.sol";
import {ILCCVault} from "../../../../src/lcc/interfaces/ILCCVault.sol";
import {OracleMock} from "../../../../src/mocks/OracleMock.sol";
import {ORACLE_PRICE_SCALE} from "../../../../src/libraries/ConstantsLib.sol";
import {Vm, VmSafe} from "../../../../lib/forge-std/src/Vm.sol";

interface IAaveV3PoolSupply {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

/// @dev This suite mutates process-global environment variables and must run single-threaded, as test:forge:fork:lcc
/// does.
contract LCCMarginDepositHelperForkTest is LCCMainnetForkBase {
    using SafeERC20 for IERC20;

    address internal constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant PARAMS_TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address internal constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    bytes32 internal constant DEPOSIT_OPERATOR_SALT_DOMAIN = bytes32("3JANE_LCC_DEPOSIT_OPERATOR_V1");

    LCCVaultFactory internal factory;
    LCCMarginDepositHelper internal helper;
    ILCCVault internal usdcVault;
    ILCCVault internal usdtVault;
    address internal alice = makeAddr("fork-alice");
    address internal bob = makeAddr("fork-bob");

    function setUp() public override {
        super.setUp();
        if (!forkEnabled) return;

        LCCMockUSD3 usd3 = new LCCMockUSD3(IERC20(USDC));
        LCCMockNotificationVault notificationVault = new LCCMockNotificationVault(IERC20(address(usd3)));
        LCCVault implementation = new LCCVault(address(notificationVault), makeAddr("treasury"));
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(implementation), address(this));
        factory = new LCCVaultFactory(address(this), address(beacon));
        helper = new LCCMarginDepositHelper(address(factory), WA_ETH_USDC, WA_ETH_USDT);
        factory.grantRole(factory.DEPOSIT_OPERATOR_ROLE(), address(helper));
        factory.grantRole(factory.LISTER_ROLE(), address(this));

        OracleMock oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE_SCALE);
        ILCCVault.VaultParams memory params = _vaultParams(address(oracle), WA_ETH_USDC);
        usdcVault = ILCCVault(factory.createVault(params, keccak256("fork-usdc")));
        params.marginAsset = WA_ETH_USDT;
        usdtVault = ILCCVault(factory.createVault(params, keccak256("fork-usdt")));

        address[] memory users = new address[](2);
        uint128[] memory caps = new uint128[](2);
        users[0] = alice;
        users[1] = bob;
        caps[0] = type(uint128).max;
        caps[1] = type(uint128).max;
        factory.setDepositorCaps(users, caps);

        _fundUnderlyingAndAToken(alice, USDC, 400e6);
        _fundUnderlyingAndAToken(bob, USDT, 400e6);
        vm.startPrank(alice);
        IERC20(USDC).forceApprove(address(helper), type(uint256).max);
        IERC20(A_USDC).forceApprove(address(helper), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        IERC20(USDT).forceApprove(address(helper), type(uint256).max);
        IERC20(A_USDT).forceApprove(address(helper), type(uint256).max);
        vm.stopPrank();
    }

    function testRealStataAndTokensSupportAllFourHelperPaths() public requiresFork {
        uint256 amount = 25e6;
        vm.prank(alice);
        uint256 usdcCommitment = helper.depositUSDC(_params(usdcVault, amount));
        vm.prank(alice);
        uint256 aUsdcCommitment = helper.depositAethUSDC(_params(usdcVault, amount));
        vm.prank(bob);
        uint256 usdtCommitment = helper.depositUSDT(_params(usdtVault, amount));
        vm.prank(bob);
        uint256 aUsdtCommitment = helper.depositAethUSDT(_params(usdtVault, amount));

        assertGt(usdcCommitment, 0);
        assertGt(aUsdcCommitment, 0);
        assertGt(usdtCommitment, 0);
        assertGt(aUsdtCommitment, 0);
        assertGt(usdcVault.getAccount(alice).activeMargin, 0);
        assertGt(usdtVault.getAccount(bob).activeMargin, 0);
        assertEq(IERC20(USDC).allowance(address(helper), WA_ETH_USDC), 0);
        assertEq(IERC20(A_USDC).allowance(address(helper), WA_ETH_USDC), 0);
        assertEq(IERC20(USDT).allowance(address(helper), WA_ETH_USDT), 0);
        assertEq(IERC20(A_USDT).allowance(address(helper), WA_ETH_USDT), 0);
        assertEq(IERC20(WA_ETH_USDC).allowance(address(helper), address(usdcVault)), 0);
        assertEq(IERC20(WA_ETH_USDT).allowance(address(helper), address(usdtVault)), 0);
    }

    function testRealUnderlyingDepositsConsumeFullLossyRoundTripAmounts() public requiresFork {
        uint256 usdcAmount = 24_999_999;
        uint256 usdtAmount = 24_999_995;

        uint256 usdcShares = IERC4626(WA_ETH_USDC).previewDeposit(usdcAmount);
        uint256 usdtShares = IERC4626(WA_ETH_USDT).previewDeposit(usdtAmount);
        assertLt(IERC4626(WA_ETH_USDC).previewMint(usdcShares), usdcAmount, "waEthUSDC round trip not lossy");
        assertLt(IERC4626(WA_ETH_USDT).previewMint(usdtShares), usdtAmount, "waEthUSDT round trip not lossy");

        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        helper.depositUSDC(_params(usdcVault, usdcAmount));
        assertEq(aliceBefore - IERC20(USDC).balanceOf(alice), usdcAmount);

        uint256 bobBefore = IERC20(USDT).balanceOf(bob);
        vm.prank(bob);
        helper.depositUSDT(_params(usdtVault, usdtAmount));
        assertEq(bobBefore - IERC20(USDT).balanceOf(bob), usdtAmount);
    }

    function testRealATokensAcceptAdjacentAmountsAcrossScaledBalanceRounding() public requiresFork {
        uint256 amount = 6;
        uint256 usdcDelta = _probeIngressDelta(IERC20(A_USDC), alice, amount);
        uint256 adjacentUsdcDelta = _probeIngressDelta(IERC20(A_USDC), alice, amount + 1);
        assertTrue(usdcDelta != amount || adjacentUsdcDelta != amount + 1, "aUSDC rounding case not exercised");

        uint256 usdtDelta = _probeIngressDelta(IERC20(A_USDT), bob, amount);
        uint256 adjacentUsdtDelta = _probeIngressDelta(IERC20(A_USDT), bob, amount + 1);
        assertTrue(usdtDelta != amount || adjacentUsdtDelta != amount + 1, "aUSDT rounding case not exercised");

        vm.startPrank(alice);
        helper.depositAethUSDC(_params(usdcVault, amount));
        helper.depositAethUSDC(_params(usdcVault, amount + 1));
        vm.stopPrank();
        vm.startPrank(bob);
        helper.depositAethUSDT(_params(usdtVault, amount));
        helper.depositAethUSDT(_params(usdtVault, amount + 1));
        vm.stopPrank();

        assertEq(IERC20(A_USDC).balanceOf(address(helper)), 0);
        assertEq(IERC20(A_USDT).balanceOf(address(helper)), 0);
        assertGt(usdcVault.getAccount(alice).activeMargin, 0);
        assertGt(usdtVault.getAccount(bob).activeMargin, 0);
    }

    function testAuthorizeScriptScenariosRunSequentially() public requiresFork {
        uint256 snapshot = vm.snapshotState();
        _assertAuthorizeScriptSchedulesExecutesAndVerifiesGrant();
        assertTrue(vm.revertToStateAndDelete(snapshot), "grant scenario restore failed");

        snapshot = vm.snapshotState();
        _assertAuthorizeScriptSchedulesExecutesAndVerifiesRevoke();
        assertTrue(vm.revertToStateAndDelete(snapshot), "revoke scenario restore failed");

        snapshot = vm.snapshotState();
        _assertAuthorizeScriptRevokesCodelessOperator();
        assertTrue(vm.revertToStateAndDelete(snapshot), "codeless revoke scenario restore failed");

        snapshot = vm.snapshotState();
        _assertAuthorizeScriptDoneGrantAttemptRequiresFreshAttemptWhenRoleWasRemoved();
        assertTrue(vm.revertToStateAndDelete(snapshot), "done-attempt scenario restore failed");

        snapshot = vm.snapshotState();
        _assertAuthorizeScriptRejectsUnreviewedHelperRuntime();
        assertTrue(vm.revertToStateAndDelete(snapshot), "runtime-check scenario restore failed");
    }

    function _assertAuthorizeScriptSchedulesExecutesAndVerifiesGrant() private {
        LCCMarginDepositHelper replacement = new LCCMarginDepositHelper(address(factory), WA_ETH_USDC, WA_ETH_USDT);
        _configureAuthorizeScript(replacement, address(helper));
        _moveFactoryToParametersTimelock();
        _authorizeDefaultBroadcaster();

        AuthorizeLCCMarginDepositHelperSafe grant = new AuthorizeLCCMarginDepositHelperSafe();
        grant.schedule(0, false);
        (uint256 calls,) = grant.getBatchInfo(0);
        assertEq(calls, 1);
        assertFalse(factory.isDepositOperator(address(replacement)));
        assertTrue(factory.isDepositOperator(address(helper)));

        bytes32 grantOperationId = _operationId(address(replacement), true, 0);
        ITimelockController controller = ITimelockController(PARAMS_TIMELOCK);
        assertTrue(controller.isOperationPending(grantOperationId));
        uint256 grantReadyAt = controller.getTimestamp(grantOperationId);

        AuthorizeLCCMarginDepositHelperSafe pendingGrant = new AuthorizeLCCMarginDepositHelperSafe();
        pendingGrant.schedule(0, false);
        (calls,) = pendingGrant.getBatchInfo(0);
        assertEq(calls, 0);
        assertEq(controller.getTimestamp(grantOperationId), grantReadyAt);
        assertFalse(factory.isDepositOperator(address(replacement)));

        AuthorizeLCCMarginDepositHelperSafe earlyGrantExecution = new AuthorizeLCCMarginDepositHelperSafe();
        vm.expectRevert();
        earlyGrantExecution.execute(0);

        vm.warp(block.timestamp + 1 days);
        address nonProposer = makeAddr("authorize-script-non-proposer");
        assertFalse(controller.hasRole(controller.PROPOSER_ROLE(), nonProposer));
        vm.setEnv("SAFE_ADDRESS", vm.toString(nonProposer));
        AuthorizeLCCMarginDepositHelperSafe grantExecution = new AuthorizeLCCMarginDepositHelperSafe();
        grantExecution.execute(0);
        assertTrue(controller.isOperationDone(grantOperationId));
        assertTrue(factory.isDepositOperator(address(replacement)));
        assertTrue(factory.isDepositOperator(address(helper)));
        grantExecution.verify();

        vm.setEnv("SAFE_ADDRESS", vm.toString(SAFE_ADDRESS));
        AuthorizeLCCMarginDepositHelperSafe completedGrant = new AuthorizeLCCMarginDepositHelperSafe();
        completedGrant.schedule(0, false);
        (calls,) = completedGrant.getBatchInfo(0);
        assertEq(calls, 0);
    }

    function _assertAuthorizeScriptSchedulesExecutesAndVerifiesRevoke() private {
        LCCMarginDepositHelper replacement = new LCCMarginDepositHelper(address(factory), WA_ETH_USDC, WA_ETH_USDT);
        factory.grantRole(factory.DEPOSIT_OPERATOR_ROLE(), address(replacement));
        _configureAuthorizeScript(replacement, address(helper));
        _moveFactoryToParametersTimelock();
        _authorizeDefaultBroadcaster();

        AuthorizeLCCMarginDepositHelperSafe revocation = new AuthorizeLCCMarginDepositHelperSafe();
        revocation.scheduleRevoke(0, false);
        (uint256 calls,) = revocation.getBatchInfo(0);
        assertEq(calls, 1);
        assertTrue(factory.isDepositOperator(address(helper)));
        bytes32 revokeOperationId = _operationId(address(helper), false, 0);
        ITimelockController controller = ITimelockController(PARAMS_TIMELOCK);
        assertTrue(controller.isOperationPending(revokeOperationId));

        vm.warp(block.timestamp + 1 days);
        AuthorizeLCCMarginDepositHelperSafe revokeExecution = new AuthorizeLCCMarginDepositHelperSafe();
        revokeExecution.executeRevoke(0);
        assertTrue(controller.isOperationDone(revokeOperationId));
        assertFalse(factory.isDepositOperator(address(helper)));
        assertTrue(factory.isDepositOperator(address(replacement)));
        revokeExecution.verifyRevoke();

        AuthorizeLCCMarginDepositHelperSafe rejected = new AuthorizeLCCMarginDepositHelperSafe();
        vm.expectRevert(bytes("address is not a deposit operator"));
        rejected.scheduleRevoke(1, false);

        vm.setEnv("LCC_DEPOSIT_OPERATOR_TO_REVOKE", vm.toString(address(replacement)));
        rejected = new AuthorizeLCCMarginDepositHelperSafe();
        vm.expectRevert(bytes("operator is LCC_MARGIN_DEPOSIT_HELPER"));
        rejected.scheduleRevoke(1, false);
    }

    function _assertAuthorizeScriptRevokesCodelessOperator() private {
        address operator = makeAddr("codeless-deposit-operator");
        assertEq(operator.code.length, 0);
        factory.grantRole(factory.DEPOSIT_OPERATOR_ROLE(), operator);
        _configureAuthorizeScript(helper, operator);
        _moveFactoryToParametersTimelock();
        _authorizeDefaultBroadcaster();

        AuthorizeLCCMarginDepositHelperSafe revocation = new AuthorizeLCCMarginDepositHelperSafe();
        revocation.scheduleRevoke(3, false);
        (uint256 calls,) = revocation.getBatchInfo(0);
        assertEq(calls, 1);
        assertTrue(factory.isDepositOperator(operator));

        bytes32 revokeOperationId = _operationId(operator, false, 3);
        ITimelockController controller = ITimelockController(PARAMS_TIMELOCK);
        assertTrue(controller.isOperationPending(revokeOperationId));

        vm.warp(block.timestamp + 1 days);
        AuthorizeLCCMarginDepositHelperSafe revokeExecution = new AuthorizeLCCMarginDepositHelperSafe();
        revokeExecution.executeRevoke(3);
        assertTrue(controller.isOperationDone(revokeOperationId));
        assertFalse(factory.isDepositOperator(operator));
        revokeExecution.verifyRevoke();
    }

    function _assertAuthorizeScriptDoneGrantAttemptRequiresFreshAttemptWhenRoleWasRemoved() private {
        LCCMarginDepositHelper replacement = new LCCMarginDepositHelper(address(factory), WA_ETH_USDC, WA_ETH_USDT);
        _configureAuthorizeScript(replacement, address(helper));
        _moveFactoryToParametersTimelock();
        _authorizeDefaultBroadcaster();

        AuthorizeLCCMarginDepositHelperSafe firstAttempt = new AuthorizeLCCMarginDepositHelperSafe();
        firstAttempt.schedule(7, false);
        vm.warp(block.timestamp + 1 days);
        firstAttempt = new AuthorizeLCCMarginDepositHelperSafe();
        firstAttempt.execute(7);

        bytes32 depositOperatorRole = factory.DEPOSIT_OPERATOR_ROLE();
        vm.prank(PARAMS_TIMELOCK);
        factory.revokeRole(depositOperatorRole, address(replacement));
        assertFalse(factory.isDepositOperator(address(replacement)));

        AuthorizeLCCMarginDepositHelperSafe completedAttempt = new AuthorizeLCCMarginDepositHelperSafe();
        vm.expectRevert(bytes("operation already executed; use a fresh attempt"));
        completedAttempt.schedule(7, false);

        AuthorizeLCCMarginDepositHelperSafe freshAttempt = new AuthorizeLCCMarginDepositHelperSafe();
        freshAttempt.schedule(8, false);
        (uint256 calls,) = freshAttempt.getBatchInfo(0);
        assertEq(calls, 1);
        assertTrue(ITimelockController(PARAMS_TIMELOCK).isOperationPending(_operationId(address(replacement), true, 8)));
    }

    function _assertAuthorizeScriptRejectsUnreviewedHelperRuntime() private {
        LCCMarginDepositHelper replacement = new LCCMarginDepositHelper(address(factory), WA_ETH_USDC, WA_ETH_USDT);
        _configureAuthorizeScript(replacement, address(helper));
        _moveFactoryToParametersTimelock();

        OracleMock wrongRuntime = new OracleMock();
        vm.setEnv("LCC_MARGIN_DEPOSIT_HELPER", vm.toString(address(wrongRuntime)));
        AuthorizeLCCMarginDepositHelperSafe rejected = new AuthorizeLCCMarginDepositHelperSafe();
        vm.expectRevert(bytes("helper runtime code hash mismatch"));
        rejected.schedule(0, false);
    }

    function _configureAuthorizeScript(LCCMarginDepositHelper replacement, address operatorToRevoke) private {
        vm.setEnv("WALLET_TYPE", "local");
        vm.setEnv("SAFE_PROPOSER_PRIVATE_KEY", vm.toString(bytes32(uint256(1))));
        vm.setEnv("SAFE_NONCE", "1");
        vm.setEnv("SAFE_ADDRESS", vm.toString(SAFE_ADDRESS));
        vm.setEnv("LCC_FACTORY", vm.toString(address(factory)));
        vm.setEnv("LCC_MARGIN_DEPOSIT_HELPER", vm.toString(address(replacement)));
        vm.setEnv("LCC_DEPOSIT_OPERATOR_TO_REVOKE", vm.toString(operatorToRevoke));
    }

    function _moveFactoryToParametersTimelock() private {
        factory.transferOwnership(PARAMS_TIMELOCK);
        vm.prank(PARAMS_TIMELOCK);
        factory.acceptOwnership();
        assertEq(factory.owner(), PARAMS_TIMELOCK);
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

    function _operationId(address account, bool grant, uint256 attempt) private view returns (bytes32) {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);
        targets[0] = address(factory);
        datas[0] = grant
            ? abi.encodeCall(factory.grantRole, (factory.DEPOSIT_OPERATOR_ROLE(), account))
            : abi.encodeCall(factory.revokeRole, (factory.DEPOSIT_OPERATOR_ROLE(), account));
        bytes32 salt = keccak256(abi.encode(DEPOSIT_OPERATOR_SALT_DOMAIN, address(factory), account, grant, attempt));
        return ITimelockController(PARAMS_TIMELOCK).hashOperationBatch(targets, values, datas, bytes32(0), salt);
    }

    function testRealUnderlyingDepositEmitsReferralAttribution() public requiresFork {
        uint256 amount = 25e6;
        bytes32 code = keccak256("FORK_REF");
        ILCCMarginDepositHelper.DepositParams memory params = _params(usdcVault, amount);
        params.referral = code;
        uint256 expectedShares = IERC4626(WA_ETH_USDC).previewDeposit(amount);

        vm.recordLogs();
        vm.prank(alice);
        uint256 commitment = helper.depositUSDC(params);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(helper) || logs[i].topics.length == 0
                    || logs[i].topics[0] != ILCCMarginDepositHelper.LCCDepositReferred.selector
            ) continue;
            ++found;
            assertEq(logs[i].topics.length, 4);
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(alice))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(usdcVault)))));
            assertEq(logs[i].topics[3], code);
            (uint256 marginShares, uint256 loggedCommitment) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(marginShares, expectedShares);
            assertEq(loggedCommitment, commitment);
        }
        assertEq(found, 1);
        assertGt(commitment, 0);
        assertEq(usdcVault.getAccount(alice).activeMargin, expectedShares);
    }

    function _probeIngressDelta(IERC20 token, address user, uint256 amount) private returns (uint256 delta) {
        uint256 snapshot = vm.snapshotState();
        uint256 beforeBalance = token.balanceOf(address(helper));
        vm.prank(user);
        token.safeTransfer(address(helper), amount);
        uint256 afterBalance = token.balanceOf(address(helper));
        assertGe(afterBalance, beforeBalance);
        delta = afterBalance - beforeBalance;
        assertTrue(vm.revertToStateAndDelete(snapshot), "rounding probe restore failed");
    }

    function _fundUnderlyingAndAToken(address user, address asset, uint256 total) private {
        deal(asset, user, total);
        uint256 supplyAmount = total / 2;
        vm.startPrank(user);
        IERC20(asset).forceApprove(AAVE_V3_POOL, supplyAmount);
        IAaveV3PoolSupply(AAVE_V3_POOL).supply(asset, supplyAmount, user, 0);
        IERC20(asset).forceApprove(AAVE_V3_POOL, 0);
        vm.stopPrank();
    }

    function _params(ILCCVault target, uint256 amount)
        private
        view
        returns (ILCCMarginDepositHelper.DepositParams memory)
    {
        return ILCCMarginDepositHelper.DepositParams({
            vault: address(target),
            amountIn: amount,
            minMarginShares: 1,
            minCommitment: 1,
            maxCommitment: type(uint256).max,
            allowPendingActivation: false,
            deadline: block.timestamp,
            referral: bytes32(0)
        });
    }

    function _vaultParams(address oracle, address marginAsset) private view returns (ILCCVault.VaultParams memory) {
        return ILCCVault.VaultParams({
            marginAsset: marginAsset,
            marginOracle: oracle,
            startTimestamp: block.timestamp,
            maxEpochs: 0,
            epochLength: 7 days,
            normalDuration: 4 days,
            preCallDuration: 1 days,
            fundingDuration: 1 days,
            marginRatioBps: 5_000,
            protocolCommitmentCap: 1_000_000_000e6,
            userCommitmentCap: 1_000_000_000e6,
            exitCapBps: 2_000,
            exitDelayEpochs: 1,
            minCommitmentEpochs: 0,
            minDepositAssets: 0,
            auctionStepCount: 0,
            auctionStepDecayRateBps: 0,
            maxAuctionAwardBps: 0,
            slashFeeBps: 0
        });
    }
}
