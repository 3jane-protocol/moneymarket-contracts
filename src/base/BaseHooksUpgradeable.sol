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
        _preMintHook(assets, shares, receiver);
        assets = abi.decode(
            _delegateCall(abi.encodeCall(ITokenizedStrategy(address(this)).mint, (shares, receiver))), (uint256)
        );
        _postMintHook(assets, shares, receiver);
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
        _preWithdrawHook(assets, shares, owner, maxLoss);
        shares = abi.decode(
            _delegateCall(
                abi.encodeWithSelector(ITokenizedStrategy.withdraw.selector, assets, receiver, owner, maxLoss)
            ),
            (uint256)
        );
        _postWithdrawHook(assets, shares, owner);
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
        _preRedeemHook(assets, shares, owner, maxLoss);
        assets = abi.decode(
            _delegateCall(abi.encodeWithSelector(ITokenizedStrategy.redeem.selector, shares, receiver, owner, maxLoss)),
            (uint256)
        );
        _postRedeemHook(assets, shares, owner);
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
        _postTransferHook(msg.sender, to, amount);
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
        _postTransferHook(from, to, amount);
        return success;
    }

    /*//////////////////////////////////////////////////////////////
                            HOOKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Can be used to adjust accounting for deposit options that change shares.
     *
     * If the preDepositHook would like to prevent the deposit from occurring it
     * can revert within the hook.
     *
     * @param assets Amount of assets being deposited
     * @param shares Expected shares to receive. 0 if not yet calculated.
     * @param receiver The address receiving the shares
     */
    function _preDepositHook(uint256 assets, uint256 shares, address receiver) internal virtual override {}

    /**
     * @dev Can be used to adjust accounting after a deposit.
     *
     * If the postDepositHook would like to prevent the deposit from occurring it
     * can revert within the hook.
     *
     * @param assets Amount of assets deposited
     * @param shares Amount of shares minted
     * @param receiver The address that received the shares
     */
    function _postDepositHook(uint256 assets, uint256 shares, address receiver) internal virtual override {}

    /**
     * @dev Can be used to adjust accounting for mint options that change assets.
     *
     * @param assets Expected assets to deposit. 0 if not yet calculated.
     * @param shares Amount of shares being minted
     * @param receiver The address receiving the shares
     */
    function _preMintHook(uint256 assets, uint256 shares, address receiver) internal virtual {}

    /**
     * @dev Can be used to adjust accounting after a mint.
     *
     * @param assets Amount of assets deposited
     * @param shares Amount of shares minted
     * @param receiver The address that received the shares
     */
    function _postMintHook(uint256 assets, uint256 shares, address receiver) internal virtual {}

    /**
     * @dev Can be used to adjust accounting for withdrawals.
     *
     * @param assets Amount of assets being withdrawn
     * @param shares Expected shares to burn. 0 if not yet calculated.
     * @param owner The address whose shares are being burned
     * @param maxLoss Maximum acceptable loss in basis points
     */
    function _preWithdrawHook(uint256 assets, uint256 shares, address owner, uint256 maxLoss) internal virtual {}

    /**
     * @dev Can be used to adjust accounting after a withdrawal.
     *
     * @param assets Amount of assets withdrawn
     * @param shares Amount of shares burned
     * @param owner The address whose shares were burned
     */
    function _postWithdrawHook(uint256 assets, uint256 shares, address owner) internal virtual {}

    /**
     * @dev Can be used to adjust accounting for redemptions.
     *
     * @param assets Expected assets to withdraw. 0 if not yet calculated.
     * @param shares Amount of shares being redeemed
     * @param owner The address whose shares are being burned
     * @param maxLoss Maximum acceptable loss in basis points
     */
    function _preRedeemHook(uint256 assets, uint256 shares, address owner, uint256 maxLoss) internal virtual {}

    /**
     * @dev Can be used to adjust accounting after a redemption.
     *
     * @param assets Amount of assets withdrawn
     * @param shares Amount of shares burned
     * @param owner The address whose shares were burned
     */
    function _postRedeemHook(uint256 assets, uint256 shares, address owner) internal virtual {}

    /**
     * @dev Can be used to adjust accounting for transfers.
     *
     * @param from The address sending the shares
     * @param to The address receiving the shares
     * @param amount The amount of shares being transferred
     */
    function _preTransferHook(address from, address to, uint256 amount) internal virtual override {}

    /**
     * @dev Can be used to adjust accounting after a transfer.
     *
     * @param from The address that sent the shares
     * @param to The address that received the shares
     * @param amount The amount of shares transferred
     */
    function _postTransferHook(address from, address to, uint256 amount) internal virtual {}

    /**
     * @dev Optional function for strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * `report` will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during `_harvestAndReport`
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(isShutdown()) {
     *       return;
     *   }
     *
     * @param _amount The amount of asset to attempt to free.
     */
    function _emergencyWithdraw(uint256 _amount) internal virtual override {}
}
