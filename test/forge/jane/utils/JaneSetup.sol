// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {JaneToken} from "../../../../src/jane/JaneToken.sol";

contract JaneSetup is Test {
    JaneToken public token;

    address public admin;
    address public minter;
    address public burner;
    address public alice;
    address public bob;
    address public charlie;
    address public treasury;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");

    uint256 public constant INITIAL_MINT = 1_000_000e18;

    event TransferableStatusChanged(bool indexed newStatus);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public virtual {
        admin = makeAddr("admin");
        minter = makeAddr("minter");
        burner = makeAddr("burner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        treasury = makeAddr("treasury");

        token = new JaneToken(admin, minter, burner);

        vm.label(address(token), "JaneToken");
        vm.label(admin, "Admin");
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
        vm.prank(admin);
        token.grantRole(TRANSFER_ROLE, account);
    }

    function setTransferable() internal {
        vm.prank(admin);
        token.setTransferable();
    }

    function createPermitSignature(uint256 privateKey, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        address owner = vm.addr(privateKey);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                token.nonces(owner),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(privateKey, digest);
    }
}
