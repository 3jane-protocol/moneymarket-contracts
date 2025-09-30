// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {RewardsDistributorSetup} from "./utils/RewardsDistributorSetup.sol";
import {RewardsDistributor} from "../../../../src/jane/RewardsDistributor.sol";
import {MerkleTreeHelper} from "./mocks/MerkleTreeHelper.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Jane} from "../../../../src/jane/Jane.sol";

contract RewardsDistributorUnitTest is RewardsDistributorSetup {
    function setUp() public override {
        super.setUp();
    }

    /// @notice Test constructor sets correct values
    function test_constructor() public view {
        assertEq(address(distributor.jane()), address(token));
        assertEq(distributor.owner(), owner);
        assertEq(distributor.merkleRootCount(), 0);
    }

    /// @notice Test adding a new merkle root
    function test_newMerkleRoot() public {
        bytes32 testRoot = keccak256("test");

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit CampaignAdded(0, testRoot);
        uint256 campaignId = distributor.newMerkleRoot(testRoot);

        assertEq(campaignId, 0);
        assertEq(distributor.merkleRoots(0), testRoot);
        assertEq(distributor.merkleRootCount(), 1);
    }

    /// @notice Test adding multiple merkle roots
    function test_newMerkleRoot_multiple() public {
        bytes32[] memory roots = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            roots[i] = keccak256(abi.encode("test", i));
            vm.prank(owner);
            uint256 campaignId = distributor.newMerkleRoot(roots[i]);
            assertEq(campaignId, i);
        }

        assertEq(distributor.merkleRootCount(), 5);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(distributor.merkleRoots(i), roots[i]);
        }
    }

    /// @notice Test only owner can add merkle roots
    function test_newMerkleRoot_onlyOwner() public {
        bytes32 testRoot = keccak256("test");

        vm.prank(alice);
        vm.expectRevert();
        distributor.newMerkleRoot(testRoot);
    }

    /// @notice Test successful claim
    function test_claim_success() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](3);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        claims[1] = MerkleTreeHelper.Claim(bob, 200e18);
        claims[2] = MerkleTreeHelper.Claim(charlie, 300e18);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        uint256 aliceBalanceBefore = getJaneBalance(alice);

        vm.expectEmit(true, true, false, true);
        emit Claimed(alice, campaignId, 100e18, alice);

        vm.prank(alice);
        distributor.claim(campaignId, proofs[0], alice, 100e18);

        assertEq(getJaneBalance(alice), aliceBalanceBefore + 100e18);
        assertTrue(distributor.claimed(alice, campaignId));
    }

    /// @notice Test claim reverts with invalid campaign
    function test_claim_invalidCampaign() public {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256("proof");

        vm.expectRevert(RewardsDistributor.InvalidCampaign.selector);
        distributor.claim(999, proof, alice, 100e18);
    }

    /// @notice Test claim reverts when already claimed
    function test_claim_alreadyClaimed() public {
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
    }

    /// @notice Test claim reverts with invalid proof
    function test_claim_invalidProof() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);

        (uint256 campaignId,,) = createCampaign(claims);

        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = keccak256("bad");

        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        distributor.claim(campaignId, badProof, alice, 100e18);
    }

    /// @notice Test claim with wrong amount reverts
    function test_claim_wrongAmount() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        distributor.claim(campaignId, proofs[0], alice, 200e18); // Wrong amount
    }

    /// @notice Test claim with wrong user reverts
    function test_claim_wrongUser() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        vm.prank(bob);
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        distributor.claim(campaignId, proofs[0], bob, 100e18); // Wrong user
    }

    /// @notice Test claiming on behalf of another user
    function test_claim_onBehalfOf() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        uint256 aliceBalanceBefore = getJaneBalance(alice);

        // Bob claims on behalf of Alice
        vm.prank(bob);
        vm.expectEmit(true, true, false, true);
        emit Claimed(alice, campaignId, 100e18, bob);
        distributor.claim(campaignId, proofs[0], alice, 100e18);

        assertEq(getJaneBalance(alice), aliceBalanceBefore + 100e18);
        assertTrue(distributor.claimed(alice, campaignId));
    }

    /// @notice Test invalidating a campaign
    function test_invalidateCampaign() public {
        bytes32 testRoot = keccak256("test");

        vm.prank(owner);
        uint256 campaignId = distributor.newMerkleRoot(testRoot);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit CampaignInvalidated(campaignId);
        distributor.invalidateCampaign(campaignId);

        assertEq(distributor.merkleRoots(campaignId), bytes32(0));
    }

    /// @notice Test can't claim from invalidated campaign
    function test_claim_invalidatedCampaign() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        // Invalidate campaign
        vm.prank(owner);
        distributor.invalidateCampaign(campaignId);

        // Try to claim
        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.InvalidCampaign.selector);
        distributor.claim(campaignId, proofs[0], alice, 100e18);
    }

    /// @notice Test only owner can invalidate campaigns
    function test_invalidateCampaign_onlyOwner() public {
        bytes32 testRoot = keccak256("test");

        vm.prank(owner);
        uint256 campaignId = distributor.newMerkleRoot(testRoot);

        vm.prank(alice);
        vm.expectRevert();
        distributor.invalidateCampaign(campaignId);
    }

    /// @notice Test invalidating non-existent campaign reverts
    function test_invalidateCampaign_nonExistent() public {
        vm.prank(owner);
        vm.expectRevert(RewardsDistributor.InvalidCampaign.selector);
        distributor.invalidateCampaign(999);
    }

    /// @notice Test verify function
    function test_verify() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);

        bytes32 root;
        bytes32[][] memory proofs;
        (root, proofs) = merkleHelper.generateMerkleTree(claims);

        // Manually add root to test verify
        vm.prank(owner);
        uint256 campaignId = distributor.newMerkleRoot(root);

        // Should not revert
        distributor.verify(campaignId, proofs[0], alice, 100e18);
    }

    /// @notice Test verify with invalid proof reverts
    function test_verify_invalidProof() public {
        bytes32 testRoot = keccak256("test");

        vm.prank(owner);
        uint256 campaignId = distributor.newMerkleRoot(testRoot);

        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = keccak256("bad");

        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        distributor.verify(campaignId, badProof, alice, 100e18);
    }

    /// @notice Test claimed function
    function test_claimed() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        assertFalse(distributor.claimed(alice, campaignId));

        vm.prank(alice);
        distributor.claim(campaignId, proofs[0], alice, 100e18);

        assertTrue(distributor.claimed(alice, campaignId));
    }

    /// @notice Test claimed tracks per-campaign status
    function test_claimed_perCampaign() public {
        // Create first campaign
        MerkleTreeHelper.Claim[] memory claims1 = new MerkleTreeHelper.Claim[](1);
        claims1[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (uint256 campaign1,, bytes32[][] memory proofs1) = createCampaign(claims1);

        // Create second campaign
        MerkleTreeHelper.Claim[] memory claims2 = new MerkleTreeHelper.Claim[](1);
        claims2[0] = MerkleTreeHelper.Claim(alice, 200e18);
        (uint256 campaign2,, bytes32[][] memory proofs2) = createCampaign(claims2);

        // Claim from first campaign
        vm.prank(alice);
        distributor.claim(campaign1, proofs1[0], alice, 100e18);

        // Check claimed status
        assertTrue(distributor.claimed(alice, campaign1));
        assertFalse(distributor.claimed(alice, campaign2));

        // Claim from second campaign
        vm.prank(alice);
        distributor.claim(campaign2, proofs2[0], alice, 200e18);

        // Both should be claimed now
        assertTrue(distributor.claimed(alice, campaign1));
        assertTrue(distributor.claimed(alice, campaign2));
    }

    /// @notice Test sweep function
    function test_sweep() public {
        // Deploy a different token for sweeping
        Jane otherToken = new Jane(owner, minter, burner);
        vm.prank(owner);
        otherToken.setTransferable();

        // Mint tokens to distributor
        vm.prank(minter);
        otherToken.mint(address(distributor), 500e18);

        uint256 ownerBalanceBefore = otherToken.balanceOf(owner);

        // Sweep tokens
        vm.prank(owner);
        distributor.sweep(IERC20(address(otherToken)));

        assertEq(otherToken.balanceOf(owner), ownerBalanceBefore + 500e18);
        assertEq(otherToken.balanceOf(address(distributor)), 0);
    }

    /// @notice Test only owner can sweep
    function test_sweep_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        distributor.sweep(IERC20(address(token)));
    }

    /// @notice Test merkleRootCount function
    function test_merkleRootCount() public {
        assertEq(distributor.merkleRootCount(), 0);

        for (uint256 i = 1; i <= 10; i++) {
            vm.prank(owner);
            distributor.newMerkleRoot(keccak256(abi.encode(i)));
            assertEq(distributor.merkleRootCount(), i);
        }
    }

    /// @notice Test zero amount claim
    function test_claim_zeroAmount() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 0);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        uint256 aliceBalanceBefore = getJaneBalance(alice);

        vm.prank(alice);
        distributor.claim(campaignId, proofs[0], alice, 0);

        assertEq(getJaneBalance(alice), aliceBalanceBefore); // No change
        assertTrue(distributor.claimed(alice, campaignId));
    }

    /// @notice Test claiming with zero address reverts (Jane doesn't allow transfers to zero)
    function test_claim_zeroAddress() public {
        address zeroUser = address(0);
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(zeroUser, 100e18);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        // Jane will revert with ERC20InvalidReceiver for zero address
        vm.expectRevert(abi.encodeWithSignature("ERC20InvalidReceiver(address)", address(0)));
        distributor.claim(campaignId, proofs[0], zeroUser, 100e18);
    }
}
