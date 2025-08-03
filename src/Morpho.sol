// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

import {
    Id,
    IMorphoStaticTyping,
    IMorphoBase,
    MarketParams,
    Position,
    Market,
    Authorization,
    Signature
} from "./interfaces/IMorpho.sol";
import {
    IMorphoRepayCallback, IMorphoSupplyCallback, IMorphoFlashLoanCallback
} from "./interfaces/IMorphoCallbacks.sol";
import {IIrm} from "./interfaces/IIrm.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IOracle} from "./interfaces/IOracle.sol";

import "./libraries/ConstantsLib.sol";
import {UtilsLib} from "./libraries/UtilsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {MathLib, WAD} from "./libraries/MathLib.sol";
import {SharesMathLib} from "./libraries/SharesMathLib.sol";
import {MarketParamsLib} from "./libraries/MarketParamsLib.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {Initializable} from "../lib/openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @title Morpho
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice The Morpho contract.
abstract contract Morpho is IMorphoStaticTyping, Initializable {
    using MathLib for uint128;
    using MathLib for uint256;
    using UtilsLib for uint256;
    using SharesMathLib for uint256;
    using SafeTransferLib for IERC20;
    using MarketParamsLib for MarketParams;

    /* STORAGE */

    /// @inheritdoc IMorphoBase
    address public owner;
    /// @inheritdoc IMorphoBase
    address public feeRecipient;
    /// @inheritdoc IMorphoStaticTyping
    mapping(Id => mapping(address => Position)) public position;
    /// @inheritdoc IMorphoStaticTyping
    mapping(Id => Market) public market;
    /// @inheritdoc IMorphoBase
    mapping(address => bool) public isIrmEnabled;
    /// @inheritdoc IMorphoBase
    mapping(uint256 => bool) public isLltvEnabled;
    /// @inheritdoc IMorphoBase
    mapping(address => uint256) public nonce;
    /// @inheritdoc IMorphoStaticTyping
    mapping(Id => MarketParams) public idToMarketParams;
    /// @inheritdoc IMorphoBase
    bytes32 public DOMAIN_SEPARATOR;
    /// @dev Storage gap for future upgrades (10 slots).
    uint256[10] private __gap;

    /* INITIALIZER */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param newOwner The initial owner of the contract.
    function __Morpho_init(address newOwner) internal onlyInitializing {
        if (newOwner == address(0)) revert ErrorsLib.ZeroAddress();

        DOMAIN_SEPARATOR = keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(this)));
        owner = newOwner;

        emit EventsLib.SetOwner(newOwner);
    }

    /* MODIFIERS */

    /// @dev Reverts if the caller is not the owner.
    modifier onlyOwner() {
        if (msg.sender != owner) revert ErrorsLib.NotOwner();
        _;
    }

    /* ONLY OWNER FUNCTIONS */

    /// @inheritdoc IMorphoBase
    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == owner) revert ErrorsLib.AlreadySet();

        owner = newOwner;

        emit EventsLib.SetOwner(newOwner);
    }

    /// @inheritdoc IMorphoBase
    function enableIrm(address irm) external onlyOwner {
        if (isIrmEnabled[irm]) revert ErrorsLib.AlreadySet();

        isIrmEnabled[irm] = true;

        emit EventsLib.EnableIrm(irm);
    }

    /// @inheritdoc IMorphoBase
    function enableLltv(uint256 lltv) external onlyOwner {
        if (isLltvEnabled[lltv]) revert ErrorsLib.AlreadySet();
        if (lltv >= WAD) revert ErrorsLib.MaxLltvExceeded();

        isLltvEnabled[lltv] = true;

        emit EventsLib.EnableLltv(lltv);
    }

    /// @inheritdoc IMorphoBase
    function setFee(MarketParams memory marketParams, uint256 newFee) external onlyOwner {
        Id id = marketParams.id();
        if (market[id].lastUpdate == 0) revert ErrorsLib.MarketNotCreated();
        if (newFee == market[id].fee) revert ErrorsLib.AlreadySet();
        if (newFee > MAX_FEE) revert ErrorsLib.MaxFeeExceeded();

        // Accrue interest using the previous fee set before changing it.
        _accrueInterest(marketParams, id);

        // Safe "unchecked" cast.
        market[id].fee = uint128(newFee);

        emit EventsLib.SetFee(id, newFee);
    }

    /// @inheritdoc IMorphoBase
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == feeRecipient) revert ErrorsLib.AlreadySet();

        feeRecipient = newFeeRecipient;

        emit EventsLib.SetFeeRecipient(newFeeRecipient);
    }

    /* MARKET CREATION */

    /// @inheritdoc IMorphoBase
    function createMarket(MarketParams memory marketParams) external {
        Id id = marketParams.id();
        if (!isIrmEnabled[marketParams.irm]) revert ErrorsLib.IrmNotEnabled();
        if (!isLltvEnabled[marketParams.lltv]) revert ErrorsLib.LltvNotEnabled();
        if (market[id].lastUpdate != 0) revert ErrorsLib.MarketAlreadyCreated();

        // Safe "unchecked" cast.
        market[id].lastUpdate = uint128(block.timestamp);
        idToMarketParams[id] = marketParams;

        emit EventsLib.CreateMarket(id, marketParams);

        if (marketParams.irm != address(0)) IIrm(marketParams.irm).borrowRate(marketParams, market[id]);
    }

    /* SUPPLY MANAGEMENT */

    /// @inheritdoc IMorphoBase
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        if (market[id].lastUpdate == 0) revert ErrorsLib.MarketNotCreated();
        if (!UtilsLib.exactlyOneZero(assets, shares)) revert ErrorsLib.InconsistentInput();
        if (onBehalf == address(0)) revert ErrorsLib.ZeroAddress();

        _accrueInterest(marketParams, id);
        _beforeSupply(marketParams, id, onBehalf, assets, shares, data);

        if (assets > 0) shares = assets.toSharesDown(market[id].totalSupplyAssets, market[id].totalSupplyShares);
        else assets = shares.toAssetsUp(market[id].totalSupplyAssets, market[id].totalSupplyShares);

        position[id][onBehalf].supplyShares += shares;
        market[id].totalSupplyShares += shares.toUint128();
        market[id].totalSupplyAssets += assets.toUint128();

        emit EventsLib.Supply(id, msg.sender, onBehalf, assets, shares);

        if (data.length > 0) IMorphoSupplyCallback(msg.sender).onMorphoSupply(assets, data);

        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        return (assets, shares);
    }

    /// @inheritdoc IMorphoBase
    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        if (market[id].lastUpdate == 0) revert ErrorsLib.MarketNotCreated();
        if (!UtilsLib.exactlyOneZero(assets, shares)) revert ErrorsLib.InconsistentInput();
        if (receiver == address(0)) revert ErrorsLib.ZeroAddress();

        _accrueInterest(marketParams, id);
        _beforeWithdraw(marketParams, id, onBehalf, assets, shares);

        if (assets > 0) shares = assets.toSharesUp(market[id].totalSupplyAssets, market[id].totalSupplyShares);
        else assets = shares.toAssetsDown(market[id].totalSupplyAssets, market[id].totalSupplyShares);

        position[id][onBehalf].supplyShares -= shares;
        market[id].totalSupplyShares -= shares.toUint128();
        market[id].totalSupplyAssets -= assets.toUint128();

        if (market[id].totalBorrowAssets > market[id].totalSupplyAssets) revert ErrorsLib.InsufficientLiquidity();

        emit EventsLib.Withdraw(id, msg.sender, onBehalf, receiver, assets, shares);

        IERC20(marketParams.loanToken).safeTransfer(receiver, assets);

        return (assets, shares);
    }

    /* BORROW MANAGEMENT */

    /// @inheritdoc IMorphoBase
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        if (market[id].lastUpdate == 0) revert ErrorsLib.MarketNotCreated();
        if (!UtilsLib.exactlyOneZero(assets, shares)) revert ErrorsLib.InconsistentInput();
        if (receiver == address(0)) revert ErrorsLib.ZeroAddress();

        _accrueInterest(marketParams, id);
        _beforeBorrow(marketParams, id, onBehalf, assets, shares);

        if (assets > 0) shares = assets.toSharesUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);
        else assets = shares.toAssetsDown(market[id].totalBorrowAssets, market[id].totalBorrowShares);

        position[id][onBehalf].borrowShares += shares.toUint128();
        market[id].totalBorrowShares += shares.toUint128();
        market[id].totalBorrowAssets += assets.toUint128();

        if (!_isHealthy(marketParams, id, onBehalf)) revert ErrorsLib.InsufficientCollateral();
        if (market[id].totalBorrowAssets > market[id].totalSupplyAssets) revert ErrorsLib.InsufficientLiquidity();

        emit EventsLib.Borrow(id, msg.sender, onBehalf, receiver, assets, shares);

        _afterBorrow(marketParams, id, onBehalf);

        IERC20(marketParams.loanToken).safeTransfer(receiver, assets);

        return (assets, shares);
    }

    /// @inheritdoc IMorphoBase
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        if (market[id].lastUpdate == 0) revert ErrorsLib.MarketNotCreated();
        if (!UtilsLib.exactlyOneZero(assets, shares)) revert ErrorsLib.InconsistentInput();
        if (onBehalf == address(0)) revert ErrorsLib.ZeroAddress();

        _accrueInterest(marketParams, id);
        _beforeRepay(marketParams, id, onBehalf, assets, shares);

        if (assets > 0) shares = assets.toSharesDown(market[id].totalBorrowAssets, market[id].totalBorrowShares);
        else assets = shares.toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);

        position[id][onBehalf].borrowShares -= shares.toUint128();
        market[id].totalBorrowShares -= shares.toUint128();
        market[id].totalBorrowAssets = UtilsLib.zeroFloorSub(market[id].totalBorrowAssets, assets).toUint128();

        // `assets` may be greater than `totalBorrowAssets` by 1.
        emit EventsLib.Repay(id, msg.sender, onBehalf, assets, shares);

        _afterRepay(marketParams, id, onBehalf, assets);

        if (data.length > 0) IMorphoRepayCallback(msg.sender).onMorphoRepay(assets, data);

        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        return (assets, shares);
    }

    /* LIQUIDATION - REMOVED */

    // Liquidation logic has been removed in favor of the markdown system.
    // The markdown system replaces traditional liquidations with dynamic debt write-offs
    // managed by an external markdown manager contract.

    /* FLASH LOANS - REMOVED */

    // Flash loan logic has been removed in favor of multi-block unsecured loans.

    /* AUTHORIZATION - REMOVED */

    // Authorization logic has been removed.
    // All borrows will be executed via a wrapper helper which performs fraud checks.
    // All withdraws will be executed by a single yield-bearing dollar contract.

    /* INTEREST MANAGEMENT */

    /// @inheritdoc IMorphoBase
    function accrueInterest(MarketParams memory marketParams) external {
        Id id = marketParams.id();
        if (market[id].lastUpdate == 0) revert ErrorsLib.MarketNotCreated();

        _accrueInterest(marketParams, id);
    }

    /// @dev Accrues interest for the given market `marketParams`.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    function _accrueInterest(MarketParams memory marketParams, Id id) internal {
        uint256 elapsed = block.timestamp - market[id].lastUpdate;
        if (elapsed == 0) return;

        if (marketParams.irm != address(0)) {
            uint256 borrowRate = IIrm(marketParams.irm).borrowRate(marketParams, market[id]);
            uint256 interest = market[id].totalBorrowAssets.wMulDown(borrowRate.wTaylorCompounded(elapsed));
            market[id].totalBorrowAssets += interest.toUint128();
            market[id].totalSupplyAssets += interest.toUint128();

            uint256 feeShares;
            if (market[id].fee != 0) {
                uint256 feeAmount = interest.wMulDown(market[id].fee);
                // The fee amount is subtracted from the total supply in this calculation to compensate for the fact
                // that total supply is already increased by the full interest (including the fee amount).
                feeShares =
                    feeAmount.toSharesDown(market[id].totalSupplyAssets - feeAmount, market[id].totalSupplyShares);
                position[id][feeRecipient].supplyShares += feeShares;
                market[id].totalSupplyShares += feeShares.toUint128();
            }

            emit EventsLib.AccrueInterest(id, borrowRate, interest, feeShares);
        }

        // Safe "unchecked" cast.
        market[id].lastUpdate = uint128(block.timestamp);
    }

    /* HEALTH CHECK */

    /// @dev Returns whether the position of `borrower` in the given market `marketParams` is healthy.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    function _isHealthy(MarketParams memory marketParams, Id id, address borrower)
        internal
        view
        virtual
        returns (bool)
    {
        if (position[id][borrower].borrowShares == 0) return true;

        uint256 collateralPrice = IOracle(marketParams.oracle).price();

        return _isHealthy(marketParams, id, borrower, collateralPrice);
    }

    /// @dev Returns whether the position of `borrower` in the given market `marketParams` with the given
    /// `collateralPrice` is healthy.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    /// @dev Rounds in favor of the protocol, so one might not be able to borrow exactly `maxBorrow` but one unit less.
    function _isHealthy(MarketParams memory marketParams, Id id, address borrower, uint256 collateralPrice)
        internal
        view
        virtual
        returns (bool)
    {
        uint256 borrowed = uint256(position[id][borrower].borrowShares).toAssetsUp(
            market[id].totalBorrowAssets, market[id].totalBorrowShares
        );
        uint256 maxBorrow = uint256(position[id][borrower].collateral).mulDivDown(collateralPrice, ORACLE_PRICE_SCALE)
            .wMulDown(marketParams.lltv);

        return maxBorrow >= borrowed;
    }

    /* HOOKS */

    /// @dev Hook called before supply operations to allow for particular pre-processing.
    /// @param marketParams The market parameters.
    /// @param id The market id.
    /// @param onBehalf The address that will receive the debt.
    /// @param assets The amount of assets to borrow.
    /// @param shares The amount of shares to borrow.
    /// @param data Additional data to pass to the callback.
    function _beforeSupply(
        MarketParams memory marketParams,
        Id id,
        address onBehalf,
        uint256 assets,
        uint256 shares,
        bytes calldata data
    ) internal virtual {}

    /// @dev Hook called before withdraw operations to allow for particular pre-processing.
    /// @param marketParams The market parameters.
    /// @param id The market id.
    /// @param onBehalf The address that will receive the debt.
    /// @param assets The amount of assets to borrow.
    /// @param shares The amount of shares to borrow.
    function _beforeWithdraw(MarketParams memory marketParams, Id id, address onBehalf, uint256 assets, uint256 shares)
        internal
        virtual
    {}

    /// @dev Hook called before borrow operations to allow for premium accrual or other pre-processing.
    /// @param marketParams The market parameters.
    /// @param id The market id.
    /// @param onBehalf The address that will receive the debt.
    /// @param assets The amount of assets to borrow.
    /// @param shares The amount of shares to borrow.
    function _beforeBorrow(MarketParams memory marketParams, Id id, address onBehalf, uint256 assets, uint256 shares)
        internal
        virtual
    {}

    /// @dev Hook called before repay operations to allow for premium accrual or other pre-processing.
    /// @param marketParams The market parameters.
    /// @param id The market id.
    /// @param onBehalf The address whose debt is being repaid.
    /// @param assets The amount of assets to repay.
    /// @param shares The amount of shares to repay.
    function _beforeRepay(MarketParams memory marketParams, Id id, address onBehalf, uint256 assets, uint256 shares)
        internal
        virtual
    {}

    /// @dev Hook called after borrow operations to allow for post-processing.
    /// @param marketParams The market parameters.
    /// @param id The market id.
    /// @param onBehalf The address that borrowed.
    function _afterBorrow(MarketParams memory marketParams, Id id, address onBehalf) internal virtual {}

    /// @dev Hook called after repay operations to allow for post-processing.
    /// @param marketParams The market parameters.
    /// @param id The market id.
    /// @param onBehalf The address whose debt was repaid.
    /// @param assets The amount of assets repaid.
    function _afterRepay(MarketParams memory marketParams, Id id, address onBehalf, uint256 assets) internal virtual {}

    /* STORAGE VIEW */

    /// @inheritdoc IMorphoBase
    function extSloads(bytes32[] calldata slots) external view returns (bytes32[] memory res) {
        uint256 nSlots = slots.length;

        res = new bytes32[](nSlots);

        for (uint256 i; i < nSlots;) {
            bytes32 slot = slots[i++];

            assembly ("memory-safe") {
                mstore(add(res, mul(i, 32)), sload(slot))
            }
        }
    }
}
