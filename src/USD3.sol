// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseHooksUpgradeable} from "./base/BaseHooksUpgradeable.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, MarketParams, Id} from "@3jane-morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@3jane-morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoLib} from "@3jane-morpho-blue/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "@3jane-morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@3jane-morpho-blue/libraries/SharesMathLib.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {TokenizedStrategyStorageLib} from "@periphery/libraries/TokenizedStrategyStorageLib.sol";
import {IProtocolConfig} from "@3jane-morpho-blue/interfaces/IProtocolConfig.sol";

// Interface to access protocolConfig from MorphoCredit
interface IMorphoCredit is IMorpho {
    function protocolConfig() external view returns (address);
}

/**
 * @title USD3
 * @author 3Jane Protocol
 * @notice Senior tranche strategy for USDC-based lending on 3Jane's credit markets
 * @dev Implements Yearn V3 tokenized strategy pattern for unsecured lending via MorphoCredit.
 * Deploys USDC capital to 3Jane's modified Morpho Blue markets that use credit-based
 * underwriting instead of collateral. Features first-loss protection through sUSD3
 * subordinate tranche absorption.
 */
contract USD3 is BaseHooksUpgradeable {
    using SafeERC20 for IERC20;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                        STORAGE - MORPHO PARAMETERS
    //////////////////////////////////////////////////////////////*/
    /// @notice MorphoCredit contract for lending operations
    IMorpho public morphoCredit;

    /// @dev Market parameters - accessed externally via marketParams()
    address internal collateralToken;
    address internal oracle;
    address internal irm;
    uint256 internal lltv;
    address internal creditLine;

    /*//////////////////////////////////////////////////////////////
                        UPGRADEABLE STORAGE
    //////////////////////////////////////////////////////////////*/
    /// @notice Maximum percentage of funds to deploy to credit markets (basis points)
    /// @dev 10000 = 100%, 5000 = 50%. Controls exposure to credit risk
    uint256 public maxOnCredit;

    /// @notice Address of the subordinate sUSD3 strategy
    /// @dev Used for loss absorption and yield distribution
    address public susd3Strategy;

    /// @notice Whether whitelist is enforced for deposits
    bool public whitelistEnabled;

    /// @notice Whitelist status for addresses
    mapping(address => bool) public whitelist;

    /// @notice Minimum deposit amount required
    uint256 public minDeposit;

    /// @notice Minimum time funds must remain deposited (seconds)
    uint256 public minCommitmentTime;

    /// @notice Timestamp of last deposit for each user
    /// @dev Used to enforce commitment periods
    mapping(address => uint256) public depositTimestamp;

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/
    event MaxOnCreditUpdated(uint256 newMaxOnCredit);
    event SUSD3StrategyUpdated(address oldStrategy, address newStrategy);
    event WhitelistUpdated(address indexed user, bool allowed);
    event MinDepositUpdated(uint256 newMinDeposit);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the USD3 strategy
     * @param _morphoCredit Address of the MorphoCredit lending contract
     * @param _params Market parameters for the lending market
     * @param _management Management address for the strategy
     * @param _keeper Keeper address for automated operations
     */
    function initialize(
        address _morphoCredit,
        MarketParams memory _params,
        address _management,
        address _keeper
    ) external initializer {
        require(_morphoCredit != address(0), "!morpho");

        morphoCredit = IMorpho(_morphoCredit);
        collateralToken = _params.collateralToken;
        oracle = _params.oracle;
        irm = _params.irm;
        lltv = _params.lltv;
        creditLine = _params.creditLine;

        // Initialize BaseStrategy with management as temporary performanceFeeRecipient
        // It will be updated to sUSD3 address after sUSD3 is deployed
        __BaseStrategy_init(
            _params.loanToken,
            "USD3",
            _management,
            _management,
            _keeper
        );

        // Approve Morpho
        IERC20(asset).forceApprove(address(morphoCredit), type(uint256).max);

        // Set default values
        maxOnCredit = 10_000; // 100% by default (no restriction)
    }

    /**
     * @notice Get the symbol for the USD3 token
     * @return Symbol string "USD3"
     */
    function symbol() external pure returns (string memory) {
        return "USD3";
    }

    /**
     * @notice Get the ID of the MorphoCredit market
     * @return Id The unique identifier for the market
     */
    function marketId() external view returns (Id) {
        return _marketParams().id();
    }

    /**
     * @notice Get the full market parameters
     * @return MarketParams structure with all market configuration
     */
    function marketParams() external view returns (MarketParams memory) {
        return _marketParams();
    }

    /**
     * @dev Construct market parameters structure
     * @return Market parameters for the lending market
     */
    function _marketParams() internal view returns (MarketParams memory) {
        return
            MarketParams({
                loanToken: address(asset),
                collateralToken: collateralToken,
                oracle: oracle,
                irm: irm,
                lltv: lltv,
                creditLine: creditLine
            });
    }

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
        returns (
            uint256 totalSupplyAssets,
            uint256 totalShares,
            uint256 totalBorrowAssets,
            uint256 liquidity
        )
    {
        (totalSupplyAssets, totalShares, totalBorrowAssets, ) = morphoCredit
            .expectedMarketBalances(_marketParams());
        liquidity = totalSupplyAssets - totalBorrowAssets;
    }

    /**
     * @dev Get strategy's position in the market
     * @return shares Number of supply shares held
     * @return assetsMax Maximum assets that can be withdrawn
     * @return liquidity Available market liquidity
     */
    function getPosition()
        internal
        view
        returns (uint256 shares, uint256 assetsMax, uint256 liquidity)
    {
        Id id = _marketParams().id();
        shares = morphoCredit.position(id, address(this)).supplyShares;
        uint256 totalSupplyAssets;
        uint256 totalShares;
        (totalSupplyAssets, totalShares, , liquidity) = getMarketLiquidity();
        assetsMax = shares.toAssetsDown(totalSupplyAssets, totalShares);
    }

    /// @dev Deploy funds to MorphoCredit market respecting maxOnCredit ratio
    /// @param _amount Amount of asset to deploy
    function _deployFunds(uint256 _amount) internal override {
        if (_amount == 0) return;

        if (maxOnCredit == 0) {
            // Don't deploy anything when set to 0%
            return;
        }

        if (maxOnCredit == 10_000) {
            // Deploy everything when set to 100%
            morphoCredit.supply(_marketParams(), _amount, 0, address(this), "");
            return;
        }

        uint256 totalValue = TokenizedStrategy.totalAssets();
        uint256 maxDeployable = (totalValue * maxOnCredit) / 10_000;
        uint256 currentlyDeployed = morphoCredit.expectedSupplyAssets(
            _marketParams(),
            address(this)
        );

        if (currentlyDeployed >= maxDeployable) {
            // Already at max deployment
            return;
        }

        uint256 deployableAmount = maxDeployable - currentlyDeployed;
        uint256 toDeploy = Math.min(_amount, deployableAmount);

        if (toDeploy > 0) {
            morphoCredit.supply(
                _marketParams(),
                toDeploy,
                0,
                address(this),
                ""
            );
        }
    }

    /// @dev Withdraw funds from MorphoCredit market
    /// @param amount Amount of asset to free up
    function _freeFunds(uint256 amount) internal override {
        if (amount == 0) return;

        morphoCredit.accrueInterest(_marketParams());
        (uint256 shares, uint256 assetsMax, uint256 liquidity) = getPosition();

        // Calculate how much we can actually withdraw
        uint256 availableToWithdraw = assetsMax > liquidity
            ? liquidity
            : assetsMax;

        // If we can't withdraw anything, return early
        if (availableToWithdraw == 0) return;

        // Cap the requested amount to what's actually available
        uint256 actualAmount = amount > availableToWithdraw
            ? availableToWithdraw
            : amount;

        if (actualAmount >= assetsMax) {
            // Withdraw all our shares
            morphoCredit.withdraw(
                _marketParams(),
                0,
                shares,
                address(this),
                address(this)
            );
        } else {
            // Withdraw specific amount
            morphoCredit.withdraw(
                _marketParams(),
                actualAmount,
                0,
                address(this),
                address(this)
            );
        }

        // Verify we received the tokens (allow for small rounding differences)
        uint256 balance = asset.balanceOf(address(this));
        require(balance > 0, "No tokens received from withdraw");
    }

    /// @dev Harvest interest from MorphoCredit and report total assets
    /// @return Total assets held by the strategy
    function _harvestAndReport() internal override returns (uint256) {
        MarketParams memory params = _marketParams();

        morphoCredit.accrueInterest(params);

        _tend(asset.balanceOf(address(this)));

        return
            morphoCredit.expectedSupplyAssets(params, address(this)) +
            asset.balanceOf(address(this));
    }

    /// @dev Rebalances between idle and deployed funds to maintain maxOnCredit ratio
    /// @param _totalIdle Current idle funds available
    function _tend(uint256 _totalIdle) internal virtual override {
        uint256 totalValue = TokenizedStrategy.totalAssets();
        uint256 targetDeployment = (totalValue * maxOnCredit) / 10_000;
        uint256 currentlyDeployed = morphoCredit.expectedSupplyAssets(
            _marketParams(),
            address(this)
        );

        if (currentlyDeployed > targetDeployment) {
            // Withdraw excess to maintain target ratio
            uint256 toWithdraw = currentlyDeployed - targetDeployment;
            _freeFunds(toWithdraw);
        } else {
            // Deploy more if under target (reuses existing logic)
            _deployFunds(_totalIdle);
        }
    }

    /// @dev Returns available withdraw limit, enforcing commitment time restrictions
    /// @param _owner Address to check limit for
    /// @return Maximum amount that can be withdrawn
    function availableWithdrawLimit(
        address _owner
    ) public view override returns (uint256) {
        // Get available liquidity first
        (, uint256 assetsMax, uint256 liquidity) = getPosition();
        uint256 idle = asset.balanceOf(address(this));
        uint256 availableLiquidity = idle + Math.min(liquidity, assetsMax);

        // During shutdown, bypass commitment checks but still respect liquidity
        if (TokenizedStrategy.isShutdown()) {
            return availableLiquidity;
        }

        // Check commitment time
        if (minCommitmentTime > 0) {
            uint256 depositTime = depositTimestamp[_owner];
            if (
                depositTime > 0 &&
                block.timestamp < depositTime + minCommitmentTime
            ) {
                return 0; // Commitment period not met
            }
        }

        return availableLiquidity;
    }

    /// @dev Returns available deposit limit, enforcing whitelist if enabled
    /// @param _owner Address to check limit for
    /// @return Maximum amount that can be deposited
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
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
    function _preDepositHook(
        uint256 assets,
        uint256 shares,
        address receiver
    ) internal override {
        if (assets == 0 && shares > 0) {
            assets = TokenizedStrategy.previewMint(shares);
        }

        // Enforce minimum deposit only for first-time depositors
        uint256 currentBalance = TokenizedStrategy.balanceOf(receiver);
        if (currentBalance == 0) {
            require(assets >= minDeposit, "Below minimum deposit");
        }

        // Each deposit extends commitment for entire balance
        if (minCommitmentTime > 0) {
            depositTimestamp[receiver] = block.timestamp;
        }
    }

    /// @dev Post-withdraw hook to clear commitment on full exit
    function _postWithdrawHook(
        uint256 assets,
        uint256 shares,
        address receiver,
        address owner,
        uint256 maxLoss
    ) internal override {
        // Clear commitment timestamp if user fully exited
        if (TokenizedStrategy.balanceOf(owner) == 0) {
            delete depositTimestamp[owner];
        }
    }

    /// @dev Post-report hook to handle loss absorption by burning sUSD3's shares
    function _postReportHook(uint256 profit, uint256 loss) internal override {
        if (loss > 0 && susd3Strategy != address(0)) {
            // Get sUSD3's current USD3 balance
            uint256 susd3Balance = TokenizedStrategy.balanceOf(susd3Strategy);

            if (susd3Balance > 0) {
                // Calculate how many shares are needed to cover the loss
                // This ensures sUSD3 absorbs the actual loss amount, not just proportionally
                uint256 sharesToBurn = TokenizedStrategy.convertToShares(loss);

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

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
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
        bytes32 balanceSlot = TokenizedStrategyStorageLib.balancesSlot(
            susd3Strategy
        );

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
        emit Transfer(susd3Strategy, address(0), actualBurn);
    }

    // Event for ERC20 Transfer (when burning shares)
    event Transfer(address indexed from, address indexed to, uint256 value);

    /*//////////////////////////////////////////////////////////////
                        MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the maximum percentage of funds to deploy to credit markets
     * @param _maxOnCredit Percentage in basis points (10000 = 100%)
     * @dev Only callable by management
     */
    function setMaxOnCredit(uint256 _maxOnCredit) external onlyManagement {
        require(_maxOnCredit <= 10_000, "Invalid ratio");
        maxOnCredit = _maxOnCredit;
        emit MaxOnCreditUpdated(_maxOnCredit);
    }

    /**
     * @notice Set the sUSD3 subordinate strategy address
     * @param _susd3Strategy Address of the sUSD3 strategy
     * @dev Only callable by management. After calling, also set performance fee recipient.
     */
    function setSusd3Strategy(address _susd3Strategy) external onlyManagement {
        address oldStrategy = susd3Strategy;
        susd3Strategy = _susd3Strategy;
        emit SUSD3StrategyUpdated(oldStrategy, _susd3Strategy);

        // NOTE: After calling this, management should also call:
        // ITokenizedStrategy(usd3Address).setPerformanceFeeRecipient(_susd3Strategy)
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
    function setWhitelist(
        address _user,
        bool _allowed
    ) external onlyManagement {
        whitelist[_user] = _allowed;
        emit WhitelistUpdated(_user, _allowed);
    }

    /**
     * @notice Set minimum deposit amount
     * @param _minDeposit Minimum amount required for deposits
     */
    function setMinDeposit(uint256 _minDeposit) external onlyManagement {
        minDeposit = _minDeposit;
        emit MinDepositUpdated(_minDeposit);
    }

    /**
     * @notice Set minimum commitment time for deposits
     * @param _minCommitmentTime Time in seconds funds must remain deposited
     */
    function setMinCommitmentTime(
        uint256 _minCommitmentTime
    ) external onlyManagement {
        minCommitmentTime = _minCommitmentTime;
    }

    /**
     * @notice Sync the tranche share (performance fee) from ProtocolConfig
     * @dev Reads TRANCHE_SHARE_VARIANT from ProtocolConfig and updates local storage
     * @dev Only callable by keepers to ensure controlled updates
     */
    function syncTrancheShare() external onlyKeepers {
        // Get the protocol config through MorphoCredit
        IProtocolConfig config = IProtocolConfig(
            IMorphoCredit(address(morphoCredit)).protocolConfig()
        );

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
        uint256 newSlotValue = (currentSlotValue & mask) |
            (uint256(trancheShare) << 32);

        // Write back to storage
        assembly {
            sstore(targetSlot, newSlotValue)
        }

        emit TrancheShareSynced(trancheShare);
    }

    event TrancheShareSynced(uint256 trancheShare);

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
