// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {IAccessControl} from "../../../lib/openzeppelin/contracts/access/IAccessControl.sol";

import {LCCBase} from "./LCCBase.t.sol";
import {ILCCMarginTransferHook, LCCReentrantMarginToken} from "./LCCReentrancy.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {LCCVaultFactory} from "../../../src/lcc/LCCVaultFactory.sol";
import {ILCCAdmissionsModule} from "../../../src/lcc/interfaces/ILCCAdmissionsModule.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";

contract LCCAdmissionsModuleMock is ILCCAdmissionsModule {
    bool internal allowed = true;
    bool internal reverting;

    function setAllowed(bool allowed_) external {
        allowed = allowed_;
    }

    function setReverting(bool reverting_) external {
        reverting = reverting_;
    }

    function canDeposit(address, address) external view returns (bool) {
        if (reverting) revert("MODULE_REVERT");
        return allowed;
    }
}

contract LCCMalformedAdmissionsModule {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(31, 1)
        }
    }
}

contract LCCReentrantAdmissionsModule is ILCCAdmissionsModule {
    LCCVaultFactory internal immutable targetFactory;

    constructor(LCCVaultFactory targetFactory_) {
        targetFactory = targetFactory_;
    }

    function canDeposit(address user, address) external view returns (bool) {
        // The nested admission attempt must be contained by the factory's isVault gate. The outer decision remains
        // usable, proving a hostile module cannot turn its STATICCALL into a registry write or recursive admission.
        (bool reentered,) =
            address(targetFactory).staticcall(abi.encodeCall(targetFactory.authorizeDeposit, (user, false)));
        return !reentered;
    }
}

contract LCCStateMutatingAdmissionsModule {
    uint256 public writes;

    function canDeposit(address user, address vault) external returns (bool) {
        // The validation probe supplies equal addresses. A real admission supplies user != vault, making this SSTORE
        // a positive control for the runtime STATICCALL boundary enforced by ILCCAdmissionsModule.canDeposit's view.
        if (user != vault) ++writes;
        return true;
    }
}

contract LCCRegistryDepositReentryProbe is ILCCMarginTransferHook {
    LCCReentrantMarginToken internal immutable token;
    LCCVault internal immutable innerVault;
    LCCVault internal immutable outerVault;
    uint256 internal immutable innerAssets;

    uint256 public innerCommitment;

    constructor(LCCReentrantMarginToken token_, LCCVault innerVault_, LCCVault outerVault_, uint256 innerAssets_) {
        token = token_;
        innerVault = innerVault_;
        outerVault = outerVault_;
        innerAssets = innerAssets_;
        token_.approve(address(innerVault_), type(uint256).max);
        token_.approve(address(outerVault_), type(uint256).max);
    }

    function depositIntoOuter(uint256 assets) external returns (uint256 commitment) {
        token.arm(address(this));
        return outerVault.deposit(assets, 1, type(uint256).max, true, type(uint256).max);
    }

    function onMarginTransfer() external {
        require(msg.sender == address(token), "ONLY_TOKEN");
        innerCommitment = innerVault.deposit(innerAssets, 1, type(uint256).max, true, type(uint256).max);
    }
}

contract LCCRegistryTest is LCCBase {
    uint256 internal constant ACCOUNTS_SLOT = 14;
    address internal unlisted = makeAddr("unlisted");

    function testSingleOwnerRoleTopologyInvariant() public view {
        bytes32 ownerRole = factory.OWNER_ROLE();
        assertEq(factory.getRoleMemberCount(ownerRole), 1);
        assertEq(factory.getRoleMember(ownerRole, 0), owner);
        assertEq(factory.getRoleMemberCount(factory.DEFAULT_ADMIN_ROLE()), 0);
        assertEq(factory.getRoleAdmin(ownerRole), factory.DEFAULT_ADMIN_ROLE());
        assertEq(factory.getRoleAdmin(factory.LISTER_ROLE()), ownerRole);
        assertEq(factory.getRoleAdmin(factory.BOUNCER_ROLE()), ownerRole);
        assertEq(factory.getRoleAdmin(factory.GUARDIAN_ROLE()), ownerRole);
    }

    function testOwnerRoleCannotBeRenounced() public {
        bytes32 ownerRole = factory.OWNER_ROLE();
        vm.expectRevert(LCCErrorsLib.CannotRenounceOwnerRole.selector);
        factory.renounceRole(ownerRole, owner);
        assertEq(factory.getRoleMemberCount(ownerRole), 1);
        assertEq(factory.owner(), owner);
    }

    function testOwnerCannotGrantAnotherOwnerDirectly() public {
        bytes32 ownerRole = factory.OWNER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, owner, factory.DEFAULT_ADMIN_ROLE()
            )
        );
        factory.grantRole(ownerRole, unlisted);
        assertEq(factory.getRoleMemberCount(ownerRole), 1);
        assertEq(factory.owner(), owner);
    }

    function testTwoStepOwnershipTransferHappyPath() public {
        address newOwner = makeAddr("newOwner");
        factory.transferOwnership(newOwner);

        assertEq(factory.pendingOwner(), newOwner);
        assertEq(factory.owner(), owner);

        vm.prank(newOwner);
        factory.acceptOwnership();

        assertEq(factory.pendingOwner(), address(0));
        assertEq(factory.owner(), newOwner);
        assertEq(factory.getRoleMemberCount(factory.OWNER_ROLE()), 1);
        assertFalse(factory.isOwner(owner));
        assertTrue(factory.isOwner(newOwner));
    }

    function testPendingOwnerMayBeOverwrittenAndWrongAddressCannotAccept() public {
        address firstPending = makeAddr("firstPending");
        address secondPending = makeAddr("secondPending");
        factory.transferOwnership(firstPending);
        factory.transferOwnership(secondPending);

        assertEq(factory.pendingOwner(), secondPending);
        vm.expectRevert(LCCErrorsLib.Unauthorized.selector);
        vm.prank(firstPending);
        factory.acceptOwnership();

        vm.prank(secondPending);
        factory.acceptOwnership();
        assertEq(factory.owner(), secondPending);
        assertEq(factory.getRoleMemberCount(factory.OWNER_ROLE()), 1);
    }

    function testPendingOwnershipTransferCanBeCancelledWithZeroAddress() public {
        address cancelledPendingOwner = makeAddr("cancelledPendingOwner");
        factory.transferOwnership(cancelledPendingOwner);

        vm.expectEmit(true, true, false, true, address(factory));
        emit LCCVaultFactory.OwnershipTransferStarted(owner, address(0));
        factory.transferOwnership(address(0));

        assertEq(factory.pendingOwner(), address(0));
        vm.expectRevert(LCCErrorsLib.Unauthorized.selector);
        vm.prank(cancelledPendingOwner);
        factory.acceptOwnership();
        assertEq(factory.owner(), owner);
    }

    function testPendingOwnershipTransferCanBeCancelledByProposingCurrentOwner() public {
        address cancelledPendingOwner = makeAddr("cancelledPendingOwner");
        factory.transferOwnership(cancelledPendingOwner);
        factory.transferOwnership(owner);

        assertEq(factory.pendingOwner(), owner);
        vm.expectRevert(LCCErrorsLib.Unauthorized.selector);
        vm.prank(cancelledPendingOwner);
        factory.acceptOwnership();

        factory.acceptOwnership();
        assertEq(factory.pendingOwner(), address(0));
        assertEq(factory.owner(), owner);
        assertEq(factory.getRoleMemberCount(factory.OWNER_ROLE()), 1);
    }

    function testAuthorizeDepositRejectsNonVaultCaller() public {
        vm.expectRevert(LCCErrorsLib.NotVault.selector);
        factory.authorizeDeposit(alice, false);
    }

    function testWhitelistEnabledRejectsAndDisabledAllowsUnlistedDepositor() public {
        LCCVault target = _newVault(_params(CAP, CAP));
        margin.mint(unlisted, 10e18);
        vm.prank(unlisted);
        margin.approve(address(target), type(uint256).max);

        vm.expectRevert(LCCErrorsLib.NotWhitelistedDepositor.selector);
        vm.prank(unlisted);
        target.deposit(10e18, 1, type(uint256).max, true, type(uint256).max);
        assertEq(target.getAccount(unlisted).activeMargin, 0);

        factory.setWhitelistEnabled(false);
        vm.prank(unlisted);
        target.deposit(10e18, 1, type(uint256).max, true, type(uint256).max);
        assertEq(factory.vaultOf(unlisted), address(target));
    }

    function testListerRoleControlsBatchWhitelist() public {
        address[] memory depositors = new address[](1);
        depositors[0] = unlisted;
        bytes32 listerRole = factory.LISTER_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, listerRole)
        );
        vm.prank(stranger);
        factory.setDepositorsWhitelisted(depositors, true);

        vm.prank(lister);
        factory.setDepositorsWhitelisted(depositors, true);
        assertTrue(factory.isWhitelistedDepositor(unlisted));
    }

    function testTopUpInRegisteredVaultIsNoOpForRegistry() public {
        _deposit(alice, 10e18);
        assertEq(factory.vaultOf(alice), address(vault));

        _deposit(alice, 5e18);
        assertEq(factory.vaultOf(alice), address(vault));
        assertEq(vault.getAccount(alice).activeMargin, 15e18);
    }

    function testOneVaultPolicyEnabledDeniesCrossVaultDeposit() public {
        LCCVault otherVault = _newVault(_params(CAP, CAP));
        _mintAndApprove(otherVault, alice, 0, 0);
        _deposit(alice, 10e18);

        vm.expectRevert(abi.encodeWithSelector(LCCErrorsLib.RegisteredElsewhere.selector, address(vault)));
        vm.prank(alice);
        otherVault.deposit(5e18, 1, type(uint256).max, true, type(uint256).max);

        assertEq(otherVault.getAccount(alice).activeMargin, 0);
        assertEq(factory.vaultOf(alice), address(vault));
    }

    function testPolicyOffAllowsMultipleVaultsAndWarmRecordsOutermostDeposit() public {
        LCCVault otherVault = _newVault(_params(CAP, CAP));
        _mintAndApprove(otherVault, alice, 0, 0);
        _deposit(alice, 10e18);

        factory.setOneVaultPolicyEnabled(false);
        vm.prank(alice);
        otherVault.deposit(5e18, 1, type(uint256).max, true, type(uint256).max);

        assertEq(vault.getAccount(alice).activeMargin, 10e18);
        assertEq(otherVault.getAccount(alice).activeMargin, 5e18);
        assertEq(factory.vaultOf(alice), address(otherVault));

        factory.setOneVaultPolicyEnabled(true);
        vm.expectRevert(abi.encodeWithSelector(LCCErrorsLib.RegisteredElsewhere.selector, address(otherVault)));
        vm.prank(alice);
        vault.deposit(1e18, 1, type(uint256).max, true, type(uint256).max);
    }

    function testClosingDisplacedVaultRestoresOneVaultPolicyConstraint() public {
        (LCCVault otherVault, uint256 firstCommitment,) = _openPolicyOffPair();

        vm.prank(bouncer);
        vault.bounceCommitment(alice, firstCommitment);
        assertTrue(vault.isAccountClosed(alice));
        assertFalse(otherVault.isAccountClosed(alice));
        assertEq(factory.vaultOf(alice), address(otherVault));

        factory.setOneVaultPolicyEnabled(true);
        vm.expectRevert(abi.encodeWithSelector(LCCErrorsLib.RegisteredElsewhere.selector, address(otherVault)));
        vm.prank(alice);
        vault.deposit(1e18, 1, type(uint256).max, true, type(uint256).max);
    }

    function testClosingBothVaultsRemovesExemptionAndRestoresFullConstraint() public {
        (LCCVault otherVault, uint256 firstCommitment, uint256 secondCommitment) = _openPolicyOffPair();

        vm.prank(bouncer);
        vault.bounceCommitment(alice, firstCommitment);
        vm.prank(bouncer);
        otherVault.bounceCommitment(alice, secondCommitment);
        assertTrue(vault.isAccountClosed(alice));
        assertTrue(otherVault.isAccountClosed(alice));

        factory.setOneVaultPolicyEnabled(true);
        vm.prank(alice);
        vault.deposit(1e18, 1, type(uint256).max, true, type(uint256).max);
        assertEq(factory.vaultOf(alice), address(vault));

        vm.expectRevert(abi.encodeWithSelector(LCCErrorsLib.RegisteredElsewhere.selector, address(vault)));
        vm.prank(alice);
        otherVault.deposit(1e18, 1, type(uint256).max, true, type(uint256).max);
    }

    function testRetainedDisplacedPositionPreservesDocumentedPolicyExemption() public {
        (LCCVault otherVault,, uint256 secondCommitment) = _openPolicyOffPair();

        factory.setOneVaultPolicyEnabled(true);
        vm.prank(bouncer);
        otherVault.bounceCommitment(alice, secondCommitment);
        assertFalse(vault.isAccountClosed(alice));
        assertTrue(otherVault.isAccountClosed(alice));
        assertEq(factory.vaultOf(alice), address(otherVault));

        vm.prank(alice);
        otherVault.deposit(1e18, 1, type(uint256).max, true, type(uint256).max);

        assertFalse(vault.isAccountClosed(alice));
        assertFalse(otherVault.isAccountClosed(alice));
        assertEq(factory.vaultOf(alice), address(otherVault));
    }

    function testPolicyOnReopeningWarmVaultRunsAdmissionsModuleAfterOriginalExploitSequence() public {
        LCCVault otherVault = _newVault(_params(CAP, CAP));
        _mintAndApprove(otherVault, alice, 0, 0);

        factory.setOneVaultPolicyEnabled(false);
        _deposit(alice, 10e18);
        vm.prank(alice);
        uint256 otherCommitment = otherVault.deposit(5e18, 1, type(uint256).max, true, type(uint256).max);
        assertEq(factory.vaultOf(alice), address(otherVault));

        factory.setOneVaultPolicyEnabled(true);
        vm.prank(bouncer);
        otherVault.bounceCommitment(alice, otherCommitment);
        assertFalse(vault.isAccountClosed(alice));
        assertTrue(otherVault.isAccountClosed(alice));

        LCCAdmissionsModuleMock module = new LCCAdmissionsModuleMock();
        factory.setAdmissionsModule(address(module));
        module.setAllowed(false);

        // hadOpenExposure is false, so the warm-pointer match is a reopen rather than a top-up and must not bypass
        // the full admission gauntlet. The named-vault check passes because the pointer still names otherVault, then
        // the module denial proves the original disable -> A+B -> enable -> close B -> redeposit B exploit no longer
        // reaches the top-up fast return.
        vm.expectRevert(
            abi.encodeWithSelector(LCCErrorsLib.AdmissionsModuleRejected.selector, alice, address(otherVault))
        );
        vm.prank(alice);
        otherVault.deposit(1e18, 1, type(uint256).max, true, type(uint256).max);
        assertTrue(otherVault.isAccountClosed(alice));
    }

    function testGrandfatheredDisplacedPositionIsNotDetectedByNamedVaultCheck() public {
        LCCVault otherVault = _newVault(_params(CAP, CAP));
        _mintAndApprove(otherVault, alice, 0, 0);

        factory.setOneVaultPolicyEnabled(false);
        _deposit(alice, 10e18);
        vm.prank(alice);
        uint256 otherCommitment = otherVault.deposit(5e18, 1, type(uint256).max, true, type(uint256).max);
        assertEq(factory.vaultOf(alice), address(otherVault));

        factory.setOneVaultPolicyEnabled(true);
        vm.prank(bouncer);
        otherVault.bounceCommitment(alice, otherCommitment);
        assertFalse(vault.isAccountClosed(alice));
        assertTrue(otherVault.isAccountClosed(alice));

        // Deliberate owner-accepted residual documented in src/lcc/README.md and docs/architecture.md: admission
        // checks only the warm named vault, not the unbounded family list, so the displaced vault position is unseen.
        vm.prank(alice);
        otherVault.deposit(1e18, 1, type(uint256).max, true, type(uint256).max);

        assertFalse(vault.isAccountClosed(alice));
        assertFalse(otherVault.isAccountClosed(alice));
        assertEq(factory.vaultOf(alice), address(otherVault));
    }

    function testTwoVaultMarginCallbackPolicyOnRevertsOuterDepositWholesale() public {
        (
            LCCReentrantMarginToken token,
            LCCVault innerVault,
            LCCVault outerVault,
            LCCRegistryDepositReentryProbe probe
        ) = _newReentrantRegistryFixture();

        vm.expectRevert(abi.encodeWithSelector(LCCErrorsLib.RegisteredElsewhere.selector, address(innerVault)));
        probe.depositIntoOuter(10e18);

        // The inner deposit reached registration first, but the outer-frame revert rolls the entire callback tree
        // back, including both token transfers and the warm registry write.
        assertEq(innerVault.getAccount(address(probe)).activeMargin, 0);
        assertEq(outerVault.getAccount(address(probe)).activeMargin, 0);
        assertEq(factory.vaultOf(address(probe)), address(0));
        assertEq(token.balanceOf(address(probe)), 20e18);
    }

    function testTwoVaultMarginCallbackPolicyOffCompletesBothAndOutermostRegistryWriteWins() public {
        (
            LCCReentrantMarginToken token,
            LCCVault innerVault,
            LCCVault outerVault,
            LCCRegistryDepositReentryProbe probe
        ) = _newReentrantRegistryFixture();
        factory.setOneVaultPolicyEnabled(false);

        uint256 outerCommitment = probe.depositIntoOuter(10e18);

        // Load-bearing positive control: policy-off must really allow the nested deposit, preserve A's fully
        // materialized account, and leave B as the exact outermost-frame winner. A refactor that bypasses either
        // nested authorization or the warm registration write must fail here rather than making the ON case pass
        // for an unrelated callback failure.
        ILCCVault.Account memory inner = innerVault.getAccount(address(probe));
        assertEq(inner.activeMargin, 10e18);
        assertEq(inner.activeCommitment, probe.innerCommitment());
        assertEq(inner.pendingMargin, 0);
        assertEq(inner.calledEpochCursor, innerVault.syncState().finalizedCallPrefix);
        assertEq(innerVault.totals().activeMargin, 10e18);
        assertEq(outerVault.getAccount(address(probe)).activeMargin, 10e18);
        assertEq(outerVault.getAccount(address(probe)).activeCommitment, outerCommitment);
        assertEq(factory.vaultOf(address(probe)), address(outerVault));
        assertEq(token.balanceOf(address(probe)), 0);
    }

    function testLazyRepointAfterFullSlashToZero() public {
        LCCVault otherVault = _newVault(_params(CAP, CAP));
        _mintAndApprove(otherVault, alice, 0, 0);
        _deposit(alice, 100e18);

        oracle.setPrice(4_999e18);
        _openCall(1e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        assertTrue(vault.isAccountClosed(alice));
        vm.prank(alice);
        otherVault.deposit(10e18, 1, type(uint256).max, true, type(uint256).max);
        assertEq(factory.vaultOf(alice), address(otherVault));
        assertEq(otherVault.getAccount(alice).pendingMargin, 10e18);
    }

    function testLazyRepointAfterMaturedExitIsClaimed() public {
        LCCVault otherVault = _newVault(_params(CAP, CAP));
        _mintAndApprove(otherVault, alice, 0, 0);
        _deposit(alice, 100e18);

        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);
        vm.warp(START + EPOCH);

        assertFalse(vault.isAccountClosed(alice));
        vm.prank(alice);
        assertEq(vault.claimExitedMargin(alice), 100e18);
        assertTrue(vault.isAccountClosed(alice));

        vm.prank(alice);
        otherVault.deposit(10e18, 1, type(uint256).max, true, type(uint256).max);
        assertEq(factory.vaultOf(alice), address(otherVault));
    }

    function testLazyRepointAfterShutdownRemainingMarginClaim() public {
        LCCVault otherVault = _newVault(_params(CAP, CAP));
        _mintAndApprove(otherVault, alice, 0, 0);
        _deposit(alice, 100e18);

        vault.shutdown();
        vm.prank(alice);
        assertEq(vault.claimRemainingMargin(alice), 100e18);
        assertTrue(vault.isAccountClosed(alice));

        vm.prank(alice);
        otherVault.deposit(10e18, 1, type(uint256).max, true, type(uint256).max);
        assertEq(factory.vaultOf(alice), address(otherVault));
    }

    function testLazyRepointAfterEntireActiveCommitmentBounce() public {
        LCCVault otherVault = _newVault(_params(CAP, CAP));
        _mintAndApprove(otherVault, alice, 0, 0);
        uint256 commitment = _deposit(alice, 100e18);

        vm.prank(bouncer);
        assertEq(vault.bounceCommitment(alice, commitment), 100e18);
        assertTrue(vault.isAccountClosed(alice));

        vm.prank(alice);
        otherVault.deposit(10e18, 1, type(uint256).max, true, type(uint256).max);
        assertEq(factory.vaultOf(alice), address(otherVault));
    }

    function testRepointDeniedWhilePriorVaultHasLiveAuctionReplayBarrier() public {
        _deployAuctionVault();
        LCCVault otherVault = _newVault(_params(CAP, CAP));
        _mintAndApprove(otherVault, alice, 0, 0);
        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);
        assertFalse(vault.isAccountClosed(alice));
        vm.expectRevert(abi.encodeWithSelector(LCCErrorsLib.RegisteredElsewhere.selector, address(vault)));
        vm.prank(alice);
        otherVault.deposit(10e18, 1, type(uint256).max, true, type(uint256).max);
        assertEq(factory.vaultOf(alice), address(vault));
    }

    function testRepointDeniedBeyondBoundedReplayThenSucceedsAfterPermissionlessMaterialization() public {
        _deployAuctionVault();
        LCCVault otherVault = _newVault(_params(CAP, CAP));
        _mintAndApprove(otherVault, alice, 0, 0);
        _createSixtyFiveCallRollingHistoryWithLastDefault();

        assertFalse(vault.isAccountClosed(alice));
        vm.expectRevert(abi.encodeWithSelector(LCCErrorsLib.RegisteredElsewhere.selector, address(vault)));
        vm.prank(alice);
        otherVault.deposit(10e18, 1, type(uint256).max, true, type(uint256).max);

        vault.materializeAccount(alice);
        assertTrue(vault.isAccountClosed(alice));
        vm.prank(alice);
        otherVault.deposit(10e18, 1, type(uint256).max, true, type(uint256).max);
        assertEq(factory.vaultOf(alice), address(otherVault));
    }

    function testAdmissionsModuleIsValidatedAndCanDeny() public {
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        factory.setAdmissionsModule(unlisted);
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        factory.setAdmissionsModule(address(margin));

        LCCAdmissionsModuleMock module = new LCCAdmissionsModuleMock();
        factory.setAdmissionsModule(address(module));
        assertEq(factory.admissionsModule(), address(module));

        module.setAllowed(false);
        vm.expectRevert(abi.encodeWithSelector(LCCErrorsLib.AdmissionsModuleRejected.selector, alice, address(vault)));
        vm.prank(alice);
        vault.deposit(10e18, 1, type(uint256).max, true, type(uint256).max);
        assertEq(vault.getAccount(alice).activeMargin, 0);
        assertEq(factory.vaultOf(alice), address(0));

        module.setAllowed(true);
        _deposit(alice, 10e18);
        module.setAllowed(false);
        _deposit(alice, 1e18); // Same-vault top-ups return before consulting the module.
        assertEq(vault.getAccount(alice).activeMargin, 11e18);
    }

    function testAdmissionsModuleDenialAppliesWhenUserReopensRegisteredVault() public {
        LCCAdmissionsModuleMock module = new LCCAdmissionsModuleMock();
        factory.setAdmissionsModule(address(module));
        uint256 commitment = _deposit(alice, 10e18);

        vm.prank(bouncer);
        vault.bounceCommitment(alice, commitment);
        assertTrue(vault.isAccountClosed(alice));

        module.setAllowed(false);
        vm.expectRevert(abi.encodeWithSelector(LCCErrorsLib.AdmissionsModuleRejected.selector, alice, address(vault)));
        vm.prank(alice);
        vault.deposit(1e18, 1, type(uint256).max, true, type(uint256).max);
    }

    function testAdmissionsModuleSwapContainsRevertingAndMalformedCandidates() public {
        LCCAdmissionsModuleMock module = new LCCAdmissionsModuleMock();
        factory.setAdmissionsModule(address(module));

        LCCAdmissionsModuleMock revertingModule = new LCCAdmissionsModuleMock();
        revertingModule.setReverting(true);
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        factory.setAdmissionsModule(address(revertingModule));

        LCCMalformedAdmissionsModule malformedModule = new LCCMalformedAdmissionsModule();
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        factory.setAdmissionsModule(address(malformedModule));

        assertEq(factory.admissionsModule(), address(module));
    }

    function testAdmissionsModuleSwapContainsReentrantCandidate() public {
        LCCAdmissionsModuleMock initialModule = new LCCAdmissionsModuleMock();
        factory.setAdmissionsModule(address(initialModule));
        LCCReentrantAdmissionsModule reentrantModule = new LCCReentrantAdmissionsModule(factory);
        factory.setAdmissionsModule(address(reentrantModule));

        assertEq(factory.admissionsModule(), address(reentrantModule));
        assertTrue(factory.whitelistEnabled());
        assertTrue(factory.oneVaultPolicyEnabled());

        _deposit(alice, 10e18);
        assertEq(factory.vaultOf(alice), address(vault));
        assertEq(vault.getAccount(alice).activeMargin, 10e18);
    }

    function testAdmissionsModuleRuntimeDecisionRejectsStateMutationUnderStaticcall() public {
        LCCStateMutatingAdmissionsModule stateMutatingModule = new LCCStateMutatingAdmissionsModule();
        factory.setAdmissionsModule(address(stateMutatingModule));
        assertEq(stateMutatingModule.writes(), 0);

        vm.expectRevert();
        vm.prank(alice);
        vault.deposit(10e18, 1, type(uint256).max, true, type(uint256).max);
        assertEq(stateMutatingModule.writes(), 0);
        assertEq(vault.getAccount(alice).activeMargin, 0);
        assertEq(factory.vaultOf(alice), address(0));

        (bool regularCallSucceeded,) = address(stateMutatingModule)
            .call(abi.encodeWithSelector(LCCStateMutatingAdmissionsModule.canDeposit.selector, alice, address(vault)));
        assertTrue(regularCallSucceeded);
        assertEq(stateMutatingModule.writes(), 1);
    }

    function _newReentrantRegistryFixture()
        internal
        returns (
            LCCReentrantMarginToken token,
            LCCVault innerVault,
            LCCVault outerVault,
            LCCRegistryDepositReentryProbe probe
        )
    {
        token = new LCCReentrantMarginToken();
        margin = token;
        innerVault = _newVault(_params(CAP, CAP));
        outerVault = _newVault(_params(CAP, CAP));
        probe = new LCCRegistryDepositReentryProbe(token, innerVault, outerVault, 10e18);

        address[] memory depositors = new address[](1);
        depositors[0] = address(probe);
        factory.setDepositorsWhitelisted(depositors, true);
        token.mint(address(probe), 20e18);
    }

    function _openPolicyOffPair()
        internal
        returns (LCCVault otherVault, uint256 firstCommitment, uint256 secondCommitment)
    {
        otherVault = _newVault(_params(CAP, CAP));
        _mintAndApprove(otherVault, alice, 0, 0);
        firstCommitment = _deposit(alice, 10e18);

        factory.setOneVaultPolicyEnabled(false);
        vm.prank(alice);
        secondCommitment = otherVault.deposit(5e18, 1, type(uint256).max, true, type(uint256).max);

        assertFalse(vault.isAccountClosed(alice));
        assertFalse(otherVault.isAccountClosed(alice));
        assertEq(factory.vaultOf(alice), address(otherVault));
    }

    function _createSixtyFiveCallRollingHistoryWithLastDefault() internal {
        _deposit(alice, 10_000e18);
        for (uint256 epoch = 0; epoch < 65; ++epoch) {
            vm.warp(START + epoch * EPOCH + NORMAL);
            vault.openEpochCall(epoch, 1e18);

            if (epoch < 64) {
                vm.warp(START + epoch * EPOCH + NORMAL + PRE_CALL);
                vm.prank(alice);
                vault.fundCall(true);
            }

            uint256 finalizationTime =
                epoch == 64 ? START + (epoch + 1) * EPOCH : START + epoch * EPOCH + NORMAL + PRE_CALL + FUNDING;
            vm.warp(finalizationTime);
            vault.finalizeEpochSlash(epoch);
        }

        assertEq(vault.syncState().finalizedCallPrefix, 65);
        assertTrue(vault.getEpochState(64).slashFinalized);

        // Recreate a legitimately lagging stored cursor: the first 64 calls were funded and the 65th defaults the
        // still-live account. One permissionless batch reaches cursor 64, after which the bounded closure view can
        // consume the final call and authorize the re-point.
        bytes32 accountSlot = keccak256(abi.encode(alice, ACCOUNTS_SLOT));
        bytes32 cursorWordSlot = bytes32(uint256(accountSlot) + 3);
        uint256 cursorWord = uint256(vm.load(address(vault), cursorWordSlot));
        vm.store(address(vault), cursorWordSlot, bytes32(cursorWord & type(uint192).max));
    }
}
