// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IERC20} from "../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseHooksUpgradeable} from "./base/BaseHooksUpgradeable.sol";
import {IUSD3} from "./interfaces/IUSD3.sol";

/**
 * @title NotificationVault
 * @notice General-purpose ERC4626 wrapper that adds a withdrawal cooldown to USD3 (asset = USD3,
 *         shares = USD3n), so wrapped USD3 can serve as money-market collateral without being
 *         unwrappable within a cooldown window.
 * @dev Holds USD3 directly (1:1, no second yield layer) and intentionally disables reporting, so PPS
 *      stays exactly 1 and donations are never reconciled into share price. `usd3` is fixed at
 *      construction (one implementation per USD3).
 *
 *      Trust assumptions:
 *      - USD3 sent directly to the vault is intentionally orphaned (no sweep). This is the same property
 *        that makes the wrapper immune to donation / share-price-inflation attacks.
 */
contract NotificationVault is BaseHooksUpgradeable {
    IUSD3 public immutable usd3;

    uint64 public cooldownDuration;
    uint64 public withdrawalWindow;

    struct UserCooldown {
        uint64 cooldownEnd;
        uint64 windowEnd;
        uint128 shares;
    }

    mapping(address => UserCooldown) public cooldowns;
    mapping(address => bool) public cooldownBypass;

    event CooldownStarted(address indexed user, uint256 shares, uint256 timestamp);
    event CooldownCancelled(address indexed user);
    event WithdrawalCompleted(address indexed user, uint256 shares, uint256 assets);
    event CooldownBypassUpdated(address indexed account, bool allowed);

    error InvalidAddress();
    error InvalidAmount();
    error InvalidCooldownConfig();
    error NoActiveCooldown();
    error InsufficientShares();
    error ReportsDisabled();

    /// @param _usd3 The USD3 strategy this vault wraps; bound for the life of the implementation.
    /// @dev Sets the `usd3` immutable. Immutables live in the implementation bytecode and are read correctly
    ///      through the proxy.
    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(address _usd3) {
        _disableInitializers();
        if (_usd3 == address(0)) revert InvalidAddress();
        usd3 = IUSD3(_usd3);
    }

    /// @notice Initialize the proxy: roles and the fixed cooldown config (USD3 comes from the constructor).
    function initialize(address _management, address _keeper, uint64 _cooldownDuration, uint64 _withdrawalWindow)
        external
        initializer
    {
        if (_management == address(0) || _keeper == address(0)) revert InvalidAddress();
        if (_withdrawalWindow == 0) revert InvalidCooldownConfig();

        cooldownDuration = _cooldownDuration;
        withdrawalWindow = _withdrawalWindow;

        __BaseStrategy_init(address(usd3), "USD3 Notification Vault", _management, _management, _keeper);
    }

    function symbol() external pure returns (string memory) {
        return "USD3n";
    }

    /// @dev No-op: the vault holds USD3 directly and never deploys it elsewhere.
    function _deployFunds(uint256) internal override {}

    /// @dev No-op: funds are always available as USD3 held directly.
    function _freeFunds(uint256) internal override {}

    /// @notice Reporting is disabled so the wrapper never adds a second yield layer or reconciles
    ///         donations into PPS; USD3n stays 1:1 with USD3 on deposit/withdraw alone.
    /// @dev Overrides the keeper-facing entrypoint to revert directly; `_harvestAndReport` below also
    ///      reverts as a backstop for the (now-unreachable) internal report path.
    function report() external pure override returns (uint256, uint256) {
        revert ReportsDisabled();
    }

    /// @dev Reverts: reporting is disabled (see `report`). Implemented only to satisfy the abstract base.
    function _harvestAndReport() internal pure override returns (uint256) {
        revert ReportsDisabled();
    }

    function _preTransferHook(address from, address to, uint256 amount) internal view override {
        if (from == address(0) || to == address(0)) return;
        if (TokenizedStrategy.isShutdown() || cooldownDuration == 0 || cooldownBypass[from]) return;

        UserCooldown memory cooldown = cooldowns[from];
        if (cooldown.shares == 0) return;

        uint256 userBalance = IERC20(address(this)).balanceOf(from);
        uint256 nonCooldownShares = userBalance > cooldown.shares ? userBalance - cooldown.shares : 0;
        if (amount > nonCooldownShares) revert InsufficientShares();
    }

    function _postWithdrawHook(uint256 assets, uint256 shares, address, address owner, uint256) internal override {
        UserCooldown storage cooldown = cooldowns[owner];
        if (cooldown.shares == 0) return;

        if (shares >= cooldown.shares) {
            delete cooldowns[owner];
        } else {
            cooldown.shares -= uint128(shares);
        }

        emit WithdrawalCompleted(owner, shares, assets);
    }

    /// @notice Start (or overwrite) the caller's withdrawal cooldown for `shares`.
    /// @dev Withdrawal/redemption is then only available during the window `[cooldownEnd, windowEnd]`;
    ///      cooled shares are also non-transferable until withdrawn. A new call overwrites any prior cooldown.
    /// @param shares Number of USD3n shares to put into cooldown.
    function startCooldown(uint256 shares) external {
        if (shares == 0) revert InvalidAmount();

        uint256 userBalance = IERC20(address(this)).balanceOf(msg.sender);
        if (shares > userBalance) revert InsufficientShares();
        if (shares > type(uint128).max) revert InvalidAmount();

        uint256 cooldownEnd = block.timestamp + cooldownDuration;
        uint256 windowEnd = cooldownEnd + withdrawalWindow;
        if (windowEnd > type(uint64).max) revert InvalidCooldownConfig();

        cooldowns[msg.sender] =
            UserCooldown({cooldownEnd: uint64(cooldownEnd), windowEnd: uint64(windowEnd), shares: uint128(shares)});

        emit CooldownStarted(msg.sender, shares, block.timestamp);
    }

    /// @notice Cancel the caller's active cooldown (re-locks the shares; a new `startCooldown` is needed to exit).
    function cancelCooldown() external {
        if (cooldowns[msg.sender].shares == 0) revert NoActiveCooldown();
        delete cooldowns[msg.sender];
        emit CooldownCancelled(msg.sender);
    }

    /// @notice Read a user's cooldown state.
    /// @return cooldownEnd Timestamp the cooldown completes (0 if none).
    /// @return windowEnd Timestamp the withdrawal window closes.
    /// @return shares Shares currently in cooldown.
    function getCooldownStatus(address user)
        external
        view
        returns (uint256 cooldownEnd, uint256 windowEnd, uint256 shares)
    {
        UserCooldown memory cooldown = cooldowns[user];
        return (cooldown.cooldownEnd, cooldown.windowEnd, cooldown.shares);
    }

    /// @notice Management toggle: let `account` withdraw/redeem and transfer its own shares without cooldown.
    /// @dev Owner-keyed only — it does not grant ERC20 allowance and cannot move another owner's shares.
    ///      Intended for trusted custody/market addresses that own collateral shares.
    function setCooldownBypass(address account, bool allowed) external onlyManagement {
        if (account == address(0)) revert InvalidAddress();
        cooldownBypass[account] = allowed;
        emit CooldownBypassUpdated(account, allowed);
    }

    function availableDepositLimit(address) public view override returns (uint256) {
        return type(uint256).max;
    }

    function availableWithdrawLimit(address owner) public view override returns (uint256) {
        uint256 idle = asset.balanceOf(address(this));
        if (TokenizedStrategy.isShutdown() || cooldownBypass[owner] || cooldownDuration == 0) return idle;

        UserCooldown memory cooldown = cooldowns[owner];
        if (cooldown.shares == 0) return 0;
        if (block.timestamp < cooldown.cooldownEnd || block.timestamp > cooldown.windowEnd) return 0;

        uint256 cooledAssets = TokenizedStrategy.convertToAssets(cooldown.shares);
        return cooledAssets < idle ? cooledAssets : idle;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     */
    uint256[40] private __gap;
}
