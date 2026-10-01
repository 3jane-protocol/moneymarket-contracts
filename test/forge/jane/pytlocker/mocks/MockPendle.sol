// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {ERC20} from "../../../../../lib/openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mock underlying asset token
contract MockAsset is ERC20 {
    constructor() ERC20("Mock Asset", "ASSET") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Mock SY token that wraps the asset
contract MockSY is ERC20 {
    address public immutable asset;

    constructor(address _asset) ERC20("Mock SY", "mSY") {
        asset = _asset;
    }

    function yieldToken() external view returns (address) {
        return asset;
    }

    /// @notice Redeem SY for underlying asset (1:1 for simplicity)
    function redeem(
        address receiver,
        uint256 amountSharesToRedeem,
        address tokenOut,
        uint256, /* minTokenOut */
        bool /* burnFromInternalBalance */
    )
        external
        returns (uint256)
    {
        require(tokenOut == asset, "MockSY: invalid tokenOut");
        _burn(msg.sender, amountSharesToRedeem);
        ERC20(asset).transfer(receiver, amountSharesToRedeem);
        return amountSharesToRedeem;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function fundAsset(uint256 amount) external {
        MockAsset(asset).mint(address(this), amount);
    }
}

/// @notice Mock YT token
contract MockYT is ERC20 {
    address public immutable SY;
    uint256 public expiry;

    mapping(address => uint256) public pendingInterest;

    constructor(address _sy, uint256 _expiry) ERC20("Mock YT", "mYT") {
        SY = _sy;
        expiry = _expiry;
    }

    function isExpired() external view returns (bool) {
        return block.timestamp >= expiry;
    }

    function redeemDueInterestAndRewards(
        address user,
        bool redeemInterest,
        bool /* redeemRewards */
    )
        external
        returns (uint256 interestOut, uint256[] memory rewardsOut)
    {
        rewardsOut = new uint256[](0);
        if (!redeemInterest) return (0, rewardsOut);

        interestOut = pendingInterest[user];
        if (interestOut > 0) {
            pendingInterest[user] = 0;
            MockSY(SY).transfer(user, interestOut);
        }
        return (interestOut, rewardsOut);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function accrueInterest(address holder, uint256 amount) external {
        pendingInterest[holder] += amount;
    }

    function setExpiry(uint256 newExpiry) external {
        expiry = newExpiry;
    }
}
