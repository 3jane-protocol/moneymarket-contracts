// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.22;

/**
 * @title IUSD3WithdrawQueue
 * @author 3Jane Protocol
 * @notice External interface for the USD3 asynchronous FIFO withdraw queue
 * @dev Receipts are share-denominated ERC-721 NFTs. Queue entry transfers USD3 shares
 * into queue custody and mints a receipt to the chosen receiver. Processing redeems
 * those shares for USDC FIFO with zero max-loss tolerance. Receipt holders claim
 * accumulated USDC at any time; the NFT burns when a receipt is fully fulfilled
 * and fully claimed.
 */
interface IUSD3WithdrawQueue {
    /// @notice Per-request state stored by the queue.
    struct Request {
        /// @notice USD3 shares queued at request time. Invariant once set.
        uint256 sharesRequested;
        /// @notice USD3 shares still awaiting processing.
        uint256 sharesRemaining;
        /// @notice USDC already allocated to this receipt and not yet claimed.
        uint256 claimableAssets;
        /// @notice Lifetime USDC claimed by this receipt.
        uint256 claimedAssets;
        /// @notice Unix timestamp at which the request was created.
        uint256 createdAt;
    }

    /**
     * @notice Queue USD3 shares for asynchronous redemption to USDC.
     * @dev Pulls `shares` from `owner` via `transferFrom` (USD3 commitment-period
     * restrictions on `owner` apply through USD3's transfer hook). Mints the receipt
     * NFT to `receiver`. Reverts if the queue is paused, if USD3 is shutdown, on any
     * zero argument, or if `previewRedeem(shares) == 0` (dust).
     * @param shares USD3 shares to queue for redemption.
     * @param receiver Address that will own the receipt NFT.
     * @param owner Holder of the USD3 shares being queued; must have approved the queue.
     * @return requestId Identifier of the new request, equal to the minted ERC-721 tokenId.
     */
    function requestRedeem(uint256 shares, address receiver, address owner) external returns (uint256 requestId);

    /**
     * @notice Process up to `maxPositions` queued requests FIFO from the queue head.
     * @dev Permissionless. Redeems USD3 shares via the 4-arg `redeem` with `maxLoss = 0`
     * so temporary illiquidity is never realized as a loss. Returns `(0, 0)` when no
     * executable liquidity exists or `maxPositions == 0`. Stale (fully-fulfilled) heads
     * are walked over and count toward `maxPositions` to bound gas.
     * @param maxPositions Maximum number of FIFO positions touched in this call.
     * @return sharesProcessed Total USD3 shares redeemed across the touched requests.
     * @return assetsAllocated Total USDC allocated to receipts across the touched requests.
     */
    function process(uint256 maxPositions) external returns (uint256 sharesProcessed, uint256 assetsAllocated);

    /**
     * @notice Claim accumulated USDC for a single receipt.
     * @dev Callable by the receipt owner or an approved operator. Pays the full
     * `claimableAssets` to `receiver` and zeros it before transfer. Burns the receipt
     * when `sharesRemaining == 0` after this claim.
     * @param requestId Receipt identifier (also the ERC-721 tokenId).
     * @param receiver Address receiving the USDC payout.
     * @return assetsClaimed USDC transferred to `receiver`.
     */
    function claim(uint256 requestId, address receiver) external returns (uint256 assetsClaimed);

    /**
     * @notice Run `process` then `claim` for a single receipt in one transaction.
     * @dev Both steps share a single reentrancy guard. The `process` step may advance
     * the queue beyond `requestId`; the `claim` step only pays what is allocated to
     * `requestId`.
     * @param requestId Receipt to claim.
     * @param receiver Address receiving the USDC payout.
     * @param maxPositions Bound passed to the inner `process` call.
     * @return assetsClaimed USDC transferred to `receiver`.
     */
    function processAndClaim(uint256 requestId, address receiver, uint256 maxPositions)
        external
        returns (uint256 assetsClaimed);

    /// @notice Sum of `sharesRemaining` across all live requests. Used by USD3 to size queue reservation.
    function totalPendingShares() external view returns (uint256 shares);

    /// @notice Unfulfilled USD3 shares for a given receipt.
    function pendingShares(uint256 requestId) external view returns (uint256 shares);

    /// @notice USDC currently claimable for a given receipt.
    function claimableAssets(uint256 requestId) external view returns (uint256 assets);

    /// @notice Full request state for a given receipt.
    function requestInfo(uint256 requestId) external view returns (Request memory request);

    /// @notice Oldest request ID that may still need processing.
    function queueHead() external view returns (uint256 requestId);

    /// @notice Highest minted request ID, or 0 when the queue has never received an entry.
    function queueTail() external view returns (uint256 requestId);
}
