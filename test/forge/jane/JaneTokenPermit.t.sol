// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {JaneSetup} from "./utils/JaneSetup.sol";
import {JaneToken} from "../../../src/jane/JaneToken.sol";

contract JaneTokenPermitTest is JaneSetup {
    uint256 internal alicePrivateKey = 0xA11CE;
    uint256 internal bobPrivateKey = 0xB0B;
    address internal aliceAddr;
    address internal bobAddr;

    function setUp() public override {
        super.setUp();
        aliceAddr = vm.addr(alicePrivateKey);
        bobAddr = vm.addr(bobPrivateKey);

        vm.label(aliceAddr, "AlicePermit");
        vm.label(bobAddr, "BobPermit");

        mintTokens(aliceAddr, 1000e18);
        mintTokens(bobAddr, 1000e18);
    }

    function test_permit_validSignature() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 500e18;

        (uint8 v, bytes32 r, bytes32 s) = createPermitSignature(alicePrivateKey, bob, value, deadline);

        assertEq(token.allowance(aliceAddr, bob), 0);
        assertEq(token.nonces(aliceAddr), 0);

        vm.expectEmit(true, true, false, true);
        emit Approval(aliceAddr, bob, value);
        token.permit(aliceAddr, bob, value, deadline, v, r, s);

        assertEq(token.allowance(aliceAddr, bob), value);
        assertEq(token.nonces(aliceAddr), 1);
    }

    function test_permit_invalidSignature() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 500e18;

        (uint8 v, bytes32 r, bytes32 s) = createPermitSignature(alicePrivateKey, bob, value, deadline);

        vm.expectRevert();
        token.permit(bobAddr, bob, value, deadline, v, r, s);
    }

    function test_permit_expiredDeadline() public {
        uint256 deadline = block.timestamp - 1;
        uint256 value = 500e18;

        (uint8 v, bytes32 r, bytes32 s) = createPermitSignature(alicePrivateKey, bob, value, deadline);

        vm.expectRevert();
        token.permit(aliceAddr, bob, value, deadline, v, r, s);
    }

    function test_permit_wrongNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 500e18;

        // First permit - this will work and increment nonce to 1
        (uint8 v, bytes32 r, bytes32 s) = createPermitSignature(alicePrivateKey, bob, value, deadline);
        token.permit(aliceAddr, bob, value, deadline, v, r, s);

        // Try to use a signature with the old nonce (0) - should fail
        // We need to create a signature with nonce 0, but nonce is now 1
        // So we create a new signature but it will have nonce 1, not 0
        // Let's just try to replay the old signature instead
        vm.expectRevert();
        token.permit(aliceAddr, bob, value, deadline, v, r, s);
    }

    function test_permit_replayAttack() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 500e18;

        (uint8 v, bytes32 r, bytes32 s) = createPermitSignature(alicePrivateKey, bob, value, deadline);

        token.permit(aliceAddr, bob, value, deadline, v, r, s);

        vm.expectRevert();
        token.permit(aliceAddr, bob, value, deadline, v, r, s);
    }

    function test_permit_wrongSpender() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 500e18;

        (uint8 v, bytes32 r, bytes32 s) = createPermitSignature(alicePrivateKey, bob, value, deadline);

        vm.expectRevert();
        token.permit(aliceAddr, charlie, value, deadline, v, r, s);
    }

    function test_permit_domainSeparator() public view {
        bytes32 expectedDomainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("JANE")),
                keccak256(bytes("1")),
                block.chainid,
                address(token)
            )
        );

        assertEq(token.DOMAIN_SEPARATOR(), expectedDomainSeparator);
    }

    function test_permit_withTransferRestrictions() public {
        assertFalse(token.transferable());

        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 500e18;

        (uint8 v, bytes32 r, bytes32 s) = createPermitSignature(alicePrivateKey, charlie, value, deadline);

        token.permit(aliceAddr, charlie, value, deadline, v, r, s);
        assertEq(token.allowance(aliceAddr, charlie), value);

        vm.prank(charlie);
        vm.expectRevert(JaneToken.TransferNotAllowed.selector);
        token.transferFrom(aliceAddr, bob, 100e18);

        grantTransferRole(bob);

        vm.prank(charlie);
        assertTrue(token.transferFrom(aliceAddr, bob, 100e18));
        assertEq(token.balanceOf(bob), 100e18); // Bob started with 0, not 1000e18
    }

    function test_permit_afterTransfer() public {
        setTransferable();

        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 500e18;
        uint256 initialNonce = token.nonces(aliceAddr);

        (uint8 v, bytes32 r, bytes32 s) = createPermitSignature(alicePrivateKey, bob, value, deadline);

        token.permit(aliceAddr, bob, value, deadline, v, r, s);
        assertEq(token.nonces(aliceAddr), initialNonce + 1);

        vm.prank(bob);
        token.transferFrom(aliceAddr, charlie, 100e18);

        assertEq(token.nonces(aliceAddr), initialNonce + 1);
        assertEq(token.allowance(aliceAddr, bob), 400e18);
    }

    function testFuzz_permit_signatures(uint256 privateKey, address spender, uint256 value, uint256 deadline) public {
        vm.assume(
            privateKey > 0
                && privateKey < 115792089237316195423570985008687907852837564279074904382605163141518161494337
        );
        vm.assume(spender != address(0));
        vm.assume(deadline > block.timestamp);
        vm.assume(value > 0 && value <= 1000e18);

        address owner = vm.addr(privateKey);
        mintTokens(owner, 1000e18);

        (uint8 v, bytes32 r, bytes32 s) = createPermitSignature(privateKey, spender, value, deadline);

        uint256 nonceBefore = token.nonces(owner);
        token.permit(owner, spender, value, deadline, v, r, s);

        assertEq(token.allowance(owner, spender), value);
        assertEq(token.nonces(owner), nonceBefore + 1);
    }
}
