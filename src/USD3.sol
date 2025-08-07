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

// Import sUSD3 interface for loss absorption
interface sUSD3 {
    function absorbLoss(uint256 amount) external;
}

// Interface to access protocolConfig from MorphoCredit
interface IMorphoCredit is IMorpho {
    function protocolConfig() external view returns (address);
}

contract USD3 is BaseHooksUpgradeable {
    using SafeERC20 for IERC20;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                        STORAGE - MORPHO PARAMETERS
    //////////////////////////////////////////////////////////////*/
    /// @notice Address for the Morpho contract.
    IMorpho public morphoBlue;

    // these internal vars can be accessed externally via marketParams()
    address internal collateralToken;
    address internal oracle;
    address internal irm;
    uint256 internal lltv;
    address internal creditLine;

    /*//////////////////////////////////////////////////////////////
                        UPGRADEABLE STORAGE
    //////////////////////////////////////////////////////////////*/
    // Ratio Management
    uint256 public maxOnCredit; // MAX_ON_CREDIT in basis points (5000 = 50%)
    address public susd3Strategy; // For ratio calculations

    // Access Control
    bool public whitelistEnabled;
    mapping(address => bool) public whitelist;
    uint256 public minDeposit;
    uint256 public minCommitmentTime; // Optional commitment time in seconds
    mapping(address => uint256) public depositTimestamp; // Track deposit times

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

    function initialize(
        address _morphoBlue,
        MarketParams memory _params,
        string memory _name,
        address _management,
        address _keeper
    ) external initializer {
        require(_morphoBlue != address(0), "!morpho");

        morphoBlue = IMorpho(_morphoBlue);
        collateralToken = _params.collateralToken;
        oracle = _params.oracle;
        irm = _params.irm;
        lltv = _params.lltv;
        creditLine = _params.creditLine;

        // Initialize BaseStrategy with management as temporary performanceFeeRecipient
        // It will be updated to sUSD3 address after sUSD3 is deployed
        __BaseStrategy_init(
            _params.loanToken,
            _name,
            _management,
            _management,
            _keeper
        );

        // Approve Morpho
        IERC20(asset).forceApprove(address(morphoBlue), type(uint256).max);

        // Set default values
        maxOnCredit = 10_000; // 100% by default (no restriction)
    }

    function symbol() external pure returns (string memory) {
        return "USD3";
    }

    function marketId() external view returns (Id) {
        return _marketParams().id();
    }

    function marketParams() external view returns (MarketParams memory) {
        return _marketParams();
    }

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
        (totalSupplyAssets, totalShares, totalBorrowAssets, ) = morphoBlue
            .expectedMarketBalances(_marketParams());
        liquidity = totalSupplyAssets - totalBorrowAssets;
    }

    function getPosition()
        internal
        view
        returns (uint256 shares, uint256 assetsMax, uint256 liquidity)
    {
        Id id = _marketParams().id();
        shares = morphoBlue.position(id, address(this)).supplyShares;
        uint256 totalSupplyAssets;
        uint256 totalShares;
        (totalSupplyAssets, totalShares, , liquidity) = getMarketLiquidity();
        assetsMax = shares.toAssetsDown(totalSupplyAssets, totalShares);
    }

    function _deployFunds(uint256 _amount) internal override {
        if (_amount == 0) return;

        if (maxOnCredit == 0) {
            // Don't deploy anything when set to 0%
            return;
        }

        if (maxOnCredit == 10_000) {
            // Deploy everything when set to 100%
            morphoBlue.supply(
                _marketParams(),
                _amount,
                0,
                address(this),
                hex""
            );
            return;
        }

        uint256 totalValue = TokenizedStrategy.totalAssets();
        uint256 maxDeployable = (totalValue * maxOnCredit) / 10_000;
        uint256 currentlyDeployed = morphoBlue.expectedSupplyAssets(
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
            morphoBlue.supply(
                _marketParams(),
                toDeploy,
                0,
                address(this),
                hex""
            );
        }
    }

    function _freeFunds(uint256 amount) internal override {
        if (amount == 0) return;

        morphoBlue.accrueInterest(_marketParams());
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
            morphoBlue.withdraw(
                _marketParams(),
                0,
                shares,
                address(this),
                address(this)
            );
        } else {
            // Withdraw specific amount
            morphoBlue.withdraw(
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

    function _harvestAndReport() internal override returns (uint256) {
        MarketParams memory params = _marketParams();

        morphoBlue.accrueInterest(params);

        // Always tend to maintain proper deployment ratio
        uint256 _totalIdle = asset.balanceOf(address(this));
        _tend(_totalIdle);

        uint256 currentTotalAssets = morphoBlue.expectedSupplyAssets(
            params,
            address(this)
        ) + asset.balanceOf(address(this));

        // Loss absorption is now handled in _postReportHook

        return currentTotalAssets;
    }

    function _tend(uint256 _totalIdle) internal virtual override {
        uint256 totalValue = TokenizedStrategy.totalAssets();
        uint256 targetDeployment = (totalValue * maxOnCredit) / 10_000;
        uint256 currentlyDeployed = morphoBlue.expectedSupplyAssets(
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

    function availableWithdrawLimit(
        address _owner
    ) public view override returns (uint256) {
        // Check commitment time first
        if (minCommitmentTime > 0) {
            uint256 depositTime = depositTimestamp[_owner];
            if (
                depositTime > 0 &&
                block.timestamp < depositTime + minCommitmentTime
            ) {
                return 0; // Commitment period not met
            }
        }

        // Get available liquidity
        (, uint256 assetsMax, uint256 liquidity) = getPosition();
        uint256 idle = asset.balanceOf(address(this));
        uint256 availableLiquidity = idle + Math.min(liquidity, assetsMax);

        return availableLiquidity;
    }

    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        // Check whitelist if enabled
        if (whitelistEnabled && !whitelist[_owner]) {
            return 0;
        }

        // Check if strategy is shutdown
        if (TokenizedStrategy.isShutdown()) {
            return 0;
        }

        // Return max uint256 to indicate no limit
        // (minDeposit will be checked in custom deposit/mint functions)
        return type(uint256).max;
    }

    /*//////////////////////////////////////////////////////////////
                        HOOKS IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Enforce minimum deposit and set commitment time
    function _enforceDepositRequirements(
        uint256 assets,
        address receiver
    ) private {
        require(assets >= minDeposit, "Below minimum deposit");

        // Each deposit extends commitment for entire balance
        if (minCommitmentTime > 0) {
            depositTimestamp[receiver] = block.timestamp;
        }
    }

    /// @dev Pre-deposit hook to enforce minimum deposit and track commitment time
    function _preDepositHook(
        uint256 assets,
        uint256 shares,
        address receiver
    ) internal override {
        if (assets == 0 && shares > 0) {
            assets = TokenizedStrategy.previewMint(shares);
        }
        _enforceDepositRequirements(assets, receiver);
    }

    /// @dev Clear commitment timestamp if user fully exited
    function _clearCommitmentIfNeeded(address owner) private {
        if (TokenizedStrategy.balanceOf(owner) == 0) {
            delete depositTimestamp[owner];
        }
    }

    /// @dev Post-withdraw hook to clear commitment on full exit (handles both withdraw and redeem)
    function _postWithdrawHook(
        uint256 assets,
        uint256 shares,
        address receiver,
        address owner,
        uint256 maxLoss
    ) internal override {
        _clearCommitmentIfNeeded(owner);
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

    /// @dev Directly burn shares from sUSD3's balance using storage manipulation
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

    function setMaxOnCredit(uint256 _maxOnCredit) external onlyManagement {
        require(_maxOnCredit <= 10_000, "Invalid ratio");
        maxOnCredit = _maxOnCredit;
        emit MaxOnCreditUpdated(_maxOnCredit);
    }

    function setSusd3Strategy(address _susd3Strategy) external onlyManagement {
        address oldStrategy = susd3Strategy;
        susd3Strategy = _susd3Strategy;
        emit SUSD3StrategyUpdated(oldStrategy, _susd3Strategy);

        // NOTE: After calling this, management should also call:
        // ITokenizedStrategy(usd3Address).setPerformanceFeeRecipient(_susd3Strategy)
        // to ensure yield distribution goes to sUSD3
    }

    function setWhitelistEnabled(bool _enabled) external onlyManagement {
        whitelistEnabled = _enabled;
    }

    function setWhitelist(
        address _user,
        bool _allowed
    ) external onlyManagement {
        whitelist[_user] = _allowed;
        emit WhitelistUpdated(_user, _allowed);
    }

    function setMinDeposit(uint256 _minDeposit) external onlyManagement {
        minDeposit = _minDeposit;
        emit MinDepositUpdated(_minDeposit);
    }

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
            IMorphoCredit(address(morphoBlue)).protocolConfig()
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
