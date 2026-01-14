// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title ICallableCredit
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Interface for the CallableCredit contract
/// @dev Enables counter-protocols to draw against borrower credit lines
/// @dev Principal tracked in USDC (draw cap), waUSDC tracked for close reconciliation
interface ICallableCredit {
    /// @notice Silo structure for each counter-protocol
    /// @param totalPrincipal Total USDC principal in this silo (draw cap)
    /// @param totalShares Total shares issued to borrowers in this silo
    /// @param totalWaUsdcHeld Actual waUSDC held in this silo
    struct Silo {
        uint128 totalPrincipal;
        uint128 totalShares;
        uint128 totalWaUsdcHeld;
    }

    /// @notice Emitted when a position is opened
    /// @param counterProtocol The counter-protocol address
    /// @param borrower The borrower address
    /// @param usdcAmount The USDC amount requested
    /// @param shares The shares minted to the borrower
    event PositionOpened(address indexed counterProtocol, address indexed borrower, uint256 usdcAmount, uint256 shares);

    /// @notice Emitted when a position is closed
    /// @param counterProtocol The counter-protocol address
    /// @param borrower The borrower address
    /// @param usdcPrincipal The USDC principal amount
    /// @param shares The shares burned
    event PositionClosed(
        address indexed counterProtocol, address indexed borrower, uint256 usdcPrincipal, uint256 shares
    );

    /// @notice Emitted when a counter-protocol draws from a specific borrower
    /// @param counterProtocol The counter-protocol address
    /// @param borrower The borrower whose position was drawn from
    /// @param recipient The address receiving the drawn funds
    /// @param usdcAmount The USDC amount requested
    /// @param usdcSent The actual USDC sent
    /// @param waUsdcSent The waUSDC sent (if USDC redemption limited)
    event Draw(
        address indexed counterProtocol,
        address indexed borrower,
        address indexed recipient,
        uint256 usdcAmount,
        uint256 usdcSent,
        uint256 waUsdcSent
    );

    /// @notice Emitted when a counter-protocol performs a pro-rata draw
    /// @param counterProtocol The counter-protocol address
    /// @param recipient The address receiving the drawn funds
    /// @param usdcAmount The USDC amount requested
    /// @param usdcSent The actual USDC sent
    /// @param waUsdcSent The waUSDC sent (if USDC redemption limited)
    event ProRataDraw(
        address indexed counterProtocol,
        address indexed recipient,
        uint256 usdcAmount,
        uint256 usdcSent,
        uint256 waUsdcSent
    );

    /// @notice Emitted when a counter-protocol's authorization status changes
    /// @param counterProtocol The counter-protocol address
    /// @param authorized The new authorization status
    event CounterProtocolAuthorized(address indexed counterProtocol, bool authorized);

    /// @notice Open a callable credit position by borrowing from MorphoCredit
    /// @dev Only callable by authorized counter-protocols
    /// @param borrower The 3Jane borrower whose credit line will be used
    /// @param usdcAmount The USDC amount to borrow and reserve
    function open(address borrower, uint256 usdcAmount) external;

    /// @notice Close a borrower's position and repay to MorphoCredit
    /// @dev Only callable by authorized counter-protocols
    /// @dev Returns excess to borrower if they repaid MorphoCredit directly
    /// @param borrower The borrower whose position to close
    /// @return usdcSent USDC amount sent to borrower as excess
    /// @return waUsdcSent waUSDC amount sent to borrower as excess (if USDC redemption limited)
    function close(address borrower) external returns (uint256 usdcSent, uint256 waUsdcSent);

    /// @notice Draw funds from a specific borrower's position (targeted draw)
    /// @dev Only callable by authorized counter-protocols
    /// @param borrower The borrower to draw from
    /// @param usdcAmount The USDC amount to draw
    /// @param recipient The address to receive the drawn funds
    /// @return usdcSent The actual USDC sent
    /// @return waUsdcSent The waUSDC sent (if USDC redemption limited)
    function draw(address borrower, uint256 usdcAmount, address recipient)
        external
        returns (uint256 usdcSent, uint256 waUsdcSent);

    /// @notice Draw funds pro-rata from all positions in the caller's silo
    /// @dev Only callable by authorized counter-protocols
    /// @param usdcAmount The USDC amount to draw
    /// @param recipient The address to receive the drawn funds
    /// @return usdcSent The actual USDC sent
    /// @return waUsdcSent The waUSDC sent (if USDC redemption limited)
    function draw(uint256 usdcAmount, address recipient) external returns (uint256 usdcSent, uint256 waUsdcSent);

    /// @notice Get silo data for a counter-protocol
    /// @param counterProtocol The counter-protocol address
    /// @return totalPrincipal The total USDC principal in the silo (draw cap)
    /// @return totalShares The total shares issued in the silo
    /// @return totalWaUsdcHeld The actual waUSDC held in the silo
    function silos(address counterProtocol)
        external
        view
        returns (uint128 totalPrincipal, uint128 totalShares, uint128 totalWaUsdcHeld);

    /// @notice Get borrower shares in a counter-protocol's silo
    /// @param counterProtocol The counter-protocol address
    /// @param borrower The borrower address
    /// @return The number of shares held by the borrower
    function borrowerShares(address counterProtocol, address borrower) external view returns (uint256);

    /// @notice Calculate the current principal value of a borrower's shares in USDC
    /// @param counterProtocol The counter-protocol address
    /// @param borrower The borrower address
    /// @return The principal value in USDC (draw cap)
    function getBorrowerPrincipal(address counterProtocol, address borrower) external view returns (uint256);

    /// @notice Check if a counter-protocol is authorized
    /// @param counterProtocol The counter-protocol address
    /// @return True if authorized
    function authorizedCounterProtocols(address counterProtocol) external view returns (bool);

    /// @notice Set authorization status for a counter-protocol
    /// @dev Only callable by owner
    /// @param counterProtocol The counter-protocol address
    /// @param authorized The authorization status
    function setAuthorizedCounterProtocol(address counterProtocol, bool authorized) external;
}
