// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseHooksUpgradeable} from "./base/BaseHooksUpgradeable.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, IMorphoCredit, MarketParams, Id} from "@3jane-morpho-blue/interfaces/IMorpho.sol";
import {MorphoLib} from "@3jane-morpho-blue/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "@3jane-morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@3jane-morpho-blue/libraries/SharesMathLib.sol";
import {TokenizedStrategyStorageLib} from "@periphery/libraries/TokenizedStrategyStorageLib.sol";
import {IProtocolConfig} from "@3jane-morpho-blue/interfaces/IProtocolConfig.sol";

/**
 * @title USD3
 * @author 3Jane Protocol
 * @notice Senior tranche strategy for USDC-based lending on 3Jane's credit markets
 * @dev Implements Yearn V3 tokenized strategy pattern for unsecured lending via MorphoCredit.
 * Deploys USDC capital to 3Jane's modified Morpho Blue markets that use credit-based
 * underwriting instead of collateral. Features first-loss protection through sUSD3
 * subordinate tranche absorption.
 *
 * Key features:
 * - Senior tranche with first-loss protection from sUSD3 holders
 * - Configurable deployment ratio to credit markets (maxOnCredit)
 * - Automatic yield distribution to sUSD3 via performance fees
 * - Loss absorption through direct share burning of sUSD3 holdings
 * - Commitment period enforcement for deposits
 * - Optional whitelist for controlled access
 * - Dynamic fee adjustment via ProtocolConfig integration
 *
 * Yield Distribution Mechanism:
 * - Tranche share distributed to sUSD3 holders via TokenizedStrategy's performance fee
 * - Performance fee can be set from 0-100% through syncTrancheShare()
 * - Direct storage manipulation bypasses TokenizedStrategy's 50% fee limit
 * - Keeper-controlled updates ensure protocol-wide consistency
 *
 * Loss Absorption Mechanism:
 * - When losses occur, sUSD3 shares are burned first (subordination)
 * - Direct storage manipulation used to burn shares without asset transfers
 * - USD3 holders protected up to total sUSD3 holdings
 * - Losses exceeding sUSD3 balance shared proportionally among USD3 holders
 */
contract USD3 is BaseHooksUpgradeable {
    using SafeERC20 for IERC20;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                        STORAGE - MORPHO PARAMETERS
    //////////////////////////////////////////////////////////////*/
    /// @notice MorphoCredit contract for lending operations
    IMorpho public morphoCredit;

    /// @notice Market ID for the lending market this strategy uses
    Id public marketId;

    /// @notice Market parameters for the lending market
    MarketParams internal _marketParams;

    /*//////////////////////////////////////////////////////////////
                        UPGRADEABLE STORAGE
    //////////////////////////////////////////////////////////////*/
    /// @notice Address of the subordinate sUSD3 strategy
    /// @dev Used for loss absorption and yield distribution
    address public sUSD3;

    /// @notice Whether whitelist is enforced for deposits
    bool public whitelistEnabled;

    /// @notice Whitelist status for addresses
    mapping(address => bool) public whitelist;

    /// @notice Whitelist of depositors allowed to 3rd party deposit
    mapping(address => bool) public depositorWhitelist;

    /// @notice Minimum deposit amount required
    uint256 public minDeposit;

    /// @notice Timestamp of last deposit for each user
    /// @dev Used to enforce commitment periods
    mapping(address => uint256) public depositTimestamp;

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/
    event SUSD3StrategyUpdated(address oldStrategy, address newStrategy);
    event WhitelistUpdated(address indexed user, bool allowed);
    event DepositorWhitelistUpdated(address indexed depositor, bool allowed);
    event MinDepositUpdated(uint256 newMinDeposit);
    event TrancheShareSynced(uint256 trancheShare);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the USD3 strategy
     * @param _morphoCredit Address of the MorphoCredit lending contract
     * @param _marketId Market ID for the lending market
     * @param _management Management address for the strategy
     * @param _keeper Keeper address for automated operations
     */
    function initialize(address _morphoCredit, Id _marketId, address _management, address _keeper)
        external
        initializer
    {
        require(_morphoCredit != address(0), "!morpho");

        morphoCredit = IMorpho(_morphoCredit);
        marketId = _marketId;

        // Get and cache market params
        MarketParams memory params = morphoCredit.idToMarketParams(_marketId);
        require(params.loanToken != address(0), "Invalid market");
        _marketParams = params;

        // Initialize BaseStrategy with management as temporary performanceFeeRecipient
        // It will be updated to sUSD3 address after sUSD3 is deployed
        __BaseStrategy_init(params.loanToken, "USD3", _management, _management, _keeper);

        // Approve Morpho
        IERC20(asset).forceApprove(address(morphoCredit), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the symbol for the USD3 token
     * @return Symbol string "USD3"
     */
    function symbol() external pure returns (string memory) {
        return "USD3";
    }

    /**
     * @notice Get the market parameters for this strategy
     * @return MarketParams struct containing lending market configuration
     */
    function marketParams() external view returns (MarketParams memory) {
        return _marketParams;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Get current market liquidity information
     * @return totalSupplyAssets Total assets supplied to the market
     * @return totalShares Total supply shares in the market
     * @return totalBorrowAssets Total assets borrowed from the market
     * @return liquidity Available liquidity in the market
     */
    function getMarketLiquidity()
        internal
        view
        returns (uint256 totalSupplyAssets, uint256 totalShares, uint256 totalBorrowAssets, uint256 liquidity)
    {
        (totalSupplyAssets, totalShares, totalBorrowAssets,) = morphoCredit.expectedMarketBalances(_marketParams);
        liquidity = totalSupplyAssets - totalBorrowAssets;
    }

    /**
     * @dev Get strategy's position in the market
     * @return shares Number of supply shares held
     * @return assetsMax Maximum assets that can be withdrawn
     * @return liquidity Available market liquidity
     */
    function getPosition() internal view returns (uint256 shares, uint256 assetsMax, uint256 liquidity) {
        shares = morphoCredit.position(marketId, address(this)).supplyShares;
        uint256 totalSupplyAssets;
        uint256 totalShares;
        (totalSupplyAssets, totalShares,, liquidity) = getMarketLiquidity();
        assetsMax = shares.toAssetsDown(totalSupplyAssets, totalShares);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL STRATEGY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Deploy funds to MorphoCredit market respecting maxOnCredit ratio
    /// @param _amount Amount of asset to deploy
    function _deployFunds(uint256 _amount) internal override {
        if (_amount == 0) return;

        uint256 maxOnCreditRatio = maxOnCredit();

        if (maxOnCreditRatio == 0) {
            // Don't deploy anything when set to 0%
            return;
        }

        if (maxOnCreditRatio == 10_000) {
            // Deploy everything when set to 100%
            morphoCredit.supply(_marketParams, _amount, 0, address(this), "");
            return;
        }

        uint256 totalValue = TokenizedStrategy.totalAssets();
        uint256 maxDeployable = (totalValue * maxOnCreditRatio) / 10_000;
        uint256 currentlyDeployed = morphoCredit.expectedSupplyAssets(_marketParams, address(this));

        if (currentlyDeployed >= maxDeployable) {
            // Already at max deployment
            return;
        }

        uint256 deployableAmount = maxDeployable - currentlyDeployed;
        uint256 toDeploy = Math.min(_amount, deployableAmount);

        if (toDeploy > 0) {
            morphoCredit.supply(_marketParams, toDeploy, 0, address(this), "");
        }
    }

    /// @dev Withdraw funds from MorphoCredit market
    /// @param amount Amount of asset to free up
    function _freeFunds(uint256 amount) internal override {
        if (amount == 0) return;

        morphoCredit.accrueInterest(_marketParams);
        (uint256 shares, uint256 assetsMax, uint256 liquidity) = getPosition();

        // Calculate how much we can actually withdraw
        uint256 availableToWithdraw = assetsMax > liquidity ? liquidity : assetsMax;

        // If we can't withdraw anything, return early
        if (availableToWithdraw == 0) return;

        // Cap the requested amount to what's actually available
        uint256 actualAmount = amount > availableToWithdraw ? availableToWithdraw : amount;

        if (actualAmount >= assetsMax) {
            // Withdraw all our shares
            morphoCredit.withdraw(_marketParams, 0, shares, address(this), address(this));
        } else {
            // Withdraw specific amount
            morphoCredit.withdraw(_marketParams, actualAmount, 0, address(this), address(this));
        }
    }

    /// @dev Emergency withdraw function to free funds from MorphoCredit
    /// @param amount The amount to withdraw (use type(uint256).max for all)
    function _emergencyWithdraw(uint256 amount) internal override {
        // This is called during shutdown to free funds from Morpho
        // Use _freeFunds which already handles the withdrawal logic
        _freeFunds(amount);
    }

    /// @dev Harvest interest from MorphoCredit and report total assets
    /// @return Total assets held by the strategy
    function _harvestAndReport() internal override returns (uint256) {
        MarketParams memory params = _marketParams;

        morphoCredit.accrueInterest(params);

        _tend(asset.balanceOf(address(this)));

        return morphoCredit.expectedSupplyAssets(params, address(this)) + asset.balanceOf(address(this));
    }

    /// @dev Rebalances between idle and deployed funds to maintain maxOnCredit ratio
    /// @param _totalIdle Current idle funds available
    function _tend(uint256 _totalIdle) internal virtual override {
        uint256 totalValue = TokenizedStrategy.totalAssets();
        uint256 targetDeployment = (totalValue * maxOnCredit()) / 10_000;
        uint256 currentlyDeployed = morphoCredit.expectedSupplyAssets(_marketParams, address(this));

        if (currentlyDeployed > targetDeployment) {
            // Withdraw excess to maintain target ratio
            uint256 toWithdraw = currentlyDeployed - targetDeployment;
            _freeFunds(toWithdraw);
        } else {
            // Deploy more if under target (reuses existing logic)
            _deployFunds(_totalIdle);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    PUBLIC VIEW FUNCTIONS (OVERRIDES)
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns available withdraw limit, enforcing commitment time restrictions and subordination ratio
    /// @param _owner Address to check limit for
    /// @return Maximum amount that can be withdrawn
    function availableWithdrawLimit(address _owner) public view override returns (uint256) {
        // Get available liquidity first
        (, uint256 assetsMax, uint256 liquidity) = getPosition();
        uint256 idle = asset.balanceOf(address(this));
        uint256 availableLiquidity = idle + Math.min(liquidity, assetsMax);

        // During shutdown, bypass all checks
        if (TokenizedStrategy.isShutdown()) {
            return availableLiquidity;
        }

        // Check subordination ratio constraint only if sUSD3 is set
        // Prevent withdrawals that would leave USD3 below minimum ratio
        if (sUSD3 != address(0)) {
            uint256 usd3TotalSupply = TokenizedStrategy.totalSupply();

            // sUSD3 holds USD3 tokens, so we check USD3 balance of sUSD3
            uint256 susd3Holdings = TokenizedStrategy.balanceOf(sUSD3);

            // Get max subordination ratio from ProtocolConfig
            uint256 maxSubRatio = maxSubordinationRatio(); // e.g., 1500 (15%)

            // Calculate the minimum total supply that maintains the ratio
            // minTotalSupply = susd3Holdings / maxSubRatio
            uint256 minTotalSupply = (susd3Holdings * MAX_BPS) / maxSubRatio;

            if (usd3TotalSupply <= minTotalSupply) {
                availableLiquidity = 0; // No withdrawals allowed
            } else {
                // Only allow withdrawal down to the minimum supply
                uint256 maxWithdrawable = usd3TotalSupply - minTotalSupply;
                availableLiquidity = Math.min(availableLiquidity, maxWithdrawable);
            }
        }

        // Check commitment time
        uint256 commitTime = minCommitmentTime();
        if (commitTime > 0) {
            uint256 depositTime = depositTimestamp[_owner];
            if (depositTime > 0 && block.timestamp < depositTime + commitTime) {
                return 0; // Commitment period not met
            }
        }

        return availableLiquidity;
    }

    /// @dev Returns available deposit limit, enforcing whitelist if enabled
    /// @param _owner Address to check limit for
    /// @return Maximum amount that can be deposited
    function availableDepositLimit(address _owner) public view override returns (uint256) {
        // Check whitelist if enabled
        if (whitelistEnabled && !whitelist[_owner]) {
            return 0;
        }

        // Return max uint256 to indicate no limit
        // (minDeposit will be checked in custom deposit/mint functions)
        return type(uint256).max;
    }

    /*//////////////////////////////////////////////////////////////
                        HOOKS IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Pre-deposit hook to enforce minimum deposit and track commitment time
    function _preDepositHook(uint256 assets, uint256 shares, address receiver) internal override {
        if (assets == 0 && shares > 0) {
            assets = TokenizedStrategy.previewMint(shares);
        }

        // Handle type(uint256).max case - resolve to actual balance
        if (assets == type(uint256).max) {
            assets = asset.balanceOf(msg.sender);
        }

        // Enforce minimum deposit only for first-time depositors
        uint256 currentBalance = TokenizedStrategy.balanceOf(receiver);
        if (currentBalance == 0) {
            require(assets >= minDeposit, "Below minimum deposit");
        }

        // Prevent commitment bypass and griefing attacks
        if (minCommitmentTime() > 0) {
            // Only allow self-deposits or whitelisted depositors
            require(
                msg.sender == receiver || depositorWhitelist[msg.sender],
                "USD3: Only self or whitelisted deposits allowed"
            );

            // Always extend commitment for valid deposits
            depositTimestamp[receiver] = block.timestamp;
        }
    }

    /// @dev Post-withdraw hook to clear commitment on full exit
    function _postWithdrawHook(uint256 assets, uint256 shares, address receiver, address owner, uint256 maxLoss)
        internal
        override
    {
        // Clear commitment timestamp if user fully exited
        if (TokenizedStrategy.balanceOf(owner) == 0) {
            delete depositTimestamp[owner];
        }
    }

    /// @dev Post-report hook to handle loss absorption by burning sUSD3's shares
    function _postReportHook(uint256 profit, uint256 loss) internal override {
        if (loss > 0 && sUSD3 != address(0)) {
            // Get sUSD3's current USD3 balance
            uint256 susd3Balance = TokenizedStrategy.balanceOf(sUSD3);

            if (susd3Balance > 0) {
                // Calculate how many shares are needed to cover the loss
                // IMPORTANT: We must use pre-report values to calculate the correct share amount
                // The report has already reduced totalAssets, so we add the loss back
                uint256 totalSupply = TokenizedStrategy.totalSupply();
                uint256 totalAssets = TokenizedStrategy.totalAssets();

                // Calculate shares to burn using pre-loss exchange rate
                uint256 sharesToBurn = loss.mulDiv(totalSupply, totalAssets + loss, Math.Rounding.Floor);

                // Cap at sUSD3's actual balance - they can't lose more than they have
                if (sharesToBurn > susd3Balance) {
                    sharesToBurn = susd3Balance;
                }

                if (sharesToBurn > 0) {
                    _burnSharesFromSusd3(sharesToBurn);
                }
            }
        }
    }

    /**
     * @notice Prevent transfers during commitment period
     * @dev Override from BaseHooksUpgradeable to enforce commitment
     * @param from Address transferring shares
     * @param to Address receiving shares
     * @param amount Amount of shares being transferred
     */
    function _preTransferHook(address from, address to, uint256 amount) internal override {
        // Allow minting (from == 0) and burning (to == 0)
        if (from == address(0) || to == address(0)) return;

        // Allow transfers to/from sUSD3 (staking and withdrawals)
        if (to == sUSD3 || from == sUSD3) return;

        // Check commitment period
        uint256 commitmentEnd = depositTimestamp[from] + minCommitmentTime();
        require(
            block.timestamp >= commitmentEnd || depositTimestamp[from] == 0,
            "USD3: Cannot transfer during commitment period"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Directly burn shares from sUSD3's balance using storage manipulation
     *
     * IMPORTANT: Direct storage manipulation is necessary here because TokenizedStrategy
     * does not expose a public burn function. The only ways to burn shares in
     * TokenizedStrategy are through withdraw/redeem (which require asset transfers)
     * or internal profit/loss accounting. Since we need to burn sUSD3's shares
     * without triggering asset transfers, direct storage manipulation is the only
     * viable approach.
     *
     * @param amount Number of shares to burn from sUSD3
     */
    function _burnSharesFromSusd3(uint256 amount) internal {
        // Calculate storage slots using the library
        bytes32 totalSupplySlot = TokenizedStrategyStorageLib.totalSupplySlot();
        bytes32 balanceSlot = TokenizedStrategyStorageLib.balancesSlot(sUSD3);

        // Read current values
        uint256 currentBalance;
        uint256 currentTotalSupply;
        assembly {
            currentBalance := sload(balanceSlot)
            currentTotalSupply := sload(totalSupplySlot)
        }

        // Ensure we don't burn more than available
        uint256 actualBurn = amount;
        if (actualBurn > currentBalance) {
            actualBurn = currentBalance;
        }

        // Update storage
        assembly {
            sstore(balanceSlot, sub(currentBalance, actualBurn))
            sstore(totalSupplySlot, sub(currentTotalSupply, actualBurn))
        }

        // Emit Transfer event to address(0) for transparency
        emit IERC20.Transfer(sUSD3, address(0), actualBurn);
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the maximum percentage of funds to deploy to credit markets from ProtocolConfig
     * @return Maximum deployment ratio in basis points (10000 = 100%)
     * @dev Returns the value from ProtocolConfig directly. If not configured in ProtocolConfig,
     *      it returns 0, effectively preventing deployment until explicitly configured.
     */
    function maxOnCredit() public view returns (uint256) {
        IProtocolConfig config = IProtocolConfig(IMorphoCredit(address(morphoCredit)).protocolConfig());
        return config.getMaxOnCredit();
    }

    /**
     * @notice Get the maximum subordination ratio from ProtocolConfig
     * @return Maximum subordination ratio in basis points
     */
    function maxSubordinationRatio() public view returns (uint256) {
        IProtocolConfig config = IProtocolConfig(IMorphoCredit(address(morphoCredit)).protocolConfig());
        uint256 ratio = config.getTrancheRatio();
        return ratio > 0 ? ratio : 1500; // Default to 15% if not set
    }

    /**
     * @notice Get the minimum commitment time from ProtocolConfig
     * @return Minimum commitment time in seconds
     */
    function minCommitmentTime() public view returns (uint256) {
        IProtocolConfig config = IProtocolConfig(IMorphoCredit(address(morphoCredit)).protocolConfig());
        return config.getUsd3CommitmentTime();
    }

    /*//////////////////////////////////////////////////////////////
                        MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the sUSD3 subordinate strategy address
     * @param _sUSD3 Address of the sUSD3 strategy
     * @dev Only callable by management. After calling, also set performance fee recipient.
     */
    function setSUSD3(address _sUSD3) external onlyManagement {
        require(sUSD3 == address(0), "sUSD3 already set");
        require(_sUSD3 != address(0), "Invalid address");

        sUSD3 = _sUSD3;
        emit SUSD3StrategyUpdated(address(0), _sUSD3);

        // NOTE: After calling this, management should also call:
        // ITokenizedStrategy(usd3Address).setPerformanceFeeRecipient(_sUSD3)
        // to ensure yield distribution goes to sUSD3
    }

    /**
     * @notice Enable or disable whitelist requirement
     * @param _enabled True to enable whitelist, false to disable
     */
    function setWhitelistEnabled(bool _enabled) external onlyManagement {
        whitelistEnabled = _enabled;
    }

    /**
     * @notice Update whitelist status for an address
     * @param _user Address to update
     * @param _allowed True to whitelist, false to remove from whitelist
     */
    function setWhitelist(address _user, bool _allowed) external onlyManagement {
        whitelist[_user] = _allowed;
        emit WhitelistUpdated(_user, _allowed);
    }

    /**
     * @notice Update depositor whitelist status for an address
     * @param _depositor Address to update
     * @param _allowed True to allow extending commitments, false to disallow
     */
    function setDepositorWhitelist(address _depositor, bool _allowed) external onlyManagement {
        depositorWhitelist[_depositor] = _allowed;
        emit DepositorWhitelistUpdated(_depositor, _allowed);
    }

    /**
     * @notice Set minimum deposit amount
     * @param _minDeposit Minimum amount required for deposits
     */
    function setMinDeposit(uint256 _minDeposit) external onlyManagement {
        minDeposit = _minDeposit;
        emit MinDepositUpdated(_minDeposit);
    }

    /*//////////////////////////////////////////////////////////////
                        KEEPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sync the tranche share (performance fee) from ProtocolConfig
     * @dev Reads TRANCHE_SHARE_VARIANT from ProtocolConfig and updates local storage
     *
     * IMPORTANT: Direct storage manipulation is necessary here because TokenizedStrategy's
     * setPerformanceFee() function has a hardcoded MAX_FEE limit of 5000 (50%). Since we
     * need to support higher fee distributions to sUSD3 (potentially up to 100% for full
     * subordination scenarios), we must bypass this restriction by directly modifying the
     * storage slot.
     *
     * Storage layout in TokenizedStrategy (slot 9):
     * - Bits 0-31: profitMaxUnlockTime (uint32)
     * - Bits 32-47: performanceFee (uint16) <- We modify this
     * - Bits 48-207: performanceFeeRecipient (address)
     *
     * @dev Only callable by keepers to ensure controlled updates
     */
    function syncTrancheShare() external onlyKeepers {
        // Get the protocol config through MorphoCredit
        IProtocolConfig config = IProtocolConfig(IMorphoCredit(address(morphoCredit)).protocolConfig());

        // Read the tranche share variant (yield share to sUSD3 in basis points)
        uint256 trancheShare = config.getTrancheShareVariant();
        require(trancheShare <= 10_000, "Invalid tranche share");

        // Get the storage slot for performanceFee using the library
        bytes32 targetSlot = TokenizedStrategyStorageLib.profitConfigSlot();

        // Read current slot value
        uint256 currentSlotValue;
        assembly {
            currentSlotValue := sload(targetSlot)
        }

        // Clear the performanceFee bits (32-47) and set new value
        uint256 mask = ~(uint256(0xFFFF) << 32);
        uint256 newSlotValue = (currentSlotValue & mask) | (uint256(trancheShare) << 32);

        // Write back to storage
        assembly {
            sstore(targetSlot, newSlotValue)
        }

        emit TrancheShareSynced(trancheShare);
    }

    /*//////////////////////////////////////////////////////////////
                        STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[40] private __gap;
}
