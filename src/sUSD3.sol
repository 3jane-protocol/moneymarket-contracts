// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseHooksUpgradeable} from "./base/BaseHooksUpgradeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IProtocolConfig} from "@3jane-morpho-blue/interfaces/IProtocolConfig.sol";
import {IMorpho, IMorphoCredit} from "@3jane-morpho-blue/interfaces/IMorpho.sol";
import {USD3} from "./USD3.sol";

/**
 * @title sUSD3
 * @notice Subordinate tranche strategy that accepts USD3 deposits and provides levered yield
 * @dev Inherits from BaseHooksUpgradeable to maintain consistency with USD3 architecture
 *
 * Key features:
 * - Configurable lock period for new deposits (via ProtocolConfig)
 * - Configurable cooldown period (via ProtocolConfig) + withdrawal window (local management)
 * - Partial cooldown support for flexible withdrawals
 * - Cooldown updates overwrite previous settings
 * - First-loss absorption protects USD3 holders
 * - Maximum subordination ratio enforcement (via ProtocolConfig)
 * - Automatic yield distribution from USD3 strategy
 * - Dynamic parameter management through ProtocolConfig integration
 * - Full withdrawal clears both lock and cooldown states
 */
contract sUSD3 is BaseHooksUpgradeable {
    using SafeERC20 for ERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                            STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Tracks user cooldown state (packed into single storage slot)
    struct UserCooldown {
        uint64 cooldownEnd; // When cooldown expires (8 bytes)
        uint64 windowEnd; // When withdrawal window closes (8 bytes)
        uint128 shares; // Shares locked for withdrawal (16 bytes)
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // MAX_BPS is inherited from BaseHooksUpgradeable

    /*//////////////////////////////////////////////////////////////
                            STORAGE
    //////////////////////////////////////////////////////////////*/

    // Cooldown tracking
    mapping(address => UserCooldown) public cooldowns;
    mapping(address => uint256) public lockedUntil; // Initial lock tracking

    // Whitelist of depositors allowed to extend lock periods
    mapping(address => bool) public depositorWhitelist;

    // Configurable parameters (only withdrawalWindow is locally managed)
    uint256 public withdrawalWindow; // Window to complete withdrawal (default 2 days)

    // Subordination management
    address public morphoCredit; // MorphoCredit address to access protocol config

    // Reserved for future use

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event CooldownStarted(
        address indexed user,
        uint256 shares,
        uint256 timestamp
    );
    event CooldownCancelled(address indexed user);
    event DepositorWhitelistUpdated(address indexed depositor, bool allowed);
    event WithdrawalCompleted(
        address indexed user,
        uint256 shares,
        uint256 assets
    );
    event WithdrawalWindowUpdated(uint256 newWindow);

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the sUSD3 strategy
     * @param _usd3Token Address of USD3 token (the asset)
     * @param _management Management address
     * @param _keeper Keeper address
     */
    function initialize(
        address _usd3Token,
        address _management,
        address _keeper
    ) external initializer {
        // Initialize BaseStrategy with USD3 as the asset
        // Use management as performance fee recipient (fees will never be charged)
        __BaseStrategy_init(
            _usd3Token,
            "sUSD3",
            _management,
            _management,
            _keeper
        );

        // Get MorphoCredit address from USD3 strategy
        morphoCredit = address(USD3(_usd3Token).morphoCredit());

        // Set default withdrawal window (locally managed)
        withdrawalWindow = 2 days;
    }

    /**
     * @notice Get the symbol for the sUSD3 token
     * @return Symbol string "sUSD3"
     */
    function symbol() external pure returns (string memory) {
        return "sUSD3";
    }

    /*//////////////////////////////////////////////////////////////
                        CORE STRATEGY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev sUSD3 holds USD3 tokens directly without deploying elsewhere
    /// @param _amount Amount to deploy (unused)
    function _deployFunds(uint256 _amount) internal override {
        // USD3 tokens stay in strategy (not deployed elsewhere)
        // Lock tracking is handled in deposit/mint overrides
    }

    /// @dev Funds are always available as USD3 tokens are held directly
    /// @param _amount Amount to free (unused)
    function _freeFunds(uint256 _amount) internal override {
        // Funds are already in the strategy, nothing to do
        // This is called during withdrawals but cooldown is enforced elsewhere
    }

    /// @dev Returns USD3 balance; yield is automatically received as USD3 mints shares to us
    /// @return Total USD3 tokens held by the strategy
    function _harvestAndReport() internal override returns (uint256) {
        // USD3 automatically mints shares to us during its report()
        // We just need to return our current balance
        // Any yield received is reflected in our USD3 token balance
        return asset.balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                        HOOKS IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Pre-deposit hook to track lock period (handles both deposit and mint)
    function _preDepositHook(
        uint256 assets,
        uint256 shares,
        address receiver
    ) internal override {
        if (assets == 0 && shares > 0) {
            assets = TokenizedStrategy.previewMint(shares);
        }

        // Prevent lock bypass and griefing attacks
        // Only allow self-deposits or whitelisted depositors
        require(
            msg.sender == receiver || depositorWhitelist[msg.sender],
            "sUSD3: Only self or whitelisted deposits allowed"
        );

        // Always extend lock period for valid deposits
        if (assets > 0 || shares > 0) {
            // Read lock duration from ProtocolConfig
            uint256 duration = lockDuration();
            lockedUntil[receiver] = block.timestamp + duration;
        }
    }

    /// @dev Post-withdraw hook to update cooldown after successful withdrawal
    function _postWithdrawHook(
        uint256 assets,
        uint256 shares,
        address receiver,
        address owner,
        uint256 maxLoss
    ) internal override {
        // Update cooldown after successful withdrawal
        UserCooldown storage cooldown = cooldowns[owner];
        if (cooldown.shares > 0) {
            if (shares >= cooldown.shares) {
                // Full withdrawal - clear the cooldown
                delete cooldowns[owner];
            } else {
                // Partial withdrawal - reduce cooldown shares
                cooldown.shares -= uint128(shares);
            }
            emit WithdrawalCompleted(owner, shares, assets);
        }

        // Clear lock timestamp if fully withdrawn
        if (TokenizedStrategy.balanceOf(owner) == 0) {
            delete lockedUntil[owner];
        }
    }

    /**
     * @notice Prevent transfers during lock period or active cooldown
     * @dev Override from BaseHooksUpgradeable to enforce lock and cooldown
     * @param from Address transferring shares
     * @param to Address receiving shares
     * @param amount Amount of shares being transferred
     */
    function _preTransferHook(
        address from,
        address to,
        uint256 amount
    ) internal override {
        // Allow minting (from == 0) and burning (to == 0)
        if (from == address(0) || to == address(0)) return;

        // Check lock period
        require(
            block.timestamp >= lockedUntil[from],
            "sUSD3: Cannot transfer during lock period"
        );

        // Check if user has active cooldown
        UserCooldown memory cooldown = cooldowns[from];
        if (cooldown.shares > 0) {
            // User has shares in cooldown, check if trying to transfer them
            // Note: 'this' refers to the sUSD3 strategy contract
            uint256 userBalance = IERC20(address(this)).balanceOf(from);
            uint256 nonCooldownShares = userBalance > cooldown.shares
                ? userBalance - cooldown.shares
                : 0;

            // Only allow transfer of non-cooldown shares
            require(
                amount <= nonCooldownShares,
                "sUSD3: Cannot transfer shares in cooldown"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                        COOLDOWN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Start cooldown for withdrawal
     * @param shares Number of shares to cooldown for withdrawal
     */
    function startCooldown(uint256 shares) external {
        require(shares > 0, "Invalid shares");
        require(
            block.timestamp >= lockedUntil[msg.sender],
            "Still in lock period"
        );
        // Note: Balance check will be enforced during actual withdrawal

        // Read cooldown duration from ProtocolConfig
        uint256 cooldownPeriod = cooldownDuration();

        // Allow updating cooldown with new amount (overwrites previous)
        cooldowns[msg.sender] = UserCooldown({
            cooldownEnd: uint64(block.timestamp + cooldownPeriod),
            windowEnd: uint64(
                block.timestamp + cooldownPeriod + withdrawalWindow
            ),
            shares: uint128(shares)
        });

        emit CooldownStarted(msg.sender, shares, block.timestamp);
    }

    /**
     * @notice Cancel active cooldown
     * @dev Resets cooldown state, requiring user to start new cooldown to withdraw
     */
    function cancelCooldown() external {
        require(cooldowns[msg.sender].shares > 0, "No active cooldown");
        delete cooldowns[msg.sender];
        emit CooldownCancelled(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Enforces maximum 15% subordination ratio (sUSD3's USD3 holdings relative to USD3 total supply)
    /// @param _owner Address to check limit for
    /// @return Maximum deposit amount allowed
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        // Check subordination ratio based on USD3 total supply
        uint256 usd3TotalSupply = IERC20(asset).totalSupply();

        // If USD3 has no supply, no deposits allowed
        if (usd3TotalSupply == 0) {
            return 0;
        }

        // Get current USD3 holdings by this sUSD3 contract
        uint256 susd3Usd3Holdings = asset.balanceOf(address(this));

        // Get max subordination ratio from ProtocolConfig
        uint256 maxRatio = maxSubordinationRatio();

        // Calculate max USD3 that sUSD3 can hold (15% of USD3 total supply)
        uint256 maxUsd3Allowed = (usd3TotalSupply * maxRatio) / MAX_BPS;

        if (susd3Usd3Holdings >= maxUsd3Allowed) {
            return 0; // Already at max subordination
        }

        // Return remaining capacity (in USD3 tokens)
        return maxUsd3Allowed - susd3Usd3Holdings;
    }

    /// @dev Enforces lock period, cooldown, and withdrawal window requirements
    /// @param _owner Address to check limit for
    /// @return Maximum withdrawal amount allowed in assets
    function availableWithdrawLimit(
        address _owner
    ) public view override returns (uint256) {
        // During shutdown, bypass all checks and return available assets
        if (TokenizedStrategy.isShutdown()) {
            // Return all available USD3 (entire balance since sUSD3 holds USD3 directly)
            return asset.balanceOf(address(this));
        }

        // Check initial lock period
        if (block.timestamp < lockedUntil[_owner]) {
            return 0;
        }

        UserCooldown memory cooldown = cooldowns[_owner];

        // No cooldown started - cannot withdraw
        if (cooldown.shares == 0) {
            return 0;
        }

        // Still in cooldown period
        if (block.timestamp < cooldown.cooldownEnd) {
            return 0;
        }

        // Window expired - must restart cooldown
        if (block.timestamp > cooldown.windowEnd) {
            return 0;
        }

        // Within valid withdrawal window - return withdrawable amount in assets
        return TokenizedStrategy.convertToAssets(cooldown.shares);
    }

    /**
     * @notice Get user's cooldown status
     * @param user Address to check
     * @return cooldownEnd When cooldown expires (0 if no cooldown)
     * @return windowEnd When withdrawal window closes
     * @return shares Number of shares in cooldown
     */
    function getCooldownStatus(
        address user
    )
        external
        view
        returns (uint256 cooldownEnd, uint256 windowEnd, uint256 shares)
    {
        UserCooldown memory cooldown = cooldowns[user];
        return (cooldown.cooldownEnd, cooldown.windowEnd, cooldown.shares);
    }

    /*//////////////////////////////////////////////////////////////
                        MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the maximum subordination ratio from ProtocolConfig
     * @return Maximum subordination ratio in basis points
     */
    function maxSubordinationRatio() public view returns (uint256) {
        IProtocolConfig config = IProtocolConfig(
            IMorphoCredit(morphoCredit).protocolConfig()
        );

        uint256 ratio = config.getTrancheRatio();
        return ratio > 0 ? ratio : 1500; // Default to 15% if not set
    }

    /**
     * @notice Get the lock duration from ProtocolConfig
     * @return Lock duration in seconds
     */
    function lockDuration() public view returns (uint256) {
        IProtocolConfig config = IProtocolConfig(
            IMorphoCredit(morphoCredit).protocolConfig()
        );

        uint256 duration = config.getSusd3LockDuration();
        return duration > 0 ? duration : 90 days; // Default to 90 days if not set
    }

    /**
     * @notice Get the cooldown duration from ProtocolConfig
     * @return Cooldown duration in seconds
     */
    function cooldownDuration() public view returns (uint256) {
        IProtocolConfig config = IProtocolConfig(
            IMorphoCredit(morphoCredit).protocolConfig()
        );

        uint256 duration = config.getSusd3CooldownPeriod();
        return duration > 0 ? duration : 7 days; // Default to 7 days if not set
    }

    /**
     * @notice Set the withdrawal window duration
     * @param _withdrawalWindow Window duration in seconds (1-7 days)
     * @dev Only callable by management
     */
    function setWithdrawalWindow(
        uint256 _withdrawalWindow
    ) external onlyManagement {
        require(
            _withdrawalWindow >= 1 days && _withdrawalWindow <= 7 days,
            "Invalid window"
        );
        withdrawalWindow = _withdrawalWindow;
        emit WithdrawalWindowUpdated(_withdrawalWindow);
    }

    /**
     * @notice Update depositor whitelist status for an address
     * @param _depositor Address to update
     * @param _allowed True to allow extending lock periods, false to disallow
     */
    function setDepositorWhitelist(
        address _depositor,
        bool _allowed
    ) external onlyManagement {
        depositorWhitelist[_depositor] = _allowed;
        emit DepositorWhitelistUpdated(_depositor, _allowed);
    }

    /*//////////////////////////////////////////////////////////////
                        STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     */
    uint256[40] private __gap;
}
