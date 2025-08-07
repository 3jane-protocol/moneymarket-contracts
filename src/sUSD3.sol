// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {BaseHooksUpgradeable} from "./base/BaseHooksUpgradeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IProtocolConfig} from "@3jane-morpho-blue/interfaces/IProtocolConfig.sol";
import {IMorpho} from "@3jane-morpho-blue/interfaces/IMorpho.sol";
import {USD3} from "./USD3.sol";

// Interface to access protocolConfig from MorphoCredit
interface IMorphoCredit is IMorpho {
    function protocolConfig() external view returns (address);
}

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
        uint256 cooldownEnd; // When cooldown expires
        uint256 windowEnd; // When withdrawal window closes
        uint256 shares; // Shares locked for withdrawal
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

    // Configurable parameters (only withdrawalWindow is locally managed)
    uint256 public withdrawalWindow; // Window to complete withdrawal (default 2 days)

    // Subordination management
    address public usd3Strategy; // USD3 strategy address for ratio checks
    address public morphoCredit; // MorphoCredit address to access protocol config

    // Yield tracking
    uint256 public accumulatedYield; // Yield received from USD3
    uint256 public lastYieldUpdate; // Last time yield was updated

    // Loss tracking
    uint256 public totalLossesAbsorbed; // Total losses absorbed by sUSD3
    uint256 public lastLossTime; // Last time losses were absorbed

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event CooldownStarted(
        address indexed user,
        uint256 shares,
        uint256 timestamp
    );
    event CooldownCancelled(address indexed user);
    event WithdrawalCompleted(
        address indexed user,
        uint256 shares,
        uint256 assets
    );
    event LossAbsorbed(uint256 amount, uint256 timestamp);
    event YieldReceived(uint256 amount, address indexed from);
    event USD3StrategyUpdated(address newStrategy);
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
     * @param _keeper Keeper address
     */
    function initialize(
        address _usd3Token,
        string memory _name,
        address _management,
        address _keeper
    ) external initializer {
        // Initialize BaseStrategy with USD3 as the asset
        // Use management as performance fee recipient (fees will never be charged)
        __BaseStrategy_init(
            _usd3Token,
            _name,
            _management,
            _management,
            _keeper
        );

        // Get MorphoCredit address from USD3 strategy
        morphoCredit = address(USD3(_usd3Token).morphoCredit());

        // Set default withdrawal window (locally managed)
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
     * @dev Harvest and report - USD3 shares are minted directly to us
     * @return Total USD3 tokens held by the strategy
     */
    function _harvestAndReport() internal override returns (uint256) {
        // USD3 automatically mints shares to us during its report()
        // We just need to return our current balance
        // Any yield received is reflected in our USD3 token balance
        return asset.balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                        HOOKS IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Pre-deposit hook to track lock period (handles both deposit and mint)
     */
    function _preDepositHook(
        uint256 assets,
        uint256 shares,
        address receiver
    ) internal override {
        if (assets == 0 && shares > 0) {
            assets = TokenizedStrategy.previewMint(shares);
        }

        // Each deposit extends lock period for entire balance
        if (assets > 0 || shares > 0) {
            // Read lock duration from ProtocolConfig
            uint256 duration = lockDuration();
            lockedUntil[receiver] = block.timestamp + duration;
        }
    }

    /**
     * @dev Post-withdraw hook to update cooldown after successful withdrawal or redemption
     */
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
                cooldown.shares -= shares;
            }
            emit WithdrawalCompleted(owner, shares, assets);
        }

        // Clear lock timestamp if fully withdrawn
        if (TokenizedStrategy.balanceOf(owner) == 0) {
            delete lockedUntil[owner];
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
            cooldownEnd: block.timestamp + cooldownPeriod,
            windowEnd: block.timestamp + cooldownPeriod + withdrawalWindow,
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
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        if (TokenizedStrategy.isShutdown()) {
            return 0;
        }

        // Check subordination ratio if USD3 strategy is set
        if (usd3Strategy != address(0)) {
            uint256 usd3TotalAssets = IERC20(usd3Strategy).totalSupply();
            uint256 susd3TotalAssets = TokenizedStrategy.totalAssets();

            // Get max subordination ratio from ProtocolConfig
            uint256 maxSubordinationRatio = getMaxSubordinationRatio();

            // If no sUSD3 deposits yet, calculate max allowed based on USD3 supply
            // sUSD3 can be max X% of total, so sUSD3/(USD3+sUSD3) = X/100
            // Which means sUSD3 = X/(100-X) * USD3
            if (susd3TotalAssets == 0 && usd3TotalAssets > 0) {
                // This is approximately 17.65% of USD3 supply for 15% subordination
                return
                    (usd3TotalAssets * maxSubordinationRatio) /
                    (MAX_BPS - maxSubordinationRatio);
            }

            uint256 totalCombined = usd3TotalAssets + susd3TotalAssets;

            if (totalCombined > 0) {
                // Calculate max sUSD3 allowed (X% of total)
                uint256 maxSusd3Allowed = (totalCombined *
                    maxSubordinationRatio) / MAX_BPS;

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
    function availableWithdrawLimit(
        address _owner
    ) public view override returns (uint256) {
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
     * @notice Set USD3 strategy address for ratio calculations
     * @param _usd3Strategy Address of USD3 strategy
     */
    function setUsd3Strategy(address _usd3Strategy) external onlyManagement {
        require(_usd3Strategy != address(0), "Invalid address");
        usd3Strategy = _usd3Strategy;
        emit USD3StrategyUpdated(_usd3Strategy);
    }

    /**
     * @notice Get the maximum subordination ratio from ProtocolConfig
     * @return Maximum subordination ratio in basis points
     */
    function getMaxSubordinationRatio() public view returns (uint256) {
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

    /*//////////////////////////////////////////////////////////////
                        LOSS ABSORPTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Absorb losses from USD3 markdowns
     * @param amount Amount of losses to absorb
     * @dev This would be called by USD3 or a keeper during markdown events
     */
    function absorbLoss(uint256 amount) external onlyKeepers {
        totalLossesAbsorbed += amount;
        lastLossTime = block.timestamp;
        emit LossAbsorbed(amount, block.timestamp);
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
