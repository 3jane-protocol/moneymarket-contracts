// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {CreditLine} from "./CreditLine.sol";
import {Jane} from "./jane/Jane.sol";
import {MarketParams} from "./interfaces/IMorpho.sol";

/// @title SettlementController
/// @author 3Jane
/// @notice Atomically burns a borrower's JANE tokens and settles their account
/// @dev Designed to be set as the OZD address in CreditLine to enable atomic settlement with token burns
contract SettlementController {
    error NotOwner();

    event SettledWithBurn(
        address indexed borrower, uint256 burnedAmount, uint256 writtenOffAssets, uint256 writtenOffShares
    );

    CreditLine public immutable creditLine;
    Jane public immutable JANE;

    /// @notice Initializes the settlement controller
    /// @param _creditLine Address of the CreditLine contract
    /// @param _jane Address of the JANE token contract
    constructor(address _creditLine, address _jane) {
        creditLine = CreditLine(_creditLine);
        JANE = Jane(_jane);
    }

    /// @notice Returns the owner address from the CreditLine contract
    function owner() public view returns (address) {
        return creditLine.owner();
    }

    /// @notice Settles a borrower's account and burns their entire JANE token balance
    /// @param marketParams Market parameters for the position
    /// @param borrower Address of the borrower
    /// @param assets Amount of assets to settle
    /// @param cover Amount of assets to cover from insurance fund
    /// @return writtenOffAssets Amount of assets written off
    /// @return writtenOffShares Amount of shares written off
    /// @dev Only callable by the owner. Burns JANE before settling to ensure atomic execution.
    ///      SettlementController must have burner role on JANE token.
    function settleAndBurn(MarketParams memory marketParams, address borrower, uint256 assets, uint256 cover)
        external
        returns (uint256 writtenOffAssets, uint256 writtenOffShares)
    {
        if (msg.sender != owner()) revert NotOwner();

        uint256 burnedAmount = JANE.balanceOf(borrower);
        if (burnedAmount > 0) {
            JANE.burn(borrower, burnedAmount);
        }

        (writtenOffAssets, writtenOffShares) = creditLine.settle(marketParams, borrower, assets, cover);

        emit SettledWithBurn(borrower, burnedAmount, writtenOffAssets, writtenOffShares);
    }
}
