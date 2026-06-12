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
        address callableAsset;
        address usd3;
        address marginOracle;
        address treasury;
        uint256 startTimestamp;
        uint256 epochLength;
        uint256 normalDuration;
        uint256 preCallDuration;
        uint256 fundingDuration;
        uint256 marginRatioBps;
        uint256 protocolCallableCapUsdc;
        uint256 userCallableCapUsdc;
        uint256 exitCapBps;
        uint256 exitDelayEpochs;
        uint256 minDepositAssets;
        uint256 auctionStepCount;
        uint256 auctionStepDecayRateBps;
        uint256 maxAuctionAwardBps;
    }

    struct Account {
        uint256 activeMargin;
        uint256 activeCallableUsdc;
        uint256 pendingMargin;
        uint256 pendingCallableUsdc;
        uint256 pendingActivationEpoch;
        uint256 calledEpochCursor;
        uint256 claimableExitMargin;
        uint256 exitBucketMargin;
        uint256 exitBucketCallable;
        bool exitRequested;
        uint256 exitMaturityEpoch;
        bool exitClaimed;
        bool exitMatured;
    }

    struct EpochState {
        bool callOpened;
        uint256 callableDenominator;
        uint256 callAmount;
        uint256 rawMarginAtCallOpen;
        uint256 fundedUsdc;
        uint256 rawMarginReleased;
        uint256 honoredRawMarginRemaining;
        uint256 honoredCallableRemaining;
        bool slashFinalized;
        bool slashDisabledByShutdown;
    }

    event DepositCheckpointed(
        address indexed user,
        uint256 marginAssets,
        uint256 marginValueUsdc,
        uint256 callableUsdc,
        uint256 activationEpoch,
        bool immediate
    );
    event PendingActivated(uint256 indexed epoch, uint256 marginAssets, uint256 callableUsdc);
    event EpochCallOpened(uint256 indexed epoch, uint256 callAmountUsdc, uint256 callableDenominator);
    event CallFunded(address indexed user, uint256 indexed epoch, uint256 obligationUsdc);
    event MarginReleased(address indexed user, uint256 indexed epoch, uint256 marginAssets);
    event FundingEscrowed(address indexed user, uint256 indexed epoch, uint256 amountUsdc);
    event EscrowedFundingPlaced(address indexed user, uint256 amountUsdc);
    event EscrowedFundingClaimed(address indexed user, address indexed receiver, uint256 amountUsdc);
    event UserDefaulted(
        address indexed user, uint256 indexed epoch, uint256 slashedMarginAssets, uint256 slashedCallableUsdc
    );
    event EpochSlashFinalized(
        uint256 indexed epoch, uint256 slashedMarginAssets, uint256 slashedCallableUsdc, bool disabledByShutdown
    );
    event ExitRequested(
        address indexed user, uint256 indexed maturityEpoch, uint256 marginAssets, uint256 callableUsdc
    );
    event ExitMatured(uint256 indexed maturityEpoch, uint256 marginAssets, uint256 callableUsdc);
    event ExitedMarginClaimed(address indexed user, address indexed receiver, uint256 marginAssets);
    event EmergencyMarginClaimed(address indexed user, address indexed receiver, uint256 marginAssets);
    event RiskCapUpdated(
        uint256 protocolCallableCapUsdc, uint256 userCallableCapUsdc, uint256 exitCapBps, uint256 minDepositAssets
    );
    event EmergencyShutdown(uint256 indexed epoch, uint256 timestamp);
    event AuctionKicked(uint256 indexed epoch, uint256 shortfallUsdc, uint256 marginPool);
    event AuctionFill(address indexed filler, uint256 indexed epoch, uint256 fillUsdc, uint256 marginAward);
    event AuctionSettled(uint256 indexed epoch, uint256 filledUsdc, uint256 marginAwarded, uint256 marginToTreasury);
    event AuctionAwardCapUpdated(uint256 maxAuctionAwardBps);

    error PendingDepositExists();
    error AccountMaterializationIncomplete();

    function currentEpoch() external view returns (uint256);
    function currentPhase() external view returns (Phase);
    function phaseEndsAt(uint256 epoch, Phase phase) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 callableUsdc);
    function requestExit() external returns (uint256 maturityEpoch);
    function claimExitedMargin(address receiver) external returns (uint256 assets);
    function claimEmergencyMargin(address receiver) external returns (uint256 assets);
    function setRiskCaps(uint256 newProtocolCap, uint256 newUserCap, uint256 newExitCapBps, uint256 newMinDeposit)
        external;
    function shutdown() external;
    function openEpochCall(uint256 epoch, uint256 totalCallAmountUsdc) external;
    function fundEpochCall(uint256 epoch) external returns (uint256 obligationUsdc);
    function fundEpochCallFor(uint256 epoch, address user) external returns (uint256 obligationUsdc);
    function takeAuction(uint256 epoch, uint256 maxFillUsdc) external returns (uint256 filledUsdc, uint256 marginAward);
    function setMaxAuctionAwardBps(uint256 newMaxAuctionAwardBps) external;
    function getAuctionState(uint256 epoch) external view returns (LCCAuctionLib.AuctionState memory);
    function pendingAuctionEpochPlusOne() external view returns (uint256);
    function maxAuctionAwardBps() external view returns (uint256);
    function auctionStepCount() external view returns (uint256);
    function auctionStepDuration() external view returns (uint256);
    function auctionStepDecayRateBps() external view returns (uint256);
    function placeEscrowedFunding(address user) external returns (uint256 placedUsdc);
    function claimEscrowedFunding(address receiver) external returns (uint256 assets);
    function finalizeEpochSlash(uint256 epoch) external;
    function materializeAccount(address user) external;
    function getAccount(address user) external view returns (Account memory);
    function getEpochState(uint256 epoch) external view returns (EpochState memory);
    function obligationOf(uint256 epoch, address user) external view returns (uint256);
    function claimableExitedMargin(address user) external view returns (uint256);
    function calledEpochs() external view returns (uint256[] memory);
    function totalActiveMargin() external view returns (uint256);
    function totalActiveCallableUsdc() external view returns (uint256);
    function totalPendingMargin() external view returns (uint256);
    function totalPendingCallableUsdc() external view returns (uint256);
    function totalEscrowedFundingUsdc() external view returns (uint256);
    function escrowedFundingUsdc(address user) external view returns (uint256);
    function protocolCallableCapUsdc() external view returns (uint256);
    function userCallableCapUsdc() external view returns (uint256);
    function exitCapBps() external view returns (uint256);
    function minDepositAssets() external view returns (uint256);
    function shutdownActive() external view returns (bool);
    function fundedEpoch(uint256 epoch, address user) external view returns (bool);
    function defaultedEpoch(uint256 epoch, address user) external view returns (bool);
    function pendingMarginByActivationEpoch(uint256 epoch) external view returns (uint256);
    function pendingCallableByActivationEpoch(uint256 epoch) external view returns (uint256);
    function exitRequestedMarginByMaturity(uint256 epoch) external view returns (uint256);
    function exitRequestedCallableByMaturity(uint256 epoch) external view returns (uint256);
}
