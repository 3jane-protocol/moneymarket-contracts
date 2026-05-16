// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.22;

import {Initializable} from "../../../lib/openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC721} from "../../../lib/openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "../../../lib/openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Metadata} from "../../../lib/openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC165} from "../../../lib/openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @dev Minimal proxy-initialized ERC-721 receipt base. The repo does not include
/// OpenZeppelin ERC721Upgradeable, and the queues only need the standard receipt
/// surface plus tightly controlled FIFO cursor storage.
abstract contract FifoReceiptQueue is Initializable, IERC721Metadata {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    error ZeroAddress();
    error NonexistentToken(uint256 tokenId);
    error TokenAlreadyMinted(uint256 tokenId);
    error IncorrectOwner(address from, uint256 tokenId, address owner);
    error NotAuthorized(address account, uint256 tokenId);
    error InvalidReceiver(address receiver);
    error UnsafeRecipient(address receiver);
    error ReentrantCall();

    string private _name;
    string private _symbol;

    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    uint256 internal _queueHead;
    uint256 internal _nextRequestId;
    uint256 private _status;
    uint256[40] private __gap;

    modifier nonReentrant() {
        if (_status == ENTERED) revert ReentrantCall();
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }

    function __FifoReceiptQueue_init(string memory name_, string memory symbol_) internal onlyInitializing {
        _name = name_;
        _symbol = symbol_;
        _queueHead = 1;
        _nextRequestId = 1;
        _status = NOT_ENTERED;
    }

    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC721).interfaceId
            || interfaceId == type(IERC721Metadata).interfaceId;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        _requireOwned(tokenId);
        return "";
    }

    function balanceOf(address owner) public view returns (uint256) {
        if (owner == address(0)) revert ZeroAddress();
        return _balances[owner];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        return _requireOwned(tokenId);
    }

    function approve(address to, uint256 tokenId) external {
        address owner = _requireOwned(tokenId);
        if (msg.sender != owner && !isApprovedForAll(owner, msg.sender)) {
            revert NotAuthorized(msg.sender, tokenId);
        }

        _approve(to, tokenId, owner);
    }

    function getApproved(uint256 tokenId) public view returns (address) {
        _requireOwned(tokenId);
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        if (operator == address(0)) revert ZeroAddress();

        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address owner, address operator) public view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        _transfer(from, to, tokenId, msg.sender);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        _transfer(from, to, tokenId, msg.sender);
        _checkOnERC721Received(msg.sender, from, to, tokenId, data);
    }

    function queueHead() public view virtual returns (uint256) {
        return _queueHead;
    }

    function nextRequestId() public view virtual returns (uint256) {
        return _nextRequestId;
    }

    function queueTail() public view virtual returns (uint256) {
        return _nextRequestId == 1 ? 0 : _nextRequestId - 1;
    }

    function _mintReceipt(address receiver) internal returns (uint256 requestId) {
        requestId = _nextRequestId++;
        _safeMint(receiver, requestId);
    }

    function _burnReceipt(uint256 requestId) internal {
        address owner = _requireOwned(requestId);

        _approve(address(0), requestId, owner);
        unchecked {
            _balances[owner] -= 1;
        }
        delete _owners[requestId];

        emit Transfer(owner, address(0), requestId);
    }

    function _isAuthorizedForReceipt(uint256 requestId, address account) internal view returns (bool) {
        address owner = ownerOf(requestId);
        return account == owner || getApproved(requestId) == account || isApprovedForAll(owner, account);
    }

    function _requireAuthorizedForReceipt(uint256 requestId) internal view {
        if (!_isAuthorizedForReceipt(requestId, msg.sender)) revert NotAuthorized(msg.sender, requestId);
    }

    function _safeMint(address to, uint256 tokenId) private {
        _mint(to, tokenId);
        _checkOnERC721Received(msg.sender, address(0), to, tokenId, "");
    }

    function _mint(address to, uint256 tokenId) private {
        if (to == address(0)) revert InvalidReceiver(address(0));
        if (_owners[tokenId] != address(0)) revert TokenAlreadyMinted(tokenId);

        unchecked {
            _balances[to] += 1;
        }
        _owners[tokenId] = to;

        emit Transfer(address(0), to, tokenId);
    }

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

    function _approve(address to, uint256 tokenId, address owner) private {
        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function _requireOwned(uint256 tokenId) private view returns (address owner) {
        owner = _owners[tokenId];
        if (owner == address(0)) revert NonexistentToken(tokenId);
    }

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
