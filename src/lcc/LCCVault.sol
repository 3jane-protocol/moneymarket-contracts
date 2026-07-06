// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

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
import {ILCCVault} from "./interfaces/ILCCVault.sol";

/// @title LCCVault
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Per-facility LCC vault. See {ILCCVault} for the external API
/// and accounting model; this contract holds the implementation, lazy materialization, and auction mechanics.
/// @dev State progression is lazy and keeperless: every state-touching entrypoint calls `_syncGlobal` to advance
/// the epoch clock, fold pending/matured buckets, and finalize eligible slashes. Per-account state is materialized
/// on demand by replaying the sparse `calledEpochs` list from each account's cursor.
contract LCCVault is ILCCVault, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using SafeCast for uint256;
    using LCCAccountLib for Account;

    uint256 internal constant MAX_MATERIALIZE_STEPS = 64;
    uint256 internal constant MAX_EXIT_MATURITY_BUCKETS = 2 * LCCConfigLib.MAX_EXIT_DELAY_EPOCHS;
    /// @notice Minimum returned funding commitment retained for attribution, assuming 6-decimal USDC funding units.
    uint256 internal constant MIN_RETURN_COMMITMENT = 1e6;

    /* STORAGE */

    /// @notice The ERC20 posted as the performance bond.
    /// @dev Must be a standard ERC20: fee-on-transfer and rebasing tokens break margin conservation. Deployments
    /// must also keep the maximum margin balance reachable under the commitment caps below type(uint128).max (a
    /// constraint on margin decimals, the oracle price floor, marginRatioBps, and protocolCommitmentCap) or
    /// deposits revert on the packed-storage cast.
    IERC20 private immutable marginAsset;
    /// @notice The ERC20 used to fund calls and auction fills; equals USD3's underlying asset.
    IERC20 private immutable fundingAsset;
    /// @notice The ERC-4626 USD3 vault that accepts fundingAsset deposits.
    IERC4626 private immutable usd3;
    /// @notice The ERC-4626 notification wrapper that delivers USD3n to funders and fillers.
    IERC4626 private immutable notificationVault;
    /// @notice Trusted oracle quoting one marginAsset in fundingAsset, scaled by ORACLE_PRICE_SCALE.
    IOracle private immutable marginOracle;
    /// @notice Recipient of slashed margin and unsold auction collateral.
    address private immutable treasury;

    /// @notice Epoch-zero start timestamp; the epoch clock derives from this.
    uint256 private immutable startTimestamp;
    /// @notice Maximum callable epochs; 0 means perpetual.
    uint256 private immutable maxEpochs;
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
    /// @notice Number of price steps spanning the Closed-window auction (0 disables auctions; otherwise >= 2).
    /// @dev The auction window (the Closed phase) is divided into auctionStepCount price steps; the protocol's
    /// retained share of the pool decays by auctionStepDecayRateBps each completed step. Takes are live strictly
    /// before the epoch end, so the reachable steps are 1..auctionStepCount-1 and the maximum live offer is
    /// pool * (1 - (1 - decay)^(auctionStepCount - 1)); the step-N boundary coincides with settlement.
    /// auctionStepCount == 0 permanently disables the auction machinery.
    uint256 private immutable auctionStepCount;
    /// @notice Per-step decay of the protocol's retained pool share, in bps.
    uint256 private immutable auctionStepDecayRateBps;
    /// @notice Duration of each auction price step, in seconds.
    /// @dev Derived: closed-window seconds / auctionStepCount.
    uint256 private immutable auctionStepDuration;

    /// @dev Mutable risk configuration. Per-epoch exit capacity is `protocolCommitmentCap * exitCapBps / BPS`.
    /// The protocol cap is used as the base (rather than live active commitment) so bucket assignment is
    /// deterministic and not path-dependent. `maxAuctionAwardBps` is the runtime auction-kicker off-switch.
    /// `slashFeeBps` is charged on unawarded slashed margin surplus.
    RiskConfig internal _riskConfig;

    /// @dev Packed aggregate totals. Commitment totals are cap-bounded by `protocolCommitmentCap <=
    /// type(uint128).max`; margin totals rely on the aggregate deployment invariant and fail safely via SafeCast.
    Totals internal _totals;

    /// @dev Packed fold cursors and single live-auction slot (epoch + 1; 0 = none). Safe because calls are
    /// sequential: an auction for epoch E exists only during E's Closed window, and a later kick happens inside
    /// _syncGlobal after _settleDueAuction has already swept E.
    SyncState internal _syncState;

    /// @dev Packed emergency shutdown state.
    ShutdownState internal _shutdown;
    /// @dev Per-epoch auction state, exposed via getAuctionState.
    mapping(uint256 => LCCAuctionLib.AuctionState) internal epochAuctions;

    /// @dev Packed positions keyed by account.
    mapping(address => LCCTypesLib.AccountStorage) internal accounts;
    /// @dev Per-epoch call accounting, exposed via getEpochState.
    mapping(uint256 => EpochState) internal epochs;
    /// @dev Sparse, ordered list of epochs in which a call was opened; the replay/finalization spine.
    uint256[] internal calledEpochList;

    /// @inheritdoc ILCCVault
    mapping(uint256 => uint256) public pendingMarginByActivationEpoch;
    /// @inheritdoc ILCCVault
    mapping(uint256 => uint256) public pendingCommitmentByActivationEpoch;
    /// @dev Distinct activation epochs with nonzero pending buckets (swap-remove tracked; bounds the fold scan).
    uint256[] internal activationEpochList;
    /// @dev 1-based index of an activation epoch in `activationEpochList` (0 = absent).
    mapping(uint256 => uint256) internal activationEpochIndexPlusOne;
    /// @inheritdoc ILCCVault
    mapping(uint256 => uint256) public exitBucketMarginByMaturity;
    /// @inheritdoc ILCCVault
    mapping(uint256 => uint256) public exitBucketCommitmentByMaturity;
    /// @dev Distinct maturity epochs with nonzero exit buckets (swap-remove tracked; bounds the fold scan).
    uint256[] internal exitMaturityList;
    /// @dev 1-based index of a maturity epoch in `exitMaturityList` (0 = absent).
    mapping(uint256 => uint256) internal exitMaturityIndexPlusOne;

    /// @dev Exiting-user exposure per (call epoch, maturity epoch); see {LCCTypesLib.ExitExposure}.
    mapping(uint256 => mapping(uint256 => LCCTypesLib.ExitExposure)) internal exitExposureByCallAndMaturity;
    /// @dev Maturity epochs touched by each call, for slash-time bucket reconciliation.
    mapping(uint256 => uint256[]) internal exitMaturitiesByCall;

    /// @inheritdoc ILCCVault
    mapping(uint256 => mapping(address => bool)) public fundedEpoch;
    /// @inheritdoc ILCCVault
    mapping(uint256 => mapping(address => bool)) public defaultedEpoch;

    /* CONSTRUCTOR */

    /// @notice Deploys a vault with immutable facility parameters and initial mutable risk caps.
    /// @dev Validates `params` and derives the auction step duration from the Closed
    /// window. The epoch clock starts at `params.startTimestamp`. The vault grants standing max allowances to the
    /// trusted, construction-fixed USD3 and notification vault spenders. USD3 short-circuits max allowance as
    /// permanently infinite; USDC decrements max allowance, but type(uint256).max is inexhaustible in practice. The
    /// vault holds no fundingAsset or USD3 between transactions, so the allowances expose no idle balance.
    /// @param params The facility configuration; see {ILCCVault.VaultParams}.
    constructor(VaultParams memory params) Ownable(params.owner) {
        LCCConfigLib.validate(params);

        marginAsset = IERC20(params.marginAsset);
        fundingAsset = IERC20(params.fundingAsset);
        notificationVault = IERC4626(params.notificationVault);
        usd3 = IERC4626(notificationVault.asset());
        marginOracle = IOracle(params.marginOracle);
        treasury = params.treasury;

        fundingAsset.forceApprove(address(usd3), type(uint256).max);
        IERC20(address(usd3)).forceApprove(address(notificationVault), type(uint256).max);

        startTimestamp = params.startTimestamp;
        maxEpochs = params.maxEpochs;
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
            maxAuctionAwardBps: params.maxAuctionAwardBps,
            slashFeeBps: params.slashFeeBps
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

    /// @inheritdoc ILCCVault
    function currentEpoch() external view returns (uint256) {
        return _currentEpoch();
    }

    /// @inheritdoc ILCCVault
    function currentPhase() external view returns (Phase) {
        return _phaseAt(block.timestamp);
    }

    /// @inheritdoc ILCCVault
    function phaseEndsAt(uint256 epoch, Phase phase) external view returns (uint256) {
        uint256 start = _epochStart(epoch);
        if (phase == Phase.Normal) return start + normalDuration;
        if (phase == Phase.PreCall) return start + normalDuration + preCallDuration;
        if (phase == Phase.Funding) return _fundingDeadline(epoch);
        return start + epochLength;
    }

    /* OWNER ACTIONS */

    /// @inheritdoc ILCCVault
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
        if (newUserCommitmentCap == 0 || newExitCapBps < LCCConfigLib.MIN_EXIT_CAP_BPS || newExitCapBps > BPS) {
            revert LCCErrorsLib.InvalidParams();
        }

        _riskConfig.protocolCommitmentCap = newProtocolCommitmentCap;
        _riskConfig.userCommitmentCap = newUserCommitmentCap;
        _riskConfig.exitCapBps = newExitCapBps;
        _riskConfig.minDepositAssets = newMinDeposit;

        emit LCCEventsLib.RiskCapUpdated(newProtocolCommitmentCap, newUserCommitmentCap, newExitCapBps, newMinDeposit);
    }

    /// @inheritdoc ILCCVault
    function setMaxAuctionAwardBps(uint256 newMaxAuctionAwardBps) external onlyOwner synced {
        if (newMaxAuctionAwardBps > BPS) revert LCCErrorsLib.InvalidParams();
        if (newMaxAuctionAwardBps != 0 && auctionStepCount == 0) revert LCCErrorsLib.InvalidParams();
        // No repricing while fillers are mid-auction.
        if (_syncState.pendingAuctionEpochPlusOne != 0) revert LCCErrorsLib.InvalidPhase();

        _riskConfig.maxAuctionAwardBps = newMaxAuctionAwardBps;

        emit LCCEventsLib.AuctionAwardCapUpdated(newMaxAuctionAwardBps);
    }

    /// @inheritdoc ILCCVault
    function setSlashFeeBps(uint256 newSlashFeeBps) external onlyOwner synced {
        if (newSlashFeeBps > BPS) revert LCCErrorsLib.InvalidParams();
        if (_syncState.pendingAuctionEpochPlusOne != 0) revert LCCErrorsLib.InvalidPhase();
        _riskConfig.slashFeeBps = newSlashFeeBps;
        emit LCCEventsLib.SlashFeeUpdated(newSlashFeeBps);
    }

    /// @inheritdoc ILCCVault
    function shutdown() external onlyOwner {
        if (_shutdown.active) revert LCCErrorsLib.ShutdownActive();
        _shutdown.active = true;
        _shutdown.timestamp = block.timestamp.toUint64();
        _shutdown.epoch = _currentEpoch().toUint64();
        emit LCCEventsLib.EmergencyShutdown(_shutdown.epoch, _shutdown.timestamp);
        // Shutdown is recorded before the sync so in-flight finalizations see it: mid-window epochs finalize
        // with slash disabled, and disposal never requires a live oracle.
        _syncGlobal();
    }

    /* USER ACTIONS */

    /// @inheritdoc ILCCVault
    /// @dev The margin oracle is fully trusted to return a fresh marginAsset-to-fundingAsset price scaled by
    /// ORACLE_PRICE_SCALE, including any token decimal conversion.
    function deposit(uint256 assets) external nonReentrant synced returns (uint256 commitment) {
        if (_shutdown.active) revert LCCErrorsLib.ShutdownActive();
        if (_terminal()) revert LCCErrorsLib.VaultTerminal();
        if (assets == 0 || assets < _riskConfig.minDepositAssets) revert LCCErrorsLib.InvalidAmount();

        Account memory account = _replayForUpdate(msg.sender);
        if (account.exitRequested && !account.exitClaimed) revert LCCErrorsLib.ExitInProgress();

        uint256 price = marginOracle.price();
        if (price == 0) revert LCCErrorsLib.OraclePriceInvalid();

        uint256 marginValue;
        (marginValue, commitment) = _marginValueAndCommitment(assets, price);
        if (commitment == 0) revert LCCErrorsLib.InvalidAmount();

        if (
            _totals.activeCommitment + _totals.pendingCommitment + commitment > _riskConfig.protocolCommitmentCap
                || account.activeCommitment + account.pendingCommitment + commitment > _riskConfig.userCommitmentCap
        ) {
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
        _storeAccount(msg.sender, account);

        emit LCCEventsLib.DepositCheckpointed(msg.sender, assets, marginValue, commitment, activationEpoch, immediate);
    }

    /// @inheritdoc ILCCVault
    function requestExit() external nonReentrant synced returns (uint256 maturityEpoch) {
        if (_terminal()) revert LCCErrorsLib.VaultTerminal();
        Account memory account = _replayForUpdate(msg.sender);
        if (account.exitRequested && !account.exitClaimed) revert LCCErrorsLib.ExitInProgress();
        if (account.pendingMargin != 0 || account.pendingCommitment != 0) revert LCCErrorsLib.PendingDepositExists();

        uint256 accountCommitment = account.activeCommitment;
        uint256 accountMargin = account.activeMargin;
        if (accountCommitment == 0 || accountMargin == 0) revert LCCErrorsLib.InvalidAmount();

        maturityEpoch = _assignExitMaturity(accountCommitment);
        if (exitMaturityIndexPlusOne[maturityEpoch] == 0 && exitMaturityList.length >= MAX_EXIT_MATURITY_BUCKETS) {
            revert LCCErrorsLib.ExitCapacityReached();
        }
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

    /// @inheritdoc ILCCVault
    function claimExitedMargin(address receiver) external nonReentrant synced returns (uint256 assets) {
        if (receiver == address(0)) revert LCCErrorsLib.ZeroAddress();

        Account memory account = _replayForUpdate(msg.sender);
        if (!account.exitRequested || account.exitClaimed) revert LCCErrorsLib.NoExitRequested();
        if (_currentEpoch() < account.exitMaturityEpoch) revert LCCErrorsLib.ExitNotMature();

        // A fully-funded exiter matures with nothing claimable; still clear the exit so the account is reusable
        // (otherwise it stays exitRequested forever and can neither deposit nor re-exit).
        assets = account.claimableExitMargin;
        account.claimableExitMargin = 0;
        account.clearExit();
        _storeAccount(msg.sender, account);

        if (assets != 0) marginAsset.safeTransfer(receiver, assets);

        emit LCCEventsLib.ExitedMarginClaimed(msg.sender, receiver, assets);
    }

    /// @inheritdoc ILCCVault
    function claimRemainingMargin(address receiver) external nonReentrant synced returns (uint256 assets) {
        if (!_shutdown.active && !_terminal()) revert LCCErrorsLib.NotWithdrawable();
        if (receiver == address(0)) revert LCCErrorsLib.ZeroAddress();

        Account memory account = _replayForUpdate(msg.sender);

        uint256 activeMargin = account.activeMargin;
        uint256 activeCommitment = account.activeCommitment;
        uint256 pendingMargin = account.pendingMargin;
        uint256 pendingCommitment = account.pendingCommitment;
        uint256 claimableExitMargin = account.claimableExitMargin;

        assets = activeMargin + pendingMargin + claimableExitMargin;
        if (assets == 0) revert LCCErrorsLib.NothingToClaim();

        uint256 maturity = account.exitMaturityEpoch;
        if (account.exitRequested && !account.exitClaimed && !account.exitMatured) {
            exitBucketMarginByMaturity[maturity] -= account.exitBucketMargin;
            exitBucketCommitmentByMaturity[maturity] -= account.exitBucketCommitment;
            _pruneExitMaturityIfEmpty(maturity);
        }

        _decreaseGlobalActive(activeMargin, activeCommitment);
        _decreasePending(account, pendingMargin, pendingCommitment);

        account.activeMargin = 0;
        account.activeCommitment = 0;
        account.pendingMargin = 0;
        account.pendingCommitment = 0;
        account.pendingActivationEpoch = 0;
        account.claimableExitMargin = 0;
        account.clearExit();
        _storeAccount(msg.sender, account);

        marginAsset.safeTransfer(receiver, assets);

        emit LCCEventsLib.RemainingMarginClaimed(msg.sender, receiver, assets);
    }

    /* CALL, FUNDING & AUCTION ACTIONS */

    /// @inheritdoc ILCCVault
    function openEpochCall(uint256 epoch, uint256 callAmount) external onlyOwner synced {
        if (_shutdown.active) revert LCCErrorsLib.ShutdownActive();
        if (_terminal()) revert LCCErrorsLib.VaultTerminal();
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

    /// @inheritdoc ILCCVault
    function fundCall() external nonReentrant synced returns (uint256 obligationAmount) {
        return _fund(msg.sender, msg.sender);
    }

    /// @inheritdoc ILCCVault
    /// @dev Push-based third-party funding: the caller pays; released margin, wrapped USD3n delivery, and funded
    /// status always accrue to `user`.
    function fundCall(address user) external nonReentrant synced returns (uint256 obligationAmount) {
        if (user == address(0)) revert LCCErrorsLib.ZeroAddress();
        return _fund(msg.sender, user);
    }

    /// @inheritdoc ILCCVault
    /// @dev If USD3 or the notification vault cannot deliver wrapped USD3n, the take reverts. The fill targets
    /// whichever auction is live, following Yearn-take semantics: `maxFillAmount` is the caller's only bound, and the
    /// award is the current ramped kicker.
    function takeAuction(uint256 maxFillAmount)
        external
        nonReentrant
        synced
        returns (uint256 filledAmount, uint256 marginAward)
    {
        if (_shutdown.active) revert LCCErrorsLib.ShutdownActive();
        // synced settled any past-window auction, so a live slot implies the window is open.
        // Terminal needs no explicit guard: no terminal auction can be live after synced settlement.
        uint256 slot = _syncState.pendingAuctionEpochPlusOne;
        if (slot == 0) revert LCCErrorsLib.AuctionNotLive();
        uint256 epoch = slot - 1;

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
        _deliverWrapped(msg.sender, filledAmount);
        if (marginAward != 0) marginAsset.safeTransfer(msg.sender, marginAward);

        emit LCCEventsLib.AuctionFill(msg.sender, epoch, filledAmount, marginAward);

        if (state.filledAmount == state.shortfallAmount) _settleAuction(epoch);
    }

    /// @inheritdoc ILCCVault
    function finalizeEpochSlash(uint256 epoch) external nonReentrant synced {
        if (!epochs[epoch].slashFinalized) {
            if (!_slashEligible(epoch)) revert LCCErrorsLib.SlashNotEligible();
            _finalizeEpochSlash(epoch);
        }
    }

    /// @inheritdoc ILCCVault
    function materializeAccount(address user) external nonReentrant synced {
        if (user == address(0)) revert LCCErrorsLib.ZeroAddress();
        // Accounts with live historical exposure may need repeated calls; empty accounts fast-forward.
        Account memory account = _loadAccount(user);
        bytes32 beforeHash = keccak256(abi.encode(account));
        LCCTypesLib.AccountReplay memory replay = _replayAndRecordDefaults(user, account);
        if (keccak256(abi.encode(replay.account)) != beforeHash) _storeAccount(user, replay.account);
    }

    /* VIEWS */

    /// @inheritdoc ILCCVault
    function getAccount(address user) external view returns (Account memory) {
        return _previewAccount(user);
    }

    /// @inheritdoc ILCCVault
    function getEpochState(uint256 epoch) external view returns (EpochState memory) {
        return epochs[epoch];
    }

    /// @inheritdoc ILCCVault
    function getAuctionState(uint256 epoch) external view returns (LCCAuctionLib.AuctionState memory) {
        return epochAuctions[epoch];
    }

    /// @inheritdoc ILCCVault
    function obligationOf(uint256 epoch, address user) external view returns (uint256) {
        EpochState storage state = epochs[epoch];
        if (!state.callOpened || state.slashFinalized || fundedEpoch[epoch][user]) return 0;
        Account memory account = _previewAccount(user);
        return _obligation(state, account.activeCommitment);
    }

    /// @inheritdoc ILCCVault
    function claimableExitedMargin(address user) external view returns (uint256) {
        Account memory account = _previewAccount(user);
        if (!account.exitRequested || account.exitClaimed || _currentEpoch() < account.exitMaturityEpoch) return 0;
        return account.claimableExitMargin;
    }

    /// @inheritdoc ILCCVault
    function calledEpochs() external view returns (uint256[] memory) {
        return calledEpochList;
    }

    /// @inheritdoc ILCCVault
    function assetConfig() external view returns (AssetConfig memory) {
        return AssetConfig({
            marginAsset: address(marginAsset),
            fundingAsset: address(fundingAsset),
            usd3: address(usd3),
            notificationVault: address(notificationVault),
            marginOracle: address(marginOracle),
            treasury: treasury
        });
    }

    /// @inheritdoc ILCCVault
    function epochConfig() external view returns (EpochConfig memory) {
        return EpochConfig({
            startTimestamp: startTimestamp,
            maxEpochs: maxEpochs,
            epochLength: epochLength,
            normalDuration: normalDuration,
            preCallDuration: preCallDuration,
            fundingDuration: fundingDuration,
            marginRatioBps: marginRatioBps,
            exitDelayEpochs: exitDelayEpochs
        });
    }

    /// @inheritdoc ILCCVault
    function auctionConfig() external view returns (AuctionConfig memory) {
        return AuctionConfig({
            auctionStepCount: auctionStepCount,
            auctionStepDecayRateBps: auctionStepDecayRateBps,
            auctionStepDuration: auctionStepDuration
        });
    }

    /// @inheritdoc ILCCVault
    function riskConfig() external view returns (RiskConfig memory) {
        return _riskConfig;
    }

    /// @inheritdoc ILCCVault
    function totals() external view returns (Totals memory) {
        return _totals;
    }

    /// @inheritdoc ILCCVault
    function syncState() external view returns (SyncState memory) {
        return _syncState;
    }

    /// @inheritdoc ILCCVault
    function shutdownState() external view returns (ShutdownState memory) {
        return _shutdown;
    }

    /* FUNDING INTERNALS */

    function _fund(address payer, address user) internal returns (uint256 obligationAmount) {
        uint256 epoch = _currentEpoch();
        if (_phaseAt(block.timestamp) != Phase.Funding) revert LCCErrorsLib.InvalidPhase();

        EpochState storage state = epochs[epoch];
        // Terminal needs no explicit guard: no call can open for epoch maxEpochs, so this check is inert.
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
        _deliverWrapped(user, obligationAmount);

        marginAsset.safeTransfer(user, releasedMargin);

        emit LCCEventsLib.CallFunded(user, epoch, obligationAmount);
        emit LCCEventsLib.MarginReleased(user, epoch, releasedMargin);
    }

    /// @dev Delivers funded USDC as wrapped USD3n. The LCC vault is the USD3 receiver, so deployments must grant
    /// the vault the USD3 supply-cap exemption and, when enabled, the regular USD3 whitelist.
    function _deliverWrapped(address receiver, uint256 fundingAmount) internal {
        uint256 usd3Assets = usd3.deposit(fundingAmount, address(this));
        notificationVault.deposit(usd3Assets, receiver);
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

    /// @dev Exit commitment that has matured but not yet folded out of `_totals`, so it still inflates
    /// `usedCommitment` when disposal computes cap headroom. The add-back never double-counts: disposal on
    /// the sync path runs before `_foldDueMaturities`, and disposal from a mid-window full-fill settlement
    /// runs after that transaction's folds, where due buckets are already zeroed and pruned so this sums 0.
    /// Reordering `_syncGlobal` to fold maturities before finalization would break the first case into a
    /// double-count that overstates headroom.
    function _dueUnfoldedExitCommitment(uint256 current) internal view returns (uint256 commitment) {
        uint256 length = exitMaturityList.length;
        for (uint256 i = 0; i < length; ++i) {
            uint256 maturity = exitMaturityList[i];
            if (maturity <= current) commitment += exitBucketCommitmentByMaturity[maturity];
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

        // Slash is disabled only when shutdown landed strictly inside the funding window; at the deadline
        // itself the window has closed and defaults are final.
        bool disabled = _shutdown.active && _shutdown.timestamp < _fundingDeadline(epoch);
        state.slashFinalized = true;
        state.slashDisabledByShutdown = disabled;

        if (disabled) {
            emit LCCEventsLib.EpochSlashFinalized(epoch, 0, 0, true);
            return;
        }

        uint256 slashedMargin = state.marginAtCallOpen - state.marginReleased - state.fundedUsersRemainingMargin;
        uint256 slashedCommitment =
            state.commitmentDenominator - state.fundedAmount - state.fundedUsersRemainingCommitment;
        state.slashedMargin = slashedMargin;

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
                _disposeSlashSurplus(epoch, slashedMargin);
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
        _disposeSlashSurplus(epoch, remainder);

        emit LCCEventsLib.AuctionSettled(epoch, state.filledAmount, state.marginAwarded);
    }

    /// @dev Values `assets` of margin at `price` (scaled by ORACLE_PRICE_SCALE) and leverages the value into a
    /// fundingAsset commitment via `marginRatioBps`.
    function _marginValueAndCommitment(uint256 assets, uint256 price)
        internal
        view
        returns (uint256 marginValue, uint256 commitment)
    {
        marginValue = assets.mulDiv(price, ORACLE_PRICE_SCALE);
        commitment = marginValue.mulDiv(BPS, marginRatioBps);
    }

    function _disposeSlashSurplus(uint256 epoch, uint256 surplus) internal {
        if (surplus == 0) return;

        EpochState storage state = epochs[epoch];

        uint256 fee = surplus.mulDiv(_riskConfig.slashFeeBps, BPS);
        uint256 returnPool = surplus - fee;

        uint256 returnCommitment;
        // The oracle is consulted only when there is a return pool to value; a full-fee sweep never
        // depends on oracle liveness.
        if (returnPool != 0) {
            // Wind-down disposal skips the going-concern oracle-revert and protocol-cap clamp so recoverable
            // margin is never bricked or diverted to treasury once no future call can ever use the returned
            // commitment. That property is a function of the current clock, not the disposed epoch: it holds once
            // the last epoch's call-opening window has passed (`_callWindowClosed`), which covers both an early
            // settlement in the last epoch's own Closed phase and a lazy finalization of any older epoch disposed
            // for the first time in that late window (or at/after terminal).
            bool windDown = _shutdown.active || _callWindowClosed();
            uint256 price;
            if (windDown) {
                try marginOracle.price() returns (uint256 p) {
                    price = p;
                } catch {}
                // A price large enough to overflow the valuation is treated like a dead oracle so
                // wind-down can never brick on disposal.
                if (price > type(uint256).max / returnPool) price = 0;
            } else {
                price = marginOracle.price();
                if (price == 0) revert LCCErrorsLib.OraclePriceInvalid();
            }

            if (price == 0) {
                returnPool = 0;
            } else {
                (, uint256 rawCommitment) = _marginValueAndCommitment(returnPool, price);
                uint256 usedCommitment = uint256(_totals.activeCommitment) + uint256(_totals.pendingCommitment);
                // During wind-down no call can ever open, so returned commitment bounds no callable
                // exposure: clamping by the protocol cap would only divert defaulters' recoverable
                // margin to the treasury. Bound it by the packed-totals width instead.
                uint256 headroom = windDown
                    ? uint256(type(uint128).max).saturatingSub(usedCommitment)
                    : _riskConfig.protocolCommitmentCap.saturatingSub(usedCommitment)
                        + _dueUnfoldedExitCommitment(_currentEpoch());
                returnCommitment = rawCommitment.min(headroom);
                if (returnCommitment < MIN_RETURN_COMMITMENT) returnCommitment = 0;
                returnPool = returnCommitment == 0 ? 0 : returnPool.mulDiv(returnCommitment, rawCommitment);
            }
        }

        if (returnPool == 0) returnCommitment = 0;

        state.returnPool = returnPool;
        state.returnCommitment = returnCommitment;
        if (returnPool != 0) _increaseGlobalActive(returnPool, returnCommitment);
        uint256 toTreasury = surplus - returnPool;
        if (toTreasury != 0) marginAsset.safeTransfer(treasury, toTreasury);
        emit LCCEventsLib.SlashSurplusDisposed(epoch, toTreasury, returnPool, returnCommitment);
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
            if (record.returnMarginShare != 0) {
                emit LCCEventsLib.ReturnPoolCredited(
                    user, record.epoch, record.returnMarginShare, record.returnCommitmentShare
                );
            }
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
            if (_syncState.pendingAuctionEpochPlusOne == epoch + 1) break;

            replay.account.activatePendingForEpoch(epoch);
            replay.account.matureExitForEpoch(epoch);

            if (_shouldDefault(replay.account, state, epoch, user)) {
                uint256 slashedMargin = replay.account.activeMargin;
                uint256 slashedCommitment = replay.account.activeCommitment;
                (uint256 marginShare, uint256 commitmentShare) = _pairedReturnPoolShare(epoch, slashedMargin);
                if (bounded) {
                    if (replay.defaults.length == 0) replay.defaults = new LCCTypesLib.DefaultRecord[](maxSteps);
                    replay.defaults[replay.defaultCount] = LCCTypesLib.DefaultRecord(
                        epoch, slashedMargin, slashedCommitment, marginShare, commitmentShare
                    );
                    unchecked {
                        ++replay.defaultCount;
                    }
                }
                replay.account.defaultAccount();
                replay.account.activeMargin += marginShare;
                replay.account.activeCommitment += commitmentShare;
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

    function _pairedReturnPoolShare(uint256 epoch, uint256 slashedMargin)
        internal
        view
        returns (uint256 marginShare, uint256 commitmentShare)
    {
        if (slashedMargin == 0) return (0, 0);

        EpochState storage state = epochs[epoch];
        uint256 aggregateSlashedMargin = state.slashedMargin;
        if (aggregateSlashedMargin == 0 || state.returnPool == 0 || state.returnCommitment == 0) return (0, 0);

        commitmentShare = state.returnCommitment.mulDiv(slashedMargin, aggregateSlashedMargin);
        if (commitmentShare == 0) return (0, 0);

        marginShare = state.returnPool.mulDiv(slashedMargin, aggregateSlashedMargin);
        if (marginShare == 0) return (0, 0);
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

    /// @dev Each account's obligation is computed independently from the call-open snapshot and rounded up, so the
    /// sum across accounts can exceed `callAmount` by up to ~(number of funding accounts - 1) units. Ceil is
    /// intentional: it keeps each funding account's pro-rata obligation from rounding below its fair share. It does
    /// not guarantee the pool collects `callAmount` in full — accounts that default still under-collect, and that
    /// shortfall is covered by the slash/auction path, not by this rounding.
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

    function _terminal() internal view returns (bool) {
        return maxEpochs != 0 && _currentEpoch() >= maxEpochs;
    }

    /// @dev True once no call can ever open again: calls open only in a PreCall phase, so once the last callable
    /// epoch's PreCall window (`maxEpochs - 1`) has elapsed nothing can open a call. Perpetual vaults (`maxEpochs ==
    /// 0`) never close. Past this point a returned slash commitment can never back a future call, so surplus disposal
    /// drops the going-concern oracle-revert and protocol-cap clamp. Monotonic and strictly before the terminal
    /// boundary, so this also covers every disposal that runs once terminal.
    function _callWindowClosed() internal view returns (bool) {
        if (maxEpochs == 0) return false;
        uint256 current = _currentEpoch();
        // No call can open past the last callable epoch's PreCall window: either terminal, or in epoch
        // `maxEpochs - 1` with its PreCall phase already elapsed (calls open only during PreCall). Expressed via
        // the epoch clock, which is bounded by block.timestamp, so an unbounded `maxEpochs` cannot overflow.
        return current >= maxEpochs || (current == maxEpochs - 1 && _phaseAt(block.timestamp) >= Phase.Funding);
    }

    function _epochStart(uint256 epoch) internal view returns (uint256) {
        return startTimestamp + epoch * epochLength;
    }

    function _fundingDeadline(uint256 epoch) internal view returns (uint256) {
        return _epochStart(epoch) + normalDuration + preCallDuration + fundingDuration;
    }
}
