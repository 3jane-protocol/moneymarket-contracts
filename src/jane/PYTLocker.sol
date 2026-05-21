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
/// @notice Permanently locks one Pendle Yield Token (YT) and distributes yield to depositors
/// @dev Uses reward-per-share accounting to prevent dilution. Harvests before deposit/claim.
///
/// Key invariants:
/// - YTs are permanently locked (no withdraw, ever)
/// - One locker is bound to one YT forever
/// - Yield is pulled via redeemDueInterestAndRewards on the bound YT
/// - New depositors never receive past yield (harvest before deposit)
/// - Yield is accounted in a single token (SY -> asset)
contract PYTLocker is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant ACC_PRECISION = 1e18;

    /*//////////////////////////////////////////////////////////////
                                CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice The Pendle YT permanently bound to this locker
    address public immutable yt;

    /// @notice The SY used by the bound YT
    address public immutable sy;

    /// @notice Accounting / payout token
    address public immutable asset;

    /// @notice Max locked supply (deposit-time cap; default type(uint256).max)
    uint256 public maxSupply;

    /*//////////////////////////////////////////////////////////////
                              ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Total locked YT
    uint256 public totalSupply;

    /// @notice User => locked YT
    mapping(address => uint256) public balanceOf;

    /// @notice Accumulated asset per locked YT
    uint256 public accYieldPerToken;

    /// @notice Carried numerator remainder from prior harvest divisions
    /// @dev Units are scaled numerator (asset wei * ACC_PRECISION). After harvest this is always < totalSupply.
    /// @dev Carry may share sub-precision yield across deposit boundaries; YT supply never decreases.
    uint256 public yieldRemainder;

    /// @notice User => reward debt
    mapping(address => uint256) public rewardDebt;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event MaxSupplyUpdated(uint256 oldMaxSupply, uint256 newMaxSupply);
    event Deposit(address indexed user, uint256 amount);
    event Harvest(uint256 assetAmount);
    event Claim(address indexed user, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAmount();
    error ZeroAddress();
    error YTExpired();
    error CannotSweepProtectedToken();
    error MaxSupplyExceeded();

    constructor(address owner_, address yt_) Ownable(owner_) {
        if (yt_ == address(0)) revert ZeroAddress();

        yt = yt_;
        sy = IPendleYT(yt_).SY();
        asset = IPendleSY(sy).yieldToken();
        maxSupply = type(uint256).max;
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the max locked supply cap
    /// @dev Cap is a deposit-time guard only; existing locked balances are unaffected.
    ///      Setting below current totalSupply blocks future deposits until the cap is raised.
    /// @param newMaxSupply The new cap (use type(uint256).max for unlimited)
    function setMaxSupply(uint256 newMaxSupply) external onlyOwner {
        emit MaxSupplyUpdated(maxSupply, newMaxSupply);
        maxSupply = newMaxSupply;
    }

    /// @notice Sweep accumulated tokens (e.g., reward tokens) for external distribution
    /// @dev Cannot sweep the bound YT, SY, or asset token
    /// @param token The token to sweep
    /// @param to The recipient address
    /// @param amount The amount to sweep
    function sweep(address token, address to, uint256 amount) external onlyOwner {
        if (token == yt || token == sy || token == asset) revert CannotSweepProtectedToken();
        IERC20(token).safeTransfer(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                HARVEST
    //////////////////////////////////////////////////////////////*/

    /// @notice Harvest yield from the bound YT (callable by anyone)
    function harvest() public nonReentrant {
        _harvest();
    }

    function _harvest() internal {
        uint256 supply = totalSupply;
        if (supply == 0) return;

        uint256 beforeBal = IERC20(asset).balanceOf(address(this));

        // Redeem interest from YT (interest comes as SY). Reward tokens are handled separately (sweep + merkle drop).
        IPendleYT(yt).redeemDueInterestAndRewards(address(this), true, true);

        // SY -> asset
        uint256 syBal = IERC20(sy).balanceOf(address(this));
        if (syBal > 0) {
            IPendleSY(sy).redeem(address(this), syBal, asset, 0, false);
        }

        uint256 gained = IERC20(asset).balanceOf(address(this)) - beforeBal;

        if (gained == 0) return;

        uint256 increment = Math.mulDiv(gained, ACC_PRECISION, supply);
        uint256 newRemainder = mulmod(gained, ACC_PRECISION, supply);
        uint256 remainder = yieldRemainder;

        // At most one carry: prior remainder < old supply <= current supply (no withdraws),
        // and newRemainder < current supply, so the sum is < 2 * current supply.
        uint256 spaceBeforeCarry = supply - remainder;
        if (newRemainder >= spaceBeforeCarry) {
            increment += 1;
            yieldRemainder = newRemainder - spaceBeforeCarry;
        } else {
            yieldRemainder = remainder + newRemainder;
        }

        accYieldPerToken += increment;

        emit Harvest(gained);
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _updateUser(address user) internal {
        uint256 bal = balanceOf[user];
        if (bal == 0) return;

        uint256 accrued = Math.mulDiv(bal, accYieldPerToken, ACC_PRECISION);

        uint256 pending = accrued - rewardDebt[user];
        if (pending == 0) return;

        rewardDebt[user] = accrued;

        IERC20(asset).safeTransfer(user, pending);

        emit Claim(user, pending);
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSIT
    //////////////////////////////////////////////////////////////*/

    /// @notice Permanently lock YTs and earn future yield
    /// @param amount Amount of YT to deposit
    function deposit(uint256 amount) external {
        deposit(amount, msg.sender);
    }

    /// @notice Permanently lock YTs and earn future yield on behalf of a user
    /// @param amount Amount of YT to deposit
    /// @param receiver The user credited with locked YT balance and rewards
    function deposit(uint256 amount, address receiver) public nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (IPendleYT(yt).isExpired()) revert YTExpired();

        uint256 supply = totalSupply;
        uint256 cap = maxSupply;
        if (supply >= cap || amount > cap - supply) revert MaxSupplyExceeded();

        // Harvest FIRST so new depositor never gets old yield
        _harvest();

        // Settle existing yield for beneficiary before increasing their balance
        _updateUser(receiver);

        IERC20(yt).safeTransferFrom(msg.sender, address(this), amount);

        balanceOf[receiver] += amount;
        totalSupply += amount;

        rewardDebt[receiver] = Math.mulDiv(balanceOf[receiver], accYieldPerToken, ACC_PRECISION);

        emit Deposit(receiver, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim accumulated yield
    function claim() external {
        claim(msg.sender);
    }

    /// @notice Claim accumulated yield on behalf of a user
    /// @param onBehalf The user receiving claimed yield
    function claim(address onBehalf) public nonReentrant {
        _harvest();
        _updateUser(onBehalf);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get user's claimable yield (may be stale, call harvest first for accuracy)
    /// @param user The user address
    /// @return pending The amount of asset tokens claimable
    function claimable(address user) external view returns (uint256 pending) {
        uint256 bal = balanceOf[user];
        if (bal == 0) return 0;

        uint256 accrued = Math.mulDiv(bal, accYieldPerToken, ACC_PRECISION);
        pending = accrued - rewardDebt[user];
    }

    /// @notice Maximum amount that can currently be deposited
    /// @return Remaining capacity, or 0 if the YT is expired or at/over the cap
    function maxDeposit() external view returns (uint256) {
        if (IPendleYT(yt).isExpired()) return 0;
        uint256 supply = totalSupply;
        uint256 cap = maxSupply;
        return supply >= cap ? 0 : cap - supply;
    }
}
