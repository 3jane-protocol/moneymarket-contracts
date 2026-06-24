// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Ownable} from "../../lib/openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "../../lib/openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "../../lib/openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "../../lib/openzeppelin/contracts/utils/math/SafeCast.sol";

import {IOracle} from "../interfaces/IOracle.sol";
import {ORACLE_PRICE_SCALE, BPS} from "../libraries/ConstantsLib.sol";
import {LCCAccountLib} from "./libraries/LCCAccountLib.sol";
import {LCCAuctionLib} from "./libraries/LCCAuctionLib.sol";
import {LCCBucketListLib} from "./libraries/LCCBucketListLib.sol";
import {LCCConfigLib} from "./libraries/LCCConfigLib.sol";
import {LCCErrorsLib} from "./libraries/LCCErrorsLib.sol";
import {LCCEventsLib} from "./libraries/LCCEventsLib.sol";
import {LCCTypesLib} from "./libraries/LCCTypesLib.sol";
import {ILeveragedCallableCreditVault} from "./interfaces/ILeveragedCallableCreditVault.sol";

/// @title LeveragedCallableCreditVault
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Per-facility leveraged callable credit vault. See {ILeveragedCallableCreditVault} for the external API
/// and accounting model; this contract holds the implementation, lazy materialization, and auction mechanics.
/// @dev State progression is lazy and keeperless: every state-touching entrypoint calls `_syncGlobal` to advance
/// the epoch clock, fold pending/matured buckets, and finalize eligible slashes. Per-account state is materialized
/// on demand by replaying the sparse `calledEpochs` list from each account's cursor.
contract LeveragedCallableCreditVault is ILeveragedCallableCreditVault, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using SafeCast for uint256;
    using LCCAccountLib for Account;

    uint256 internal constant MAX_MATERIALIZE_STEPS = 64;

    /* STORAGE */

    /// @notice The ERC20 posted as the performance bond.
    /// @dev Must be a standard ERC20: fee-on-transfer and rebasing tokens break margin conservation. Deployments
    /// must also keep the maximum margin balance reachable under the commitment caps below type(uint128).max (a
    /// constraint on margin decimals, the oracle price floor, marginRatioBps, and protocolCommitmentCap) or
    /// deposits revert on the packed-storage cast.
    IERC20 private immutable marginAsset;
    /// @notice The ERC20 used to fund calls and auction fills; equals USD3's underlying asset.
    IERC20 private immutable fundingAsset;
    /// @notice The ERC-4626 vault that funded amounts are deposited into for the funder.
    IERC4626 private immutable usd3;
    /// @notice Trusted oracle quoting one marginAsset in fundingAsset, scaled by ORACLE_PRICE_SCALE.
    IOracle private immutable marginOracle;
    /// @notice Recipient of slashed margin and unsold auction collateral.
    address private immutable treasury;

    /// @notice Epoch-zero start timestamp; the epoch clock derives from this.
    uint256 private immutable startTimestamp;
    /// @notice Total epoch duration in seconds.
    uint256 private immutable epochLength;
    /// @notice Seconds of the Normal phase.
    uint256 private immutable normalDuration;
    /// @notice Seconds of the PreCall phase.
    uint256 private immutable preCallDuration;
    /// @notice Seconds of the Funding phase.
    uint256 private immutable fundingDuration;
    /// @notice Leverage ratio in bps: commitment = marginValue * BPS / marginRatioBps.
    uint256 private immutable marginRatioBps;
    /// @notice Minimum epochs between an exit request and its earliest maturity.
    uint256 private immutable exitDelayEpochs;
    /// @notice Number of price steps spanning the Closed-window auction (0 disables auctions).
    /// @dev The auction window (the Closed phase) is divided into auctionStepCount price steps; the protocol's
    /// retained share of the pool decays by auctionStepDecayRateBps each step, so the curve completes exactly over
    /// every auction window. auctionStepCount == 0 permanently disables the auction machinery.
    uint256 private immutable auctionStepCount;
    /// @notice Per-step decay of the protocol's retained pool share, in bps.
    uint256 private immutable auctionStepDecayRateBps;
    /// @notice Duration of each auction price step, in seconds.
    /// @dev Derived: closed-window seconds / auctionStepCount.
    uint256 private immutable auctionStepDuration;

    /// @dev Mutable risk configuration. Per-epoch exit capacity is `protocolCommitmentCap * exitCapBps / BPS`.
    /// The protocol cap is used as the base (rather than live active commitment) so bucket assignment is
    /// deterministic and not path-dependent. `maxAuctionAwardBps` is the runtime auction-kicker off-switch.
    RiskConfig internal _riskConfig;

    /// @dev Packed aggregate totals. Commitment totals are cap-bounded by `protocolCommitmentCap <=
    /// type(uint128).max`; margin totals rely on the aggregate deployment invariant and fail safely via SafeCast.
    Totals internal _totals;

    /// @dev Packed fold cursors and single live-auction slot (epoch + 1; 0 = none). Safe because calls are
    /// sequential: an auction for epoch E exists only during E's Closed window, and a later kick happens inside
    /// _syncGlobal after _settleDueAuction has already swept E.
    SyncState internal _syncState;

    /// @dev Packed terminal emergency shutdown state.
    ShutdownState internal _shutdown;
    /// @dev Per-epoch auction state, exposed via getAuctionState.
    mapping(uint256 => LCCAuctionLib.AuctionState) internal epochAuctions;

    /// @dev Packed positions keyed by account.
    mapping(address => LCCTypesLib.AccountStorage) internal accounts;
    /// @dev Per-epoch call accounting, exposed via getEpochState.
    mapping(uint256 => EpochState) internal epochs;
    /// @dev Sparse, ordered list of epochs in which a call was opened; the replay/finalization spine.
    uint256[] internal calledEpochList;

    /// @inheritdoc ILeveragedCallableCreditVault
    mapping(uint256 => uint256) public pendingMarginByActivationEpoch;
    /// @inheritdoc ILeveragedCallableCreditVault
    mapping(uint256 => uint256) public pendingCommitmentByActivationEpoch;
    /// @dev Distinct activation epochs with nonzero pending buckets (swap-remove tracked; bounds the fold scan).
    uint256[] internal activationEpochList;
    /// @dev 1-based index of an activation epoch in `activationEpochList` (0 = absent).
    mapping(uint256 => uint256) internal activationEpochIndexPlusOne;
    /// @inheritdoc ILeveragedCallableCreditVault
    mapping(uint256 => uint256) public exitBucketMarginByMaturity;
    /// @inheritdoc ILeveragedCallableCreditVault
    mapping(uint256 => uint256) public exitBucketCommitmentByMaturity;
    /// @dev Distinct maturity epochs with nonzero exit buckets (swap-remove tracked; bounds the fold scan).
    uint256[] internal exitMaturityList;
    /// @dev 1-based index of a maturity epoch in `exitMaturityList` (0 = absent).
    mapping(uint256 => uint256) internal exitMaturityIndexPlusOne;

    /// @dev Exiting-user exposure per (call epoch, maturity epoch); see {LCCTypesLib.ExitExposure}.
    mapping(uint256 => mapping(uint256 => LCCTypesLib.ExitExposure)) internal exitExposureByCallAndMaturity;
    /// @dev Maturity epochs touched by each call, for slash-time bucket reconciliation.
    mapping(uint256 => uint256[]) internal exitMaturitiesByCall;

    /// @inheritdoc ILeveragedCallableCreditVault
    mapping(uint256 => mapping(address => bool)) public fundedEpoch;
    /// @inheritdoc ILeveragedCallableCreditVault
    mapping(uint256 => mapping(address => bool)) public defaultedEpoch;

    /// @inheritdoc ILeveragedCallableCreditVault
    mapping(address => uint256) public escrowedFundingAmount;

    /* CONSTRUCTOR */

    /// @notice Deploys a vault with immutable facility parameters and initial mutable risk caps.
    /// @dev Validates `params` and derives the auction step duration from the Closed
    /// window. The epoch clock starts at `params.startTimestamp`.
    /// @param params The facility configuration; see {ILeveragedCallableCreditVault.VaultParams}.
    constructor(VaultParams memory params) Ownable(params.owner) {
        LCCConfigLib.validate(params);

        marginAsset = IERC20(params.marginAsset);
        fundingAsset = IERC20(params.fundingAsset);
        usd3 = IERC4626(params.usd3);
        marginOracle = IOracle(params.marginOracle);
        treasury = params.treasury;

        startTimestamp = params.startTimestamp;
        epochLength = params.epochLength;
        normalDuration = params.normalDuration;
        preCallDuration = params.preCallDuration;
        fundingDuration = params.fundingDuration;
        marginRatioBps = params.marginRatioBps;
        exitDelayEpochs = params.exitDelayEpochs;
        auctionStepCount = params.auctionStepCount;
        auctionStepDecayRateBps = params.auctionStepDecayRateBps;
        auctionStepDuration = params.auctionStepCount == 0
            ? 0
            : (params.epochLength - params.normalDuration - params.preCallDuration - params.fundingDuration)
                / params.auctionStepCount;

        _riskConfig = RiskConfig({
            protocolCommitmentCap: params.protocolCommitmentCap,
            userCommitmentCap: params.userCommitmentCap,
            exitCapBps: params.exitCapBps,
            minDepositAssets: params.minDepositAssets,
            maxAuctionAwardBps: params.maxAuctionAwardBps
        });

        uint256 epoch = _currentEpoch();
        _syncState.lastActivationFolded = epoch.toUint64();
        _syncState.lastMaturityFolded = epoch.toUint64();
    }

    /* MODIFIERS */

    modifier synced() {
        _syncGlobal();
        _;
    }

    /* CLOCK VIEWS */

    /// @inheritdoc ILeveragedCallableCreditVault
    function currentEpoch() external view returns (uint256) {
        return _currentEpoch();
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function currentPhase() external view returns (Phase) {
        return _phaseAt(block.timestamp);
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function phaseEndsAt(uint256 epoch, Phase phase) external view returns (uint256) {
        uint256 start = _epochStart(epoch);
        if (phase == Phase.Normal) return start + normalDuration;
        if (phase == Phase.PreCall) return start + normalDuration + preCallDuration;
        if (phase == Phase.Funding) return _fundingDeadline(epoch);
        return start + epochLength;
    }

    /* OWNER ACTIONS */

    /// @inheritdoc ILeveragedCallableCreditVault
    /// @dev Lowering caps below current utilization does not force existing positions or assigned exit buckets to
    /// unwind.
    function setRiskCaps(
        uint256 newProtocolCommitmentCap,
        uint256 newUserCommitmentCap,
        uint256 newExitCapBps,
        uint256 newMinDeposit
    ) external onlyOwner synced {
        if (newProtocolCommitmentCap == 0 || newProtocolCommitmentCap > type(uint128).max) {
            revert LCCErrorsLib.InvalidParams();
        }
        if (newUserCommitmentCap == 0 || newExitCapBps == 0 || newExitCapBps > BPS) {
            revert LCCErrorsLib.InvalidParams();
        }

        _riskConfig.protocolCommitmentCap = newProtocolCommitmentCap;
        _riskConfig.userCommitmentCap = newUserCommitmentCap;
        _riskConfig.exitCapBps = newExitCapBps;
        _riskConfig.minDepositAssets = newMinDeposit;

        emit LCCEventsLib.RiskCapUpdated(newProtocolCommitmentCap, newUserCommitmentCap, newExitCapBps, newMinDeposit);
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function setMaxAuctionAwardBps(uint256 newMaxAuctionAwardBps) external onlyOwner synced {
        if (newMaxAuctionAwardBps > BPS) revert LCCErrorsLib.InvalidParams();
        if (newMaxAuctionAwardBps != 0 && auctionStepCount == 0) revert LCCErrorsLib.InvalidParams();
        // No repricing while fillers are mid-auction.
        if (_syncState.pendingAuctionEpochPlusOne != 0) revert LCCErrorsLib.InvalidPhase();

        _riskConfig.maxAuctionAwardBps = newMaxAuctionAwardBps;

        emit LCCEventsLib.AuctionAwardCapUpdated(newMaxAuctionAwardBps);
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function shutdown() external onlyOwner synced {
        if (_shutdown.active) revert LCCErrorsLib.ShutdownActive();
        _shutdown.active = true;
        _shutdown.timestamp = block.timestamp.toUint64();
        _shutdown.epoch = _currentEpoch().toUint64();
        // Re-run after recording shutdown so in-flight calls can finalize with slash disabled.
        _syncGlobal();
        emit LCCEventsLib.EmergencyShutdown(_shutdown.epoch, _shutdown.timestamp);
    }

    /* USER ACTIONS */

    /// @inheritdoc ILeveragedCallableCreditVault
    /// @dev The margin oracle is fully trusted to return a fresh marginAsset-to-fundingAsset price scaled by
    /// ORACLE_PRICE_SCALE, including any token decimal conversion.
    function deposit(uint256 assets, address receiver) external nonReentrant synced returns (uint256 commitment) {
        if (_shutdown.active) revert LCCErrorsLib.ShutdownActive();
        if (receiver == address(0)) revert LCCErrorsLib.ZeroAddress();
        if (assets == 0 || assets < _riskConfig.minDepositAssets) revert LCCErrorsLib.InvalidAmount();

        Account memory account = _replayForUpdate(receiver);
        if (account.exitRequested && !account.exitClaimed) revert LCCErrorsLib.ExitInProgress();

        uint256 price = marginOracle.price();
        if (price == 0) revert LCCErrorsLib.OraclePriceInvalid();

        uint256 marginValue = assets.mulDiv(price, ORACLE_PRICE_SCALE);
        commitment = marginValue.mulDiv(BPS, marginRatioBps);
        if (commitment == 0) revert LCCErrorsLib.InvalidAmount();

        if (_totals.activeCommitment + _totals.pendingCommitment + commitment > _riskConfig.protocolCommitmentCap) {
            revert LCCErrorsLib.CapExceeded();
        }
        if (account.activeCommitment + account.pendingCommitment + commitment > _riskConfig.userCommitmentCap) {
            revert LCCErrorsLib.CapExceeded();
        }

        marginAsset.safeTransferFrom(msg.sender, address(this), assets);

        (uint256 activationEpoch, bool immediate) = _depositActivation();
        if (immediate) {
            account.activeMargin += assets;
            account.activeCommitment += commitment;
            _increaseGlobalActive(assets, commitment);
        } else {
            _addPending(account, assets, commitment, activationEpoch);
        }
        _storeAccount(receiver, account);

        emit LCCEventsLib.DepositCheckpointed(receiver, assets, marginValue, commitment, activationEpoch, immediate);
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function requestExit() external nonReentrant synced returns (uint256 maturityEpoch) {
        Account memory account = _replayForUpdate(msg.sender);
        if (account.exitRequested && !account.exitClaimed) revert LCCErrorsLib.ExitInProgress();
        if (account.pendingMargin != 0 || account.pendingCommitment != 0) revert LCCErrorsLib.PendingDepositExists();

        uint256 accountCommitment = account.activeCommitment;
        uint256 accountMargin = account.activeMargin;
        if (accountCommitment == 0 || accountMargin == 0) revert LCCErrorsLib.InvalidAmount();

        maturityEpoch = _assignExitMaturity(accountCommitment);
        account.exitRequested = true;
        account.exitMaturityEpoch = maturityEpoch;
        account.exitClaimed = false;
        account.exitMatured = false;
        account.claimableExitMargin = 0;
        account.exitBucketMargin = accountMargin;
        account.exitBucketCommitment = accountCommitment;
        _storeAccount(msg.sender, account);

        exitBucketMarginByMaturity[maturityEpoch] += accountMargin;
        exitBucketCommitmentByMaturity[maturityEpoch] += accountCommitment;
        _trackExitMaturity(maturityEpoch);
        _addCurrentCallExitExposure(msg.sender, accountMargin, accountCommitment, maturityEpoch);

        emit LCCEventsLib.ExitRequested(msg.sender, maturityEpoch, accountMargin, accountCommitment);
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function claimExitedMargin(address receiver) external nonReentrant synced returns (uint256 assets) {
        if (receiver == address(0)) revert LCCErrorsLib.ZeroAddress();

        Account memory account = _replayForUpdate(msg.sender);
        if (!account.exitRequested || account.exitClaimed) revert LCCErrorsLib.NoExitRequested();
        if (_currentEpoch() < account.exitMaturityEpoch) revert LCCErrorsLib.ExitNotMature();

        assets = account.claimableExitMargin;
        if (assets == 0) revert LCCErrorsLib.NothingToClaim();

        account.claimableExitMargin = 0;
        account.clearExit();
        _storeAccount(msg.sender, account);

        marginAsset.safeTransfer(receiver, assets);

        emit LCCEventsLib.ExitedMarginClaimed(msg.sender, receiver, assets);
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function claimEmergencyMargin(address receiver) external nonReentrant synced returns (uint256 assets) {
        if (!_shutdown.active) revert LCCErrorsLib.ShutdownRequired();
        if (receiver == address(0)) revert LCCErrorsLib.ZeroAddress();

        Account memory account = _replayForUpdate(msg.sender);

        assets = account.activeMargin + account.pendingMargin;
        if (assets == 0) revert LCCErrorsLib.NothingToClaim();

        uint256 maturity = account.exitMaturityEpoch;
        if (account.exitRequested && !account.exitClaimed && !account.exitMatured) {
            exitBucketMarginByMaturity[maturity] -= account.exitBucketMargin;
            exitBucketCommitmentByMaturity[maturity] -= account.exitBucketCommitment;
            _pruneExitMaturityIfEmpty(maturity);
        }

        _decreaseGlobalActive(account.activeMargin, account.activeCommitment);
        _decreasePending(account, account.pendingMargin, account.pendingCommitment);

        account.activeMargin = 0;
        account.activeCommitment = 0;
        account.pendingMargin = 0;
        account.pendingCommitment = 0;
        account.pendingActivationEpoch = 0;
        account.clearExit();
        _storeAccount(msg.sender, account);

        marginAsset.safeTransfer(receiver, assets);

        emit LCCEventsLib.EmergencyMarginClaimed(msg.sender, receiver, assets);
    }

    /* CALL, FUNDING & AUCTION ACTIONS */

    /// @inheritdoc ILeveragedCallableCreditVault
    function openEpochCall(uint256 epoch, uint256 callAmount) external onlyOwner synced {
        if (_shutdown.active) revert LCCErrorsLib.ShutdownActive();
        if (epoch != _currentEpoch()) revert LCCErrorsLib.InvalidEpoch();
        if (_phaseAt(block.timestamp) != Phase.PreCall) revert LCCErrorsLib.InvalidPhase();
        if (callAmount == 0) revert LCCErrorsLib.InvalidAmount();

        _requireNoPriorUnsettledCall(epoch);

        EpochState storage state = epochs[epoch];
        if (state.callOpened) revert LCCErrorsLib.CallAlreadyOpened();
        if (callAmount > _totals.activeCommitment) revert LCCErrorsLib.InvalidAmount();

        state.callOpened = true;
        state.commitmentDenominator = _totals.activeCommitment;
        state.callAmount = callAmount;
        state.marginAtCallOpen = _totals.activeMargin;
        calledEpochList.push(epoch);
        _snapshotExitBucketsForCall(epoch);

        emit LCCEventsLib.EpochCallOpened(epoch, callAmount, _totals.activeCommitment);
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function fundEpochCall(uint256 epoch) external nonReentrant synced returns (uint256 obligationAmount) {
        return _fund(epoch, msg.sender, msg.sender);
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    /// @dev Push-based third-party funding: the caller pays; released margin, the USD3 position (or escrow credit),
    /// and funded status always accrue to `user`. Escrow credit is never refundable to the payer.
    function fundEpochCallFor(uint256 epoch, address user)
        external
        nonReentrant
        synced
        returns (uint256 obligationAmount)
    {
        if (user == address(0)) revert LCCErrorsLib.ZeroAddress();
        return _fund(epoch, msg.sender, user);
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    /// @dev No escrow fallback for fillers — they are volunteers, not obligated funders: if USD3 cannot accept the
    /// deposit (capacity, depositor whitelist, first-time minimum) the take reverts. Fills require the vault to be
    /// on USD3's depositorWhitelist while commitment enforcement is active.
    function takeAuction(uint256 epoch, uint256 maxFillAmount)
        external
        nonReentrant
        synced
        returns (uint256 filledAmount, uint256 marginAward)
    {
        if (_shutdown.active) revert LCCErrorsLib.ShutdownActive();
        // synced settled any past-window auction, so a live slot implies the window is open.
        if (_syncState.pendingAuctionEpochPlusOne != epoch + 1) revert LCCErrorsLib.AuctionNotLive();

        LCCAuctionLib.AuctionState storage state = epochAuctions[epoch];
        uint256 remainingShortfallAmount = state.shortfallAmount - state.filledAmount;
        filledAmount = maxFillAmount < remainingShortfallAmount ? maxFillAmount : remainingShortfallAmount;
        if (filledAmount == 0) revert LCCErrorsLib.InvalidAmount();

        uint256 price = marginOracle.price();
        if (price == 0) revert LCCErrorsLib.OraclePriceInvalid();

        marginAward = LCCAuctionLib.computeAward(
            state,
            filledAmount,
            block.timestamp - _fundingDeadline(epoch),
            auctionStepDuration,
            auctionStepDecayRateBps,
            _riskConfig.maxAuctionAwardBps,
            price
        );

        state.filledAmount += filledAmount.toUint128();
        state.marginAwarded += marginAward;

        fundingAsset.safeTransferFrom(msg.sender, address(this), filledAmount);
        _depositToUsd3(msg.sender, filledAmount);
        if (marginAward != 0) marginAsset.safeTransfer(msg.sender, marginAward);

        emit LCCEventsLib.AuctionFill(msg.sender, epoch, filledAmount, marginAward);

        if (state.filledAmount == state.shortfallAmount) _settleAuction(epoch);
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function depositEscrowedFunding(address user) external nonReentrant synced returns (uint256 placedAmount) {
        if (user == address(0)) revert LCCErrorsLib.ZeroAddress();

        uint256 escrowAmount = escrowedFundingAmount[user];
        if (escrowAmount == 0) revert LCCErrorsLib.NothingToClaim();

        placedAmount = escrowAmount.min(usd3.maxDeposit(user));
        if (placedAmount == 0) revert LCCErrorsLib.InvalidAmount();

        _removeEscrow(user, placedAmount);
        _depositToUsd3(user, placedAmount);

        emit LCCEventsLib.EscrowedFundingPlaced(user, placedAmount);
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    /// @dev Returns escrowed funding to the funder after terminal shutdown, when USD3 placement can no longer be
    /// forced.
    function claimEscrowedFunding(address receiver) external nonReentrant synced returns (uint256 assets) {
        if (!_shutdown.active) revert LCCErrorsLib.ShutdownRequired();
        if (receiver == address(0)) revert LCCErrorsLib.ZeroAddress();

        assets = escrowedFundingAmount[msg.sender];
        if (assets == 0) revert LCCErrorsLib.NothingToClaim();

        _removeEscrow(msg.sender, assets);

        fundingAsset.safeTransfer(receiver, assets);

        emit LCCEventsLib.EscrowedFundingClaimed(msg.sender, receiver, assets);
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function finalizeEpochSlash(uint256 epoch) external nonReentrant synced {
        if (!epochs[epoch].slashFinalized) {
            if (!_slashEligible(epoch)) revert LCCErrorsLib.SlashNotEligible();
            _finalizeEpochSlash(epoch);
        }
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function materializeAccount(address user) external nonReentrant synced {
        if (user == address(0)) revert LCCErrorsLib.ZeroAddress();
        // Accounts with live historical exposure may need repeated calls; empty accounts fast-forward.
        Account memory account = _loadAccount(user);
        bytes32 beforeHash = keccak256(abi.encode(account));
        LCCTypesLib.AccountReplay memory replay = _replayAndRecordDefaults(user, account);
        if (keccak256(abi.encode(replay.account)) != beforeHash) _storeAccount(user, replay.account);
    }

    /* VIEWS */

    /// @inheritdoc ILeveragedCallableCreditVault
    function getAccount(address user) external view returns (Account memory) {
        return _previewAccount(user);
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function getEpochState(uint256 epoch) external view returns (EpochState memory) {
        return epochs[epoch];
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function getAuctionState(uint256 epoch) external view returns (LCCAuctionLib.AuctionState memory) {
        return epochAuctions[epoch];
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function obligationOf(uint256 epoch, address user) external view returns (uint256) {
        EpochState storage state = epochs[epoch];
        if (!state.callOpened || state.slashFinalized || fundedEpoch[epoch][user]) return 0;
        Account memory account = _previewAccount(user);
        return _obligation(state, account.activeCommitment);
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function claimableExitedMargin(address user) external view returns (uint256) {
        Account memory account = _previewAccount(user);
        if (!account.exitRequested || account.exitClaimed || _currentEpoch() < account.exitMaturityEpoch) return 0;
        return account.claimableExitMargin;
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function calledEpochs() external view returns (uint256[] memory) {
        return calledEpochList;
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function assetConfig() external view returns (AssetConfig memory) {
        return AssetConfig({
            marginAsset: address(marginAsset),
            fundingAsset: address(fundingAsset),
            usd3: address(usd3),
            marginOracle: address(marginOracle),
            treasury: treasury
        });
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function epochConfig() external view returns (EpochConfig memory) {
        return EpochConfig({
            startTimestamp: startTimestamp,
            epochLength: epochLength,
            normalDuration: normalDuration,
            preCallDuration: preCallDuration,
            fundingDuration: fundingDuration,
            marginRatioBps: marginRatioBps,
            exitDelayEpochs: exitDelayEpochs
        });
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function auctionConfig() external view returns (AuctionConfig memory) {
        return AuctionConfig({
            auctionStepCount: auctionStepCount,
            auctionStepDecayRateBps: auctionStepDecayRateBps,
            auctionStepDuration: auctionStepDuration
        });
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function riskConfig() external view returns (RiskConfig memory) {
        return _riskConfig;
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function totals() external view returns (Totals memory) {
        return _totals;
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function syncState() external view returns (SyncState memory) {
        return _syncState;
    }

    /// @inheritdoc ILeveragedCallableCreditVault
    function shutdownState() external view returns (ShutdownState memory) {
        return _shutdown;
    }

    /* FUNDING INTERNALS */

    function _fund(uint256 epoch, address payer, address user) internal returns (uint256 obligationAmount) {
        if (epoch != _currentEpoch()) revert LCCErrorsLib.InvalidEpoch();
        if (_phaseAt(block.timestamp) != Phase.Funding) revert LCCErrorsLib.InvalidPhase();

        EpochState storage state = epochs[epoch];
        if (!state.callOpened || state.slashFinalized) revert LCCErrorsLib.InvalidEpoch();
        if (fundedEpoch[epoch][user]) revert LCCErrorsLib.AlreadyFunded();

        Account memory account = _replayForUpdate(user);
        uint256 activeMargin = account.activeMargin;
        uint256 activeCommitment = account.activeCommitment;
        obligationAmount = _obligation(state, activeCommitment);
        if (obligationAmount == 0) revert LCCErrorsLib.InvalidAmount();

        uint256 releasedMargin = activeMargin.mulDiv(obligationAmount, activeCommitment);
        uint256 remainingMargin = activeMargin - releasedMargin;
        uint256 remainingCommitment = activeCommitment - obligationAmount;

        _recordExitingFund(epoch, account, obligationAmount, releasedMargin, remainingMargin, remainingCommitment);

        account.activeMargin = remainingMargin;
        account.activeCommitment = remainingCommitment;
        _storeAccount(user, account);
        fundedEpoch[epoch][user] = true;

        state.fundedAmount += obligationAmount;
        state.marginReleased += releasedMargin;
        state.fundedUsersRemainingMargin += remainingMargin;
        state.fundedUsersRemainingCommitment += remainingCommitment;

        _decreaseGlobalActive(releasedMargin, obligationAmount);

        fundingAsset.safeTransferFrom(payer, address(this), obligationAmount);
        _fundOrEscrow(user, epoch, obligationAmount);

        marginAsset.safeTransfer(user, releasedMargin);

        emit LCCEventsLib.CallFunded(user, epoch, obligationAmount);
        emit LCCEventsLib.MarginReleased(user, epoch, releasedMargin);
    }

    /// @dev Funding success must not depend on USD3 accepting the deposit: when USD3 cannot take the full amount —
    /// insufficient maxDeposit, or a pre-deposit hook revert invisible to maxDeposit (depositor whitelist,
    /// first-time minimum deposit) — the funding asset is escrowed for the funder instead of reverting (which would
    /// default honoring users at the deadline). Deployments should add the vault to USD3's depositorWhitelist so the
    /// direct
    /// path is the norm; escrow covers the failure if not.
    function _fundOrEscrow(address user, uint256 epoch, uint256 fundingAmount) internal {
        if (usd3.maxDeposit(user) >= fundingAmount) {
            fundingAsset.forceApprove(address(usd3), fundingAmount);
            try usd3.deposit(fundingAmount, user) returns (uint256) {
                return;
            } catch {
                fundingAsset.forceApprove(address(usd3), 0);
            }
        }
        _addEscrow(user, fundingAmount);
        emit LCCEventsLib.EscrowedFundingCreated(user, epoch, fundingAmount);
    }

    function _depositToUsd3(address receiver, uint256 fundingAmount) internal {
        fundingAsset.forceApprove(address(usd3), fundingAmount);
        usd3.deposit(fundingAmount, receiver);
    }

    function _addEscrow(address user, uint256 fundingAmount) internal {
        escrowedFundingAmount[user] += fundingAmount;
        _totals.escrowedFunding += fundingAmount;
    }

    function _removeEscrow(address user, uint256 fundingAmount) internal {
        escrowedFundingAmount[user] -= fundingAmount;
        _totals.escrowedFunding -= fundingAmount;
    }

    /* SYNC, FOLD & SLASH INTERNALS */

    function _syncGlobal() internal {
        _settleDueAuction();

        while (_syncState.finalizedCallPrefix < calledEpochList.length) {
            uint256 epoch = calledEpochList[_syncState.finalizedCallPrefix];
            if (!epochs[epoch].slashFinalized) {
                if (!_slashEligible(epoch)) break;
                _finalizeEpochSlash(epoch);
            }
            if (epochs[epoch].slashFinalized) {
                _syncState.finalizedCallPrefix = (uint256(_syncState.finalizedCallPrefix) + 1).toUint64();
            }
        }

        uint256 current = _currentEpoch();
        _foldDueActivations(current);
        _syncState.lastActivationFolded = current.toUint64();

        // Slash finalization must run before maturity folds so defaulted exiter exposure is carved out of exit buckets
        // before those buckets decrement global active totals.
        _foldDueMaturities(current);
        _syncState.lastMaturityFolded = current.toUint64();
    }

    function _foldDueActivations(uint256 current) internal {
        uint256[] memory dueEpochs = new uint256[](activationEpochList.length);
        uint256 dueCount;
        for (uint256 i = activationEpochList.length; i != 0;) {
            unchecked {
                --i;
            }
            uint256 epoch = activationEpochList[i];
            if (epoch <= current) {
                dueEpochs[dueCount] = epoch;
                unchecked {
                    ++dueCount;
                }
            }
        }

        for (uint256 i = 0; i < dueCount; ++i) {
            _foldActivation(dueEpochs[i]);
        }
    }

    function _foldDueMaturities(uint256 current) internal {
        uint256[] memory dueEpochs = new uint256[](exitMaturityList.length);
        uint256 dueCount;
        for (uint256 i = exitMaturityList.length; i != 0;) {
            unchecked {
                --i;
            }
            uint256 epoch = exitMaturityList[i];
            if (epoch <= current) {
                dueEpochs[dueCount] = epoch;
                unchecked {
                    ++dueCount;
                }
            }
        }

        for (uint256 i = 0; i < dueCount; ++i) {
            _foldMaturity(dueEpochs[i]);
        }
    }

    function _foldActivation(uint256 epoch) internal {
        uint256 margin = pendingMarginByActivationEpoch[epoch];
        uint256 commitment = pendingCommitmentByActivationEpoch[epoch];
        if (margin == 0 && commitment == 0) return;

        pendingMarginByActivationEpoch[epoch] = 0;
        pendingCommitmentByActivationEpoch[epoch] = 0;
        _pruneActivationEpochIfEmpty(epoch);
        _decreasePendingTotals(margin, commitment);
        _increaseGlobalActive(margin, commitment);

        emit LCCEventsLib.PendingActivated(epoch, margin, commitment);
    }

    function _foldMaturity(uint256 epoch) internal {
        uint256 margin = exitBucketMarginByMaturity[epoch];
        uint256 commitment = exitBucketCommitmentByMaturity[epoch];
        if (margin == 0 && commitment == 0) return;

        exitBucketMarginByMaturity[epoch] = 0;
        exitBucketCommitmentByMaturity[epoch] = 0;
        _pruneExitMaturityIfEmpty(epoch);
        _decreaseGlobalActive(margin, commitment);

        emit LCCEventsLib.ExitMatured(epoch, margin, commitment);
    }

    function _finalizeEpochSlash(uint256 epoch) internal {
        EpochState storage state = epochs[epoch];
        if (!state.callOpened || state.slashFinalized) return;

        bool disabled = _shutdown.active && _shutdown.timestamp <= _fundingDeadline(epoch);
        state.slashFinalized = true;
        state.slashDisabledByShutdown = disabled;

        if (disabled) {
            emit LCCEventsLib.EpochSlashFinalized(epoch, 0, 0, true);
            return;
        }

        uint256 slashedMargin = state.marginAtCallOpen - state.marginReleased - state.fundedUsersRemainingMargin;
        uint256 slashedCommitment =
            state.commitmentDenominator - state.fundedAmount - state.fundedUsersRemainingCommitment;

        _reduceExitBucketsForSlash(epoch);

        _decreaseGlobalActive(slashedMargin, slashedCommitment);

        if (slashedMargin != 0) {
            uint256 shortfallAmount = state.callAmount > state.fundedAmount ? state.callAmount - state.fundedAmount : 0;
            // Kick an auction only while its timestamp-derived window is still open; a late lazy finalization
            // falls through to treasury and the shortfall fails cleanly.
            if (
                shortfallAmount != 0 && _riskConfig.maxAuctionAwardBps != 0 && !_shutdown.active
                    && block.timestamp < _epochStart(epoch) + epochLength
            ) {
                epochAuctions[epoch] = LCCAuctionLib.AuctionState({
                    shortfallAmount: shortfallAmount.toUint128(),
                    filledAmount: 0,
                    marginPool: slashedMargin,
                    marginAwarded: 0
                });
                _syncState.pendingAuctionEpochPlusOne = (epoch + 1).toUint64();
                emit LCCEventsLib.AuctionKicked(epoch, shortfallAmount, slashedMargin);
            } else {
                marginAsset.safeTransfer(treasury, slashedMargin);
            }
        }

        emit LCCEventsLib.EpochSlashFinalized(epoch, slashedMargin, slashedCommitment, false);
    }

    /// @dev Sweeps the live auction once its window has passed (or once shutdown blocks takes). Runs before slash
    /// finalization in _syncGlobal so a prior epoch's auction always settles before a new one can be kicked.
    /// Settlement touches no active totals or exit buckets, so the slash-before-maturity-folds ordering below is
    /// unaffected.
    function _settleDueAuction() internal {
        uint256 slot = _syncState.pendingAuctionEpochPlusOne;
        if (slot == 0) return;

        uint256 epoch = slot - 1;
        if (!_shutdown.active && block.timestamp < _epochStart(epoch) + epochLength) return;
        _settleAuction(epoch);
    }

    function _settleAuction(uint256 epoch) internal {
        LCCAuctionLib.AuctionState storage state = epochAuctions[epoch];
        _syncState.pendingAuctionEpochPlusOne = 0;

        uint256 remainder = state.marginPool - state.marginAwarded;
        if (remainder != 0) marginAsset.safeTransfer(treasury, remainder);

        emit LCCEventsLib.AuctionSettled(epoch, state.filledAmount, state.marginAwarded, remainder);
    }

    /* ACCOUNT REPLAY INTERNALS */

    function _replayForUpdate(address user) internal returns (Account memory account) {
        LCCTypesLib.AccountReplay memory replay = _replayAndRecordDefaults(user, _loadAccount(user));
        if (!replay.complete) revert LCCErrorsLib.AccountMaterializationIncomplete();
        // Callers mutate the returned account and are responsible for the single _storeAccount write.
        return replay.account;
    }

    function _replayAndRecordDefaults(address user, Account memory account)
        internal
        returns (LCCTypesLib.AccountReplay memory replay)
    {
        replay = _replayAccount(account, user, MAX_MATERIALIZE_STEPS);
        _recordDefaults(user, replay);
    }

    function _recordDefaults(address user, LCCTypesLib.AccountReplay memory replay) internal {
        for (uint256 i = 0; i < replay.defaultCount; ++i) {
            LCCTypesLib.DefaultRecord memory record = replay.defaults[i];
            defaultedEpoch[record.epoch][user] = true;
            emit LCCEventsLib.UserDefaulted(user, record.epoch, record.slashedMargin, record.slashedCommitment);
        }
    }

    function _loadAccount(address user) internal view returns (Account memory account) {
        LCCTypesLib.AccountStorage storage stored = accounts[user];
        account.activeMargin = stored.activeMargin;
        account.activeCommitment = stored.activeCommitment;
        account.pendingMargin = stored.pendingMargin;
        account.pendingCommitment = stored.pendingCommitment;
        account.pendingActivationEpoch = stored.pendingActivationEpoch;
        account.calledEpochCursor = stored.calledEpochCursor;
        account.claimableExitMargin = stored.claimableExitMargin;
        account.exitBucketMargin = stored.exitBucketMargin;
        account.exitBucketCommitment = stored.exitBucketCommitment;
        account.exitRequested = stored.exitRequested;
        account.exitMaturityEpoch = stored.exitMaturityEpoch;
        account.exitClaimed = stored.exitClaimed;
        account.exitMatured = stored.exitMatured;
    }

    function _storeAccount(address user, Account memory account) internal {
        accounts[user] = LCCTypesLib.AccountStorage({
            activeMargin: account.activeMargin.toUint128(),
            activeCommitment: account.activeCommitment.toUint128(),
            pendingMargin: account.pendingMargin.toUint128(),
            pendingCommitment: account.pendingCommitment.toUint128(),
            claimableExitMargin: account.claimableExitMargin.toUint128(),
            exitBucketMargin: account.exitBucketMargin.toUint128(),
            exitBucketCommitment: account.exitBucketCommitment.toUint128(),
            pendingActivationEpoch: account.pendingActivationEpoch.toUint64(),
            calledEpochCursor: account.calledEpochCursor.toUint64(),
            exitMaturityEpoch: account.exitMaturityEpoch.toUint64(),
            exitRequested: account.exitRequested,
            exitClaimed: account.exitClaimed,
            exitMatured: account.exitMatured
        });
    }

    function _previewAccount(address user) internal view returns (Account memory account) {
        return _replayAccount(_loadAccount(user), user, 0).account;
    }

    /// @dev `maxSteps == 0` means an unbounded read-only replay that does not record defaults.
    function _replayAccount(Account memory account, address user, uint256 maxSteps)
        internal
        view
        returns (LCCTypesLib.AccountReplay memory replay)
    {
        bool bounded = maxSteps != 0;
        replay.account = account;

        if (replay.account.isZeroExposure()) {
            replay.account.calledEpochCursor = _syncState.finalizedCallPrefix;
            replay.complete = true;
            return replay;
        }

        uint256 cursor = replay.account.calledEpochCursor;
        uint256 steps;
        bool stoppedAtUnfinalized;
        uint256 unfinalizedEpoch;

        while (cursor < calledEpochList.length) {
            if (bounded && steps == maxSteps) break;

            uint256 epoch = calledEpochList[cursor];
            EpochState storage state = epochs[epoch];
            if (!state.slashFinalized) {
                stoppedAtUnfinalized = true;
                unfinalizedEpoch = epoch;
                break;
            }

            replay.account.activatePendingForEpoch(epoch);
            replay.account.matureExitForEpoch(epoch);

            if (_shouldDefault(replay.account, state, epoch, user)) {
                if (bounded) {
                    if (replay.defaults.length == 0) replay.defaults = new LCCTypesLib.DefaultRecord[](maxSteps);
                    replay.defaults[replay.defaultCount] =
                        LCCTypesLib.DefaultRecord(epoch, replay.account.activeMargin, replay.account.activeCommitment);
                    unchecked {
                        ++replay.defaultCount;
                    }
                }
                replay.account.defaultAccount();
            }

            unchecked {
                ++cursor;
                ++steps;
            }

            if (replay.account.isZeroExposure()) {
                cursor = _syncState.finalizedCallPrefix;
                break;
            }
        }

        replay.account.calledEpochCursor = cursor;
        replay.complete = cursor >= _syncState.finalizedCallPrefix;
        if (!replay.complete) return replay;

        uint256 activationFolded = _effectiveLastActivationFolded();
        uint256 maturityFolded = _effectiveLastMaturityFolded();
        if (stoppedAtUnfinalized && _slashEligible(unfinalizedEpoch)) {
            if (activationFolded > unfinalizedEpoch) activationFolded = unfinalizedEpoch;
            if (maturityFolded > unfinalizedEpoch) maturityFolded = unfinalizedEpoch;
        }

        replay.account.activatePendingForEpoch(activationFolded);
        replay.account.matureExitForEpoch(maturityFolded);
    }

    function _shouldDefault(Account memory account, EpochState storage state, uint256 epoch, address user)
        internal
        view
        returns (bool)
    {
        if (state.slashDisabledByShutdown || fundedEpoch[epoch][user] || account.activeCommitment == 0) {
            return false;
        }
        return !account.exitRequested || account.exitMaturityEpoch > epoch;
    }

    /* BUCKET & EXIT-EXPOSURE INTERNALS */

    function _trackExitMaturity(uint256 maturityEpoch) internal {
        LCCBucketListLib.track(exitMaturityList, exitMaturityIndexPlusOne, maturityEpoch);
    }

    function _trackActivationEpoch(uint256 activationEpoch) internal {
        LCCBucketListLib.track(activationEpochList, activationEpochIndexPlusOne, activationEpoch);
    }

    function _pruneActivationEpochIfEmpty(uint256 activationEpoch) internal {
        bool empty = pendingMarginByActivationEpoch[activationEpoch] == 0
            && pendingCommitmentByActivationEpoch[activationEpoch] == 0;
        LCCBucketListLib.pruneIfEmpty(activationEpochList, activationEpochIndexPlusOne, activationEpoch, empty);
    }

    function _pruneExitMaturityIfEmpty(uint256 maturityEpoch) internal {
        bool empty =
            exitBucketMarginByMaturity[maturityEpoch] == 0 && exitBucketCommitmentByMaturity[maturityEpoch] == 0;
        LCCBucketListLib.pruneIfEmpty(exitMaturityList, exitMaturityIndexPlusOne, maturityEpoch, empty);
    }

    function _snapshotExitBucketsForCall(uint256 epoch) internal {
        for (uint256 i = 0; i < exitMaturityList.length; ++i) {
            uint256 maturity = exitMaturityList[i];
            if (maturity <= epoch) continue;

            uint256 margin = exitBucketMarginByMaturity[maturity];
            uint256 commitment = exitBucketCommitmentByMaturity[maturity];
            if (margin == 0 && commitment == 0) continue;

            _addCallExitExposure(epoch, maturity, margin, commitment);
        }
    }

    function _addCurrentCallExitExposure(
        address user,
        uint256 accountMargin,
        uint256 accountCommitment,
        uint256 maturityEpoch
    ) internal {
        uint256 epoch = _currentEpoch();
        EpochState storage state = epochs[epoch];
        if (!state.callOpened || state.slashFinalized || fundedEpoch[epoch][user] || maturityEpoch <= epoch) {
            return;
        }
        _addCallExitExposure(epoch, maturityEpoch, accountMargin, accountCommitment);
    }

    function _addCallExitExposure(uint256 epoch, uint256 maturity, uint256 margin, uint256 commitment) internal {
        LCCTypesLib.ExitExposure storage exposure = exitExposureByCallAndMaturity[epoch][maturity];
        if (!exposure.listed) {
            exposure.listed = true;
            exitMaturitiesByCall[epoch].push(maturity);
        }
        exposure.margin += margin;
        exposure.commitment += commitment;
    }

    function _recordExitingFund(
        uint256 epoch,
        Account memory account,
        uint256 obligationAmount,
        uint256 releasedMargin,
        uint256 remainingMargin,
        uint256 remainingCommitment
    ) internal {
        if (!account.exitRequested || account.exitClaimed || account.exitMatured) return;

        uint256 maturity = account.exitMaturityEpoch;
        exitBucketMarginByMaturity[maturity] -= releasedMargin;
        exitBucketCommitmentByMaturity[maturity] -= obligationAmount;
        _pruneExitMaturityIfEmpty(maturity);
        account.exitBucketMargin -= releasedMargin;
        account.exitBucketCommitment -= obligationAmount;

        LCCTypesLib.ExitExposure storage exposure = exitExposureByCallAndMaturity[epoch][maturity];
        if (!exposure.listed) return;

        exposure.fundedAmount += obligationAmount;
        exposure.marginReleased += releasedMargin;
        exposure.fundedUsersRemainingMargin += remainingMargin;
        exposure.fundedUsersRemainingCommitment += remainingCommitment;
    }

    function _reduceExitBucketsForSlash(uint256 epoch) internal {
        uint256[] storage maturities = exitMaturitiesByCall[epoch];
        for (uint256 i = 0; i < maturities.length; ++i) {
            uint256 maturity = maturities[i];
            LCCTypesLib.ExitExposure storage exposure = exitExposureByCallAndMaturity[epoch][maturity];

            uint256 slashedMargin = exposure.margin - exposure.marginReleased - exposure.fundedUsersRemainingMargin;
            uint256 slashedCommitment =
                exposure.commitment - exposure.fundedAmount - exposure.fundedUsersRemainingCommitment;
            if (slashedMargin == 0 && slashedCommitment == 0) continue;

            exitBucketMarginByMaturity[maturity] -= slashedMargin;
            exitBucketCommitmentByMaturity[maturity] -= slashedCommitment;
            _pruneExitMaturityIfEmpty(maturity);
        }
    }

    function _effectiveLastActivationFolded() internal view returns (uint256) {
        uint256 current = _currentEpoch();
        return current > _syncState.lastActivationFolded ? current : _syncState.lastActivationFolded;
    }

    function _effectiveLastMaturityFolded() internal view returns (uint256) {
        uint256 current = _currentEpoch();
        return current > _syncState.lastMaturityFolded ? current : _syncState.lastMaturityFolded;
    }

    function _addPending(Account memory account, uint256 margin, uint256 commitment, uint256 activationEpoch) internal {
        if (account.pendingActivationEpoch != 0 && account.pendingActivationEpoch != activationEpoch) {
            revert LCCErrorsLib.InvalidEpoch();
        }

        account.pendingMargin += margin;
        account.pendingCommitment += commitment;
        account.pendingActivationEpoch = activationEpoch;

        _increasePendingTotals(margin, commitment);
        pendingMarginByActivationEpoch[activationEpoch] += margin;
        pendingCommitmentByActivationEpoch[activationEpoch] += commitment;
        if (activationEpoch > _syncState.lastActivationFolded) _trackActivationEpoch(activationEpoch);
    }

    function _decreasePending(Account memory account, uint256 margin, uint256 commitment) internal {
        if (margin == 0 && commitment == 0) return;

        uint256 activationEpoch = account.pendingActivationEpoch;
        _decreasePendingTotals(margin, commitment);

        if (activationEpoch > _syncState.lastActivationFolded) {
            pendingMarginByActivationEpoch[activationEpoch] -= margin;
            pendingCommitmentByActivationEpoch[activationEpoch] -= commitment;
            _pruneActivationEpochIfEmpty(activationEpoch);
        }
    }

    function _decreaseGlobalActive(uint256 margin, uint256 commitment) internal {
        if (margin != 0) _totals.activeMargin = (uint256(_totals.activeMargin) - margin).toUint128();
        if (commitment != 0) {
            _totals.activeCommitment = (uint256(_totals.activeCommitment) - commitment).toUint128();
        }
    }

    function _increaseGlobalActive(uint256 margin, uint256 commitment) internal {
        if (margin != 0) _totals.activeMargin = (uint256(_totals.activeMargin) + margin).toUint128();
        if (commitment != 0) {
            _totals.activeCommitment = (uint256(_totals.activeCommitment) + commitment).toUint128();
        }
    }

    function _increasePendingTotals(uint256 margin, uint256 commitment) internal {
        if (margin != 0) _totals.pendingMargin = (uint256(_totals.pendingMargin) + margin).toUint128();
        if (commitment != 0) {
            _totals.pendingCommitment = (uint256(_totals.pendingCommitment) + commitment).toUint128();
        }
    }

    function _decreasePendingTotals(uint256 margin, uint256 commitment) internal {
        if (margin != 0) _totals.pendingMargin = (uint256(_totals.pendingMargin) - margin).toUint128();
        if (commitment != 0) {
            _totals.pendingCommitment = (uint256(_totals.pendingCommitment) - commitment).toUint128();
        }
    }

    /// @dev Assignment is first-fit by request time, not strict FIFO: funded or slashed amounts can free bucket
    /// capacity retroactively, and a request larger than the whole per-epoch capacity takes the first bucket with any
    /// remaining room.
    function _assignExitMaturity(uint256 accountCommitment) internal view returns (uint256 maturityEpoch) {
        uint256 capacity = _riskConfig.protocolCommitmentCap.mulDiv(_riskConfig.exitCapBps, BPS);
        if (capacity == 0) revert LCCErrorsLib.InvalidParams();

        maturityEpoch = _currentEpoch() + exitDelayEpochs;
        while (true) {
            uint256 assigned = exitBucketCommitmentByMaturity[maturityEpoch];
            if (assigned < capacity) {
                uint256 remaining = capacity - assigned;
                if (accountCommitment <= remaining || accountCommitment > capacity) return maturityEpoch;
            }
            unchecked {
                ++maturityEpoch;
            }
        }
    }

    /* EPOCH & PHASE MATH */

    function _depositActivation() internal view returns (uint256 activationEpoch, bool immediate) {
        uint256 epoch = _currentEpoch();
        immediate = _phaseAt(block.timestamp) == Phase.Normal && !epochs[epoch].callOpened;
        activationEpoch = immediate ? epoch : epoch + 1;
    }

    function _requireNoPriorUnsettledCall(uint256 epoch) internal view {
        if (
            _syncState.finalizedCallPrefix < calledEpochList.length
                && calledEpochList[_syncState.finalizedCallPrefix] < epoch
        ) {
            revert LCCErrorsLib.PriorCallUnsettled();
        }
    }

    function _slashEligible(uint256 epoch) internal view returns (bool) {
        EpochState storage state = epochs[epoch];
        if (!state.callOpened || state.slashFinalized) return false;
        if (_shutdown.active && _shutdown.timestamp <= _fundingDeadline(epoch)) return true;
        return block.timestamp >= _fundingDeadline(epoch);
    }

    function _obligation(EpochState storage state, uint256 activeCommitment) internal view returns (uint256) {
        if (activeCommitment == 0 || state.commitmentDenominator == 0) return 0;
        return activeCommitment.mulDiv(state.callAmount, state.commitmentDenominator, Math.Rounding.Ceil);
    }

    function _phaseAt(uint256 timestamp) internal view returns (Phase) {
        uint256 elapsed = timestamp >= startTimestamp ? (timestamp - startTimestamp) % epochLength : 0;
        if (elapsed < normalDuration) return Phase.Normal;
        if (elapsed < normalDuration + preCallDuration) return Phase.PreCall;
        if (elapsed < normalDuration + preCallDuration + fundingDuration) return Phase.Funding;
        return Phase.Closed;
    }

    function _currentEpoch() internal view returns (uint256) {
        if (block.timestamp < startTimestamp) return 0;
        return (block.timestamp - startTimestamp) / epochLength;
    }

    function _epochStart(uint256 epoch) internal view returns (uint256) {
        return startTimestamp + epoch * epochLength;
    }

    function _fundingDeadline(uint256 epoch) internal view returns (uint256) {
        return _epochStart(epoch) + normalDuration + preCallDuration + fundingDuration;
    }
}
