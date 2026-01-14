// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "../../lib/openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title IPendleYT
/// @notice Interface for Pendle Yield Token
interface IPendleYT {
    function redeemDueInterestAndRewards(address user, bool redeemInterest, bool redeemRewards)
        external
        returns (uint256 interestOut, uint256[] memory rewardsOut);

    function SY() external view returns (address);
    function isExpired() external view returns (bool);
}

/// @title IPendleSY
/// @notice Interface for Pendle Standardized Yield token
interface IPendleSY {
    function redeem(
        address receiver,
        uint256 amountSharesToRedeem,
        address tokenOut,
        uint256 minTokenOut,
        bool burnFromInternalBalance
    ) external returns (uint256 amountTokenOut);

    function yieldToken() external view returns (address);
}

/// @title PYTLocker
/// @author 3Jane
/// @notice Permanently locks Pendle Yield Tokens (YTs) and distributes yield to depositors
/// @dev Uses reward-per-share accounting to prevent dilution. Harvests before deposit/claim.
///
/// Key invariants:
/// - YTs are permanently locked (no withdraw, ever)
/// - Yield is pulled via redeemDueInterestAndRewards on the YT
/// - New depositors never receive past yield (harvest before deposit)
/// - Yield is accounted in a single token (SY -> asset)
contract PYTLocker is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant ACC_PRECISION = 1e18;

    /*//////////////////////////////////////////////////////////////
                                CONFIG
    //////////////////////////////////////////////////////////////*/

    struct Market {
        address sy;
        address asset; // accounting / payout token
        bool enabled;
    }

    /// @notice YT => market config
    mapping(address => Market) public markets;

    /*//////////////////////////////////////////////////////////////
                              ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice YT => total locked
    mapping(address => uint256) public totalSupply;

    /// @notice YT => user => locked YT
    mapping(address => mapping(address => uint256)) public balanceOf;

    /// @notice YT => accumulated asset per locked YT
    mapping(address => uint256) public accYieldPerToken;

    /// @notice YT => user => reward debt
    mapping(address => mapping(address => uint256)) public rewardDebt;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event MarketAdded(address indexed yt, address indexed sy, address indexed asset);
    event Deposit(address indexed user, address indexed yt, uint256 amount);
    event Harvest(address indexed yt, uint256 assetAmount);
    event Claim(address indexed user, address indexed yt, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error MarketExists();
    error UnsupportedYT();
    error ZeroAmount();
    error YTExpired();

    constructor(address owner_) Ownable(owner_) {}

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Add a new YT market to the locker
    /// @param yt The YT token address
    /// @param sy The SY token address (for redeeming to asset)
    /// @param asset The accounting/payout token
    function addMarket(address yt, address sy, address asset) external onlyOwner {
        if (markets[yt].enabled) revert MarketExists();
        markets[yt] = Market({sy: sy, asset: asset, enabled: true});
        emit MarketAdded(yt, sy, asset);
    }

    /*//////////////////////////////////////////////////////////////
                                HARVEST
    //////////////////////////////////////////////////////////////*/

    /// @notice Harvest yield from a YT market (callable by anyone)
    /// @param yt The YT token address
    function harvest(address yt) public {
        Market memory m = markets[yt];
        if (!m.enabled) revert UnsupportedYT();

        uint256 supply = totalSupply[yt];
        if (supply == 0) return;

        uint256 beforeBal = IERC20(m.asset).balanceOf(address(this));

        // Redeem interest from YT (interest comes as SY)
        IPendleYT(yt).redeemDueInterestAndRewards(address(this), true, true);

        // SY -> asset
        uint256 syBal = IERC20(m.sy).balanceOf(address(this));
        if (syBal > 0) {
            IPendleSY(m.sy).redeem(address(this), syBal, m.asset, 0, false);
        }

        uint256 gained = IERC20(m.asset).balanceOf(address(this)) - beforeBal;

        if (gained == 0) return;

        accYieldPerToken[yt] += (gained * ACC_PRECISION) / supply;

        emit Harvest(yt, gained);
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _updateUser(address yt, address user) internal {
        uint256 bal = balanceOf[yt][user];
        if (bal == 0) return;

        uint256 accrued = (bal * accYieldPerToken[yt]) / ACC_PRECISION;

        uint256 pending = accrued - rewardDebt[yt][user];
        if (pending == 0) return;

        rewardDebt[yt][user] = accrued;

        address asset = markets[yt].asset;
        IERC20(asset).safeTransfer(user, pending);

        emit Claim(user, yt, pending);
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSIT
    //////////////////////////////////////////////////////////////*/

    /// @notice Permanently lock YTs and earn future yield
    /// @param yt The YT token address
    /// @param amount Amount of YT to deposit
    function deposit(address yt, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (!markets[yt].enabled) revert UnsupportedYT();
        if (IPendleYT(yt).isExpired()) revert YTExpired();

        // Harvest FIRST so new depositor never gets old yield
        harvest(yt);

        // Settle existing yield (auto-transfers to user)
        _updateUser(yt, msg.sender);

        IERC20(yt).safeTransferFrom(msg.sender, address(this), amount);

        balanceOf[yt][msg.sender] += amount;
        totalSupply[yt] += amount;

        rewardDebt[yt][msg.sender] = (balanceOf[yt][msg.sender] * accYieldPerToken[yt]) / ACC_PRECISION;

        emit Deposit(msg.sender, yt, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim accumulated yield for a YT
    /// @param yt The YT token address
    function claim(address yt) external nonReentrant {
        harvest(yt);
        _updateUser(yt, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get user's claimable yield (may be stale, call harvest first for accuracy)
    /// @param yt The YT token address
    /// @param user The user address
    /// @return pending The amount of asset tokens claimable
    function claimable(address yt, address user) external view returns (uint256 pending) {
        uint256 bal = balanceOf[yt][user];
        if (bal == 0) return 0;

        uint256 accrued = (bal * accYieldPerToken[yt]) / ACC_PRECISION;
        pending = accrued - rewardDebt[yt][user];
    }

    /// @notice Check if a YT market is supported
    /// @param yt The YT token address
    /// @return True if the market is enabled
    function isSupported(address yt) external view returns (bool) {
        return markets[yt].enabled;
    }
}
