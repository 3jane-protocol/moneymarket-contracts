// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCAuctionLib} from "../libraries/LCCAuctionLib.sol";

interface ILeveragedCallableCreditVault {
    enum Phase {
        Normal,
        PreCall,
        Funding,
        Closed
    }

    struct VaultParams {
        address owner;
        address marginAsset;
        address fundingAsset;
        address usd3;
        address marginOracle;
        address treasury;
        uint256 startTimestamp;
        uint256 epochLength;
        uint256 normalDuration;
        uint256 preCallDuration;
        uint256 fundingDuration;
        uint256 marginRatioBps;
        uint256 protocolCommitmentCap;
        uint256 userCommitmentCap;
        uint256 exitCapBps;
        uint256 exitDelayEpochs;
        uint256 minDepositAssets;
        uint256 auctionStepCount;
        uint256 auctionStepDecayRateBps;
        uint256 maxAuctionAwardBps;
    }

    struct Account {
        uint256 activeMargin;
        uint256 activeCommitment;
        uint256 pendingMargin;
        uint256 pendingCommitment;
        uint256 pendingActivationEpoch;
        uint256 calledEpochCursor;
        uint256 claimableExitMargin;
        uint256 exitBucketMargin;
        uint256 exitBucketCommitment;
        bool exitRequested;
        uint256 exitMaturityEpoch;
        bool exitClaimed;
        bool exitMatured;
    }

    struct EpochState {
        bool callOpened;
        uint256 commitmentDenominator;
        uint256 callAmount;
        uint256 marginAtCallOpen;
        uint256 fundedAmount;
        uint256 marginReleased;
        uint256 fundedUsersRemainingMargin;
        uint256 fundedUsersRemainingCommitment;
        bool slashFinalized;
        bool slashDisabledByShutdown;
    }

    event DepositCheckpointed(
        address indexed user,
        uint256 marginAssets,
        uint256 marginValue,
        uint256 commitment,
        uint256 activationEpoch,
        bool immediate
    );
    event PendingActivated(uint256 indexed epoch, uint256 marginAssets, uint256 commitment);
    event EpochCallOpened(uint256 indexed epoch, uint256 callAmount, uint256 commitmentDenominator);
    event CallFunded(address indexed user, uint256 indexed epoch, uint256 obligationAmount);
    event MarginReleased(address indexed user, uint256 indexed epoch, uint256 marginAssets);
    event EscrowedFundingCreated(address indexed user, uint256 indexed epoch, uint256 fundingAmount);
    event EscrowedFundingPlaced(address indexed user, uint256 fundingAmount);
    event EscrowedFundingClaimed(address indexed user, address indexed receiver, uint256 fundingAmount);
    event UserDefaulted(address indexed user, uint256 indexed epoch, uint256 slashedMargin, uint256 slashedCommitment);
    event EpochSlashFinalized(
        uint256 indexed epoch, uint256 slashedMargin, uint256 slashedCommitment, bool disabledByShutdown
    );
    event ExitRequested(address indexed user, uint256 indexed maturityEpoch, uint256 marginAssets, uint256 commitment);
    event ExitMatured(uint256 indexed maturityEpoch, uint256 marginAssets, uint256 commitment);
    event ExitedMarginClaimed(address indexed user, address indexed receiver, uint256 marginAssets);
    event EmergencyMarginClaimed(address indexed user, address indexed receiver, uint256 marginAssets);
    event RiskCapUpdated(
        uint256 protocolCommitmentCap, uint256 userCommitmentCap, uint256 exitCapBps, uint256 minDepositAssets
    );
    event EmergencyShutdown(uint256 indexed epoch, uint256 timestamp);
    event AuctionKicked(uint256 indexed epoch, uint256 shortfallAmount, uint256 marginPool);
    event AuctionFill(address indexed filler, uint256 indexed epoch, uint256 fillAmount, uint256 marginAward);
    event AuctionSettled(uint256 indexed epoch, uint256 filledAmount, uint256 marginAwarded, uint256 marginToTreasury);
    event AuctionAwardCapUpdated(uint256 maxAuctionAwardBps);

    error PendingDepositExists();
    error AccountMaterializationIncomplete();

    function currentEpoch() external view returns (uint256);
    function currentPhase() external view returns (Phase);
    function phaseEndsAt(uint256 epoch, Phase phase) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 commitment);
    function requestExit() external returns (uint256 maturityEpoch);
    function claimExitedMargin(address receiver) external returns (uint256 assets);
    function claimEmergencyMargin(address receiver) external returns (uint256 assets);
    function setRiskCaps(
        uint256 newProtocolCommitmentCap,
        uint256 newUserCommitmentCap,
        uint256 newExitCapBps,
        uint256 newMinDeposit
    ) external;
    function shutdown() external;
    function openEpochCall(uint256 epoch, uint256 callAmount) external;
    function fundEpochCall(uint256 epoch) external returns (uint256 obligationAmount);
    function fundEpochCallFor(uint256 epoch, address user) external returns (uint256 obligationAmount);
    function takeAuction(uint256 epoch, uint256 maxFillAmount)
        external
        returns (uint256 filledAmount, uint256 marginAward);
    function setMaxAuctionAwardBps(uint256 newMaxAuctionAwardBps) external;
    function getAuctionState(uint256 epoch) external view returns (LCCAuctionLib.AuctionState memory);
    function pendingAuctionEpochPlusOne() external view returns (uint256);
    function maxAuctionAwardBps() external view returns (uint256);
    function auctionStepCount() external view returns (uint256);
    function auctionStepDuration() external view returns (uint256);
    function auctionStepDecayRateBps() external view returns (uint256);
    function depositEscrowedFunding(address user) external returns (uint256 placedAmount);
    function claimEscrowedFunding(address receiver) external returns (uint256 assets);
    function finalizeEpochSlash(uint256 epoch) external;
    function materializeAccount(address user) external;
    function getAccount(address user) external view returns (Account memory);
    function getEpochState(uint256 epoch) external view returns (EpochState memory);
    function obligationOf(uint256 epoch, address user) external view returns (uint256);
    function claimableExitedMargin(address user) external view returns (uint256);
    function calledEpochs() external view returns (uint256[] memory);
    function totalActiveMargin() external view returns (uint256);
    function totalActiveCommitment() external view returns (uint256);
    function totalPendingMargin() external view returns (uint256);
    function totalPendingCommitment() external view returns (uint256);
    function totalEscrowedFundingAmount() external view returns (uint256);
    function escrowedFundingAmount(address user) external view returns (uint256);
    function protocolCommitmentCap() external view returns (uint256);
    function userCommitmentCap() external view returns (uint256);
    function exitCapBps() external view returns (uint256);
    function minDepositAssets() external view returns (uint256);
    function shutdownActive() external view returns (bool);
    function fundedEpoch(uint256 epoch, address user) external view returns (bool);
    function defaultedEpoch(uint256 epoch, address user) external view returns (bool);
    function pendingMarginByActivationEpoch(uint256 epoch) external view returns (uint256);
    function pendingCommitmentByActivationEpoch(uint256 epoch) external view returns (uint256);
    function exitBucketMarginByMaturity(uint256 epoch) external view returns (uint256);
    function exitBucketCommitmentByMaturity(uint256 epoch) external view returns (uint256);
}
