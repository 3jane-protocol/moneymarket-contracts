// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Id, IMorpho, MarketParams} from "../interfaces/IMorpho.sol";
import {IMorphoCredit} from "../interfaces/IMorpho.sol";
import {IInsuranceFund} from "../interfaces/IInsuranceFund.sol";
import {IERC20} from "../interfaces/IERC20.sol";

contract CreditLineMock {
    address public owner;
    address public morpho;
    address public mm;
    address public insuranceFund;

    mapping(address account => uint256) public creditLines;
    mapping(Id => mapping(address => uint128)) public borrowerRates;

    constructor(address _morpho) {
        morpho = _morpho;
        owner = msg.sender;
    }

    function setCreditLine(Id id, address borrower, uint256 credit, uint128 premiumRate) external {
        creditLines[borrower] = credit;
        borrowerRates[id][borrower] = premiumRate;

        // Call MorphoCredit to set the actual credit line and premium rate
        IMorphoCredit(morpho).setCreditLine(id, borrower, credit, premiumRate);
    }

    function setMm(address newMm) external {
        mm = newMm;
    }

    function setOwner(address newOwner) external {
        owner = newOwner;
    }

    function setInsuranceFund(address newInsuranceFund) external {
        insuranceFund = newInsuranceFund;
    }

    /// @notice Settle a position for a borrower
    /// @param marketParams Market parameters for the position
    /// @param borrower Address of the borrower
    /// @param assets Amount of assets to settle (currently unused, settles entire position)
    /// @param cover Amount of assets to cover from insurance fund
    function settle(MarketParams memory marketParams, address borrower, uint256 assets, uint256 cover)
        external
        returns (uint256 writtenOffAssets, uint256 writtenOffShares)
    {
        // Only owner can call settle
        require(msg.sender == owner, "Only owner can settle");
        // If cover is greater than 0, handle insurance fund repayment
        if (cover > 0) {
            // Call bring function on insurance fund to transfer loanToken to this contract
            IInsuranceFund(insuranceFund).bring(marketParams.loanToken, cover);

            // Approve the loanToken for the Morpho contract
            IERC20(marketParams.loanToken).approve(morpho, cover);

            // Call repay on the borrower's account
            IMorpho(morpho).repay(marketParams, cover, 0, borrower, "");
        }

        // Settle the account (which will handle any remaining debt)
        (writtenOffAssets, writtenOffShares) = IMorphoCredit(morpho).settleAccount(marketParams, borrower);
    }
}
