// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.22;

import {Initializable} from "../../../lib/openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC721} from "../../../lib/openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "../../../lib/openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Metadata} from "../../../lib/openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC165} from "../../../lib/openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title FifoReceiptQueue
 * @author 3Jane Protocol
 * @notice Abstract FIFO ERC-721 receipt base shared by 3Jane's asynchronous withdraw queues.
 * @dev Hand-rolled ERC-721 (subset of OZ v5 semantics; no Enumerable) plus monotonic
 * request IDs that double as both FIFO position and ERC-721 tokenId. The repo does not
 * include `ERC721Upgradeable`, and the queues need tight control over storage layout
 * for upgrade safety, so the minimal surface is implemented here directly.
 *
 * Inheriting contracts are expected to:
 * - Take custody of the request-asset share token on entry and mint a receipt via
 *   {_mintReceipt}.
 * - Implement queue processing: redeeming custodied shares into a claim asset and
 *   updating per-request state.
 * - Implement claim payout, calling {_burnReceipt} when a request is fully settled.
 * - Gate claim/cancel-style operations through {_requireAuthorizedForReceipt}.
 */
abstract contract FifoReceiptQueue is Initializable, IERC721Metadata {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    /// @notice Thrown when a zero address is supplied where one is not allowed.
    error ZeroAddress();
    /// @notice Thrown when a query or transfer references a tokenId that has never been minted or has been burned.
    error NonexistentToken(uint256 tokenId);
    /// @notice Thrown if {_mint} is called for a tokenId that is already owned. Should not occur with monotonic IDs.
    error TokenAlreadyMinted(uint256 tokenId);
    /// @notice Thrown when {transferFrom}/{safeTransferFrom} `from` does not match the current owner.
    error IncorrectOwner(address from, uint256 tokenId, address owner);
    /// @notice Thrown when the caller lacks owner/approved/operator authority over the receipt.
    error NotAuthorized(address account, uint256 tokenId);
    /// @notice Thrown when a transfer or mint targets the zero address.
    error InvalidReceiver(address receiver);
    /// @notice Thrown when a contract receiver does not implement `onERC721Received` correctly.
    error UnsafeRecipient(address receiver);
    /// @notice Thrown by {nonReentrant} when an entrypoint is invoked recursively.
    error ReentrantCall();

    string private _name;
    string private _symbol;

    /// @dev Standard ERC-721 storage. Owner-of-token, balance-of-owner, per-token approval,
    /// and operator approvals indexed by (owner, operator).
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    /// @notice Oldest request ID that may still need processing. Advances monotonically.
    uint256 internal _queueHead;
    /// @notice Next request ID to mint. Starts at 1; tokenId 0 is never issued.
    uint256 internal _nextRequestId;
    /// @dev Reentrancy guard state. NOT_ENTERED (1) or ENTERED (2); 0 indicates uninitialized.
    uint256 private _status;
    /// @dev Storage gap reserved for future fields added to this base.
    uint256[40] private __gap;

    /// @notice Single-entrancy guard reused by inheriting queues across request/process/claim entrypoints.
    modifier nonReentrant() {
        if (_status == ENTERED) revert ReentrantCall();
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }

    /**
     * @notice Initialize the receipt metadata and FIFO cursors.
     * @dev Head and tail both start at 1 so tokenId 0 is never minted; that lets `queueTail()`
     * use 0 as the "no entries yet" sentinel.
     * @param name_ ERC-721 collection name.
     * @param symbol_ ERC-721 collection symbol.
     */
    function __FifoReceiptQueue_init(string memory name_, string memory symbol_) internal onlyInitializing {
        _name = name_;
        _symbol = symbol_;
        _queueHead = 1;
        _nextRequestId = 1;
        _status = NOT_ENTERED;
    }

    /// @inheritdoc IERC165
    /// @dev `pure` is permitted as a stricter override of the interface's `view`.
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC721).interfaceId
            || interfaceId == type(IERC721Metadata).interfaceId;
    }

    /// @inheritdoc IERC721Metadata
    function name() external view returns (string memory) {
        return _name;
    }

    /// @inheritdoc IERC721Metadata
    function symbol() external view returns (string memory) {
        return _symbol;
    }

    /// @inheritdoc IERC721Metadata
    /// @dev v1 returns the empty string for any owned token. Off-chain UIs should derive
    /// receipt state from {requestInfo} on the concrete queue.
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        _requireOwned(tokenId);
        return "";
    }

    /// @inheritdoc IERC721
    function balanceOf(address owner) public view returns (uint256) {
        if (owner == address(0)) revert ZeroAddress();
        return _balances[owner];
    }

    /// @inheritdoc IERC721
    function ownerOf(uint256 tokenId) public view returns (address) {
        return _requireOwned(tokenId);
    }

    /// @inheritdoc IERC721
    function approve(address to, uint256 tokenId) external {
        address owner = _requireOwned(tokenId);
        if (msg.sender != owner && !isApprovedForAll(owner, msg.sender)) {
            revert NotAuthorized(msg.sender, tokenId);
        }

        _approve(to, tokenId, owner);
    }

    /// @inheritdoc IERC721
    function getApproved(uint256 tokenId) public view returns (address) {
        _requireOwned(tokenId);
        return _tokenApprovals[tokenId];
    }

    /// @inheritdoc IERC721
    function setApprovalForAll(address operator, bool approved) external {
        if (operator == address(0)) revert ZeroAddress();

        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    /// @inheritdoc IERC721
    function isApprovedForAll(address owner, address operator) public view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    /// @inheritdoc IERC721
    function transferFrom(address from, address to, uint256 tokenId) public {
        _transfer(from, to, tokenId, msg.sender);
    }

    /// @inheritdoc IERC721
    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    /// @inheritdoc IERC721
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        _transfer(from, to, tokenId, msg.sender);
        _checkOnERC721Received(msg.sender, from, to, tokenId, data);
    }

    /// @notice Oldest request ID that may still need processing.
    function queueHead() public view virtual returns (uint256) {
        return _queueHead;
    }

    /// @notice Next request ID to mint.
    function nextRequestId() public view virtual returns (uint256) {
        return _nextRequestId;
    }

    /// @notice Highest minted request ID, or 0 when the queue has never received an entry.
    function queueTail() public view virtual returns (uint256) {
        return _nextRequestId == 1 ? 0 : _nextRequestId - 1;
    }

    /**
     * @notice Mint the next FIFO receipt to `receiver` and return its ID.
     * @dev Uses safe-mint so contract receivers must implement {IERC721Receiver}.
     * @param receiver Address that will own the new receipt NFT.
     * @return requestId The minted tokenId and the request's FIFO position.
     */
    function _mintReceipt(address receiver) internal returns (uint256 requestId) {
        requestId = _nextRequestId++;
        _safeMint(receiver, requestId);
    }

    /**
     * @notice Burn a receipt NFT once its underlying request is fully settled.
     * @dev Concrete queues should clear request storage before or after calling this.
     * @param requestId Receipt to burn. Must currently be owned.
     */
    function _burnReceipt(uint256 requestId) internal {
        address owner = _requireOwned(requestId);

        _approve(address(0), requestId, owner);
        unchecked {
            _balances[owner] -= 1;
        }
        delete _owners[requestId];

        emit Transfer(owner, address(0), requestId);
    }

    /**
     * @notice True if `account` is the owner of, an approved address for, or an operator over `requestId`.
     * @param requestId Receipt being queried.
     * @param account Account to test.
     * @return True if `account` has receipt-level authority.
     */
    function _isAuthorizedForReceipt(uint256 requestId, address account) internal view returns (bool) {
        address owner = ownerOf(requestId);
        return account == owner || getApproved(requestId) == account || isApprovedForAll(owner, account);
    }

    /**
     * @notice Revert with {NotAuthorized} if `msg.sender` lacks authority over `requestId`.
     * @param requestId Receipt being acted on.
     */
    function _requireAuthorizedForReceipt(uint256 requestId) internal view {
        if (!_isAuthorizedForReceipt(requestId, msg.sender)) revert NotAuthorized(msg.sender, requestId);
    }

    /// @dev Mint and then call {_checkOnERC721Received} on contract receivers.
    function _safeMint(address to, uint256 tokenId) private {
        _mint(to, tokenId);
        _checkOnERC721Received(msg.sender, address(0), to, tokenId, "");
    }

    /// @dev Low-level mint. Reverts on zero receiver or already-minted tokenId.
    function _mint(address to, uint256 tokenId) private {
        if (to == address(0)) revert InvalidReceiver(address(0));
        if (_owners[tokenId] != address(0)) revert TokenAlreadyMinted(tokenId);

        unchecked {
            _balances[to] += 1;
        }
        _owners[tokenId] = to;

        emit Transfer(address(0), to, tokenId);
    }

    /// @dev Low-level transfer. Clears any prior per-token approval. `auth` is the caller
    /// whose authority is being verified.
    function _transfer(address from, address to, uint256 tokenId, address auth) private {
        if (to == address(0)) revert InvalidReceiver(address(0));

        address owner = _requireOwned(tokenId);
        if (owner != from) revert IncorrectOwner(from, tokenId, owner);
        if (auth != owner && getApproved(tokenId) != auth && !isApprovedForAll(owner, auth)) {
            revert NotAuthorized(auth, tokenId);
        }

        _approve(address(0), tokenId, owner);

        unchecked {
            _balances[from] -= 1;
            _balances[to] += 1;
        }
        _owners[tokenId] = to;

        emit Transfer(from, to, tokenId);
    }

    /// @dev Set per-token approval and emit {Approval}.
    function _approve(address to, uint256 tokenId, address owner) private {
        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    /// @dev Read `_owners[tokenId]` and revert with {NonexistentToken} on zero.
    function _requireOwned(uint256 tokenId) private view returns (address owner) {
        owner = _owners[tokenId];
        if (owner == address(0)) revert NonexistentToken(tokenId);
    }

    /// @dev If `to` is a contract, call `onERC721Received` and revert unless it returns the
    /// expected selector. EOAs are accepted without a callback.
    function _checkOnERC721Received(address operator, address from, address to, uint256 tokenId, bytes memory data)
        private
    {
        if (to.code.length == 0) return;

        try IERC721Receiver(to).onERC721Received(operator, from, tokenId, data) returns (bytes4 retval) {
            if (retval != IERC721Receiver.onERC721Received.selector) revert UnsafeRecipient(to);
        } catch {
            revert UnsafeRecipient(to);
        }
    }
}
