// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseHooksUpgradeable, IERC20, IMorphoCredit, IProtocolConfig, Math, SafeERC20, USD3} from "./USD3.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {ProtocolConfigLib} from "../libraries/ProtocolConfigLib.sol";

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

    /// Whitelist of depositors allowed to 3rd party deposit
    mapping(address => bool) public depositorWhitelist;

    // Subordination management
    address public morphoCredit; // MorphoCredit address to access protocol config

    // Reserved for future use

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event CooldownStarted(address indexed user, uint256 shares, uint256 timestamp);
    event CooldownCancelled(address indexed user);
    event DepositorWhitelistUpdated(address indexed depositor, bool allowed);
    event WithdrawalCompleted(address indexed user, uint256 shares, uint256 assets);

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
    function initialize(address _usd3Token, address _management, address _keeper) external initializer {
        // Initialize BaseStrategy with USD3 as the asset
        // Use management as performance fee recipient (fees will never be charged)
        __BaseStrategy_init(_usd3Token, "sUSD3", _management, _management, _keeper);

        // Get MorphoCredit address from USD3 strategy
        morphoCredit = address(USD3(_usd3Token).morphoCredit());
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
    function _preDepositHook(uint256 assets, uint256 shares, address receiver) internal override {
        if (assets == 0 && shares > 0) {
            assets = TokenizedStrategy.previewMint(shares);
        }

        // Prevent lock bypass and griefing attacks
        // Only allow self-deposits or whitelisted depositors
        require(
            msg.sender == receiver || depositorWhitelist[msg.sender], "sUSD3: Only self or whitelisted deposits allowed"
        );

        // Always extend lock period for valid deposits
        if (assets > 0 || shares > 0) {
            // Read lock duration from ProtocolConfig
            uint256 duration = lockDuration();
            lockedUntil[receiver] = block.timestamp + duration;
        }
    }

    /// @dev Post-withdraw hook to update cooldown after successful withdrawal
    function _postWithdrawHook(uint256 assets, uint256 shares, address receiver, address owner, uint256 maxLoss)
        internal
        override
    {
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
    function _preTransferHook(address from, address to, uint256 amount) internal override {
        // Allow minting (from == 0) and burning (to == 0)
        if (from == address(0) || to == address(0)) return;

        // Check lock period
        require(block.timestamp >= lockedUntil[from], "sUSD3: Cannot transfer during lock period");

        // Check if user has active cooldown
        UserCooldown memory cooldown = cooldowns[from];
        if (cooldown.shares > 0) {
            // User has shares in cooldown, check if trying to transfer them
            // Note: 'this' refers to the sUSD3 strategy contract
            uint256 userBalance = IERC20(address(this)).balanceOf(from);
            uint256 nonCooldownShares = userBalance > cooldown.shares ? userBalance - cooldown.shares : 0;

            // Only allow transfer of non-cooldown shares
            require(amount <= nonCooldownShares, "sUSD3: Cannot transfer shares in cooldown");
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
        require(block.timestamp >= lockedUntil[msg.sender], "Still in lock period");

        // Validate shares against actual balance
        uint256 userBalance = IERC20(address(this)).balanceOf(msg.sender);
        require(shares <= userBalance, "Insufficient balance for cooldown");

        // Read cooldown duration from ProtocolConfig
        uint256 cooldownPeriod = cooldownDuration();

        // Allow updating cooldown with new amount (overwrites previous)
        cooldowns[msg.sender] = UserCooldown({
            cooldownEnd: uint64(block.timestamp + cooldownPeriod),
            windowEnd: uint64(block.timestamp + cooldownPeriod + withdrawalWindow()),
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

    /// @dev Enforces maximum subordination ratio based on market debt (actual or potential)
    /// @param _owner Address to check limit for
    /// @return Maximum deposit amount allowed
    function availableDepositLimit(address _owner) public view override returns (uint256) {
        // Get the subordinated debt cap in USDC terms
        uint256 subordinatedDebtCapUSDC = getSubordinatedDebtCapInUSDC();

        if (subordinatedDebtCapUSDC == 0) {
            // No debt to subordinate, no deposits needed
            return 0;
        }

        uint256 currentUSD3Holdings = asset.balanceOf(address(this));
        uint256 currentHoldingsUSDC = IStrategy(address(asset)).convertToAssets(currentUSD3Holdings);

        if (currentHoldingsUSDC >= subordinatedDebtCapUSDC) {
            // Already at or above the subordination cap
            return 0;
        }

        // Calculate remaining capacity in USDC terms
        uint256 remainingCapacityUSDC = subordinatedDebtCapUSDC - currentHoldingsUSDC;

        // Convert USDC capacity back to USD3 shares
        // This is the maximum USD3 tokens that can be deposited
        return IStrategy(address(asset)).convertToShares(remainingCapacityUSDC);
    }

    /// @dev Enforces lock period, cooldown, and withdrawal window requirements
    /// @param _owner Address to check limit for
    /// @return Maximum withdrawal amount allowed in assets
    function availableWithdrawLimit(address _owner) public view override returns (uint256) {
        // During shutdown, bypass all checks and return available assets
        if (TokenizedStrategy.isShutdown()) {
            // Return all available USD3 (entire balance since sUSD3 holds USD3 directly)
            return asset.balanceOf(address(this));
        }

        // Check initial lock period
        if (block.timestamp < lockedUntil[_owner]) {
            return 0;
        }

        // Determine withdrawal limit based on cooldown state
        uint256 userWithdrawLimit;
        if (cooldownDuration() == 0) {
            // No cooldown required
            userWithdrawLimit = type(uint256).max;
        } else {
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

            userWithdrawLimit = TokenizedStrategy.convertToAssets(cooldown.shares);
        }

        // Check backing requirement
        uint256 subordinatedDebtFloorUSDC = getSubordinatedDebtFloorInUSDC();

        if (subordinatedDebtFloorUSDC == 0) {
            return userWithdrawLimit;
        }

        uint256 currentUSD3Holdings = asset.balanceOf(address(this));
        uint256 currentAssetsUSDC = IStrategy(address(asset)).convertToAssets(currentUSD3Holdings);

        if (currentAssetsUSDC <= subordinatedDebtFloorUSDC) {
            // Cannot withdraw without going below minimum backing
            return 0;
        }

        // Calculate maximum withdrawable while maintaining backing
        uint256 maxWithdrawable = currentAssetsUSDC - subordinatedDebtFloorUSDC;

        // Convert back to USD3 shares for withdrawal
        uint256 maxWithdrawableUSD3 = IStrategy(address(asset)).convertToShares(maxWithdrawable);

        // Return minimum of withdrawal limit and max withdrawable
        return Math.min(userWithdrawLimit, maxWithdrawableUSD3);
    }

    /**
     * @notice Get user's cooldown status
     * @param user Address to check
     * @return cooldownEnd When cooldown expires (0 if no cooldown)
     * @return windowEnd When withdrawal window closes
     * @return shares Number of shares in cooldown
     */
    function getCooldownStatus(address user)
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
     * @notice Get the lock duration from ProtocolConfig
     * @return Lock duration in seconds
     */
    function lockDuration() public view returns (uint256) {
        IProtocolConfig config = IProtocolConfig(IMorphoCredit(morphoCredit).protocolConfig());

        uint256 duration = config.getSusd3LockDuration();
        return duration > 0 ? duration : 90 days; // Default to 90 days if not set
    }

    /**
     * @notice Get the cooldown duration from ProtocolConfig
     * @return Cooldown duration in seconds
     */
    function cooldownDuration() public view returns (uint256) {
        IProtocolConfig config = IProtocolConfig(IMorphoCredit(morphoCredit).protocolConfig());
        return config.getSusd3CooldownPeriod();
    }

    /**
     * @notice Get the withdrawal window from ProtocolConfig
     * @return Withdrawal window duration in seconds
     */
    function withdrawalWindow() public view returns (uint256) {
        IProtocolConfig config = IProtocolConfig(IMorphoCredit(morphoCredit).protocolConfig());
        uint256 window = config.getSusd3WithdrawalWindow();
        return window > 0 ? window : 2 days; // Default to 2 days if not set
    }

    /**
     * @notice Update depositor whitelist status for an address
     * @param _depositor Address to update
     * @param _allowed True to allow extending lock periods, false to disallow
     */
    function setDepositorWhitelist(address _depositor, bool _allowed) external onlyManagement {
        depositorWhitelist[_depositor] = _allowed;
        emit DepositorWhitelistUpdated(_depositor, _allowed);
    }

    /*//////////////////////////////////////////////////////////////
                    SUBORDINATION CALCULATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the maximum subordination ratio from ProtocolConfig
     * @return Maximum subordination ratio in basis points (e.g., 1500 = 15%)
     */
    function maxSubordinationRatio() public view returns (uint256) {
        IProtocolConfig config = IProtocolConfig(IMorphoCredit(morphoCredit).protocolConfig());
        uint256 ratio = config.getTrancheRatio();
        return ratio > 0 ? ratio : 1500; // Default to 15% if not set
    }

    /**
     * @notice Get the minimum backing ratio from ProtocolConfig
     * @return Minimum backing ratio in basis points
     */
    function minBackingRatio() public view returns (uint256) {
        IProtocolConfig config = IProtocolConfig(IMorphoCredit(morphoCredit).protocolConfig());
        return config.config(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO);
    }

    /**
     * @notice Calculate maximum sUSD3 deposits allowed based on debt and subordination ratio
     * @dev Returns the cap amount for subordinated debt based on actual or potential market debt
     * @return Maximum subordinated debt cap, expressed in USDC
     */
    function getSubordinatedDebtCapInUSDC() public view returns (uint256) {
        USD3 usd3 = USD3(address(asset));

        // Get actual borrowed amount
        (,, uint256 totalBorrowAssetsWaUSDC,) = usd3.getMarketLiquidity();
        uint256 actualDebtUSDC = usd3.WAUSDC().convertToAssets(totalBorrowAssetsWaUSDC);

        // Get potential debt based on debt ceiling
        IProtocolConfig config = IProtocolConfig(IMorphoCredit(morphoCredit).protocolConfig());
        uint256 debtCap = config.config(ProtocolConfigLib.DEBT_CAP);

        uint256 potentialDebtUSDC;
        if (debtCap > 0) {
            potentialDebtUSDC = usd3.WAUSDC().convertToAssets(debtCap);
        }
        uint256 maxDebtUSDC = Math.max(actualDebtUSDC, potentialDebtUSDC);

        if (maxDebtUSDC == 0) {
            return 0; // No debt to subordinate
        }

        uint256 maxSubRatio = maxSubordinationRatio(); // e.g., 1500 (15%)

        // Cap on subordinated debt = max(actual, potential) * subordination ratio
        return (maxDebtUSDC * maxSubRatio) / MAX_BPS;
    }

    /**
     * @notice Calculate minimum sUSD3 backing required for current market debt
     * @dev Returns the floor amount of sUSD3 assets needed based on MIN_SUSD3_BACKING_RATIO
     * @return Minimum backing amount required, expressed in USDC
     */
    function getSubordinatedDebtFloorInUSDC() public view returns (uint256) {
        // Get minimum backing ratio
        uint256 backingRatio = minBackingRatio();

        // If backing ratio is 0, no minimum backing required
        if (backingRatio == 0) return 0;

        USD3 usd3 = USD3(address(asset));

        // Get actual borrowed amount
        (,, uint256 totalBorrowAssetsWaUSDC,) = usd3.getMarketLiquidity();
        uint256 debtUSDC = usd3.WAUSDC().convertToAssets(totalBorrowAssetsWaUSDC);

        // Calculate minimum required backing
        return (debtUSDC * backingRatio) / MAX_BPS;
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
