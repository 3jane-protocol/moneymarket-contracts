// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {Jane} from "../../../../src/jane/Jane.sol";

contract JaneSetup is Test {
    Jane public token;

    address public owner;
    address public minter;
    address public distributor;
    address public alice;
    address public bob;
    address public charlie;
    address public treasury;

    uint256 public constant INITIAL_MINT = 1_000_000e18;

    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");

    event TransferEnabled();
    event MintingFinalized();
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public virtual {
        owner = makeAddr("owner");
        minter = makeAddr("minter");
        distributor = makeAddr("distributor");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        treasury = makeAddr("treasury");

        token = new Jane(owner, distributor);

        // Grant MINTER_ROLE to minter for tests
        vm.prank(owner);
        token.grantRole(MINTER_ROLE, minter);

        vm.label(address(token), "JaneToken");
        vm.label(owner, "Owner");
        vm.label(minter, "Minter");
        vm.label(distributor, "Distributor");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");
        vm.label(treasury, "Treasury");
    }

    function mintTokens(address to, uint256 amount) internal {
        vm.prank(minter);
        token.mint(to, amount);
    }

    function grantTransferRole(address account) internal {
        vm.prank(owner);
        token.grantRole(TRANSFER_ROLE, account);
    }

    function revokeTransferRole(address account) internal {
        vm.prank(owner);
        token.revokeRole(TRANSFER_ROLE, account);
    }

    function setTransferable() internal {
        vm.prank(owner);
        token.setTransferable();
    }

    function addMinter(address account) internal {
        vm.prank(owner);
        token.grantRole(MINTER_ROLE, account);
    }

    function removeMinter(address account) internal {
        vm.prank(owner);
        token.revokeRole(MINTER_ROLE, account);
    }

    function createPermitSignature(uint256 privateKey, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        address signer = vm.addr(privateKey);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                spender,
                value,
                token.nonces(signer),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(privateKey, digest);
    }
}
