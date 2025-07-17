// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategyUpgradeable} from "./base/BaseStrategyUpgradeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IMorpho, MarketParams, Id} from "@3jane-morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@3jane-morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoLib} from "@3jane-morpho-blue/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "@3jane-morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@3jane-morpho-blue/libraries/SharesMathLib.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract USD3 is BaseStrategyUpgradeable {
    using SafeERC20 for ERC20;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                        STORAGE - MORPHO PARAMETERS
    //////////////////////////////////////////////////////////////*/
    /// @notice Address for the Morpho contract.
    IMorpho public morphoBlue;

    // these internal vars can be accessed externally via marketParams()
    address internal loanToken;
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
    uint256 public usd3MinRatio; // USD3_RATIO in basis points (8000 = 80%)
    address public susd3Strategy; // For ratio calculations

    // Access Control
    bool public whitelistEnabled;
    mapping(address => bool) public whitelist;
    uint256 public minDeposit;
    uint256 public minCommitmentTime; // Optional commitment time in seconds
    mapping(address => uint256) public depositTimestamp; // Track deposit times

    // Yield Sharing
    uint256 public interestShareVariant; // Basis points for sUSD3 (2000 = 20%)

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/
    event MaxOnCreditUpdated(uint256 newMaxOnCredit);
    event USD3MinRatioUpdated(uint256 newRatio);
    event SUSD3StrategyUpdated(address newStrategy);
    event WhitelistUpdated(address indexed user, bool allowed);
    event MinDepositUpdated(uint256 newMinDeposit);
    event InterestShareVariantUpdated(uint256 newShare);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _morphoBlue,
        MarketParams memory _params,
        string memory _name,
        address _management,
        address _performanceFeeRecipient,
        address _keeper
    ) external initializer {
        require(_morphoBlue != address(0), "!morpho");

        // Set immutables as storage
        morphoBlue = IMorpho(_morphoBlue);
        loanToken = _params.loanToken;
        collateralToken = _params.collateralToken;
        oracle = _params.oracle;
        irm = _params.irm;
        lltv = _params.lltv;
        creditLine = _params.creditLine;

        // Initialize BaseStrategy
        __BaseStrategy_init(loanToken, _name, _management, _performanceFeeRecipient, _keeper);

        // Approve Morpho
        ERC20(loanToken).forceApprove(address(morphoBlue), type(uint256).max);
        
        // Set default values
        maxOnCredit = 10_000; // 100% by default (no restriction)
        usd3MinRatio = 0; // No ratio enforcement by default
    }

    function symbol() external view returns (string memory) {
        return "USD3";
    }

    function marketId() external view returns (Id) {
        return _marketParams().id();
    }

    function marketParams() external view returns (MarketParams memory) {
        return _marketParams();
    }

    function _marketParams() internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: loanToken,
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
        returns (uint256 totalSupplyAssets, uint256 totalShares, uint256 totalBorrowAssets, uint256 liquidity)
    {
        (totalSupplyAssets, totalShares, totalBorrowAssets,) = morphoBlue.expectedMarketBalances(_marketParams());
        liquidity = totalSupplyAssets - totalBorrowAssets;
    }

    function getPosition() internal view returns (uint256 shares, uint256 assetsMax, uint256 liquidity) {
        Id id = _marketParams().id();
        shares = morphoBlue.position(id, address(this)).supplyShares;
        uint256 totalSupplyAssets;
        uint256 totalShares;
        (totalSupplyAssets, totalShares,, liquidity) = getMarketLiquidity();
        assetsMax = shares.toAssetsDown(totalSupplyAssets, totalShares);
    }

    /// @inheritdoc BaseStrategyUpgradeable
    function _deployFunds(uint256 _amount) internal override {
        if (_amount == 0) return;
        
        if (maxOnCredit == 0 || maxOnCredit == 10_000) {
            // If not set or set to 100%, deploy everything
            morphoBlue.supply(_marketParams(), _amount, 0, address(this), hex"");
            return;
        }
        
        uint256 totalValue = _totalAssets();
        uint256 maxDeployable = (totalValue * maxOnCredit) / 10_000;
        uint256 currentlyDeployed = morphoBlue.expectedSupplyAssets(_marketParams(), address(this));
        
        if (currentlyDeployed >= maxDeployable) {
            // Already at max deployment
            return;
        }
        
        uint256 deployableAmount = maxDeployable - currentlyDeployed;
        uint256 toDeploy = Math.min(_amount, deployableAmount);
        
        if (toDeploy > 0) {
            morphoBlue.supply(_marketParams(), toDeploy, 0, address(this), hex"");
        }
    }

    /// @inheritdoc BaseStrategyUpgradeable
    function _freeFunds(uint256 amount) internal override {
        if (amount == 0) return;
        
        morphoBlue.accrueInterest(_marketParams());
        (uint256 shares, uint256 assetsMax, uint256 liquidity) = getPosition();

        // Calculate how much we can actually withdraw
        uint256 availableToWithdraw = assetsMax > liquidity ? liquidity : assetsMax;
        
        // If we can't withdraw anything, return early
        if (availableToWithdraw == 0) return;
        
        // Cap the requested amount to what's actually available
        uint256 actualAmount = amount > availableToWithdraw ? availableToWithdraw : amount;
        
        if (actualAmount >= assetsMax) {
            // Withdraw all our shares
            morphoBlue.withdraw(_marketParams(), 0, shares, address(this), address(this));
        } else {
            // Withdraw specific amount
            morphoBlue.withdraw(_marketParams(), actualAmount, 0, address(this), address(this));
        }
        
        // Verify we received the tokens (allow for small rounding differences)
        uint256 balance = asset().balanceOf(address(this));
        require(balance > 0, "No tokens received from withdraw");
    }

    /// @inheritdoc BaseStrategyUpgradeable
    function _harvestAndReport() internal override returns (uint256) {
        MarketParams memory params = _marketParams();

        morphoBlue.accrueInterest(params);

        // An airdrop might have cause asset to be available, deposit!
        uint256 _totalIdle = asset().balanceOf(address(this));
        if (_totalIdle > 0) {
            _tend(_totalIdle);
        }

        return morphoBlue.expectedSupplyAssets(params, address(this));
    }

    /// @inheritdoc BaseStrategyUpgradeable
    function _tend(uint256 _totalIdle) internal virtual override {
        _deployFunds(_totalIdle);
    }

    /// @inheritdoc BaseStrategyUpgradeable
    function availableWithdrawLimit(address _owner) public view override returns (uint256) {
        // Check commitment time first
        if (minCommitmentTime > 0) {
            uint256 depositTime = depositTimestamp[_owner];
            if (depositTime > 0 && block.timestamp < depositTime + minCommitmentTime) {
                return 0; // Commitment period not met
            }
        }
        
        // Get base liquidity available
        (uint256 shares, uint256 assetsMax, uint256 liquidity) = getPosition();
        uint256 idle = asset().balanceOf(address(this));
        uint256 baseLiquidity = idle + Math.min(liquidity, assetsMax);
        
        // Check USD3 ratio constraint
        if (usd3MinRatio > 0 && susd3Strategy != address(0)) {
            uint256 usd3Value = _totalAssets();
            uint256 susd3Value = IERC20(susd3Strategy).totalSupply();
            uint256 totalValue = usd3Value + susd3Value;
            
            if (totalValue > 0) {
                // Calculate max withdrawable while maintaining ratio
                uint256 minUsd3Value = (totalValue * usd3MinRatio) / 10_000;
                if (usd3Value <= minUsd3Value) {
                    return 0; // Already at minimum ratio
                }
                
                uint256 maxWithdrawable = usd3Value - minUsd3Value;
                return Math.min(baseLiquidity, maxWithdrawable);
            }
        }
        
        return baseLiquidity;
    }

    /// @inheritdoc BaseStrategyUpgradeable
    function availableDepositLimit(address _owner) public view override returns (uint256) {
        // Check whitelist if enabled
        if (whitelistEnabled && !whitelist[_owner]) {
            return 0;
        }
        
        // Check if strategy is shutdown
        if (_isShutdown()) {
            return 0;
        }
        
        // Return max uint256 to indicate no limit 
        // (minDeposit will be checked in custom deposit/mint functions)
        return type(uint256).max;
    }

    /*//////////////////////////////////////////////////////////////
                        OVERRIDDEN ERC4626 FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit assets with minimum deposit enforcement
    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        require(assets >= minDeposit, "Below minimum deposit");
        
        // Track deposit timestamp if commitment enabled
        if (minCommitmentTime > 0 && depositTimestamp[receiver] == 0) {
            depositTimestamp[receiver] = block.timestamp;
        }
        
        // Delegate to TokenizedStrategy implementation
        bytes memory result = _delegateCall(
            abi.encodeWithSelector(0x6e553f65, assets, receiver) // deposit(uint256,address)
        );
        return abi.decode(result, (uint256));
    }

    /// @notice Mint shares with minimum deposit enforcement
    function mint(uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
        // Calculate assets needed for shares
        assets = _previewMint(shares);
        require(assets >= minDeposit, "Below minimum deposit");
        
        // Track deposit timestamp if commitment enabled
        if (minCommitmentTime > 0 && depositTimestamp[receiver] == 0) {
            depositTimestamp[receiver] = block.timestamp;
        }
        
        // Delegate to TokenizedStrategy implementation
        bytes memory result = _delegateCall(
            abi.encodeWithSelector(0x94bf804d, shares, receiver) // mint(uint256,address)
        );
        return abi.decode(result, (uint256));
    }


    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                        MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setMaxOnCredit(uint256 _maxOnCredit) external onlyManagement {
        require(_maxOnCredit <= 10_000, "Invalid ratio");
        maxOnCredit = _maxOnCredit;
        emit MaxOnCreditUpdated(_maxOnCredit);
    }

    function setUsd3MinRatio(uint256 _usd3MinRatio) external onlyManagement {
        require(_usd3MinRatio <= 10_000, "Invalid ratio");
        usd3MinRatio = _usd3MinRatio;
        emit USD3MinRatioUpdated(_usd3MinRatio);
    }

    function setSusd3Strategy(address _susd3Strategy) external onlyManagement {
        susd3Strategy = _susd3Strategy;
        emit SUSD3StrategyUpdated(_susd3Strategy);
    }

    function setWhitelistEnabled(bool _enabled) external onlyManagement {
        whitelistEnabled = _enabled;
    }

    function setWhitelist(address _user, bool _allowed) external onlyManagement {
        whitelist[_user] = _allowed;
        emit WhitelistUpdated(_user, _allowed);
    }

    function setMinDeposit(uint256 _minDeposit) external onlyManagement {
        minDeposit = _minDeposit;
        emit MinDepositUpdated(_minDeposit);
    }

    function setMinCommitmentTime(uint256 _minCommitmentTime) external onlyManagement {
        minCommitmentTime = _minCommitmentTime;
    }

    function setInterestShareVariant(uint256 _interestShareVariant) external onlyManagement {
        require(_interestShareVariant <= 10_000, "Invalid share");
        interestShareVariant = _interestShareVariant;
        emit InterestShareVariantUpdated(_interestShareVariant);
    }


    /*//////////////////////////////////////////////////////////////
                        MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier nonReentrant() {
        // Use a simple reentrancy guard since we're delegating to TokenizedStrategy
        // which has its own reentrancy protection
        _;
    }


    /*//////////////////////////////////////////////////////////////
                        STORAGE GAP
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[37] private __gap;
}
