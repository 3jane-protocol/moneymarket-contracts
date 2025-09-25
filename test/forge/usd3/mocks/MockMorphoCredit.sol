// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {
    IMorpho,
    MarketParams,
    Id,
    Position,
    Market,
    Authorization,
    Signature
} from "../../../../src/interfaces/IMorpho.sol";
import {SharesMathLib} from "../../../../src/libraries/SharesMathLib.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockMorphoCredit
 * @notice Mock implementation of MorphoCredit for testing USD3 strategy
 * @dev Simplified implementation focusing on supply/withdraw functionality
 */
contract MockMorphoCredit is IMorpho {
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    mapping(Id => Market) internal markets;
    mapping(Id => mapping(address => Position)) internal positions;
    mapping(address => bool) public isIrmEnabled;
    mapping(uint256 => bool) public isLltvEnabled;
    mapping(Id => mapping(address => bool)) public authorizations;
    mapping(Id => MarketParams) internal _marketParams;

    address public owner;
    address public feeRecipient;
    uint256 public fee;
    address public protocolConfig; // Added for USD3/sUSD3 integration

    constructor() {
        owner = msg.sender;
    }

    // Set protocol config for testing
    function setProtocolConfig(address _protocolConfig) external {
        protocolConfig = _protocolConfig;
    }

    // Core supply/withdraw functions

    function supply(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory)
        external
        returns (uint256 assetsSupplied, uint256 sharesSupplied)
    {
        Id id = marketParams.id();
        Market storage m = markets[id];

        // Handle zero supply gracefully
        if (assets == 0 && shares == 0) {
            return (0, 0);
        }

        // Simple share calculation
        if (m.totalSupplyShares == 0) {
            sharesSupplied = assets * SharesMathLib.VIRTUAL_SHARES;
        } else {
            sharesSupplied = assets.toSharesDown(m.totalSupplyAssets, m.totalSupplyShares);
        }

        assetsSupplied = assets;

        // Update market state
        m.totalSupplyAssets = uint128(uint256(m.totalSupplyAssets) + assets);
        m.totalSupplyShares = uint128(uint256(m.totalSupplyShares) + sharesSupplied);
        m.lastUpdate = uint128(block.timestamp);

        // Update position
        positions[id][onBehalf].supplyShares = uint128(uint256(positions[id][onBehalf].supplyShares) + sharesSupplied);

        // Transfer tokens only if assets > 0
        if (assets > 0) {
            IERC20(marketParams.loanToken).transferFrom(msg.sender, address(this), assets);
        }

        return (assetsSupplied, sharesSupplied);
    }

    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn) {
        Id id = marketParams.id();
        Market storage m = markets[id];
        Position storage p = positions[id][onBehalf];

        // Calculate withdrawal
        if (shares > 0) {
            assetsWithdrawn = shares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
            sharesWithdrawn = shares;
        } else {
            assetsWithdrawn = assets;
            sharesWithdrawn = assets.toSharesUp(m.totalSupplyAssets, m.totalSupplyShares);
        }

        // Update market state
        m.totalSupplyAssets -= uint128(assetsWithdrawn);
        m.totalSupplyShares -= uint128(sharesWithdrawn);
        m.lastUpdate = uint128(block.timestamp);

        // Update position
        p.supplyShares -= uint128(sharesWithdrawn);

        // Transfer tokens
        IERC20(marketParams.loanToken).transfer(receiver, assetsWithdrawn);

        return (assetsWithdrawn, sharesWithdrawn);
    }

    // Borrow/repay stubs (minimal implementation)

    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        Market storage m = markets[id];
        Position storage p = positions[id][onBehalf];

        // Check credit limit
        require(p.borrowShares + assets <= p.collateral, "exceeds credit limit");

        // Check liquidity
        uint256 available = IERC20(marketParams.loanToken).balanceOf(address(this));
        require(available >= assets, "insufficient liquidity");

        // Update position
        p.borrowShares += uint128(assets);

        // Update market state
        m.totalBorrowAssets += uint128(assets);
        m.totalBorrowShares += uint128(assets); // Simplified 1:1

        // Transfer tokens from this contract's balance
        IERC20(marketParams.loanToken).transfer(receiver, assets);

        return (assets, assets);
    }

    function repay(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory)
        external
        returns (uint256, uint256)
    {
        Id id = marketParams.id();
        Market storage m = markets[id];
        Position storage p = positions[id][onBehalf];

        // Update position
        p.borrowShares -= uint128(assets);

        // Update market state
        m.totalBorrowAssets -= uint128(assets);
        m.totalBorrowShares -= uint128(assets); // Simplified 1:1

        // Transfer tokens
        IERC20(marketParams.loanToken).transferFrom(msg.sender, address(this), assets);

        return (assets, assets);
    }

    // View functions

    function expectedSupplyAssets(MarketParams memory marketParams, address user) external view returns (uint256) {
        Id id = marketParams.id();
        Market storage m = markets[id];
        Position storage p = positions[id][user];

        // Handle empty market case
        if (m.totalSupplyShares == 0 || p.supplyShares == 0) {
            return 0;
        }

        return uint256(p.supplyShares).toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
    }

    function expectedBorrowAssets(MarketParams memory marketParams, address user) external view returns (uint256) {
        Id id = marketParams.id();
        Position storage p = positions[id][user];
        return p.borrowShares; // Simplified 1:1
    }

    function expectedMarketBalances(MarketParams memory marketParams)
        external
        view
        returns (
            uint256 _totalSupplyAssets,
            uint256 _totalSupplyShares,
            uint256 _totalBorrowAssets,
            uint256 _totalBorrowShares
        )
    {
        Id id = marketParams.id();
        Market storage m = markets[id];

        return (m.totalSupplyAssets, m.totalSupplyShares, m.totalBorrowAssets, m.totalBorrowShares);
    }

    function supplyShares(Id id, address user) external view returns (uint256) {
        return positions[id][user].supplyShares;
    }

    function borrowShares(Id id, address user) external view returns (uint256) {
        return positions[id][user].borrowShares;
    }

    function collateral(Id id, address user) external view returns (uint256) {
        return positions[id][user].collateral;
    }

    function totalSupplyAssets(Id id) external view returns (uint256) {
        return markets[id].totalSupplyAssets;
    }

    function totalSupplyShares(Id id) external view returns (uint256) {
        return markets[id].totalSupplyShares;
    }

    function totalBorrowAssets(Id id) external view returns (uint256) {
        return markets[id].totalBorrowAssets;
    }

    function totalBorrowShares(Id id) external view returns (uint256) {
        return markets[id].totalBorrowShares;
    }

    function lastUpdate(Id id) external view returns (uint256) {
        return markets[id].lastUpdate;
    }

    function isMarketCreated(Id id) external view returns (bool) {
        return markets[id].lastUpdate != 0;
    }

    // Admin functions

    function createMarket(MarketParams memory marketParams) external {
        Id id = marketParams.id();
        require(markets[id].lastUpdate == 0, "market already created");
        markets[id].lastUpdate = uint128(block.timestamp);
        _marketParams[id] = marketParams;
    }

    function enableIrm(address irm) external {
        isIrmEnabled[irm] = true;
    }

    function enableLltv(uint256 lltv) external {
        isLltvEnabled[lltv] = true;
    }

    function setOwner(address newOwner) external {
        owner = newOwner;
    }

    function setFee(MarketParams memory, uint256 newFee) external {
        fee = newFee;
    }

    function setFeeRecipient(address newFeeRecipient) external {
        feeRecipient = newFeeRecipient;
    }

    // Authorization

    function setAuthorization(address authorized, bool newIsAuthorized) external {
        // Simplified: store globally instead of per-user
        authorizations[Id.wrap(0)][authorized] = newIsAuthorized;
    }

    function setAuthorizationWithSig(Authorization memory, Signature memory) external {
        revert("not implemented");
    }

    function isAuthorized(address, address user) external view returns (bool) {
        return authorizations[Id.wrap(0)][user];
    }

    function nonce(address) external pure returns (uint256) {
        return 0;
    }

    // Liquidation stubs

    function liquidate(MarketParams memory, address, uint256, uint256, bytes memory)
        external
        pure
        returns (uint256, uint256)
    {
        revert("not implemented");
    }

    // Flash loan stub

    function flashLoan(address, uint256, bytes calldata) external pure {
        revert("not implemented");
    }

    // Missing interface functions

    function DOMAIN_SEPARATOR() external pure returns (bytes32) {
        return bytes32(0);
    }

    function idToMarketParams(Id id) external view returns (MarketParams memory) {
        return _marketParams[id];
    }

    function market(Id id) external view returns (Market memory) {
        return markets[id];
    }

    function position(Id id, address user) external view returns (Position memory) {
        return positions[id][user];
    }

    // Supply/withdraw collateral stubs

    function supplyCollateral(MarketParams memory, uint256, address, bytes memory) external pure {
        revert("not implemented");
    }

    function withdrawCollateral(MarketParams memory, uint256, address, address) external pure {
        revert("not implemented");
    }

    // Extra functions for accruing interest

    function accrueInterest(MarketParams memory marketParams) external {
        // No-op for simplicity - just update timestamp
        Id id = marketParams.id();
        markets[id].lastUpdate = uint128(block.timestamp);
    }

    function extSloads(bytes32[] memory slots) external view returns (bytes32[] memory values) {
        values = new bytes32[](slots.length);
        // Return zero values for all slots in this mock
        for (uint256 i = 0; i < slots.length; i++) {
            values[i] = bytes32(0);
        }
    }

    // Test helper to simulate markdown
    function simulateMarkdown(Id id, uint256 lossAmount) external {
        Market storage m = markets[id];
        require(m.totalSupplyAssets >= lossAmount, "loss too large");
        m.totalSupplyAssets -= uint128(lossAmount);
    }

    // Mock setCreditLine for testing
    function setCreditLine(Id id, address borrower, uint256 credit, uint128 premiumRate) external {
        // Check caller is creditLine (must get market params first)
        MarketParams memory params = _marketParams[id];
        require(msg.sender == params.creditLine, "NotCreditLine()");

        // In a real implementation, this would set credit limits
        // For testing, we just store the credit as collateral
        positions[id][borrower].collateral = uint128(credit);
    }
}
