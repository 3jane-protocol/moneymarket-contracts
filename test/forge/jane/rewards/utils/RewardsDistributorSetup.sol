// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {JaneSetup} from "../../utils/JaneSetup.sol";
import {RewardsDistributor} from "../../../../../src/jane/RewardsDistributor.sol";
import {MerkleTreeHelper} from "../mocks/MerkleTreeHelper.sol";
import {JaneToken} from "../../../../../src/jane/JaneToken.sol";

contract RewardsDistributorSetup is JaneSetup {
    RewardsDistributor public distributor;
    MerkleTreeHelper public merkleHelper;

    // Test users
    address public dave;
    address public eve;
    address public frank;

    // Events
    event CampaignAdded(uint256 indexed campaignId, bytes32 merkleRoot);
    event Claimed(address indexed user, uint256 indexed campaignId, uint256 amount, address indexed claimant);
    event CampaignInvalidated(uint256 indexed campaignId);

    function setUp() public virtual override {
        super.setUp();

        // Create additional test users
        dave = makeAddr("dave");
        eve = makeAddr("eve");
        frank = makeAddr("frank");

        // Deploy merkle helper
        merkleHelper = new MerkleTreeHelper();

        // Deploy distributor
        distributor = new RewardsDistributor(owner, address(token));

        // Fund distributor with JANE tokens
        mintTokens(address(distributor), 1_000_000e18);

        // Enable transfers for testing
        setTransferable();

        vm.label(address(distributor), "RewardsDistributor");
        vm.label(address(merkleHelper), "MerkleTreeHelper");
        vm.label(dave, "Dave");
        vm.label(eve, "Eve");
        vm.label(frank, "Frank");
    }

    /**
     * @notice Creates a campaign with the given claims
     * @param claims Array of claims to include in the campaign
     * @return campaignId The ID of the created campaign
     * @return root The merkle root of the campaign
     * @return proofs Array of proofs for each claim
     */
    function createCampaign(MerkleTreeHelper.Claim[] memory claims)
        internal
        returns (uint256 campaignId, bytes32 root, bytes32[][] memory proofs)
    {
        (root, proofs) = merkleHelper.generateMerkleTree(claims);

        vm.prank(owner);
        campaignId = distributor.newMerkleRoot(root);
    }

    /**
     * @notice Creates a simple test campaign with predefined users
     * @return campaignId The ID of the created campaign
     * @return proofs Array of proofs for alice, bob, charlie
     */
    function createSimpleCampaign() internal returns (uint256 campaignId, bytes32[][] memory proofs) {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](3);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        claims[1] = MerkleTreeHelper.Claim(bob, 200e18);
        claims[2] = MerkleTreeHelper.Claim(charlie, 300e18);

        bytes32 root;
        (campaignId, root, proofs) = createCampaign(claims);
    }

    /**
     * @notice Funds the distributor with additional JANE tokens
     * @param amount Amount of tokens to fund
     */
    function fundDistributor(uint256 amount) internal {
        mintTokens(address(distributor), amount);
    }

    /**
     * @notice Gets claim data for a specific user and amount
     * @param user User address
     * @param amount Claim amount
     * @param claims Full claims array used to generate the tree
     * @return proof The merkle proof for the claim
     */
    function getClaimProof(address user, uint256 amount, MerkleTreeHelper.Claim[] memory claims)
        internal
        view
        returns (bytes32[] memory proof)
    {
        (, bytes32[][] memory proofs) = merkleHelper.generateMerkleTree(claims);

        // Find the user's index in claims
        for (uint256 i = 0; i < claims.length; i++) {
            if (claims[i].user == user && claims[i].amount == amount) {
                return proofs[i];
            }
        }
        revert("User not found in claims");
    }

    /**
     * @notice Helper to claim rewards
     * @param campaignId Campaign to claim from
     * @param proof Merkle proof
     * @param user User to claim for
     * @param amount Amount to claim
     */
    function claim(uint256 campaignId, bytes32[] memory proof, address user, uint256 amount) internal {
        distributor.claim(campaignId, proof, user, amount);
    }

    /**
     * @notice Helper to claim rewards as a specific sender
     * @param sender Address to send the claim transaction from
     * @param campaignId Campaign to claim from
     * @param proof Merkle proof
     * @param user User to claim for
     * @param amount Amount to claim
     */
    function claimAs(address sender, uint256 campaignId, bytes32[] memory proof, address user, uint256 amount)
        internal
    {
        vm.prank(sender);
        distributor.claim(campaignId, proof, user, amount);
    }

    /**
     * @notice Creates a large campaign for gas testing
     * @param userCount Number of users in the campaign
     * @return campaignId The ID of the created campaign
     */
    function createLargeCampaign(uint256 userCount) internal returns (uint256 campaignId) {
        MerkleTreeHelper.Claim[] memory claims = merkleHelper.generateLargeClaims(userCount, 100e18);
        bytes32 root;
        bytes32[][] memory proofs;
        (campaignId, root, proofs) = createCampaign(claims);
    }

    /**
     * @notice Gets the balance of JANE tokens for an address
     * @param account Address to check
     * @return Balance of JANE tokens
     */
    function getJaneBalance(address account) internal view returns (uint256) {
        return token.balanceOf(account);
    }

    /**
     * @notice Invalidates a campaign as the owner
     * @param campaignId Campaign to invalidate
     */
    function invalidateCampaign(uint256 campaignId) internal {
        vm.prank(owner);
        distributor.invalidateCampaign(campaignId);
    }

    /**
     * @notice Sweeps tokens from the distributor as the owner
     * @param tokenAddress Token to sweep
     */
    function sweep(address tokenAddress) internal {
        vm.prank(owner);
        distributor.sweep(JaneToken(tokenAddress));
    }

    /**
     * @notice Advances block timestamp by the specified amount
     * @param timeToAdvance Time to advance in seconds
     */
    function advanceTime(uint256 timeToAdvance) internal {
        vm.warp(block.timestamp + timeToAdvance);
    }

    /**
     * @notice Warps to a specific timestamp
     * @param timestamp Target timestamp
     */
    function warpTo(uint256 timestamp) internal {
        vm.warp(timestamp);
    }
}
