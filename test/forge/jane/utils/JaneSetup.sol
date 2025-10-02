// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {Jane} from "../../../../src/jane/Jane.sol";

contract JaneSetup is Test {
    Jane public token;

    address public owner;
    address public minter;
    address public burner;
    address public alice;
    address public bob;
    address public charlie;
    address public treasury;

    uint256 public constant INITIAL_MINT = 1_000_000e18;

    event TransferEnabled();
    event MintingFinalized();
    event TransferAuthorized(address indexed account, bool indexed authorized);
    event MinterAuthorized(address indexed account, bool indexed authorized);
    event BurnerAuthorized(address indexed account, bool indexed authorized);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public virtual {
        owner = makeAddr("owner");
        minter = makeAddr("minter");
        burner = makeAddr("burner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        treasury = makeAddr("treasury");

        token = new Jane(owner, minter, burner);

        vm.label(address(token), "JaneToken");
        vm.label(owner, "Owner");
        vm.label(minter, "Minter");
        vm.label(burner, "Burner");
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
        token.addTransferRole(account);
    }

    function revokeTransferRole(address account) internal {
        vm.prank(owner);
        token.removeTransferRole(account);
    }

    function setTransferable() internal {
        vm.prank(owner);
        token.setTransferable();
    }

    function addMinter(address account) internal {
        vm.prank(owner);
        token.addMinter(account);
    }

    function removeMinter(address account) internal {
        vm.prank(owner);
        token.removeMinter(account);
    }

    function addBurner(address account) internal {
        vm.prank(owner);
        token.addBurner(account);
    }

    function removeBurner(address account) internal {
        vm.prank(owner);
        token.removeBurner(account);
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
