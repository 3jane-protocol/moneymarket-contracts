// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "../../lib/openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "../../lib/openzeppelin/contracts/utils/math/Math.sol";
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

    /// @notice YT => max locked supply (deposit-time cap; default type(uint256).max)
    mapping(address => uint256) public marketMaxSupply;

    /// @notice Tokens that cannot be swept (SY and asset tokens from all markets)
    mapping(address => bool) internal _protectedToken;

    /*//////////////////////////////////////////////////////////////
                              ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice YT => total locked
    mapping(address => uint256) public totalSupply;

    /// @notice YT => user => locked YT
    mapping(address => mapping(address => uint256)) public balanceOf;

    /// @notice YT => accumulated asset per locked YT
    mapping(address => uint256) public accYieldPerToken;

    /// @notice YT => carried numerator remainder from prior harvest divisions
    /// @dev Units are scaled numerator (asset wei * ACC_PRECISION). After harvest this is always < totalSupply[YT].
    /// @dev Market-level carry may share sub-precision yield across deposit boundaries; YT supply never decreases.
    mapping(address => uint256) public yieldRemainder;

    /// @notice YT => user => reward debt
    mapping(address => mapping(address => uint256)) public rewardDebt;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event MarketAdded(address indexed yt, address indexed sy, address indexed asset);
    event MarketMaxSupplyUpdated(address indexed yt, uint256 oldMaxSupply, uint256 newMaxSupply);
    event Deposit(address indexed user, address indexed yt, uint256 amount);
    event Harvest(address indexed yt, uint256 assetAmount);
    event Claim(address indexed user, address indexed yt, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error MarketExists();
    error UnsupportedYT();
    error ZeroAmount();
    error ZeroAddress();
    error YTExpired();
    error CannotSweepMarketToken();
    error MarketMaxSupplyExceeded();

    constructor(address owner_) Ownable(owner_) {}

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Add a new YT market to the locker
    /// @param yt The YT token address
    function addMarket(address yt) external onlyOwner {
        if (markets[yt].enabled) revert MarketExists();
        address sy = IPendleYT(yt).SY();
        address asset = IPendleSY(sy).yieldToken();
        markets[yt] = Market({sy: sy, asset: asset, enabled: true});
        marketMaxSupply[yt] = type(uint256).max;
        _protectedToken[sy] = true;
        _protectedToken[asset] = true;
        emit MarketAdded(yt, sy, asset);
    }

    /// @notice Set the max locked supply cap for a market
    /// @dev Cap is a deposit-time guard only; existing locked balances are unaffected.
    ///      Setting below current totalSupply blocks future deposits until the cap is raised.
    /// @param yt The YT token address
    /// @param maxSupply The new cap (use type(uint256).max for unlimited)
    function setMarketMaxSupply(address yt, uint256 maxSupply) external onlyOwner {
        if (!markets[yt].enabled) revert UnsupportedYT();
        uint256 oldMaxSupply = marketMaxSupply[yt];
        marketMaxSupply[yt] = maxSupply;
        emit MarketMaxSupplyUpdated(yt, oldMaxSupply, maxSupply);
    }

    /// @notice Sweep accumulated tokens (e.g., reward tokens) for external distribution
    /// @dev Cannot sweep YT, SY, or asset tokens from any market
    /// @param token The token to sweep
    /// @param to The recipient address
    /// @param amount The amount to sweep
    function sweep(address token, address to, uint256 amount) external onlyOwner {
        if (markets[token].enabled || _protectedToken[token]) revert CannotSweepMarketToken();
        IERC20(token).safeTransfer(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                HARVEST
    //////////////////////////////////////////////////////////////*/

    /// @notice Harvest yield from a YT market (callable by anyone)
    /// @param yt The YT token address
    function harvest(address yt) public nonReentrant {
        _harvest(yt);
    }

    function _harvest(address yt) internal {
        Market memory m = markets[yt];
        if (!m.enabled) revert UnsupportedYT();

        uint256 supply = totalSupply[yt];
        if (supply == 0) return;

        uint256 beforeBal = IERC20(m.asset).balanceOf(address(this));

        // Redeem interest from YT (interest comes as SY). Reward tokens are handled separately (sweep + merkle drop).
        IPendleYT(yt).redeemDueInterestAndRewards(address(this), true, true);

        // SY -> asset
        uint256 syBal = IERC20(m.sy).balanceOf(address(this));
        if (syBal > 0) {
            IPendleSY(m.sy).redeem(address(this), syBal, m.asset, 0, false);
        }

        uint256 gained = IERC20(m.asset).balanceOf(address(this)) - beforeBal;

        if (gained == 0) return;

        uint256 increment = Math.mulDiv(gained, ACC_PRECISION, supply);
        uint256 newRemainder = mulmod(gained, ACC_PRECISION, supply);
        uint256 remainder = yieldRemainder[yt];

        // At most one carry: prior remainder < old supply <= current supply (no withdraws),
        // and newRemainder < current supply, so the sum is < 2 * current supply.
        uint256 spaceBeforeCarry = supply - remainder;
        if (newRemainder >= spaceBeforeCarry) {
            increment += 1;
            yieldRemainder[yt] = newRemainder - spaceBeforeCarry;
        } else {
            yieldRemainder[yt] = remainder + newRemainder;
        }

        accYieldPerToken[yt] += increment;

        emit Harvest(yt, gained);
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _updateUser(address yt, address user) internal {
        uint256 bal = balanceOf[yt][user];
        if (bal == 0) return;

        uint256 accrued = Math.mulDiv(bal, accYieldPerToken[yt], ACC_PRECISION);

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
    function deposit(address yt, uint256 amount) external {
        deposit(yt, amount, msg.sender);
    }

    /// @notice Permanently lock YTs and earn future yield on behalf of a user
    /// @param yt The YT token address
    /// @param amount Amount of YT to deposit
    /// @param receiver The user credited with locked YT balance and rewards
    function deposit(address yt, uint256 amount, address receiver) public nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (!markets[yt].enabled) revert UnsupportedYT();
        if (IPendleYT(yt).isExpired()) revert YTExpired();

        uint256 supply = totalSupply[yt];
        uint256 cap = marketMaxSupply[yt];
        if (supply >= cap || amount > cap - supply) revert MarketMaxSupplyExceeded();

        // Harvest FIRST so new depositor never gets old yield
        _harvest(yt);

        // Settle existing yield for beneficiary before increasing their balance
        _updateUser(yt, receiver);

        IERC20(yt).safeTransferFrom(msg.sender, address(this), amount);

        balanceOf[yt][receiver] += amount;
        totalSupply[yt] += amount;

        rewardDebt[yt][receiver] = Math.mulDiv(balanceOf[yt][receiver], accYieldPerToken[yt], ACC_PRECISION);

        emit Deposit(receiver, yt, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim accumulated yield for a YT
    /// @param yt The YT token address
    function claim(address yt) external {
        claim(yt, msg.sender);
    }

    /// @notice Claim accumulated yield for a YT on behalf of a user
    /// @param yt The YT token address
    /// @param onBehalf The user receiving claimed yield
    function claim(address yt, address onBehalf) public nonReentrant {
        _harvest(yt);
        _updateUser(yt, onBehalf);
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

        uint256 accrued = Math.mulDiv(bal, accYieldPerToken[yt], ACC_PRECISION);
        pending = accrued - rewardDebt[yt][user];
    }

    /// @notice Check if a YT market is supported
    /// @param yt The YT token address
    /// @return True if the market is enabled
    function isSupported(address yt) external view returns (bool) {
        return markets[yt].enabled;
    }

    /// @notice Maximum amount that can currently be deposited into a market
    /// @param yt The YT token address
    /// @return Remaining capacity, or 0 if the market is unsupported, expired, or at/over the cap
    function maxDeposit(address yt) external view returns (uint256) {
        if (!markets[yt].enabled) return 0;
        if (IPendleYT(yt).isExpired()) return 0;
        uint256 supply = totalSupply[yt];
        uint256 cap = marketMaxSupply[yt];
        return supply >= cap ? 0 : cap - supply;
    }
}
