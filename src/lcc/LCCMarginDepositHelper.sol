// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "../../lib/openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {ILCCMarginDepositHelper} from "./interfaces/ILCCMarginDepositHelper.sol";
import {ILCCVault} from "./interfaces/ILCCVault.sol";
import {IStataTokenV2} from "./interfaces/IStataTokenV2.sol";

interface ILCCMarginDepositFactory {
    function isVault(address vault) external view returns (bool);
}

/// @title LCCMarginDepositHelper
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Wraps USDC, USDT, or their Aave aTokens into static aTokens and deposits them for the caller.
/// @dev The beneficiary is always msg.sender. This contract has no delegated-deposit, arbitrary-call, rescue,
/// ownership, or upgrade surface.
contract LCCMarginDepositHelper is ILCCMarginDepositHelper, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address public immutable override factory;
    address public immutable override usdc;
    address public immutable override aEthUSDC;
    address public immutable override waEthUSDC;
    address public immutable override usdt;
    address public immutable override aEthUSDT;
    address public immutable override waEthUSDT;

    constructor(address factory_, address waEthUSDC_, address waEthUSDT_) {
        if (factory_ == address(0) || waEthUSDC_ == address(0) || waEthUSDT_ == address(0)) revert ZeroAddress();
        if (factory_.code.length == 0 || waEthUSDC_.code.length == 0 || waEthUSDT_.code.length == 0) {
            revert InvalidStataToken();
        }

        (address usdc_, address aEthUSDC_) = _stataWiring(waEthUSDC_);
        (address usdt_, address aEthUSDT_) = _stataWiring(waEthUSDT_);
        if (
            usdc_ == usdt_ || aEthUSDC_ == aEthUSDT_ || waEthUSDC_ == waEthUSDT_ || usdc_ == aEthUSDC_
                || usdt_ == aEthUSDT_
        ) revert InvalidStataToken();

        factory = factory_;
        usdc = usdc_;
        aEthUSDC = aEthUSDC_;
        waEthUSDC = waEthUSDC_;
        usdt = usdt_;
        aEthUSDT = aEthUSDT_;
        waEthUSDT = waEthUSDT_;
    }

    function depositUSDC(DepositParams calldata params) external nonReentrant returns (uint256 commitment) {
        return _depositUnderlying(params, IERC20(usdc), IStataTokenV2(waEthUSDC));
    }

    function depositAethUSDC(DepositParams calldata params) external nonReentrant returns (uint256 commitment) {
        return _depositAToken(params, IERC20(aEthUSDC), IStataTokenV2(waEthUSDC));
    }

    function depositUSDT(DepositParams calldata params) external nonReentrant returns (uint256 commitment) {
        return _depositUnderlying(params, IERC20(usdt), IStataTokenV2(waEthUSDT));
    }

    function depositAethUSDT(DepositParams calldata params) external nonReentrant returns (uint256 commitment) {
        return _depositAToken(params, IERC20(aEthUSDT), IStataTokenV2(waEthUSDT));
    }

    function _depositUnderlying(DepositParams calldata params, IERC20 input, IStataTokenV2 stata)
        private
        returns (uint256 commitment)
    {
        _validateVault(params.vault, address(stata));
        uint256 maximum = stata.maxDeposit(address(this));
        if (params.amountIn > maximum) revert MaxDepositExceeded(params.amountIn, maximum);

        input.safeTransferFrom(msg.sender, address(this), params.amountIn);

        input.forceApprove(address(stata), params.amountIn);
        uint256 returnedShares = stata.deposit(params.amountIn, address(this));
        input.forceApprove(address(stata), 0);

        return _depositMargin(params, stata, returnedShares);
    }

    function _depositAToken(DepositParams calldata params, IERC20 input, IStataTokenV2 stata)
        private
        returns (uint256 commitment)
    {
        _validateVault(params.vault, address(stata));

        input.safeTransferFrom(msg.sender, address(this), params.amountIn);

        input.forceApprove(address(stata), params.amountIn);
        uint256 returnedShares = stata.depositATokens(params.amountIn, address(this));
        input.forceApprove(address(stata), 0);

        return _depositMargin(params, stata, returnedShares);
    }

    function _depositMargin(DepositParams calldata params, IStataTokenV2 stata, uint256 marginShares)
        private
        returns (uint256 commitment)
    {
        if (marginShares < params.minMarginShares) {
            revert InsufficientMarginShares(marginShares, params.minMarginShares);
        }

        IERC20(address(stata)).forceApprove(params.vault, marginShares);
        commitment = ILCCVault(params.vault)
            .deposit(
                marginShares,
                msg.sender,
                params.minCommitment,
                params.maxCommitment,
                params.allowPendingActivation,
                params.deadline
            );
        IERC20(address(stata)).forceApprove(params.vault, 0);
    }

    function _validateVault(address vault, address expectedMarginAsset) private view {
        if (!ILCCMarginDepositFactory(factory).isVault(vault)) revert UnregisteredVault();
        if (ILCCVault(vault).assetConfig().marginAsset != expectedMarginAsset) revert WrongMarginAsset();
    }

    function _stataWiring(address stata) private view returns (address asset_, address aToken_) {
        try IStataTokenV2(stata).asset() returns (address value) {
            asset_ = value;
        } catch {
            revert InvalidStataToken();
        }
        try IStataTokenV2(stata).aToken() returns (address value) {
            aToken_ = value;
        } catch {
            revert InvalidStataToken();
        }
        if (asset_ == address(0) || aToken_ == address(0) || asset_.code.length == 0 || aToken_.code.length == 0) {
            revert InvalidStataToken();
        }
    }
}
