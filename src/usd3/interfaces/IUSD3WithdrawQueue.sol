// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.22;

interface IUSD3WithdrawQueue {
    struct Request {
        uint256 sharesRequested;
        uint256 sharesRemaining;
        uint256 claimableAssets;
        uint256 claimedAssets;
        uint256 createdAt;
    }

    function requestRedeem(uint256 shares, address receiver, address owner) external returns (uint256 requestId);

    function process(uint256 maxPositions) external returns (uint256 sharesProcessed, uint256 assetsAllocated);

    function claim(uint256 requestId, address receiver) external returns (uint256 assetsClaimed);

    function processAndClaim(uint256 requestId, address receiver, uint256 maxPositions)
        external
        returns (uint256 assetsClaimed);

    function totalPendingShares() external view returns (uint256 shares);

    function pendingShares(uint256 requestId) external view returns (uint256 shares);

    function claimableAssets(uint256 requestId) external view returns (uint256 assets);

    function requestInfo(uint256 requestId) external view returns (Request memory request);

    function queueHead() external view returns (uint256 requestId);

    function queueTail() external view returns (uint256 requestId);
}
