// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {BaseStrategyUpgradeable} from "./BaseStrategyUpgradeable.sol";
import {Hooks} from "@periphery/Bases/Hooks/Hooks.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

/**
 * @title BaseHooksUpgradeable
 * @author Yearn's BaseHooks adapted for upgradeable strategies
 * @notice This contract can be inherited by any strategy wishing to implement
 *         pre or post hooks for deposit, withdraw, transfer, or report functions.
 *
 *         This version:
 *         - Inherits from BaseStrategyUpgradeable instead of BaseHealthCheck
 *         - Uses Yearn's Hooks contract for standardized hook interfaces
 *         - Is compatible with upgradeable proxy patterns
 */
abstract contract BaseHooksUpgradeable is BaseStrategyUpgradeable, Hooks {
    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant MAX_BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                        OVERRIDDEN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit assets and receive shares
     * @param assets Amount of assets to deposit
     * @param receiver Address to receive the shares
     * @return shares Amount of shares minted
     */
    function deposit(uint256 assets, address receiver) external virtual returns (uint256 shares) {
        _preDepositHook(assets, shares, receiver);
        shares = abi.decode(
            _delegateCall(abi.encodeCall(ITokenizedStrategy(address(this)).deposit, (assets, receiver))), (uint256)
        );
        _postDepositHook(assets, shares, receiver);
    }

    /**
     * @notice Mint shares by depositing assets
     * @param shares Amount of shares to mint
     * @param receiver Address to receive the shares
     * @return assets Amount of assets deposited
     */
    function mint(uint256 shares, address receiver) external virtual returns (uint256 assets) {
        _preDepositHook(assets, shares, receiver);
        assets = abi.decode(
            _delegateCall(abi.encodeCall(ITokenizedStrategy(address(this)).mint, (shares, receiver))), (uint256)
        );
        _postDepositHook(assets, shares, receiver);
    }

    /**
     * @notice Withdraw assets by burning shares
     * @param assets Amount of assets to withdraw
     * @param receiver Address to receive the assets
     * @param owner Address whose shares are burned
     * @return shares Amount of shares burned
     */
    function withdraw(uint256 assets, address receiver, address owner) external virtual returns (uint256 shares) {
        return withdraw(assets, receiver, owner, 0);
    }

    /**
     * @notice Withdraw assets with custom max loss
     * @param assets Amount of assets to withdraw
     * @param receiver Address to receive the assets
     * @param owner Address whose shares are burned
     * @param maxLoss Maximum acceptable loss in basis points
     * @return shares Amount of shares burned
     */
    function withdraw(uint256 assets, address receiver, address owner, uint256 maxLoss)
        public
        virtual
        returns (uint256 shares)
    {
        _preWithdrawHook(assets, shares, receiver, owner, maxLoss);
        shares = abi.decode(
            _delegateCall(
                abi.encodeWithSelector(ITokenizedStrategy.withdraw.selector, assets, receiver, owner, maxLoss)
            ),
            (uint256)
        );
        _postWithdrawHook(assets, shares, receiver, owner, maxLoss);
    }

    /**
     * @notice Redeem shares for assets
     * @param shares Amount of shares to redeem
     * @param receiver Address to receive the assets
     * @param owner Address whose shares are burned
     * @return assets Amount of assets withdrawn
     */
    function redeem(uint256 shares, address receiver, address owner) external virtual returns (uint256 assets) {
        return redeem(shares, receiver, owner, MAX_BPS);
    }

    /**
     * @notice Redeem shares with custom max loss
     * @param shares Amount of shares to redeem
     * @param receiver Address to receive the assets
     * @param owner Address whose shares are burned
     * @param maxLoss Maximum acceptable loss in basis points
     * @return assets Amount of assets withdrawn
     */
    function redeem(uint256 shares, address receiver, address owner, uint256 maxLoss)
        public
        virtual
        returns (uint256 assets)
    {
        _preWithdrawHook(assets, shares, receiver, owner, maxLoss);
        assets = abi.decode(
            _delegateCall(abi.encodeWithSelector(ITokenizedStrategy.redeem.selector, shares, receiver, owner, maxLoss)),
            (uint256)
        );
        _postWithdrawHook(assets, shares, receiver, owner, maxLoss);
    }

    /**
     * @notice Transfer shares to another address
     * @param to Address to receive the shares
     * @param amount Amount of shares to transfer
     * @return success Whether the transfer succeeded
     */
    function transfer(address to, uint256 amount) external virtual returns (bool) {
        _preTransferHook(msg.sender, to, amount);
        bool success =
            abi.decode(_delegateCall(abi.encodeCall(ITokenizedStrategy(address(this)).transfer, (to, amount))), (bool));
        _postTransferHook(msg.sender, to, amount, success);
        return success;
    }

    /**
     * @notice Transfer shares from one address to another
     * @param from Address to transfer from
     * @param to Address to transfer to
     * @param amount Amount of shares to transfer
     * @return success Whether the transfer succeeded
     */
    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        _preTransferHook(from, to, amount);
        bool success = abi.decode(
            _delegateCall(abi.encodeCall(ITokenizedStrategy(address(this)).transferFrom, (from, to, amount))), (bool)
        );
        _postTransferHook(from, to, amount, success);
        return success;
    }

    /**
     * @notice Report profit and loss
     * @return profit Amount of profit generated
     * @return loss Amount of loss incurred
     */
    function report() external virtual returns (uint256 profit, uint256 loss) {
        _preReportHook();
        (profit, loss) = _reportInternal();
        _postReportHook(profit, loss);
    }

    /**
     * @dev Internal report execution hook to centralize delegatecall logic.
     */
    function _reportInternal() internal returns (uint256 profit, uint256 loss) {
        (profit, loss) =
            abi.decode(_delegateCall(abi.encodeCall(ITokenizedStrategy(address(this)).report, ())), (uint256, uint256));
    }
}
