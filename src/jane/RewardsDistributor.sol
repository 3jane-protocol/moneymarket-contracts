// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "../../lib/openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MerkleProof} from "../../lib/openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Jane} from "./Jane.sol";

/**
 * @title RewardsDistributor
 * @notice Distributes JANE token rewards using a merkle tree with cumulative allocation tracking
 * @dev Users can claim the difference between their total allocation and already claimed amount
 * @dev Supports two distribution modes: transfer (from contract balance) or mint (on-demand)
 */
contract RewardsDistributor is Ownable, ReentrancyGuard {
    error InvalidProof();
    error NothingToClaim();
    error LengthMismatch();
    error MaxClaimableExceeded();

    /// @notice Emitted when the merkle root is updated
    event RootUpdated(bytes32 indexed oldRoot, bytes32 indexed newRoot);

    /// @notice Emitted when rewards are claimed
    /// @param user The address receiving the rewards
    /// @param amount The amount of JANE tokens claimed
    /// @param totalClaimed The total amount the user has claimed after this claim
    event Claimed(address indexed user, uint256 amount, uint256 totalClaimed);

    /// @notice Start timestamp of epoch 0
    uint256 internal immutable START;

    /// @notice 7 day epoch length
    uint256 internal constant EPOCH = 604800;

    /// @notice The JANE token being distributed
    Jane public immutable jane;

    /// @notice Whether to mint tokens on claim (true) or transfer from balance (false)
    bool public useMint;

    /// @notice The current merkle root
    bytes32 public merkleRoot;

    /// @notice Tracks cumulative amount claimed by each user
    mapping(address => uint256) public claimed;

    /// @notice Tracks total emissions allocated per epoch
    mapping(uint256 => uint256) public epochEmissions;

    /// @notice Tracks total amount claimed across all users
    uint256 public totalClaimed;

    /// @notice Maximum total amount that can be claimed (sum of all epoch emissions)
    uint256 public maxClaimable;

    /**
     * @notice Initializes the rewards distributor
     * @param _initialOwner Address that will own the contract
     * @param _jane Address of the JANE token contract
     * @param _useMint True to mint tokens on claim, false to transfer from contract balance
     * @param _start The start timestamp of epoch 0
     */
    constructor(address _initialOwner, address _jane, bool _useMint, uint256 _start) Ownable(_initialOwner) {
        jane = Jane(_jane);
        useMint = _useMint;
        START = _start;
    }

    /**
     * @notice Returns the current epoch number
     * @return The current epoch based on block.timestamp
     */
    function epoch() external view returns (uint256) {
        return epoch(block.timestamp);
    }

    /**
     * @notice Calculates the epoch number for a given timestamp
     * @param timestamp The timestamp to calculate the epoch for
     * @return The epoch number
     */
    function epoch(uint256 timestamp) public view returns (uint256) {
        return (timestamp - START) / EPOCH;
    }

    /**
     * @notice Updates the merkle root
     * @param _root The new merkle root
     */
    function updateRoot(bytes32 _root) external onlyOwner {
        bytes32 oldRoot = merkleRoot;
        merkleRoot = _root;
        emit RootUpdated(oldRoot, _root);
    }

    /**
     * @notice Sets the emissions for a specific epoch and updates the max claimable amount
     * @param _epoch The epoch number
     * @param emissions The total emissions allocated for this epoch
     */
    function setEpochEmissions(uint256 _epoch, uint256 emissions) external onlyOwner {
        uint256 _prevEmissions = epochEmissions[_epoch];

        if (_prevEmissions == 0) {
            maxClaimable += emissions;
        } else if (emissions > _prevEmissions) {
            maxClaimable += emissions - _prevEmissions;
        } else {
            maxClaimable -= _prevEmissions - emissions;
        }

        epochEmissions[_epoch] = emissions;
    }

    /**
     * @notice Sets the distribution mode
     * @param _useMint True to mint tokens on claim, false to transfer from contract balance
     */
    function setUseMint(bool _useMint) external onlyOwner {
        useMint = _useMint;
    }

    /**
     * @notice Claims available rewards for a user
     * @param user Address to claim rewards for
     * @param totalAllocation Total cumulative allocation for the user
     * @param proof Merkle proof for the claim
     */
    function claim(address user, uint256 totalAllocation, bytes32[] calldata proof) external nonReentrant {
        _claim(user, totalAllocation, proof);
    }

    /**
     * @notice Claims available rewards for multiple users
     * @param users Addresses to claim rewards for
     * @param totalAllocations Total cumulative allocations for each user
     * @param proofs Merkle proofs for each claim
     */
    function claimMultiple(address[] calldata users, uint256[] calldata totalAllocations, bytes32[][] calldata proofs)
        external
        nonReentrant
    {
        uint256 length = users.length;
        if (length != totalAllocations.length || length != proofs.length) revert LengthMismatch();

        for (uint256 i = 0; i < length; i++) {
            _claim(users[i], totalAllocations[i], proofs[i]);
        }
    }

    /**
     * @notice Internal function to process a claim
     * @param user Address to claim rewards for
     * @param totalAllocation Total cumulative allocation for the user
     * @param proof Merkle proof for the claim
     */
    function _claim(address user, uint256 totalAllocation, bytes32[] calldata proof) internal {
        // Verify proof
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(user, totalAllocation))));
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) revert InvalidProof();

        // Calculate claimable amount
        uint256 alreadyClaimed = claimed[user];
        if (totalAllocation <= alreadyClaimed) revert NothingToClaim();
        uint256 claimable = totalAllocation - alreadyClaimed;

        // Cap claimable amount if it would exceed maxClaimable
        if (maxClaimable == 0 || totalClaimed >= maxClaimable) {
            revert MaxClaimableExceeded();
        }
        uint256 remaining = maxClaimable - totalClaimed;
        if (claimable > remaining) {
            claimable = remaining;
        }

        // Update claimed amount
        claimed[user] = alreadyClaimed + claimable;
        totalClaimed += claimable;

        // Distribute tokens
        if (useMint) {
            jane.mint(user, claimable);
        } else {
            jane.transfer(user, claimable);
        }

        emit Claimed(user, claimable, totalAllocation);
    }

    /**
     * @notice Calculates claimable amount for a user
     * @param user Address to check
     * @param totalAllocation Total cumulative allocation
     * @return Claimable amount
     */
    function getClaimable(address user, uint256 totalAllocation) external view returns (uint256) {
        uint256 alreadyClaimed = claimed[user];
        return totalAllocation > alreadyClaimed ? totalAllocation - alreadyClaimed : 0;
    }

    /**
     * @notice Verifies a merkle proof
     * @param user Address in the proof
     * @param totalAllocation Allocation in the proof
     * @param proof Merkle proof
     * @return True if proof is valid
     */
    function verify(address user, uint256 totalAllocation, bytes32[] calldata proof) external view returns (bool) {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(user, totalAllocation))));
        return MerkleProof.verify(proof, merkleRoot, leaf);
    }

    /**
     * @notice Recovers tokens sent to this contract
     * @param token The ERC20 token to recover
     */
    function sweep(IERC20 token) external onlyOwner {
        token.transfer(owner(), token.balanceOf(address(this)));
    }
}
