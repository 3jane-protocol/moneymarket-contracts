// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "../../lib/openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BitMaps} from "../../lib/openzeppelin/contracts/utils/structs/BitMaps.sol";
import {MerkleProof} from "../../lib/openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Jane} from "./Jane.sol";

/**
 * @title RewardsDistributor
 * @notice Distributes JANE token rewards using merkle proofs with per-campaign tracking
 * @dev Uses BitMaps for efficient storage of claimed status across unlimited campaigns
 * @dev Supports two distribution modes: transfer (from contract balance) or mint (on-demand)
 */
contract RewardsDistributor is Ownable, ReentrancyGuard {
    using BitMaps for BitMaps.BitMap;

    error InvalidProof();
    error AlreadyClaimed();
    error InvalidCampaign();
    error LengthMismatch();

    /// @notice Emitted when a new campaign is added
    event CampaignAdded(uint256 indexed campaignId, bytes32 merkleRoot);

    /// @notice Emitted when rewards are claimed
    /// @param user The address receiving the rewards
    /// @param campaignId The campaign from which rewards were claimed
    /// @param amount The amount of JANE tokens claimed
    /// @param claimant The address that initiated the claim (can be different from user)
    event Claimed(address indexed user, uint256 indexed campaignId, uint256 amount, address indexed claimant);

    /// @notice Emitted when a campaign is invalidated
    event CampaignInvalidated(uint256 indexed campaignId);

    /// @notice The JANE token being distributed
    Jane public immutable jane;

    /// @notice Whether to mint tokens on claim (true) or transfer from balance (false)
    bool public useMint;

    /// @notice Array of merkle roots, one per campaign
    bytes32[] public merkleRoots;

    /// @notice Tracks which users have claimed from which campaigns
    mapping(address => BitMaps.BitMap) internal claimedBitmap;

    /**
     * @notice Initializes the rewards distributor
     * @param _initialOwner Address that will own the contract
     * @param _jane Address of the JANE token contract
     * @param _useMint True to mint tokens on claim, false to transfer from contract balance
     */
    constructor(address _initialOwner, address _jane, bool _useMint) Ownable(_initialOwner) {
        jane = Jane(_jane);
        useMint = _useMint;
    }

    /**
     * @notice Sets the distribution mode
     * @param _useMint True to mint tokens on claim, false to transfer from contract balance
     */
    function setUseMint(bool _useMint) external onlyOwner {
        useMint = _useMint;
    }

    /**
     * @notice Adds a new merkle root for a campaign
     * @param root The merkle root for the new campaign
     * @return rootId The ID of the newly added campaign
     */
    function newMerkleRoot(bytes32 root) external onlyOwner returns (uint256 rootId) {
        rootId = merkleRoots.length;
        merkleRoots.push(root);
        emit CampaignAdded(rootId, root);
    }

    /**
     * @notice Claims rewards for a user from a specific campaign
     * @dev Depending on useMint, either mints new tokens or transfers from contract balance
     * @param rootId The campaign ID to claim from
     * @param proof The merkle proof for the claim
     * @param addr The address to send rewards to
     * @param amount The amount of tokens to claim
     */
    function claim(uint256 rootId, bytes32[] memory proof, address addr, uint256 amount) public nonReentrant {
        if (rootId >= merkleRoots.length) revert InvalidCampaign();
        bytes32 root = merkleRoots[rootId];
        if (root == bytes32(0)) revert InvalidCampaign();
        if (claimed(addr, rootId)) revert AlreadyClaimed();

        _verify(root, proof, addr, amount);
        _setClaimed(addr, rootId);

        if (useMint) {
            jane.mint(addr, amount);
        } else {
            jane.transfer(addr, amount);
        }

        emit Claimed(addr, rootId, amount, msg.sender);
    }

    /**
     * @notice Claims rewards from multiple campaigns in a single transaction
     * @param rootIds Array of campaign IDs to claim from
     * @param amounts Array of amounts to claim
     * @param addrs Array of addresses to send rewards to
     * @param proofs Array of merkle proofs for each claim
     */
    function claimMultiple(
        uint256[] calldata rootIds,
        uint256[] calldata amounts,
        address[] calldata addrs,
        bytes32[][] calldata proofs
    ) external {
        uint256 length = rootIds.length;
        if (length != amounts.length || length != addrs.length || length != proofs.length) {
            revert LengthMismatch();
        }

        for (uint256 i = 0; i < length; i++) {
            claim(rootIds[i], proofs[i], addrs[i], amounts[i]);
        }
    }

    /**
     * @notice Invalidates a campaign by setting its merkle root to zero
     * @dev Once invalidated, no claims can be made from this campaign
     * @param campaignId The ID of the campaign to invalidate
     */
    function invalidateCampaign(uint256 campaignId) external onlyOwner {
        if (campaignId >= merkleRoots.length) revert InvalidCampaign();
        merkleRoots[campaignId] = bytes32(0);
        emit CampaignInvalidated(campaignId);
    }

    /**
     * @notice Returns the total number of campaigns
     * @return The number of merkle roots stored
     */
    function merkleRootCount() external view returns (uint256) {
        return merkleRoots.length;
    }

    /**
     * @notice Verifies a merkle proof for a claim
     * @param rootId The campaign ID to verify against
     * @param proof The merkle proof to verify
     * @param addr The address in the claim
     * @param amount The amount in the claim
     */
    function verify(uint256 rootId, bytes32[] memory proof, address addr, uint256 amount) public view {
        _verify(merkleRoots[rootId], proof, addr, amount);
    }

    function _verify(bytes32 root, bytes32[] memory proof, address addr, uint256 amount) internal pure {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(addr, amount))));
        if (!MerkleProof.verify(proof, root, leaf)) revert InvalidProof();
    }

    /**
     * @notice Internal function to mark a claim as completed
     * @param user The user who claimed
     * @param merkleRootId The campaign ID that was claimed
     */
    function _setClaimed(address user, uint256 merkleRootId) internal {
        claimedBitmap[user].set(merkleRootId);
    }

    /**
     * @notice Checks if a user has claimed from a specific campaign
     * @param user The user to check
     * @param merkleRootId The campaign ID to check
     * @return Whether the user has claimed from this campaign
     */
    function claimed(address user, uint256 merkleRootId) public view returns (bool) {
        return claimedBitmap[user].get(merkleRootId);
    }

    /**
     * @notice Recovers tokens sent to this contract
     * @param token The ERC20 token to recover
     */
    function sweep(IERC20 token) external onlyOwner {
        token.transfer(owner(), token.balanceOf(address(this)));
    }
}
