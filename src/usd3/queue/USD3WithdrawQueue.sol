// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.22;

import {IERC20, SafeERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {IUSD3WithdrawQueue} from "../interfaces/IUSD3WithdrawQueue.sol";
import {FifoReceiptQueue} from "./FifoReceiptQueue.sol";

contract USD3WithdrawQueue is FifoReceiptQueue, IUSD3WithdrawQueue {
    using SafeERC20 for IERC20;

    error InvalidUSD3();
    error QueuePaused();
    error Shutdown();
    error ZeroShares();
    error ZeroAssets();
    error ZeroReceiver();
    error ZeroOwner();
    error Unauthorized(address account);
    error NothingClaimable(uint256 requestId);

    ITokenizedStrategy public immutable usd3;
    IERC20 public immutable usdc;

    uint256 public totalPendingShares;
    mapping(uint256 => Request) internal _requests;
    bool public entriesPaused = true;
    uint256[40] private __gap;

    event RequestRedeem(uint256 indexed requestId, address indexed owner, address indexed receiver, uint256 shares);
    event Processed(uint256 indexed requestId, uint256 sharesProcessed, uint256 assetsAllocated);
    event ProcessBatch(uint256 sharesProcessed, uint256 assetsAllocated, uint256 positionsProcessed);
    event Claim(uint256 indexed requestId, address indexed receiver, uint256 assets);
    event EntriesPaused(bool paused);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _usd3) {
        if (_usd3 == address(0)) revert InvalidUSD3();

        usd3 = ITokenizedStrategy(_usd3);
        usdc = IERC20(ITokenizedStrategy(_usd3).asset());
        _disableInitializers();
    }

    function initialize() external initializer {
        __FifoReceiptQueue_init("USD3 Withdraw Queue", "USD3-WQ");
        entriesPaused = true;
    }

    function requestRedeem(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        if (entriesPaused) revert QueuePaused();
        if (usd3.isShutdown()) revert Shutdown();
        if (shares == 0) revert ZeroShares();
        if (usd3.previewRedeem(shares) == 0) revert ZeroAssets();
        if (receiver == address(0)) revert ZeroReceiver();
        if (owner == address(0)) revert ZeroOwner();

        IERC20(address(usd3)).safeTransferFrom(owner, address(this), shares);

        requestId = _mintReceipt(receiver);
        _requests[requestId] = Request({
            sharesRequested: shares,
            sharesRemaining: shares,
            claimableAssets: 0,
            claimedAssets: 0,
            createdAt: block.timestamp
        });
        totalPendingShares += shares;

        emit RequestRedeem(requestId, owner, receiver, shares);
    }

    function process(uint256 maxPositions)
        external
        nonReentrant
        returns (uint256 sharesProcessed, uint256 assetsAllocated)
    {
        (sharesProcessed, assetsAllocated,) = _process(maxPositions);
    }

    function claim(uint256 requestId, address receiver) external nonReentrant returns (uint256 assetsClaimed) {
        assetsClaimed = _claim(requestId, receiver);
    }

    function processAndClaim(uint256 requestId, address receiver, uint256 maxPositions)
        external
        nonReentrant
        returns (uint256 assetsClaimed)
    {
        _process(maxPositions);
        assetsClaimed = _claim(requestId, receiver);
    }

    function setEntriesPaused(bool paused) external {
        if (msg.sender != usd3.management() && msg.sender != usd3.emergencyAdmin()) revert Unauthorized(msg.sender);

        entriesPaused = paused;
        emit EntriesPaused(paused);
    }

    function queueHead() public view override(FifoReceiptQueue, IUSD3WithdrawQueue) returns (uint256) {
        return super.queueHead();
    }

    function queueTail() public view override(FifoReceiptQueue, IUSD3WithdrawQueue) returns (uint256) {
        return super.queueTail();
    }

    function pendingShares(uint256 requestId) external view returns (uint256 shares) {
        return _requests[requestId].sharesRemaining;
    }

    function claimableAssets(uint256 requestId) external view returns (uint256 assets) {
        return _requests[requestId].claimableAssets;
    }

    function requestInfo(uint256 requestId) external view returns (Request memory request) {
        return _requests[requestId];
    }

    function _process(uint256 maxPositions)
        internal
        returns (uint256 sharesProcessed, uint256 assetsAllocated, uint256 positionsProcessed)
    {
        if (maxPositions == 0) {
            return (0, 0, 0);
        }

        uint256 sharesAvailable = usd3.maxRedeem(address(this));
        if (sharesAvailable == 0) {
            return (0, 0, 0);
        }

        uint256 current = _queueHead;
        while (current < _nextRequestId && positionsProcessed < maxPositions && sharesAvailable > 0) {
            Request storage request = _requests[current];

            if (request.sharesRemaining == 0) {
                current++;
                _queueHead = current;
                positionsProcessed++;
                continue;
            }

            uint256 sharesToProcess = Math.min(request.sharesRemaining, sharesAvailable);
            if (sharesToProcess < request.sharesRemaining) {
                uint256 remainingAfterProcess = request.sharesRemaining - sharesToProcess;
                if (usd3.previewRedeem(remainingAfterProcess) == 0) break;
            }
            if (usd3.previewRedeem(sharesToProcess) == 0) break;

            uint256 assetsOut = usd3.redeem(sharesToProcess, address(this), address(this), 0);

            request.sharesRemaining -= sharesToProcess;
            request.claimableAssets += assetsOut;
            totalPendingShares -= sharesToProcess;

            sharesProcessed += sharesToProcess;
            assetsAllocated += assetsOut;
            sharesAvailable -= sharesToProcess;
            positionsProcessed++;

            emit Processed(current, sharesToProcess, assetsOut);

            if (request.sharesRemaining == 0) {
                current++;
                _queueHead = current;
            } else {
                break;
            }
        }

        emit ProcessBatch(sharesProcessed, assetsAllocated, positionsProcessed);
    }

    function _claim(uint256 requestId, address receiver) internal returns (uint256 assetsClaimed) {
        if (receiver == address(0)) revert ZeroReceiver();
        _requireAuthorizedForReceipt(requestId);

        Request storage request = _requests[requestId];
        assetsClaimed = request.claimableAssets;
        if (assetsClaimed == 0) revert NothingClaimable(requestId);

        request.claimableAssets = 0;
        request.claimedAssets += assetsClaimed;

        usdc.safeTransfer(receiver, assetsClaimed);

        if (request.sharesRemaining == 0) {
            delete _requests[requestId];
            _burnReceipt(requestId);
        }

        emit Claim(requestId, receiver, assetsClaimed);
    }
}
