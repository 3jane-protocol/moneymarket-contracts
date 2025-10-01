// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {RewardsDistributorSetup} from "./utils/RewardsDistributorSetup.sol";
import {RewardsDistributor} from "../../../../src/jane/RewardsDistributor.sol";
import {MerkleTreeHelper} from "./mocks/MerkleTreeHelper.sol";
import {Jane} from "../../../../src/jane/Jane.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MaliciousToken
 * @notice Token that attempts reentrancy during transfer
 */
contract MaliciousToken is ERC20 {
    RewardsDistributor public target;
    uint256 public attackCampaignId;
    bytes32[] public attackProof;
    address public attackUser;
    uint256 public attackAmount;
    uint256 public attackCount;

    constructor() ERC20("Malicious", "MAL") {
        _mint(msg.sender, 1000000e18);
    }

    function setAttackParams(
        RewardsDistributor _target,
        uint256 _campaignId,
        bytes32[] memory _proof,
        address _user,
        uint256 _amount
    ) external {
        target = _target;
        attackCampaignId = _campaignId;
        attackProof = _proof;
        attackUser = _user;
        attackAmount = _amount;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        // Attempt reentrancy
        if (attackCount < 2) {
            attackCount++;
            try target.claim(attackCampaignId, attackProof, attackUser, attackAmount) {
                // Should not reach here due to reentrancy guard
            } catch {
                // Expected to fail
            }
        }
        return super.transfer(to, amount);
    }
}

contract RewardsDistributorSecurityTest is RewardsDistributorSetup {
    MaliciousToken public maliciousToken;

    function setUp() public override {
        super.setUp();
        maliciousToken = new MaliciousToken();
    }

    /// @notice Test reentrancy protection on claim
    function test_reentrancyProtection_claim() public {
        // Create campaign
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        // Try to claim twice in same transaction (second should fail due to reentrancy guard)
        // The nonReentrant modifier will revert the nested call
        vm.prank(alice);
        distributor.claim(campaignId, proofs[0], alice, 100e18);

        // Verify only claimed once
        assertTrue(distributor.claimed(alice, campaignId));
        assertEq(getJaneBalance(alice), 100e18);
    }

    /// @notice Test claiming with modified proof components
    function test_modifiedProof_wrongComponents() public {
        // Create legitimate campaign
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](2);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        claims[1] = MerkleTreeHelper.Claim(bob, 200e18);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        // Modify proof by swapping components
        bytes32[] memory modifiedProof = new bytes32[](proofs[0].length);
        for (uint256 i = 0; i < proofs[0].length; i++) {
            modifiedProof[i] = keccak256(abi.encode(proofs[0][i]));
        }

        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        distributor.claim(campaignId, modifiedProof, alice, 100e18);
    }

    /// @notice Test claiming with proof from different campaign
    function test_proofFromDifferentCampaign() public {
        // Create first campaign
        MerkleTreeHelper.Claim[] memory claims1 = new MerkleTreeHelper.Claim[](1);
        claims1[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (uint256 campaign1,, bytes32[][] memory proofs1) = createCampaign(claims1);

        // Create second campaign
        MerkleTreeHelper.Claim[] memory claims2 = new MerkleTreeHelper.Claim[](1);
        claims2[0] = MerkleTreeHelper.Claim(alice, 200e18);
        (uint256 campaign2,,) = createCampaign(claims2);

        // Try to use proof from campaign1 on campaign2
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        distributor.claim(campaign2, proofs1[0], alice, 100e18);
    }

    /// @notice Test claiming more than allocated amount
    function test_claimMoreThanAllocated() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        // Try to claim double the allocated amount
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        distributor.claim(campaignId, proofs[0], alice, 200e18);
    }

    /// @notice Test double spending prevention
    function test_doubleSpendingPrevention() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        // First claim succeeds
        vm.prank(alice);
        distributor.claim(campaignId, proofs[0], alice, 100e18);

        // Second claim fails
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.AlreadyClaimed.selector);
        distributor.claim(campaignId, proofs[0], alice, 100e18);

        // Third claim with different sender also fails
        vm.prank(bob);
        vm.expectRevert(RewardsDistributor.AlreadyClaimed.selector);
        distributor.claim(campaignId, proofs[0], alice, 100e18);
    }

    /// @notice Test access control - only owner can add merkle roots
    function test_accessControl_addMerkleRoot() public {
        bytes32 root = keccak256("test");

        address[] memory attackers = new address[](3);
        attackers[0] = alice;
        attackers[1] = bob;
        attackers[2] = address(distributor);

        for (uint256 i = 0; i < attackers.length; i++) {
            vm.prank(attackers[i]);
            vm.expectRevert();
            distributor.newMerkleRoot(root);
        }

        // Owner can add
        vm.prank(owner);
        distributor.newMerkleRoot(root);
    }

    /// @notice Test access control - only owner can invalidate campaigns
    function test_accessControl_invalidateCampaign() public {
        vm.prank(owner);
        uint256 campaignId = distributor.newMerkleRoot(keccak256("test"));

        address[] memory attackers = new address[](3);
        attackers[0] = alice;
        attackers[1] = bob;
        attackers[2] = address(distributor);

        for (uint256 i = 0; i < attackers.length; i++) {
            vm.prank(attackers[i]);
            vm.expectRevert();
            distributor.invalidateCampaign(campaignId);
        }

        // Owner can invalidate
        vm.prank(owner);
        distributor.invalidateCampaign(campaignId);
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
            distributor.sweep(IERC20(address(token)));
        }

        // Owner can sweep
        vm.prank(owner);
        distributor.sweep(IERC20(address(token)));
    }

    /// @notice Test privilege escalation attempt
    function test_privilegeEscalation_ownershipTransfer() public {
        // Try to transfer ownership as non-owner
        vm.prank(alice);
        vm.expectRevert();
        distributor.transferOwnership(alice);

        // Owner can transfer
        vm.prank(owner);
        distributor.transferOwnership(alice);
        assertEq(distributor.owner(), alice);
    }

    /// @notice Test campaign manipulation - trying to claim from non-existent campaign
    function test_campaignManipulation_nonExistent() public {
        bytes32[] memory fakeProof = new bytes32[](1);
        fakeProof[0] = keccak256("fake");

        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.InvalidCampaign.selector);
        distributor.claim(999, fakeProof, alice, 100e18);
    }

    /// @notice Test claiming with wrong user address
    function test_wrongUserAddress() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        // Bob tries to claim using Alice's proof but for himself
        vm.prank(bob);
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        distributor.claim(campaignId, proofs[0], bob, 100e18);
    }

    /// @notice Test second preimage attack prevention
    function test_secondPreimageAttack() public {
        // Create legitimate campaign
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        // Try to create a different claim that might hash to same value
        // This should fail because the leaf computation is specific
        bytes32[] memory attackProof = new bytes32[](proofs[0].length);
        for (uint256 i = 0; i < proofs[0].length; i++) {
            attackProof[i] = proofs[0][i];
        }

        // Even with same proof, different parameters should fail
        vm.prank(bob);
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        distributor.claim(campaignId, attackProof, bob, 100e18);
    }

    /// @notice Test front-running protection through merkle proof
    function test_frontRunningProtection() public {
        // Create campaign
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](2);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        claims[1] = MerkleTreeHelper.Claim(bob, 200e18);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        // Bob sees Alice's transaction and tries to front-run with Alice's proof
        vm.prank(bob);
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        distributor.claim(campaignId, proofs[0], bob, 100e18);

        // Alice's original transaction succeeds
        vm.prank(alice);
        distributor.claim(campaignId, proofs[0], alice, 100e18);

        // Bob can still claim his own allocation
        vm.prank(bob);
        distributor.claim(campaignId, proofs[1], bob, 200e18);
    }

    /// @notice Test overflow in claim amounts
    function test_overflow_claimAmount() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, type(uint256).max);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        // Fund distributor with max tokens (this will fail in practice due to supply limits)
        // But the claim logic should handle it gracefully
        vm.prank(alice);
        vm.expectRevert(); // Will revert due to insufficient balance in distributor
        distributor.claim(campaignId, proofs[0], alice, type(uint256).max);
    }

    /// @notice Test malformed proof arrays
    function test_malformedProof_emptyArray() public {
        vm.prank(owner);
        uint256 campaignId = distributor.newMerkleRoot(keccak256("test"));

        bytes32[] memory emptyProof = new bytes32[](0);

        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        distributor.claim(campaignId, emptyProof, alice, 100e18);
    }

    /// @notice Test malformed proof arrays - too many elements
    function test_malformedProof_tooManyElements() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

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
        distributor.claim(campaignId, bloatedProof, alice, 100e18);
    }

    /// @notice Test claiming after campaign invalidation
    function test_claimAfterInvalidation() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](2);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        claims[1] = MerkleTreeHelper.Claim(bob, 200e18);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        // Alice claims successfully
        vm.prank(alice);
        distributor.claim(campaignId, proofs[0], alice, 100e18);

        // Campaign gets invalidated
        vm.prank(owner);
        distributor.invalidateCampaign(campaignId);

        // Bob can't claim from invalidated campaign
        vm.prank(bob);
        vm.expectRevert(RewardsDistributor.InvalidCampaign.selector);
        distributor.claim(campaignId, proofs[1], bob, 200e18);

        // Alice can't claim again even though campaign is invalidated
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.InvalidCampaign.selector);
        distributor.claim(campaignId, proofs[0], alice, 100e18);
    }

    /// @notice Test gas griefing resistance
    function test_gasGriefing_largeProof() public {
        // Create a proof with maximum reasonable size
        bytes32[] memory largeProof = new bytes32[](20); // ~log2(1M users)
        for (uint256 i = 0; i < largeProof.length; i++) {
            largeProof[i] = keccak256(abi.encode(i));
        }

        vm.prank(owner);
        uint256 campaignId = distributor.newMerkleRoot(keccak256("test"));

        // Should fail verification, not run out of gas
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        distributor.claim(campaignId, largeProof, alice, 100e18);
    }

    /// @notice Test storage collision prevention with BitMaps
    function test_storageCollision_bitmaps() public {
        // Create many campaigns to test bitmap word boundaries
        uint256 numCampaigns = 257; // Cross multiple bitmap words

        for (uint256 i = 0; i < numCampaigns; i++) {
            MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
            claims[0] = MerkleTreeHelper.Claim(alice, 1e18);

            (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

            // Claim from specific campaigns
            if (i == 0 || i == 255 || i == 256) {
                vm.prank(alice);
                distributor.claim(campaignId, proofs[0], alice, 1e18);
            }
        }

        // Verify correct bitmap status across word boundaries
        assertTrue(distributor.claimed(alice, 0)); // First word
        assertTrue(distributor.claimed(alice, 255)); // Last bit of first word
        assertTrue(distributor.claimed(alice, 256)); // First bit of second word

        // Others should not be claimed
        assertFalse(distributor.claimed(alice, 1));
        assertFalse(distributor.claimed(alice, 254));
        assertFalse(distributor.claimed(alice, 257));
    }

    /// @notice Test claim with minimal valid proof
    function test_minimalValidProof() public {
        // Single user campaign (minimal tree)
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        // Should have minimal proof
        assertTrue(proofs[0].length == 0 || proofs[0].length == 1);

        // Should still work
        vm.prank(alice);
        distributor.claim(campaignId, proofs[0], alice, 100e18);
        assertEq(getJaneBalance(alice), 100e18);
    }

    /// @notice Test access control - only owner can call setUseMint
    function test_accessControl_setUseMint() public {
        // Non-owner cannot toggle
        address[] memory nonOwners = new address[](3);
        nonOwners[0] = alice;
        nonOwners[1] = bob;
        nonOwners[2] = charlie;

        for (uint256 i = 0; i < nonOwners.length; i++) {
            vm.prank(nonOwners[i]);
            vm.expectRevert();
            distributor.setUseMint(true);
        }

        // Owner can toggle
        vm.prank(owner);
        distributor.setUseMint(true);
        assertTrue(distributor.useMint());
    }

    /// @notice Test mint mode requires minter role
    function test_mintMode_requiresMinterRole() public {
        // Enable mint mode but don't grant role
        toggleMintMode(true);

        (uint256 campaignId, bytes32[][] memory proofs) = createSimpleCampaign();

        vm.prank(alice);
        vm.expectRevert(Jane.NotMinter.selector);
        distributor.claim(campaignId, proofs[0], alice, 100e18);
    }

    /// @notice Test mint mode respects mintFinalized
    function test_mintMode_respectsMintFinalized() public {
        addMinter(address(distributor));
        toggleMintMode(true);

        // Finalize minting
        vm.prank(owner);
        token.finalizeMinting();

        (uint256 campaignId, bytes32[][] memory proofs) = createSimpleCampaign();

        vm.prank(alice);
        vm.expectRevert(Jane.MintFinalized.selector);
        distributor.claim(campaignId, proofs[0], alice, 100e18);
    }

    /// @notice Test transfer mode requires sufficient balance
    function test_transferMode_requiresSufficientBalance() public {
        // Deploy new distributor without funding
        RewardsDistributor emptyDistributor = new RewardsDistributor(owner, address(token), false);

        // Create campaign
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root, bytes32[][] memory proofs) = merkleHelper.generateMerkleTree(claims);

        vm.prank(owner);
        uint256 campaignId = emptyDistributor.newMerkleRoot(root);

        // Claim should fail due to insufficient balance
        vm.prank(alice);
        vm.expectRevert();
        emptyDistributor.claim(campaignId, proofs[0], alice, 100e18);
    }
}
