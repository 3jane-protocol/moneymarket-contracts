// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {JaneSetup} from "../../utils/JaneSetup.sol";
import {RewardsDistributor} from "../../../../../src/jane/RewardsDistributor.sol";
import {MerkleTreeHelper} from "../mocks/MerkleTreeHelper.sol";
import {Jane} from "../../../../../src/jane/Jane.sol";

contract RewardsDistributorSetup is JaneSetup {
    RewardsDistributor public rewardsDistributor;
    MerkleTreeHelper public merkleHelper;

    // Test users
    address public dave;
    address public eve;
    address public frank;

    // Epoch start time (January 1, 2024 00:00:00 UTC)
    uint256 public constant START = 1704067200;

    // Events
    event RootUpdated(bytes32 indexed oldRoot, bytes32 indexed newRoot);
    event Claimed(address indexed user, uint256 amount, uint256 totalClaimed);

    function setUp() public virtual override {
        super.setUp();

        // Create additional test users
        dave = makeAddr("dave");
        eve = makeAddr("eve");
        frank = makeAddr("frank");

        // Deploy merkle helper
        merkleHelper = new MerkleTreeHelper();

        // Deploy distributor in transfer mode by default
        rewardsDistributor = new RewardsDistributor(owner, address(token), false, START, 0);

        // Fund distributor with JANE tokens
        mintTokens(address(rewardsDistributor), 1_000_000e18);

        // Enable transfers for testing
        setTransferable();

        // Set default epoch emissions to allow testing without explicit setup
        // This provides a generous cap for existing tests
        vm.prank(owner);
        rewardsDistributor.setEpochEmissions(0, 10_000_000e18);

        vm.label(address(rewardsDistributor), "RewardsDistributor");
        vm.label(address(merkleHelper), "MerkleTreeHelper");
        vm.label(dave, "Dave");
        vm.label(eve, "Eve");
        vm.label(frank, "Frank");
    }

    /**
     * @notice Updates root with given claims
     * @param claims Array of claims to include in the merkle tree
     * @return root The merkle root
     * @return proofs Array of proofs for each claim
     */
    function updateRoot(MerkleTreeHelper.Claim[] memory claims)
        internal
        returns (bytes32 root, bytes32[][] memory proofs)
    {
        (root, proofs) = merkleHelper.generateMerkleTree(claims);
        vm.prank(owner);
        rewardsDistributor.updateRoot(root);
    }

    /**
     * @notice Sets up simple 3-user root
     * @return proofs Array of proofs for alice, bob, charlie
     */
    function setupSimpleRoot() internal returns (bytes32[][] memory proofs) {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](3);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        claims[1] = MerkleTreeHelper.Claim(bob, 200e18);
        claims[2] = MerkleTreeHelper.Claim(charlie, 300e18);

        bytes32 root;
        (root, proofs) = updateRoot(claims);
    }

    /**
     * @notice Funds the distributor with additional JANE tokens
     * @param amount Amount of tokens to fund
     */
    function fundDistributor(uint256 amount) internal {
        mintTokens(address(rewardsDistributor), amount);
    }

    /**
     * @notice Helper to claim rewards
     * @param user Address to claim for
     * @param totalAllocation Total allocation
     * @param proof Merkle proof
     */
    function claim(address user, uint256 totalAllocation, bytes32[] memory proof) internal {
        rewardsDistributor.claim(user, totalAllocation, proof);
    }

    /**
     * @notice Helper to claim as specific sender
     * @param sender Address to send the claim transaction from
     * @param user User to claim for
     * @param totalAllocation Total allocation
     * @param proof Merkle proof
     */
    function claimAs(address sender, address user, uint256 totalAllocation, bytes32[] memory proof) internal {
        vm.prank(sender);
        rewardsDistributor.claim(user, totalAllocation, proof);
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
     * @notice Sweeps tokens from the distributor as the owner
     * @param tokenAddress Token to sweep
     */
    function sweep(address tokenAddress) internal {
        vm.prank(owner);
        rewardsDistributor.sweep(Jane(tokenAddress));
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

    /**
     * @notice Toggles the distributor's mint mode
     * @param _useMint True to enable mint mode, false for transfer mode
     */
    function toggleMintMode(bool _useMint) internal {
        vm.prank(owner);
        rewardsDistributor.setUseMint(_useMint);
    }

    /**
     * @notice Sets epoch emissions as owner
     * @param epoch The epoch number
     * @param emissions The emissions amount
     */
    function setEpochEmissions(uint256 epoch, uint256 emissions) internal {
        vm.prank(owner);
        rewardsDistributor.setEpochEmissions(epoch, emissions);
    }
}
