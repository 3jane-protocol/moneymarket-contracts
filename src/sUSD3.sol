// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseHooksUpgradeable} from "./base/BaseHooksUpgradeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {USD3} from "./USD3.sol";

/**
 * @title sUSD3
 * @notice Subordinate tranche strategy that accepts USD3 deposits and provides levered yield
 * @dev Inherits from BaseHooksUpgradeable to maintain consistency with USD3 architecture
 *      
 * Key features:
 * - 90-day initial lock period for new deposits
 * - 7-day cooldown + 2-day withdrawal window
 * - Partial cooldown support (better UX than all-or-nothing)
 * - First-loss absorption for USD3 protection
 * - Maximum 15% subordination ratio enforcement
 */
contract sUSD3 is BaseHooksUpgradeable {
    using SafeERC20 for ERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                            STRUCTS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Tracks user cooldown state
    struct UserCooldown {
        uint256 cooldownEnd;      // When cooldown expires
        uint256 windowEnd;         // When withdrawal window closes
        uint256 shares;            // Shares locked for withdrawal
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/
    
    // MAX_BPS is inherited from BaseHooksUpgradeable
    uint256 public constant MAX_SUBORDINATION_RATIO = 1500; // 15% in basis points

    /*//////////////////////////////////////////////////////////////
                            STORAGE
    //////////////////////////////////////////////////////////////*/
    
    // Cooldown tracking
    mapping(address => UserCooldown) public cooldowns;
    mapping(address => uint256) public lockedUntil;  // Initial lock tracking
    
    // Configurable parameters
    uint256 public lockDuration;        // Initial lock period (default 90 days)
    uint256 public cooldownDuration;    // Cooldown period (default 7 days)  
    uint256 public withdrawalWindow;    // Window to complete withdrawal (default 2 days)
    
    // Subordination management
    address public usd3Strategy;        // USD3 strategy address for ratio checks
    
    // Yield tracking
    uint256 public accumulatedYield;    // Yield received from USD3
    uint256 public lastYieldUpdate;     // Last time yield was updated
    
    // Loss tracking
    uint256 public totalLossesAbsorbed; // Total losses absorbed by sUSD3
    uint256 public lastLossTime;        // Last time losses were absorbed

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/
    
    event CooldownStarted(address indexed user, uint256 shares, uint256 timestamp);
    event CooldownCancelled(address indexed user);
    event WithdrawalCompleted(address indexed user, uint256 shares, uint256 assets);
    event LossAbsorbed(uint256 amount, uint256 timestamp);
    event YieldReceived(uint256 amount, address indexed from);
    event USD3StrategyUpdated(address newStrategy);
    event LockDurationUpdated(uint256 newDuration);
    event CooldownDurationUpdated(uint256 newDuration);
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
     * @param _name Name for the strategy token
     * @param _management Management address
     * @param _performanceFeeRecipient Performance fee recipient
     * @param _keeper Keeper address
     */
    function initialize(
        address _usd3Token,
        string memory _name,
        address _management,
        address _performanceFeeRecipient,
        address _keeper
    ) external initializer {
        // Initialize BaseStrategy with USD3 as the asset
        __BaseStrategy_init(_usd3Token, _name, _management, _performanceFeeRecipient, _keeper);
        
        // Set default durations
        lockDuration = 90 days;
        cooldownDuration = 7 days;
        withdrawalWindow = 2 days;
        
        // Note: usd3Strategy will be set by management after both contracts are deployed
    }

    function symbol() external pure returns (string memory) {
        return "sUSD3";
    }

    /*//////////////////////////////////////////////////////////////
                        CORE STRATEGY FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @dev Deploy funds - for sUSD3, we keep USD3 tokens in the strategy
     * @param _amount Amount to deploy (not used as we don't deploy elsewhere)
     */
    function _deployFunds(uint256 _amount) internal override {
        // USD3 tokens stay in strategy (not deployed elsewhere)
        // Lock tracking is handled in deposit/mint overrides
    }

    /**
     * @dev Free funds - for sUSD3, funds are already available
     * @param _amount Amount to free (not used as funds are already free)
     */
    function _freeFunds(uint256 _amount) internal override {
        // Funds are already in the strategy, nothing to do
        // This is called during withdrawals but cooldown is enforced elsewhere
    }

    /**
     * @dev Harvest and report - account for any yield or losses
     * @return Total assets held by the strategy
     */
    function _harvestAndReport() internal override returns (uint256) {
        // First, try to claim any pending yield from USD3
        if (usd3Strategy != address(0)) {
            try USD3(usd3Strategy).claimYieldDistribution() returns (uint256 claimed) {
                if (claimed > 0) {
                    accumulatedYield += claimed;
                    lastYieldUpdate = block.timestamp;
                    emit YieldReceived(claimed, usd3Strategy);
                }
            } catch {
                // Silently handle if claim fails
            }
        }
        
        // Return total USD3 tokens held
        return IERC20(_asset).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                        HOOKS IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @dev Set/extend lock period on each deposit
     */
    function _setInitialLockIfNeeded(address receiver, uint256 assets, uint256 shares) private {
        // Each deposit extends lock period for entire balance
        if (assets > 0 || shares > 0) {
            lockedUntil[receiver] = block.timestamp + lockDuration;
        }
    }

    /**
     * @dev Pre-deposit hook to track lock period on first deposit
     */
    function _preDepositHook(
        uint256 assets,
        uint256 shares,
        address receiver
    ) internal override {
        _setInitialLockIfNeeded(receiver, assets, shares);
    }

    /**
     * @dev Pre-mint hook to track lock period on first mint
     * Must match deposit hook to prevent lock bypass
     */
    function _preMintHook(
        uint256 assets,
        uint256 shares,
        address receiver
    ) internal override {
        // For mint(), we need to calculate the assets that will be deposited
        uint256 assetsNeeded = ITokenizedStrategy(address(this)).previewMint(shares);
        _setInitialLockIfNeeded(receiver, assetsNeeded, shares);
    }

    /**
     * @dev Update cooldown after successful withdrawal/redemption
     */
    function _updateCooldownAfterWithdrawal(address owner, uint256 shares, uint256 assets) private {
        UserCooldown storage cooldown = cooldowns[owner];
        if (cooldown.shares > 0) {
            if (shares >= cooldown.shares) {
                // Full withdrawal - clear the cooldown
                delete cooldowns[owner];
            } else {
                // Partial withdrawal - reduce cooldown shares
                cooldown.shares -= shares;
            }
            emit WithdrawalCompleted(owner, shares, assets);
        }
        
        // Clear lock timestamp if fully withdrawn
        if (ITokenizedStrategy(address(this)).balanceOf(owner) == 0) {
            delete lockedUntil[owner];
        }
    }

    /**
     * @dev Post-withdraw hook to update cooldown after successful withdrawal
     */
    function _postWithdrawHook(
        uint256 assets,
        uint256 shares,
        address owner
    ) internal override {
        _updateCooldownAfterWithdrawal(owner, shares, assets);
    }

    /**
     * @dev Post-redeem hook to update cooldown after successful redemption
     */
    function _postRedeemHook(
        uint256 assets,
        uint256 shares,
        address owner
    ) internal override {
        _updateCooldownAfterWithdrawal(owner, shares, assets);
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
        // Note: Balance check will be enforced during actual withdrawal
        
        // Allow updating cooldown with new amount (overwrites previous)
        cooldowns[msg.sender] = UserCooldown({
            cooldownEnd: block.timestamp + cooldownDuration,
            windowEnd: block.timestamp + cooldownDuration + withdrawalWindow,
            shares: shares
        });
        
        emit CooldownStarted(msg.sender, shares, block.timestamp);
    }
    
    /**
     * @notice Cancel active cooldown
     */
    function cancelCooldown() external {
        require(cooldowns[msg.sender].shares > 0, "No active cooldown");
        delete cooldowns[msg.sender];
        emit CooldownCancelled(msg.sender);
    }
    

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Check available deposit limit based on subordination ratio
     * @param _owner Address to check limit for
     * @return Maximum deposit amount allowed
     */
    function availableDepositLimit(address _owner) public view override returns (uint256) {
        if (_isShutdown()) {
            return 0;
        }
        
        // Check subordination ratio if USD3 strategy is set
        if (usd3Strategy != address(0)) {
            uint256 usd3TotalAssets = IERC20(usd3Strategy).totalSupply();
            uint256 susd3TotalAssets = _totalAssets();
            
            // If no sUSD3 deposits yet, calculate max allowed based on USD3 supply
            // sUSD3 can be max 15% of total, so sUSD3/(USD3+sUSD3) = 0.15
            // Which means sUSD3 = 0.15/0.85 * USD3
            if (susd3TotalAssets == 0 && usd3TotalAssets > 0) {
                // This is approximately 17.65% of USD3 supply
                return (usd3TotalAssets * MAX_SUBORDINATION_RATIO) / (MAX_BPS - MAX_SUBORDINATION_RATIO);
            }
            
            uint256 totalCombined = usd3TotalAssets + susd3TotalAssets;
            
            if (totalCombined > 0) {
                // Calculate max sUSD3 allowed (15% of total)
                uint256 maxSusd3Allowed = (totalCombined * MAX_SUBORDINATION_RATIO) / MAX_BPS;
                
                if (susd3TotalAssets >= maxSusd3Allowed) {
                    return 0; // Already at max subordination
                }
                
                // Return remaining capacity
                return maxSusd3Allowed - susd3TotalAssets;
            }
        }
        
        // If no USD3 strategy set or no deposits yet, return max
        return type(uint256).max;
    }
    
    /**
     * @notice Check available withdraw limit (considers cooldowns)
     * @param _owner Address to check limit for
     * @return Maximum withdrawal amount allowed in assets
     */
    function availableWithdrawLimit(address _owner) public view override returns (uint256) {
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
        return ITokenizedStrategy(address(this)).convertToAssets(cooldown.shares);
    }
    
    /**
     * @notice Get user's cooldown status
     * @param user Address to check
     * @return cooldownEnd When cooldown expires (0 if no cooldown)
     * @return windowEnd When withdrawal window closes
     * @return shares Number of shares in cooldown
     */
    function getCooldownStatus(address user) external view returns (
        uint256 cooldownEnd,
        uint256 windowEnd,
        uint256 shares
    ) {
        UserCooldown memory cooldown = cooldowns[user];
        return (cooldown.cooldownEnd, cooldown.windowEnd, cooldown.shares);
    }

    /*//////////////////////////////////////////////////////////////
                        MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Set USD3 strategy address for ratio calculations
     * @param _usd3Strategy Address of USD3 strategy
     */
    function setUsd3Strategy(address _usd3Strategy) external onlyManagement {
        require(_usd3Strategy != address(0), "Invalid address");
        usd3Strategy = _usd3Strategy;
        emit USD3StrategyUpdated(_usd3Strategy);
    }
    
    /**
     * @notice Update lock duration for new deposits
     * @param _lockDuration New lock duration in seconds
     */
    function setLockDuration(uint256 _lockDuration) external onlyManagement {
        require(_lockDuration <= 365 days, "Lock too long");
        lockDuration = _lockDuration;
        emit LockDurationUpdated(_lockDuration);
    }
    
    /**
     * @notice Update cooldown duration
     * @param _cooldownDuration New cooldown duration in seconds
     */
    function setCooldownDuration(uint256 _cooldownDuration) external onlyManagement {
        require(_cooldownDuration <= 30 days, "Cooldown too long");
        cooldownDuration = _cooldownDuration;
        emit CooldownDurationUpdated(_cooldownDuration);
    }
    
    /**
     * @notice Update withdrawal window
     * @param _withdrawalWindow New withdrawal window in seconds
     */
    function setWithdrawalWindow(uint256 _withdrawalWindow) external onlyManagement {
        require(_withdrawalWindow >= 1 days && _withdrawalWindow <= 7 days, "Invalid window");
        withdrawalWindow = _withdrawalWindow;
        emit WithdrawalWindowUpdated(_withdrawalWindow);
    }

    /*//////////////////////////////////////////////////////////////
                        LOSS ABSORPTION
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Absorb losses from USD3 markdowns
     * @param amount Amount of losses to absorb
     * @dev This would be called by USD3 or a keeper during markdown events
     */
    function absorbLoss(uint256 amount) external onlyKeepers {
        require(amount > 0, "Invalid amount");
        
        totalLossesAbsorbed += amount;
        lastLossTime = block.timestamp;
        
        emit LossAbsorbed(amount, block.timestamp);
        
        // In production, this would adjust share prices to reflect the loss
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