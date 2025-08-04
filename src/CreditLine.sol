// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.18;

import {Id, IMorpho, IMorphoCredit, MarketParams} from "./interfaces/IMorpho.sol";
import {ICreditLine} from "./interfaces/ICreditLine.sol";
import {IProtocolConfig, CreditLineConfig} from "./interfaces/IProtocolConfig.sol";
import {IProver} from "./interfaces/IProver.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {MathLib} from "./libraries/MathLib.sol";
import {Ownable} from "../lib/openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IInsuranceFund} from "./interfaces/IInsuranceFund.sol";

/// @title CreditLine
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice This contract manages credit line operations for the Morpho protocol
/// @dev Handles credit line creation, validation, and configuration management
contract CreditLine is ICreditLine, Ownable {
    using MathLib for uint256;

    /// @notice Maximum premium rate allowed per second (100% APR / 365 days)
    /// @dev ~31.7 billion per second for 100% APR
    uint256 private constant MAX_DRP = 31709791983;

    /// @notice Address of the OZ Defender
    /// @inheritdoc ICreditLine
    address public ozd;

    /// @notice Address of the markdown manager
    /// @inheritdoc ICreditLine
    address public mm;

    /// @notice Address of the prover contract for additional verification
    /// @dev Prover can be set to address(0) to disable verification
    /// @inheritdoc ICreditLine
    address public prover;

    /// @notice Address of the insurance fund
    address public insuranceFund;

    /// @inheritdoc ICreditLine
    address public immutable MORPHO;

    /* CONSTRUCTOR */
    /// @notice Initializes the CreditLine contract with required addresses
    /// @param _morpho Address of the main Morpho Credit contract
    /// @param _owner Address that will have owner privileges
    /// @param _ozd Address of the OZD contract for external touch
    /// @param _prover Address of the prover contract (can be address(0))
    /// @param _mm Address of the markdown manager
    /// @dev Validates all non-zero addresses and transfers ownership to the specified owner
    constructor(address _morpho, address _owner, address _ozd, address _mm, address _prover) Ownable(_owner) {
        // Validate that critical addresses are not zero
        if (_morpho == address(0)) revert ErrorsLib.ZeroAddress();
        if (_ozd == address(0)) revert ErrorsLib.ZeroAddress();
        if (_mm == address(0)) revert ErrorsLib.ZeroAddress();

        // Initialize contract state
        MORPHO = _morpho;
        ozd = _ozd;
        prover = _prover;
        mm = _mm;
    }

    /// @dev Reverts if the caller is not the owner or ozd
    /// @notice Ensures only the contract owner or ozd can execute privileged functions
    modifier onlyOwnerOrOzd() {
        if (msg.sender != owner() && msg.sender != ozd) revert ErrorsLib.NotOwnerOrOzd();
        _;
    }

    /// @notice Updates the OZD contract address
    /// @param newOzd New address for the OZD contract
    /// @dev Only callable by the contract owner
    /// @dev Reverts if the new address is the same as the current one
    /// @inheritdoc ICreditLine
    function setOzd(address newOzd) external onlyOwner {
        if (newOzd == ozd) revert ErrorsLib.AlreadySet();

        ozd = newOzd;
    }

    /// @notice Updates the markdown manager address
    /// @param newMm New address for the markdown manager
    /// @dev Only callable by the contract owner
    /// @dev Reverts if the new address is the same as the current one
    /// @inheritdoc ICreditLine
    function setMm(address newMm) external onlyOwner {
        if (newMm == mm) revert ErrorsLib.AlreadySet();

        mm = newMm;
    }

    /// @notice Updates the prover contract address
    /// @param newProver New address for the prover contract
    /// @dev Only callable by the contract owner
    /// @dev Reverts if the new address is the same as the current one
    /// @dev Can be set to address(0) to disable verification
    /// @inheritdoc ICreditLine
    function setProver(address newProver) external onlyOwner {
        if (newProver == prover) revert ErrorsLib.AlreadySet();

        prover = newProver;
    }

    /// @notice Updates the insurance fund address
    /// @param newInsuranceFund New address for the insurance fund
    /// @dev Only callable by the contract owner
    /// @dev Reverts if the new address is the same as the current one
    function setInsuranceFund(address newInsuranceFund) external onlyOwner {
        if (newInsuranceFund == insuranceFund) revert ErrorsLib.AlreadySet();

        insuranceFund = newInsuranceFund;
    }

    /// @notice Sets credit lines for multiple borrowers
    /// @param ids Array of market IDs
    /// @param borrowers Array of borrower addresses
    /// @param vv Array of value verified values
    /// @param credit Array of credit amounts
    /// @param drp Array of default risk premiums
    function setCreditLines(
        Id[] calldata ids,
        address[] calldata borrowers,
        uint256[] calldata vv,
        uint256[] calldata credit,
        uint128[] calldata drp
    ) external onlyOwnerOrOzd {
        uint256 len = ids.length;
        if (borrowers.length != len || vv.length != len || credit.length != len || drp.length != len) {
            revert ErrorsLib.InvalidArrayLength();
        }

        // Get protocol configuration for validation
        CreditLineConfig memory terms = IProtocolConfig(IMorphoCredit(MORPHO).protocolConfig()).getCreditLineConfig();

        for (uint256 i = 0; i < len; ++i) {
            // Verify the credit line parameters if a prover is set
            if (prover != address(0) && !IProver(prover).verify(ids[i], borrowers[i], vv[i], credit[i], drp[i])) {
                revert ErrorsLib.Unverified();
            }

            // Validate value verified against maximum allowed
            if (vv[i] > terms.maxVV) revert ErrorsLib.MaxVvExceeded();

            // Validate credit amount against minimum and maximum limits
            if (credit[i] > terms.maxCreditLine) revert ErrorsLib.MaxCreditLineExceeded();
            if (credit[i] < terms.minCreditLine) revert ErrorsLib.MinCreditLineExceeded();

            // Validate loan-to-value ratio (LTV) - credit/vv must not exceed maxLTV
            if (credit[i].wDivDown(vv[i]) > terms.maxLTV) revert ErrorsLib.MaxLtvExceeded();

            // Validate default risk premium against both contract and protocol limits
            if (drp[i] > MAX_DRP || drp[i] > terms.maxDRP) revert ErrorsLib.MaxDrpExceeded();

            // Set the credit line in the main Morpho contract
            IMorphoCredit(MORPHO).setCreditLine(ids[i], borrowers[i], credit[i], drp[i]);
        }
    }

    /// @notice Close a payment cycle and create it on-chain retroactively
    /// @param id Market ID
    /// @param endDate Cycle end date
    /// @param borrowers Array of borrower addresses
    /// @param repaymentBps Array of repayment basis points (e.g., 500 = 5%)
    /// @param endingBalances Array of ending balances for penalty calculations
    /// @dev The ending balance is crucial for penalty calculations - it represents
    /// the borrower's debt at cycle end and is used to calculate penalty interest
    /// from that point forward, ensuring path independence
    function closeCycleAndPostObligations(
        Id id,
        uint256 endDate,
        address[] calldata borrowers,
        uint256[] calldata repaymentBps,
        uint256[] calldata endingBalances
    ) external onlyOwnerOrOzd {
        IMorphoCredit(MORPHO).closeCycleAndPostObligations(id, endDate, borrowers, repaymentBps, endingBalances);
    }

    /// @notice Add more obligations to the most recently closed cycle
    /// @param id Market ID
    /// @param borrowers Array of borrower addresses
    /// @param repaymentBps Array of repayment basis points (e.g., 500 = 5%)
    /// @param endingBalances Array of ending balances
    function addObligationsToLatestCycle(
        Id id,
        address[] calldata borrowers,
        uint256[] calldata repaymentBps,
        uint256[] calldata endingBalances
    ) external onlyOwnerOrOzd {
        IMorphoCredit(MORPHO).addObligationsToLatestCycle(id, borrowers, repaymentBps, endingBalances);
    }

    /// @notice Settle a position for a borrower
    /// @param marketParams Market parameters for the position
    /// @param borrower Address of the borrower
    /// @param assets Amount of assets to settle (currently unused, settles entire position)
    /// @param cover Amount of assets to cover from insurance fund (must be <= assets)
    /// @dev Only callable by owner or OZD contract
    /// @dev If cover > 0, transfers loanToken from insurance fund, approves, and repays before settling
    /// @dev Returns the amount of assets and shares written off
    function settle(MarketParams memory marketParams, address borrower, uint256 assets, uint256 cover)
        external
        onlyOwnerOrOzd
        returns (uint256 writtenOffAssets, uint256 writtenOffShares)
    {
        // Validate that cover is less than or equal to assets
        if (cover > assets) revert ErrorsLib.InvalidCoverAmount();

        // If cover is greater than 0, handle insurance fund repayment
        if (cover > 0) {
            // Call bring function on insurance fund to transfer loanToken to this contract
            IInsuranceFund(insuranceFund).bring(marketParams.loanToken, cover);

            // Approve the loanToken for the Morpho contract
            IERC20(marketParams.loanToken).approve(address(MORPHO), cover);

            // Call repay on the borrower's account
            IMorpho(MORPHO).repay(marketParams, cover, 0, borrower, "");
        }

        // Settle the account (which will handle any remaining debt)
        (writtenOffAssets, writtenOffShares) = IMorphoCredit(MORPHO).settleAccount(marketParams, borrower);
    }
}
