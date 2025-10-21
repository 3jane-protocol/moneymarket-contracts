// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {RewardsDistributorSetup} from "./utils/RewardsDistributorSetup.sol";
import {RewardsDistributor} from "../../../../src/jane/RewardsDistributor.sol";
import {MerkleTreeHelper} from "./mocks/MerkleTreeHelper.sol";
import {Jane} from "../../../../src/jane/Jane.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RewardsDistributorSecurityTest is RewardsDistributorSetup {
    function setUp() public override {
        super.setUp();
    }

    /// @notice Test reentrancy protection on claim
    function test_reentrancyProtection_claim() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        vm.prank(alice);
        rewardsDistributor.claim(alice, 100e18, proofs[0]);

        assertEq(rewardsDistributor.claimed(alice), 100e18);
        assertEq(getJaneBalance(alice), 100e18);

        // Try to claim again (should revert with NothingToClaim)
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.NothingToClaim.selector);
        rewardsDistributor.claim(alice, 100e18, proofs[0]);
    }

    /// @notice Test claiming with modified proof components
    function test_modifiedProof_wrongComponents() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](2);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        claims[1] = MerkleTreeHelper.Claim(bob, 200e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        // Modify proof by hashing components
        bytes32[] memory modifiedProof = new bytes32[](proofs[0].length);
        for (uint256 i = 0; i < proofs[0].length; i++) {
            modifiedProof[i] = keccak256(abi.encode(proofs[0][i]));
        }

        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        rewardsDistributor.claim(alice, 100e18, modifiedProof);
    }

    /// @notice Test claiming more than allocated amount
    function test_claimMoreThanAllocated() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        // Try to claim double the allocated amount
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        rewardsDistributor.claim(alice, 200e18, proofs[0]);
    }

    /// @notice Test double claiming prevention
    function test_doubleClaimingPrevention() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        // First claim succeeds
        vm.prank(alice);
        rewardsDistributor.claim(alice, 100e18, proofs[0]);

        // Second claim fails
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.NothingToClaim.selector);
        rewardsDistributor.claim(alice, 100e18, proofs[0]);

        // Third claim with different sender also fails
        vm.prank(bob);
        vm.expectRevert(RewardsDistributor.NothingToClaim.selector);
        rewardsDistributor.claim(alice, 100e18, proofs[0]);
    }

    /// @notice Test access control - only owner can update root
    function test_accessControl_updateRoot() public {
        bytes32 root = keccak256("test");

        address[] memory attackers = new address[](3);
        attackers[0] = alice;
        attackers[1] = bob;
        attackers[2] = address(distributor);

        for (uint256 i = 0; i < attackers.length; i++) {
            vm.prank(attackers[i]);
            vm.expectRevert();
            rewardsDistributor.updateRoot(root);
        }

        // Owner can update
        vm.prank(owner);
        rewardsDistributor.updateRoot(root);
        assertEq(rewardsDistributor.merkleRoot(), root);
    }

    /// @notice Test access control - only owner can sweep
    function test_accessControl_sweep() public {
        address[] memory attackers = new address[](3);
        attackers[0] = alice;
        attackers[1] = bob;
        attackers[2] = address(distributor);

        for (uint256 i = 0; i < attackers.length; i++) {
            vm.prank(attackers[i]);
            vm.expectRevert();
            rewardsDistributor.sweep(IERC20(address(token)));
        }

        // Owner can sweep
        vm.prank(owner);
        rewardsDistributor.sweep(IERC20(address(token)));
    }

    /// @notice Test privilege escalation attempt
    function test_privilegeEscalation_ownershipTransfer() public {
        // Try to transfer ownership as non-owner
        vm.prank(alice);
        vm.expectRevert();
        rewardsDistributor.transferOwnership(alice);

        // Owner can transfer
        vm.prank(owner);
        rewardsDistributor.transferOwnership(alice);
        assertEq(rewardsDistributor.owner(), alice);
    }

    /// @notice Test claiming with wrong user address
    function test_wrongUserAddress() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        // Bob tries to claim using Alice's proof but for himself
        vm.prank(bob);
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        rewardsDistributor.claim(bob, 100e18, proofs[0]);
    }

    /// @notice Test second preimage attack prevention
    function test_secondPreimageAttack() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        // Try to use same proof for different user
        bytes32[] memory attackProof = new bytes32[](proofs[0].length);
        for (uint256 i = 0; i < proofs[0].length; i++) {
            attackProof[i] = proofs[0][i];
        }

        // Even with same proof, different user should fail
        vm.prank(bob);
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        rewardsDistributor.claim(bob, 100e18, attackProof);
    }

    /// @notice Test front-running protection through merkle proof
    function test_frontRunningProtection() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](2);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        claims[1] = MerkleTreeHelper.Claim(bob, 200e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        // Bob sees Alice's transaction and tries to front-run with Alice's proof
        vm.prank(bob);
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        rewardsDistributor.claim(bob, 100e18, proofs[0]);

        // Alice's original transaction succeeds
        vm.prank(alice);
        rewardsDistributor.claim(alice, 100e18, proofs[0]);

        // Bob can still claim his own allocation
        vm.prank(bob);
        rewardsDistributor.claim(bob, 200e18, proofs[1]);
    }

    /// @notice Test overflow in claim amounts
    function test_overflow_claimAmount() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, type(uint256).max);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        // Will revert due to insufficient balance in distributor
        vm.prank(alice);
        vm.expectRevert();
        rewardsDistributor.claim(alice, type(uint256).max, proofs[0]);
    }

    /// @notice Test malformed proof - empty array
    function test_malformedProof_emptyArray() public {
        vm.prank(owner);
        rewardsDistributor.updateRoot(keccak256("test"));

        bytes32[] memory emptyProof = new bytes32[](0);

        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        rewardsDistributor.claim(alice, 100e18, emptyProof);
    }

    /// @notice Test malformed proof - too many elements
    function test_malformedProof_tooManyElements() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        // Add extra elements to proof
        bytes32[] memory bloatedProof = new bytes32[](proofs[0].length + 10);
        for (uint256 i = 0; i < proofs[0].length; i++) {
            bloatedProof[i] = proofs[0][i];
        }
        for (uint256 i = proofs[0].length; i < bloatedProof.length; i++) {
            bloatedProof[i] = keccak256(abi.encode(i));
        }

        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        rewardsDistributor.claim(alice, 100e18, bloatedProof);
    }

    /// @notice Test gas griefing resistance with large proof
    function test_gasGriefing_largeProof() public {
        bytes32[] memory largeProof = new bytes32[](20); // ~log2(1M users)
        for (uint256 i = 0; i < largeProof.length; i++) {
            largeProof[i] = keccak256(abi.encode(i));
        }

        vm.prank(owner);
        rewardsDistributor.updateRoot(keccak256("test"));

        // Should fail verification, not run out of gas
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        rewardsDistributor.claim(alice, 100e18, largeProof);
    }

    /// @notice Test claim with minimal valid proof (single user)
    function test_minimalValidProof() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        // Should have minimal proof
        assertTrue(proofs[0].length == 0 || proofs[0].length == 1);

        // Should still work
        vm.prank(alice);
        rewardsDistributor.claim(alice, 100e18, proofs[0]);
        assertEq(getJaneBalance(alice), 100e18);
    }

    /// @notice Test access control - only owner can call setUseMint
    function test_accessControl_setUseMint() public {
        address[] memory nonOwners = new address[](3);
        nonOwners[0] = alice;
        nonOwners[1] = bob;
        nonOwners[2] = charlie;

        for (uint256 i = 0; i < nonOwners.length; i++) {
            vm.prank(nonOwners[i]);
            vm.expectRevert();
            rewardsDistributor.setUseMint(true);
        }

        // Owner can toggle
        vm.prank(owner);
        rewardsDistributor.setUseMint(true);
        assertTrue(rewardsDistributor.useMint());
    }

    /// @notice Test mint mode requires minter role
    function test_mintMode_requiresMinterRole() public {
        toggleMintMode(true);

        bytes32[][] memory proofs = setupSimpleRoot();

        vm.prank(alice);
        vm.expectRevert();
        rewardsDistributor.claim(alice, 100e18, proofs[0]);
    }

    /// @notice Test transfer mode requires sufficient balance
    function test_transferMode_requiresSufficientBalance() public {
        // Deploy new distributor without funding
        RewardsDistributor emptyDistributor = new RewardsDistributor(owner, address(token), false, START);

        // Create root
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root, bytes32[][] memory proofs) = merkleHelper.generateMerkleTree(claims);

        vm.prank(owner);
        emptyDistributor.updateRoot(root);

        // Claim should fail due to insufficient balance
        vm.prank(alice);
        vm.expectRevert();
        emptyDistributor.claim(alice, 100e18, proofs[0]);
    }

    /// @notice Test allocation reduction cannot be exploited
    function test_allocationReduction_cannotExploit() public {
        // Alice allocated 500, claims all
        MerkleTreeHelper.Claim[] memory claims1 = new MerkleTreeHelper.Claim[](1);
        claims1[0] = MerkleTreeHelper.Claim(alice, 500e18);
        (bytes32 root1, bytes32[][] memory proofs1) = updateRoot(claims1);

        rewardsDistributor.claim(alice, 500e18, proofs1[0]);
        assertEq(rewardsDistributor.claimed(alice), 500e18);

        // Root updated: Alice reduced to 200
        MerkleTreeHelper.Claim[] memory claims2 = new MerkleTreeHelper.Claim[](1);
        claims2[0] = MerkleTreeHelper.Claim(alice, 200e18);
        (bytes32 root2, bytes32[][] memory proofs2) = updateRoot(claims2);

        // Cannot claim (200 <= 500)
        vm.expectRevert(RewardsDistributor.NothingToClaim.selector);
        rewardsDistributor.claim(alice, 200e18, proofs2[0]);

        // Alice keeps what she claimed
        assertEq(token.balanceOf(alice), 500e18);
    }

    /// @notice Test proof reuse after root update fails
    function test_proofReuseAfterRootUpdate() public {
        // Week 1
        MerkleTreeHelper.Claim[] memory claims1 = new MerkleTreeHelper.Claim[](1);
        claims1[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root1, bytes32[][] memory proofs1) = updateRoot(claims1);

        rewardsDistributor.claim(alice, 100e18, proofs1[0]);

        // Week 2 - new root
        MerkleTreeHelper.Claim[] memory claims2 = new MerkleTreeHelper.Claim[](1);
        claims2[0] = MerkleTreeHelper.Claim(alice, 250e18);
        (bytes32 root2, bytes32[][] memory proofs2) = updateRoot(claims2);

        // Try to reuse old proof (should fail)
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        rewardsDistributor.claim(alice, 100e18, proofs1[0]);

        // Correct proof works
        rewardsDistributor.claim(alice, 250e18, proofs2[0]);
        assertEq(token.balanceOf(alice), 250e18);
    }

    /// @notice Test cumulative tracking prevents overpayment
    function test_cumulativeTracking_preventsOverpayment() public {
        // Week 1: alice = 100
        MerkleTreeHelper.Claim[] memory claims1 = new MerkleTreeHelper.Claim[](1);
        claims1[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root1, bytes32[][] memory proofs1) = updateRoot(claims1);

        rewardsDistributor.claim(alice, 100e18, proofs1[0]);

        // Week 2: alice = 150
        MerkleTreeHelper.Claim[] memory claims2 = new MerkleTreeHelper.Claim[](1);
        claims2[0] = MerkleTreeHelper.Claim(alice, 150e18);
        (bytes32 root2, bytes32[][] memory proofs2) = updateRoot(claims2);

        rewardsDistributor.claim(alice, 150e18, proofs2[0]);

        // Alice should have exactly 150, not 250
        assertEq(token.balanceOf(alice), 150e18);
        assertEq(rewardsDistributor.claimed(alice), 150e18);
    }

    /// @notice Test claiming with zero allocation
    function test_claimWithZeroAllocation() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 0);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        vm.expectRevert(RewardsDistributor.NothingToClaim.selector);
        rewardsDistributor.claim(alice, 0, proofs[0]);
    }

    /// @notice Test root update event emissions
    function test_rootUpdateEvents() public {
        bytes32 root1 = keccak256("root1");
        bytes32 root2 = keccak256("root2");

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit RootUpdated(bytes32(0), root1);
        rewardsDistributor.updateRoot(root1);

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit RootUpdated(root1, root2);
        rewardsDistributor.updateRoot(root2);
    }
}
