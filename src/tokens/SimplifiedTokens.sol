// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title SimplifiedWAUSDC
 * @notice Simplified ERC4626 wrapper for Aave's aUSDC
 * @dev This is a simplified version for testing. Production should use
 * the full StaticATokenLM implementation from bgd-labs/static-a-token-v3
 */
contract SimplifiedWAUSDC is ERC4626 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    address public immutable aToken;
    uint256 private _lastUpdate;
    uint256 private _exchangeRate = 1e6; // Start at 1:1 for USDC (6 decimals)

    constructor(address _aToken, string memory _name, string memory _symbol)
        ERC4626(IERC20(_aToken))
        ERC20(_name, _symbol)
    {
        aToken = _aToken;
        _lastUpdate = block.timestamp;
    }

    function decimals() public pure override(ERC4626) returns (uint8) {
        return 6; // USDC decimals
    }

    function totalAssets() public view override returns (uint256) {
        // In production, this would query the actual aToken balance
        // For testing, we simulate yield accrual
        uint256 balance = IERC20(aToken).balanceOf(address(this));
        uint256 timeElapsed = block.timestamp - _lastUpdate;

        // Simulate ~3% APY
        if (timeElapsed > 0 && balance > 0) {
            uint256 yield = (balance * 3 * timeElapsed) / (100 * 365 days);
            return balance + yield;
        }
        return balance;
    }
}

/**
 * @title SimplifiedUSD3
 * @notice Simplified senior tranche vault
 * @dev This is a simplified version for testing. Production should use
 * the full USD3 implementation with Yearn V3 tokenized strategy
 */
contract SimplifiedUSD3 is ERC4626 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    address public morphoCredit;
    address public sUSD3;
    uint256 public performanceFee; // In basis points (10000 = 100%)
    uint256 public maxOnCredit = 8000; // Max 80% deployed to credit markets

    mapping(address => uint256) public depositTimestamp;
    uint256 public minCommitmentTime = 30 days;

    event PerformanceFeeUpdated(uint256 newFee);
    event SUSD3Updated(address newSUSD3);

    constructor(address _waUSDC, address _morphoCredit, string memory _name, string memory _symbol)
        ERC4626(IERC20(_waUSDC))
        ERC20(_name, _symbol)
    {
        morphoCredit = _morphoCredit;
    }

    function setSUSD3(address _sUSD3) external {
        require(sUSD3 == address(0), "Already set");
        sUSD3 = _sUSD3;
        emit SUSD3Updated(_sUSD3);
    }

    function setPerformanceFee(uint256 _fee) external {
        require(_fee <= 10000, "Fee too high");
        performanceFee = _fee;
        emit PerformanceFeeUpdated(_fee);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        depositTimestamp[receiver] = block.timestamp;
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        require(block.timestamp >= depositTimestamp[owner] + minCommitmentTime, "Commitment period not met");
        super._withdraw(caller, receiver, owner, assets, shares);
    }
}

/**
 * @title SimplifiedSUSD3
 * @notice Simplified subordinate tranche vault
 * @dev This is a simplified version for testing. Production should use
 * the full sUSD3 implementation with cooldown periods
 */
contract SimplifiedSUSD3 is ERC4626 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    struct UserCooldown {
        uint128 cooldownEnd;
        uint128 shares;
    }

    mapping(address => UserCooldown) public cooldowns;
    mapping(address => uint256) public lockedUntil;

    uint256 public cooldownDuration = 7 days;
    uint256 public withdrawalWindow = 2 days;
    uint256 public lockPeriod = 30 days;

    event CooldownStarted(address indexed user, uint256 shares, uint256 timestamp);
    event WithdrawalCompleted(address indexed user, uint256 shares, uint256 assets);

    constructor(address _usd3, string memory _name, string memory _symbol)
        ERC4626(IERC20(_usd3))
        ERC20(_name, _symbol)
    {}

    function startCooldown(uint256 shares) external {
        require(balanceOf(msg.sender) >= shares, "Insufficient balance");

        cooldowns[msg.sender] =
            UserCooldown({cooldownEnd: uint128(block.timestamp + cooldownDuration), shares: uint128(shares)});

        emit CooldownStarted(msg.sender, shares, block.timestamp);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        lockedUntil[receiver] = block.timestamp + lockPeriod;
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        UserCooldown memory cooldown = cooldowns[owner];

        require(block.timestamp >= lockedUntil[owner], "Lock period active");
        require(block.timestamp >= cooldown.cooldownEnd, "Cooldown not complete");
        require(block.timestamp <= cooldown.cooldownEnd + withdrawalWindow, "Withdrawal window expired");
        require(shares <= cooldown.shares, "Exceeds cooled down amount");

        // Update cooldown
        cooldowns[owner].shares = cooldown.shares - uint128(shares);

        super._withdraw(caller, receiver, owner, assets, shares);

        emit WithdrawalCompleted(owner, shares, assets);
    }
}
