// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.22;

import {IERC20, SafeERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {IUSD3WithdrawQueue} from "../interfaces/IUSD3WithdrawQueue.sol";
import {FifoReceiptQueue} from "./FifoReceiptQueue.sol";

/**
 * @title USD3WithdrawQueue
 * @author 3Jane Protocol
 * @notice Asynchronous FIFO withdraw queue for USD3 -> USDC redemptions used when USD3
 * USDC liquidity is constrained.
 * @dev Sidecar contract. USD3 reserves liquidity for pending claims via its immutable
 * `withdrawQueue` pointer so ordinary redemptions never consume USDC owed to earlier
 * queued requests. Receipts are share-denominated ERC-721 NFTs that float with USD3 PPS
 * until fulfilled.
 *
 * Mechanism:
 * - {requestRedeem} pulls USD3 shares into queue custody and mints a receipt NFT to the
 *   chosen receiver. Commitment-period restrictions on the share owner are inherited
 *   from USD3's transfer hook.
 * - {process} is permissionless and walks the FIFO from the head, redeeming custodied
 *   USD3 shares to USDC with `maxLoss = 0` so temporary illiquidity is never realized
 *   as a loss. Stale (already-fulfilled) heads count toward `maxPositions`.
 * - {claim} pays accumulated USDC to the receipt owner (or approved operator) and burns
 *   the NFT once the request is fully fulfilled.
 * - {processAndClaim} performs both in a single transaction under one reentrancy guard.
 */
contract USD3WithdrawQueue is FifoReceiptQueue, IUSD3WithdrawQueue {
    using SafeERC20 for IERC20;

    /// @notice Thrown when constructed with `_usd3 == address(0)`.
    error InvalidUSD3();
    /// @notice Thrown by {requestRedeem} when {entriesPaused} is true.
    error QueuePaused();
    /// @notice Thrown by {requestRedeem} when USD3 reports `isShutdown() == true`.
    error Shutdown();
    /// @notice Thrown by {requestRedeem} on a zero-share request.
    error ZeroShares();
    /// @notice Thrown by {requestRedeem} when `previewRedeem(shares) == 0` (dust request that would otherwise revert in
    /// USD3).
    error ZeroAssets();
    /// @notice Thrown by {requestRedeem} / {claim} on a zero `receiver`.
    error ZeroReceiver();
    /// @notice Thrown by {requestRedeem} on a zero `owner`.
    error ZeroOwner();
    /// @notice Thrown by {setEntriesPaused} when caller is neither USD3 `management` nor `emergencyAdmin`.
    error Unauthorized(address account);
    /// @notice Thrown by {claim} when the receipt has nothing currently claimable.
    error NothingClaimable(uint256 requestId);

    /// @notice USD3 strategy this queue serves. Immutable across the implementation's lifetime.
    ITokenizedStrategy public immutable usd3;
    /// @notice USDC token paid out on claim. Read once from `usd3.asset()` at deploy and invariant
    /// for this implementation; a future USD3 asset change requires a new queue implementation.
    IERC20 public immutable usdc;

    /// @notice Sum of `sharesRemaining` across all live requests. Used by USD3 to size queue reservation.
    uint256 public totalPendingShares;
    /// @dev Per-request state keyed by `requestId == tokenId`.
    mapping(uint256 => Request) internal _requests;
    /// @notice When true, {requestRedeem} reverts but {process}, {claim}, and {processAndClaim}
    /// remain available. Defaults to `true` so a freshly-deployed queue is paused until
    /// management explicitly opens entries.
    bool public entriesPaused = true;
    /// @dev Storage gap reserved for future fields added to this contract.
    uint256[40] private __gap;

    /// @notice Emitted when a user queues a redemption.
    /// @param requestId New request / receipt ID.
    /// @param owner Holder of the queued USD3 shares.
    /// @param receiver Address granted the receipt NFT.
    /// @param shares USD3 shares transferred into queue custody.
    event RequestRedeem(uint256 indexed requestId, address indexed owner, address indexed receiver, uint256 shares);

    /// @notice Emitted once per request touched by {process} that actually moved shares.
    /// @param requestId Request that was processed.
    /// @param sharesProcessed USD3 shares redeemed for this request in this call.
    /// @param assetsAllocated USDC allocated to this request in this call.
    event Processed(uint256 indexed requestId, uint256 sharesProcessed, uint256 assetsAllocated);

    /// @notice Emitted at the end of every {process} invocation, summarizing the batch.
    /// @param sharesProcessed Total USD3 shares redeemed in this call.
    /// @param assetsAllocated Total USDC allocated to receipts in this call.
    /// @param positionsProcessed FIFO positions touched (including stale-head skips).
    event ProcessBatch(uint256 sharesProcessed, uint256 assetsAllocated, uint256 positionsProcessed);

    /// @notice Emitted when a claim is paid out.
    /// @param requestId Receipt that was claimed.
    /// @param receiver Address that received the USDC payout.
    /// @param assets USDC transferred.
    event Claim(uint256 indexed requestId, address indexed receiver, uint256 assets);

    /// @notice Emitted on every {setEntriesPaused} toggle.
    event EntriesPaused(bool paused);

    /**
     * @notice Deploy a queue bound to a specific USD3 strategy.
     * @dev Reads `usdc = usd3.asset()` at deploy and freezes it for this implementation.
     * Disables the proxy implementation initializer so this contract cannot be misused
     * directly without a proxy.
     * @param _usd3 USD3 proxy address. Reverts on zero.
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _usd3) {
        if (_usd3 == address(0)) revert InvalidUSD3();

        usd3 = ITokenizedStrategy(_usd3);
        usdc = IERC20(ITokenizedStrategy(_usd3).asset());
        _disableInitializers();
    }

    /**
     * @notice Proxy initializer. Sets ERC-721 metadata and FIFO cursors.
     * @dev Leaves `entriesPaused = true` so the queue is closed at deploy; management
     * must call {setEntriesPaused} to open it.
     */
    function initialize() external initializer {
        __FifoReceiptQueue_init("USD3 Withdraw Queue", "USD3-WQ");
        entriesPaused = true;
    }

    /**
     * @notice Queue USD3 shares for asynchronous redemption to USDC.
     * @dev Pulls `shares` from `owner` via `transferFrom`, so USD3 commitment-period
     * restrictions on `owner` apply through USD3's transfer hook. Mints the receipt NFT
     * to `receiver`. Reverts on queue pause, USD3 shutdown, any zero argument, or when
     * the request would redeem to zero USDC at current PPS.
     * @param shares USD3 shares to queue.
     * @param receiver Address that will own the receipt NFT.
     * @param owner Holder of the shares; must have approved the queue to spend `shares`.
     * @return requestId New request / receipt ID.
     */
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

    /**
     * @notice Process up to `maxPositions` queued requests FIFO from the head.
     * @dev Permissionless. Returns `(0, 0)` without reverting when there is no executable
     * liquidity, when `maxPositions == 0`, or when the head's residual would otherwise
     * trigger USD3's `ZERO_ASSETS` guard.
     * @param maxPositions Maximum FIFO positions touched in this call (including stale-head skips).
     * @return sharesProcessed Total USD3 shares redeemed across the batch.
     * @return assetsAllocated Total USDC allocated to receipts across the batch.
     */
    function process(uint256 maxPositions)
        external
        nonReentrant
        returns (uint256 sharesProcessed, uint256 assetsAllocated)
    {
        (sharesProcessed, assetsAllocated,) = _process(maxPositions);
    }

    /**
     * @notice Claim accumulated USDC for a single receipt.
     * @dev Callable by the receipt owner or an approved operator. Zeros `claimableAssets`
     * before transferring. Burns the receipt when `sharesRemaining == 0` after the claim.
     * @param requestId Receipt to claim.
     * @param receiver Address receiving the USDC payout.
     * @return assetsClaimed USDC transferred to `receiver`.
     */
    function claim(uint256 requestId, address receiver) external nonReentrant returns (uint256 assetsClaimed) {
        assetsClaimed = _claim(requestId, receiver);
    }

    /**
     * @notice Run {process} and then {claim} for `requestId` under a single reentrancy guard.
     * @dev Lets a claimant advance the queue toward (or past) their position and collect
     * accumulated USDC in one transaction.
     * @param requestId Receipt to claim.
     * @param receiver Address receiving the USDC payout.
     * @param maxPositions Bound passed to the inner {process} call.
     * @return assetsClaimed USDC transferred to `receiver`.
     */
    function processAndClaim(uint256 requestId, address receiver, uint256 maxPositions)
        external
        nonReentrant
        returns (uint256 assetsClaimed)
    {
        _process(maxPositions);
        assetsClaimed = _claim(requestId, receiver);
    }

    /**
     * @notice Pause or unpause new queue entries.
     * @dev Callable by USD3 `management` or `emergencyAdmin`. Does not affect {process} or
     * {claim}, so in-flight requests can always be drained.
     * @param paused New paused state.
     */
    function setEntriesPaused(bool paused) external {
        if (msg.sender != usd3.management() && msg.sender != usd3.emergencyAdmin()) revert Unauthorized(msg.sender);

        entriesPaused = paused;
        emit EntriesPaused(paused);
    }

    /// @inheritdoc IUSD3WithdrawQueue
    function queueHead() public view override(FifoReceiptQueue, IUSD3WithdrawQueue) returns (uint256) {
        return super.queueHead();
    }

    /// @inheritdoc IUSD3WithdrawQueue
    function queueTail() public view override(FifoReceiptQueue, IUSD3WithdrawQueue) returns (uint256) {
        return super.queueTail();
    }

    /// @inheritdoc IUSD3WithdrawQueue
    function pendingShares(uint256 requestId) external view returns (uint256 shares) {
        return _requests[requestId].sharesRemaining;
    }

    /// @inheritdoc IUSD3WithdrawQueue
    function claimableAssets(uint256 requestId) external view returns (uint256 assets) {
        return _requests[requestId].claimableAssets;
    }

    /// @inheritdoc IUSD3WithdrawQueue
    function requestInfo(uint256 requestId) external view returns (Request memory request) {
        return _requests[requestId];
    }

    /// @dev FIFO processing loop. Each iteration consumes one `maxPositions` slot whether it
    /// skipped a stale (already-fulfilled) head or actually redeemed; this bounds gas against
    /// long runs of out-of-order-claimed receipts. Before redeeming, both the prospective
    /// `sharesToProcess` and any partial residual are checked via `previewRedeem` to avoid
    /// USD3's `ZERO_ASSETS` revert on dust amounts. A non-empty partial fulfillment ends the
    /// loop (it would block the next head anyway).
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

    /// @dev Auth-check, zero-before-transfer, then burn-on-settlement. Reverts when there
    /// is nothing claimable so callers do not pay gas for no-ops.
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
