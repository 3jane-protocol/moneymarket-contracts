// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {IERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LCCBase, LCCDepositRouterMock, LCCRevertingOracle} from "./LCCBase.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {LCCEventsLib} from "../../../src/lcc/libraries/LCCEventsLib.sol";

contract LCCArbitraryCallRouterMock {
    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        bool success;
        (success, result) = target.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}

contract LCCPathologicalBeneficiary {
    fallback() external payable {
        revert("NO_CALLBACKS");
    }
}

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

    function testDepositStagesDuringFundingWithoutOpenCallAndAggregateBucketActivates() public {
        vm.warp(START + NORMAL + PRE_CALL);
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

        vm.warp(START + NORMAL + PRE_CALL);
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

    function testCommitmentBoundsRejectOutsideAndAcceptInclusiveEdges() public {
        vm.expectRevert(LCCErrorsLib.InvalidAmount.selector);
        vm.prank(alice);
        vault.deposit(100e18, alice, 200e18 + 1, type(uint256).max, true, type(uint256).max);

        vm.prank(alice);
        assertEq(vault.deposit(100e18, alice, 200e18, type(uint256).max, true, type(uint256).max), 200e18);

        vm.expectRevert(LCCErrorsLib.InvalidAmount.selector);
        vm.prank(bob);
        vault.deposit(100e18, bob, 1, 200e18 - 1, true, type(uint256).max);

        vm.prank(bob);
        assertEq(vault.deposit(100e18, bob, 1, 200e18, true, type(uint256).max), 200e18);
    }

    function testInvalidCommitmentBoundsRevert() public {
        vm.expectRevert(LCCErrorsLib.InvalidAmount.selector);
        vm.prank(alice);
        vault.deposit(100e18, alice, 0, 200e18, true, type(uint256).max);

        vm.expectRevert(LCCErrorsLib.InvalidAmount.selector);
        vm.prank(alice);
        vault.deposit(100e18, alice, 200e18 + 1, 200e18, true, type(uint256).max);
    }

    function testWallClockDeadlineRejectsExpiredAndAcceptsInclusiveDeadline() public {
        vm.expectRevert(LCCErrorsLib.DeadlineExpired.selector);
        vm.prank(alice);
        vault.deposit(100e18, alice, 200e18, 200e18, true, block.timestamp - 1);

        vm.prank(alice);
        assertEq(vault.deposit(100e18, alice, 200e18, 200e18, true, block.timestamp), 200e18);
    }

    function testDepositDeadlineUsesWallClockAfterPause() public {
        vm.prank(owner);
        vault.pause();
        vm.warp(block.timestamp + 100);
        vm.prank(owner);
        vault.unpause();

        uint256 effectiveNow = _effectiveTime(vault);
        uint256 deadline = effectiveNow + 50;
        assertGt(deadline, effectiveNow);
        assertLt(deadline, block.timestamp);

        vm.expectRevert(LCCErrorsLib.DeadlineExpired.selector);
        vm.prank(alice);
        vault.deposit(100e18, alice, 200e18, 200e18, true, deadline);
    }

    function testPendingActivationRequiresOptInAtEndOfPreCallBoundary() public {
        vm.warp(START + NORMAL + PRE_CALL);

        vm.expectRevert(LCCErrorsLib.InvalidPhase.selector);
        vm.prank(alice);
        vault.deposit(100e18, alice, 200e18, 200e18, false, type(uint256).max);

        vm.prank(alice);
        assertEq(vault.deposit(100e18, alice, 200e18, 200e18, true, type(uint256).max), 200e18);
        assertEq(vault.getAccount(alice).pendingCommitment, 200e18);
    }

    function testDepositsAllowedDuringPreCallAndOpenedCallButBlockedDuringLiveAuction() public {
        _deployAuctionVault();
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);

        vm.warp(START + NORMAL);
        _deposit(carol, 25e18);
        assertEq(vault.getAccount(carol).pendingCommitment, 50e18);

        vm.prank(owner);
        vault.openEpochCall(0, 100e18);
        vm.warp(START + NORMAL + PRE_CALL);
        _deposit(carol, 25e18);
        assertEq(vault.getAccount(carol).pendingCommitment, 100e18);

        _finishFunding();
        vault.finalizeEpochSlash(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);

        vm.expectRevert(LCCErrorsLib.InvalidPhase.selector);
        _deposit(carol, 1e18);
    }

    function testDelegatedDepositDebitsPayerAndCreditsOnlyBeneficiary() public {
        uint256 assets = 100e18;
        _mintAndApproveMarginPayer(address(vault), depositOperator, assets);
        assertFalse(factory.isWhitelistedDepositor(depositOperator));
        uint256 payerBalanceBefore = margin.balanceOf(depositOperator);

        uint256 commitment = _depositFor(depositOperator, alice, assets);

        assertEq(margin.balanceOf(depositOperator), payerBalanceBefore - assets);
        assertEq(vault.getAccount(alice).activeMargin, assets);
        assertEq(vault.getAccount(alice).activeCommitment, commitment);
        assertEq(vault.getAccount(depositOperator).activeMargin, 0);
        assertEq(factory.vaultOf(alice), address(vault));
        assertEq(factory.vaultOf(depositOperator), address(0));
    }

    function testDelegatedDepositRequiresPayerAllowanceAndIgnoresBeneficiaryAllowance() public {
        uint256 assets = 10e18;
        margin.mint(depositOperator, assets);

        vm.expectRevert();
        _depositFor(depositOperator, alice, assets);

        vm.prank(alice);
        margin.approve(address(vault), 0);
        vm.prank(depositOperator);
        margin.approve(address(vault), assets);

        _depositFor(depositOperator, alice, assets);
        assertEq(vault.getAccount(alice).activeMargin, assets);
    }

    function testUnauthorizedDelegatedDepositRevertsAtomicallyWithZeroStateDelta() public {
        uint256 assets = 10e18;
        _mintAndApproveMarginPayer(address(vault), stranger, assets);
        uint256 payerBalanceBefore = margin.balanceOf(stranger);

        vm.expectRevert(abi.encodeWithSelector(LCCErrorsLib.UnauthorizedDepositOperator.selector, stranger));
        vm.prank(stranger);
        vault.deposit(assets, alice, 1, type(uint256).max, true, type(uint256).max);

        assertEq(margin.balanceOf(stranger), payerBalanceBefore);
        assertEq(margin.balanceOf(address(vault)), 0);
        assertEq(vault.getAccount(alice).activeMargin, 0);
        assertEq(vault.totals().activeMargin, 0);
        assertEq(factory.vaultOf(alice), address(0));
    }

    function testRevokedDepositOperatorCannotDeposit() public {
        _mintAndApproveMarginPayer(address(vault), depositOperator, 10e18);
        factory.revokeRole(factory.DEPOSIT_OPERATOR_ROLE(), depositOperator);

        vm.expectRevert(abi.encodeWithSelector(LCCErrorsLib.UnauthorizedDepositOperator.selector, depositOperator));
        _depositFor(depositOperator, alice, 10e18);
        assertEq(vault.getAccount(alice).activeMargin, 0);
    }

    function testExplicitSelfDepositNeedsNoDepositOperatorRole() public {
        assertFalse(factory.isDepositOperator(alice));
        vm.prank(alice);
        vault.deposit(10e18, alice, 1, type(uint256).max, true, type(uint256).max);
        assertEq(vault.getAccount(alice).activeMargin, 10e18);
    }

    function testZeroBeneficiaryRevertsEvenWhenWhitelistIsDisabled() public {
        factory.setWhitelistEnabled(false);
        _mintAndApproveMarginPayer(address(vault), depositOperator, 10e18);

        vm.expectRevert(LCCErrorsLib.ZeroAddress.selector);
        _depositFor(depositOperator, address(0), 10e18);

        assertEq(margin.balanceOf(address(vault)), 0);
        assertEq(vault.getAccount(address(0)).activeMargin, 0);
    }

    function testZeroBeneficiaryRevertsEvenWhenWhitelistIsEnabled() public {
        assertTrue(factory.whitelistEnabled());
        _mintAndApproveMarginPayer(address(vault), depositOperator, 10e18);

        vm.expectRevert(LCCErrorsLib.ZeroAddress.selector);
        _depositFor(depositOperator, address(0), 10e18);

        assertEq(margin.balanceOf(address(vault)), 0);
        assertEq(vault.getAccount(address(0)).activeMargin, 0);
    }

    function testDelegatedDepositCannotCreditBeneficiaryWithExitInProgress() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);
        _mintAndApproveMarginPayer(address(vault), depositOperator, 10e18);

        vm.expectRevert(LCCErrorsLib.ExitInProgress.selector);
        _depositFor(depositOperator, alice, 10e18);
    }

    function testDelegatedDepositConsumesBeneficiaryUserCapNotPayerCap() public {
        vault = _newVault(_params(1_000e18, 200e18));
        _mintAndApprove(vault, alice, 100e18, 0);
        _mintAndApproveMarginPayer(address(vault), depositOperator, 11e18);
        vm.prank(alice);
        vault.deposit(100e18, alice, 1, type(uint256).max, true, type(uint256).max);

        vm.expectRevert(LCCErrorsLib.CapExceeded.selector);
        _depositFor(depositOperator, alice, 11e18);

        assertEq(vault.getAccount(alice).activeCommitment, 200e18);
        assertEq(vault.getAccount(depositOperator).activeCommitment, 0);
    }

    function testDelegatedDepositsShareProtocolCapAcrossBeneficiaries() public {
        vault = _newVault(_params(300e18, 1_000e18));
        _mintAndApprove(vault, alice, 100e18, 0);
        _mintAndApproveMarginPayer(address(vault), depositOperator, 51e18);
        vm.prank(alice);
        vault.deposit(100e18, alice, 1, type(uint256).max, true, type(uint256).max);

        vm.expectRevert(LCCErrorsLib.CapExceeded.selector);
        _depositFor(depositOperator, bob, 51e18);
        assertEq(vault.totals().activeCommitment, 200e18);
    }

    function testDelegatedDepositExtendsBeneficiaryCommitmentLock() public {
        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        params.minCommitmentEpochs = 2;
        _deployVaultWithParams(params);
        _mintAndApproveMarginPayer(address(vault), depositOperator, 1e18);
        _deposit(alice, 10e18);

        vm.warp(START + EPOCH);
        _depositFor(depositOperator, alice, 1e18);
        assertEq(vault.getAccount(alice).commitmentStartEpoch, 1);

        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);

        vm.warp(START + 3 * EPOCH);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);
    }

    function testTwoDelegatedPayersMergePendingForOneBeneficiary() public {
        factory.grantRole(factory.DEPOSIT_OPERATOR_ROLE(), bob);
        _mintAndApproveMarginPayer(address(vault), depositOperator, 10e18);
        _mintAndApproveMarginPayer(address(vault), bob, 15e18);
        vm.warp(START + NORMAL + PRE_CALL);

        _depositFor(depositOperator, alice, 10e18);
        _depositFor(bob, alice, 15e18);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.pendingMargin, 25e18);
        assertEq(account.pendingCommitment, 50e18);
        assertEq(account.pendingActivationEpoch, 1);
        assertEq(vault.pendingMarginByActivationEpoch(1), 25e18);
    }

    function testDelegatedDepositDoesNotWeakenPendingActivationEpochCollision() public {
        uint256 accountsSlot = 14;
        _assertLayoutSlot("accounts", accountsSlot);
        _mintAndApproveMarginPayer(address(vault), depositOperator, 20e18);
        vm.warp(START + NORMAL + PRE_CALL);
        _depositFor(depositOperator, alice, 10e18);

        bytes32 accountBase = keccak256(abi.encode(alice, accountsSlot));
        bytes32 epochWordSlot = bytes32(uint256(accountBase) + 3);
        uint256 epochWord = uint256(vm.load(address(vault), epochWordSlot));
        uint256 pendingEpochMask = uint256(type(uint64).max) << 128;
        vm.store(address(vault), epochWordSlot, bytes32((epochWord & ~pendingEpochMask) | (uint256(2) << 128)));

        vm.expectRevert(LCCErrorsLib.InvalidEpoch.selector);
        _depositFor(depositOperator, alice, 10e18);
    }

    function testDepositCheckpointedIndexesBeneficiaryThenPayer() public {
        _mintAndApproveMarginPayer(address(vault), depositOperator, 10e18);

        vm.expectEmit(true, true, false, true, address(vault));
        emit LCCEventsLib.DepositCheckpointed(alice, depositOperator, 10e18, 10e18, 20e18, 0, true);
        _depositFor(depositOperator, alice, 10e18);
    }

    function testCooperativeRouterCanFundWhitelistedBeneficiaryWithoutPayerWhitelisting() public {
        LCCDepositRouterMock router = new LCCDepositRouterMock(IERC20(address(margin)));
        factory.grantRole(factory.DEPOSIT_OPERATOR_ROLE(), address(router));
        _mintAndApproveMarginPayer(address(router), carol, 10e18);
        assertFalse(factory.isWhitelistedDepositor(address(router)));

        vm.prank(carol);
        router.depositFor(vault, alice, 10e18, 1, type(uint256).max, false, type(uint256).max);

        assertEq(vault.getAccount(alice).activeMargin, 10e18);
        assertEq(vault.getAccount(carol).activeMargin, 0);
    }

    function testArbitraryRouterCanRefreshVictimLockWithDust() public {
        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        params.minCommitmentEpochs = 2;
        _deployVaultWithParams(params);
        _deposit(alice, 10e18);
        LCCArbitraryCallRouterMock router = _newArbitraryRouter(1);

        vm.warp(START + EPOCH);
        _arbitraryRouterDeposit(router, alice, 1, false);

        assertEq(vault.getAccount(alice).commitmentStartEpoch, 1);
    }

    function testArbitraryRouterCanStagePendingThatBlocksVictimExit() public {
        _deposit(alice, 10e18);
        LCCArbitraryCallRouterMock router = _newArbitraryRouter(1);
        vm.warp(START + NORMAL + PRE_CALL);
        _arbitraryRouterDeposit(router, alice, 1, true);

        vm.expectRevert(LCCErrorsLib.PendingDepositExists.selector);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);
    }

    function testArbitraryRouterCanStagePendingThatBlocksBouncer() public {
        uint256 commitment = _deposit(alice, 10e18);
        LCCArbitraryCallRouterMock router = _newArbitraryRouter(1);
        vm.warp(START + NORMAL + PRE_CALL);
        _arbitraryRouterDeposit(router, alice, 1, true);

        vm.expectRevert(LCCErrorsLib.PendingDepositExists.selector);
        vm.prank(bouncer);
        vault.bounceCommitment(alice, commitment);
    }

    function testArbitraryRouterCanRepeatAfterActivationWithoutBeneficiaryAction() public {
        _deposit(alice, 10e18);
        LCCArbitraryCallRouterMock router = _newArbitraryRouter(2);
        vm.warp(START + NORMAL + PRE_CALL);
        _arbitraryRouterDeposit(router, alice, 1, true);

        vm.warp(START + EPOCH);
        _syncAs(stranger);
        _arbitraryRouterDeposit(router, alice, 1, false);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 10e18 + 2);
        assertEq(account.commitmentStartEpoch, 1);
    }

    function testArbitraryRouterCanCreditPathologicalContractBeneficiary() public {
        LCCPathologicalBeneficiary beneficiary = new LCCPathologicalBeneficiary();
        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = address(beneficiary);
        factory.setDepositorsWhitelisted(beneficiaries, true);
        LCCArbitraryCallRouterMock router = _newArbitraryRouter(1);

        _arbitraryRouterDeposit(router, address(beneficiary), 1, false);

        assertEq(vault.getAccount(address(beneficiary)).activeMargin, 1);
        assertEq(factory.vaultOf(address(beneficiary)), address(vault));
    }

    function _newArbitraryRouter(uint256 assets) internal returns (LCCArbitraryCallRouterMock router) {
        router = new LCCArbitraryCallRouterMock();
        factory.grantRole(factory.DEPOSIT_OPERATOR_ROLE(), address(router));
        margin.mint(address(router), assets);
        vm.prank(stranger);
        router.execute(address(margin), abi.encodeCall(IERC20.approve, (address(vault), type(uint256).max)));
    }

    function _arbitraryRouterDeposit(
        LCCArbitraryCallRouterMock router,
        address beneficiary,
        uint256 assets,
        bool allowPendingActivation
    ) internal {
        vm.prank(stranger);
        router.execute(
            address(vault),
            abi.encodeCall(
                ILCCVault.deposit,
                (assets, beneficiary, 1, type(uint256).max, allowPendingActivation, type(uint256).max)
            )
        );
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
        vm.warp(START + NORMAL + PRE_CALL);

        vm.expectRevert(LCCErrorsLib.CapExceeded.selector);
        _deposit(alice, pendingAmount);

        assertEq(vault.totals().pendingMargin, 0);
        assertEq(vault.pendingMarginByActivationEpoch(1), 0);
    }
}
