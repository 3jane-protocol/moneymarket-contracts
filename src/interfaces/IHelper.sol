// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC4626} from "../../lib/forge-std/src/interfaces/IERC4626.sol";

import {MarketParams} from "./IMorpho.sol";

/// @title IHelper
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice Helper contract to simplify interactions with 3Jane's token ecosystem and Morpho protocol
/// @dev This contract handles the token conversions: USDC → waUSDC → USD3 → sUSD3
interface IHelper {
    /// @notice The Morpho protocol contract address
    /// @return The address of the Morpho contract
    function MORPHO() external view returns (address);

    /// @notice The USD3 token address (ERC4626 vault for waUSDC)
    /// @return The address of the USD3 token
    function USD3() external view returns (address);

    /// @notice The sUSD3 token address (subordinate/staked USD3, also ERC4626)
    /// @return The address of the sUSD3 token
    function sUSD3() external view returns (address);

    /// @notice The USDC token address (base stablecoin)
    /// @return The address of the USDC token
    function USDC() external view returns (address);

    /// @notice The waUSDC token address (wrapped asset USDC, ERC4626 vault)
    /// @return The address of the waUSDC token
    function WAUSDC() external view returns (address);

    /// @notice Deposits USDC and converts through the token hierarchy
    /// @dev Flow: USDC → waUSDC → USD3 (→ sUSD3 if hop=true)
    /// @param assets The amount of USDC to deposit
    /// @param receiver The address that will receive the USD3/sUSD3 shares
    /// @param hop If true, deposits into sUSD3; if false, stops at USD3
    /// @return The amount of shares minted (USD3 or sUSD3 depending on hop)
    function deposit(uint256 assets, address receiver, bool hop) external returns (uint256);

    /// @notice Redeems USD3 shares back to USDC
    /// @dev Flow: USD3 → waUSDC → USDC. Caller must have approved Helper for USD3 spending
    /// @param shares The amount of USD3 shares to redeem
    /// @param receiver The address that will receive the USDC
    /// @return The amount of USDC received
    function redeem(uint256 shares, address receiver) external returns (uint256);

    /// @notice Borrows assets from a Morpho market and unwraps to USDC
    /// @dev The borrowed waUSDC is automatically unwrapped to USDC for the borrower
    /// @param marketParams The market parameters defining which market to borrow from
    /// @param assets The amount of assets to borrow (in waUSDC terms)
    /// @return usdcAmount The amount of USDC received by the borrower
    /// @return shares The amount of borrow shares created
    function borrow(MarketParams memory marketParams, uint256 assets) external returns (uint256, uint256);

    /// @notice Repays a loan by wrapping USDC to waUSDC
    /// @dev Flow: USDC → waUSDC → Morpho repay. Caller must have approved Helper for USDC spending
    /// @param marketParams The market parameters defining which market to repay
    /// @param assets The amount of USDC to repay
    /// @param onBehalf The address whose debt is being repaid
    /// @param data Additional data for the repay operation (e.g., for callbacks)
    /// @return usdcAmount The amount of USDC used from the caller
    /// @return shares The amount of borrow shares repaid
    function repay(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes calldata data)
        external
        returns (uint256, uint256);
}
