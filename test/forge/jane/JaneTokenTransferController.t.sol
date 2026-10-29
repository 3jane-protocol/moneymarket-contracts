// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {JaneSetup} from "./utils/JaneSetup.sol";
import {Jane} from "../../../src/jane/Jane.sol";
import {TransferControllerMock} from "../../../src/mocks/TransferControllerMock.sol";
import {IAccessControl} from "../../../lib/openzeppelin/contracts/access/IAccessControl.sol";

contract JaneTokenTransferControllerTest is JaneSetup {
    TransferControllerMock internal controller;

    event TransferControllerSet(address indexed controller);

    function setUp() public override {
        super.setUp();
        controller = new TransferControllerMock();
        mintTokens(alice, 1000e18);
        mintTokens(bob, 1000e18);
        setTransferable();
    }

    function _setController(address c) internal {
        vm.prank(owner);
        token.setTransferController(c);
    }

    // Setter

    function test_setTransferController_onlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, OWNER_ROLE)
        );
        vm.prank(alice);
        token.setTransferController(address(controller));
        assertEq(token.transferController(), address(0));
    }

    function test_setTransferController_emitsAndStores() public {
        vm.expectEmit(true, false, false, false, address(token));
        emit TransferControllerSet(address(controller));
        _setController(address(controller));
        assertEq(token.transferController(), address(controller));
    }

    function test_setTransferController_zeroDisables() public {
        _setController(address(controller));
        controller.setAllowAll(false);

        vm.prank(alice);
        vm.expectRevert(Jane.TransferNotAllowed.selector);
        token.transfer(bob, 1e18);

        vm.expectEmit(true, false, false, false, address(token));
        emit TransferControllerSet(address(0));
        _setController(address(0));
        assertEq(token.transferController(), address(0));

        vm.prank(alice);
        assertTrue(token.transfer(bob, 1e18));
        assertEq(token.balanceOf(bob), 1001e18);
        assertEq(controller.didTransferCount(), 0);
    }

    // Deny path

    function test_transfer_deniedByController() public {
        _setController(address(controller));
        controller.setDeniedFrom(alice, true);

        vm.prank(alice);
        vm.expectRevert(Jane.TransferNotAllowed.selector);
        token.transfer(bob, 100e18);

        assertEq(token.balanceOf(alice), 1000e18);
        assertEq(token.balanceOf(bob), 1000e18);
        assertEq(controller.didTransferCount(), 0);
    }

    function test_transfer_deniedByControllerRecipient() public {
        _setController(address(controller));
        controller.setDeniedTo(charlie, true);

        vm.prank(alice);
        vm.expectRevert(Jane.TransferNotAllowed.selector);
        token.transfer(charlie, 100e18);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 100e18));
    }

    function test_transfer_deniedByControllerMaxAmount() public {
        _setController(address(controller));
        controller.setMaxAmount(50e18);

        vm.prank(alice);
        vm.expectRevert(Jane.TransferNotAllowed.selector);
        token.transfer(bob, 50e18 + 1);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 50e18));
    }

    function test_transferFrom_deniedByController() public {
        _setController(address(controller));
        controller.setDeniedFrom(alice, true);

        vm.prank(alice);
        token.approve(charlie, 100e18);

        vm.prank(charlie);
        vm.expectRevert(Jane.TransferNotAllowed.selector);
        token.transferFrom(alice, bob, 100e18);

        assertEq(token.balanceOf(alice), 1000e18);
        assertEq(token.balanceOf(bob), 1000e18);
        assertEq(token.allowance(alice, charlie), 100e18);
        assertEq(controller.didTransferCount(), 0);
    }

    // Allow path

    function test_transfer_allowed_callsDidTransferWithPostState() public {
        _setController(address(controller));

        vm.prank(alice);
        assertTrue(token.transfer(bob, 100e18));

        assertEq(token.balanceOf(alice), 900e18);
        assertEq(token.balanceOf(bob), 1100e18);
        assertEq(controller.didTransferCount(), 1);
        assertEq(controller.lastToken(), address(token));
        assertEq(controller.lastFrom(), alice);
        assertEq(controller.lastTo(), bob);
        assertEq(controller.lastAmount(), 100e18);
        assertEq(controller.lastFromBalance(), 900e18);
        assertEq(controller.lastToBalance(), 1100e18);
    }

    function test_transferFrom_allowed_passesTokenOwnerNotSpender() public {
        _setController(address(controller));
        controller.setDeniedFrom(charlie, true);

        vm.prank(alice);
        token.approve(charlie, 100e18);

        vm.prank(charlie);
        assertTrue(token.transferFrom(alice, bob, 100e18));

        assertEq(token.allowance(alice, charlie), 0);
        assertEq(controller.didTransferCount(), 1);
        assertEq(controller.lastFrom(), alice);
        assertEq(controller.lastTo(), bob);
        assertEq(controller.lastAmount(), 100e18);
        assertEq(controller.lastFromBalance(), 900e18);
        assertEq(controller.lastToBalance(), 1100e18);
    }

    function testFuzz_transfer_allowed(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != alice);
        amount = bound(amount, 0, 1000e18);
        _setController(address(controller));

        uint256 toBefore = token.balanceOf(to);

        vm.prank(alice);
        assertTrue(token.transfer(to, amount));

        assertEq(token.balanceOf(alice), 1000e18 - amount);
        assertEq(token.balanceOf(to), toBefore + amount);
        assertEq(controller.didTransferCount(), 1);
        assertEq(controller.lastFrom(), alice);
        assertEq(controller.lastTo(), to);
        assertEq(controller.lastAmount(), amount);
        assertEq(controller.lastFromBalance(), 1000e18 - amount);
        assertEq(controller.lastToBalance(), toBefore + amount);
    }

    // Role gate ordering and additivity

    function test_roleGateRunsFirst_controllerNotReached() public {
        Jane fresh = new Jane(owner);
        vm.prank(owner);
        fresh.grantRole(MINTER_ROLE, minter);
        vm.prank(minter);
        fresh.mint(alice, 100e18);
        vm.prank(owner);
        fresh.setTransferController(address(controller));
        controller.setRevertOnCan(true);

        vm.prank(alice);
        vm.expectRevert(Jane.TransferNotAllowed.selector);
        fresh.transfer(bob, 1e18);
    }

    function test_transferRole_doesNotBypassController() public {
        Jane fresh = new Jane(owner);
        vm.startPrank(owner);
        fresh.grantRole(MINTER_ROLE, minter);
        fresh.grantRole(TRANSFER_ROLE, alice);
        fresh.setTransferController(address(controller));
        vm.stopPrank();
        vm.prank(minter);
        fresh.mint(alice, 100e18);

        controller.setAllowAll(false);
        vm.prank(alice);
        vm.expectRevert(Jane.TransferNotAllowed.selector);
        fresh.transfer(bob, 1e18);

        controller.setAllowAll(true);
        vm.prank(alice);
        assertTrue(fresh.transfer(bob, 1e18));
        assertEq(fresh.balanceOf(bob), 1e18);
    }

    // Controller reverts

    function test_canTransferRevert_propagates() public {
        _setController(address(controller));
        controller.setRevertOnCan(true);

        vm.prank(alice);
        vm.expectRevert(TransferControllerMock.CanTransferReverted.selector);
        token.transfer(bob, 1e18);

        vm.prank(alice);
        token.approve(charlie, 1e18);
        vm.prank(charlie);
        vm.expectRevert(TransferControllerMock.CanTransferReverted.selector);
        token.transferFrom(alice, bob, 1e18);
    }

    function test_didTransferRevert_revertsAtomically() public {
        _setController(address(controller));
        controller.setRevertOnDid(true);

        vm.prank(alice);
        vm.expectRevert(TransferControllerMock.DidTransferReverted.selector);
        token.transfer(bob, 100e18);

        assertEq(token.balanceOf(alice), 1000e18);
        assertEq(token.balanceOf(bob), 1000e18);

        vm.prank(alice);
        token.approve(charlie, 100e18);
        vm.prank(charlie);
        vm.expectRevert(TransferControllerMock.DidTransferReverted.selector);
        token.transferFrom(alice, bob, 100e18);

        assertEq(token.balanceOf(alice), 1000e18);
        assertEq(token.balanceOf(bob), 1000e18);
        assertEq(token.allowance(alice, charlie), 100e18);
    }

    // Mint, burn, permit bypass

    function test_mintAndBurn_bypassController() public {
        _setController(address(controller));
        controller.setAllowAll(false);
        controller.setRevertOnCan(true);
        controller.setRevertOnDid(true);

        mintTokens(charlie, 10e18);
        assertEq(token.balanceOf(charlie), 10e18);

        vm.prank(charlie);
        token.burn(4e18);
        assertEq(token.balanceOf(charlie), 6e18);
        assertEq(controller.didTransferCount(), 0);
    }

    function test_permit_unaffectedByController() public {
        _setController(address(controller));
        controller.setRevertOnCan(true);
        controller.setRevertOnDid(true);

        uint256 signerKey = 0xA11CE;
        address signer = vm.addr(signerKey);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = createPermitSignature(signerKey, bob, 50e18, deadline);

        token.permit(signer, bob, 50e18, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), 50e18);
        assertEq(token.nonces(signer), 1);
    }

    // Recovery

    function test_renounceOwner_revertsWhileControllerSet() public {
        _setController(address(controller));

        vm.prank(owner);
        vm.expectRevert(Jane.ControllerStillSet.selector);
        token.renounceRole(OWNER_ROLE, owner);

        assertTrue(token.hasRole(OWNER_ROLE, owner));
        assertEq(token.owner(), owner);
    }

    function test_renounceOwner_nonOwnerIsNoOpWhileControllerSet() public {
        _setController(address(controller));

        vm.prank(alice);
        token.renounceRole(OWNER_ROLE, alice);

        assertTrue(token.hasRole(OWNER_ROLE, owner));
        assertEq(token.owner(), owner);
    }

    function test_renounceOwner_badConfirmationWhileControllerSet() public {
        _setController(address(controller));

        vm.prank(owner);
        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
        token.renounceRole(OWNER_ROLE, treasury);

        assertTrue(token.hasRole(OWNER_ROLE, owner));
        assertEq(token.owner(), owner);
    }

    function test_renounceOwner_succeedsAfterClearingController() public {
        _setController(address(controller));
        _setController(address(0));

        vm.prank(owner);
        token.renounceRole(OWNER_ROLE, owner);

        assertFalse(token.hasRole(OWNER_ROLE, owner));
        assertEq(token.owner(), address(0));
    }

    function test_renounceMinter_unaffectedByController() public {
        _setController(address(controller));

        vm.prank(minter);
        token.renounceRole(MINTER_ROLE, minter);

        assertFalse(token.hasRole(MINTER_ROLE, minter));
    }

    function test_recovery_clearRevertingCanTransfer() public {
        _setController(address(controller));
        controller.setRevertOnCan(true);

        vm.prank(alice);
        vm.expectRevert(TransferControllerMock.CanTransferReverted.selector);
        token.transfer(bob, 1e18);

        _setController(address(0));

        vm.prank(alice);
        assertTrue(token.transfer(bob, 1e18));
        assertEq(token.balanceOf(bob), 1001e18);
    }

    function test_recovery_clearRevertingDidTransfer() public {
        _setController(address(controller));
        controller.setRevertOnDid(true);

        vm.prank(alice);
        vm.expectRevert(TransferControllerMock.DidTransferReverted.selector);
        token.transfer(bob, 1e18);

        _setController(address(0));

        vm.prank(alice);
        assertTrue(token.transfer(bob, 1e18));
        assertEq(token.balanceOf(bob), 1001e18);
    }
}
