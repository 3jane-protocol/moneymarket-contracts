// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {JaneToken} from "../../../../src/jane/JaneToken.sol";

contract JaneSetup is Test {
    JaneToken public token;

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
    event TransferRoleUpdated(address indexed account, bool indexed hasRole);
    event MinterUpdated(address indexed oldMinter, address indexed newMinter);
    event BurnerUpdated(address indexed oldBurner, address indexed newBurner);
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

        token = new JaneToken(owner, minter, burner);

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
        token.setTransferRole(account, true);
    }

    function revokeTransferRole(address account) internal {
        vm.prank(owner);
        token.setTransferRole(account, false);
    }

    function setTransferable() internal {
        vm.prank(owner);
        token.setTransferable();
    }

    function setMinter(address newMinter) internal {
        vm.prank(owner);
        token.setMinter(newMinter);
    }

    function setBurner(address newBurner) internal {
        vm.prank(owner);
        token.setBurner(newBurner);
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
