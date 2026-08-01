// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

import {Ownable} from "../../lib/openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "../../lib/openzeppelin/contracts/interfaces/IERC4626.sol";
import {Initializable} from "../../lib/openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "../../lib/openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "../../lib/openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "../../lib/openzeppelin/contracts/utils/math/SafeCast.sol";

import {IOracle} from "../interfaces/IOracle.sol";
import {BPS} from "../libraries/ConstantsLib.sol";
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
contract LCCVault is ILCCVault, Initializable, Ownable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using SafeCast for uint256;
    using LCCAccountLib for Account;

    uint256 internal constant MAX_MATERIALIZE_STEPS = 64;
    uint256 internal constant MAX_EXIT_MATURITY_BUCKETS = 2 * LCCConfigLib.MAX_EXIT_DELAY_EPOCHS;
    /// @notice Maximum extra fundingAsset pulled to ensure a dust obligation mints at least one USD3 share.
    uint256 internal constant MAX_FUNDING_TOP_UP = 1_000;
    /// @notice Minimum returned funding commitment retained for attribution, assuming 6-decimal USDC funding units.
    uint256 internal constant MIN_RETURN_COMMITMENT = 1e6;

    /* STORAGE */

    /// @notice The ERC-4626 notification wrapper that delivers USD3n to funders and fillers.
    IERC4626 private immutable notificationVault;
    /// @notice The ERC-4626 USD3 vault that accepts fundingAsset deposits.
    IERC4626 private immutable usd3;
    /// @notice The ERC20 used to fund calls and auction fills; equals USD3's underlying asset.
    IERC20 private immutable fundingAsset;
    /// @notice Protocol-wide recipient of slashed margin and unsold auction collateral.
    address private immutable treasury;

    // Sequential proxy storage starts after Ownable's _owner. Reentrancy state is transaction-scoped and uses no
    // persistent storage.

    /// @dev Packed per-facility epoch clock: startTimestamp, maxEpochs (0 = perpetual), epochLength, and the
    /// Normal/PreCall/Funding phase durations. Written once in initialize.
    LCCTypesLib.ClockConfig internal _clockConfig;
    /// @dev Packed per-facility margin config: marginAsset (the ERC20 performance bond), marginRatioBps, and
    /// exitDelayEpochs. The margin asset must be a standard ERC20: fee-on-transfer and rebasing tokens break margin
    /// conservation. Deployments must also keep the maximum margin balance reachable under the commitment caps
    /// below type(uint128).max (a constraint on margin decimals, the oracle price floor, marginRatioBps, and
    /// protocolCommitmentCap) or deposits revert on the packed-storage cast.
    LCCTypesLib.AssetConfigStorage internal _assetConfig;
    /// @dev Packed per-facility oracle + auction config: marginOracle, auctionStepCount, auctionStepDecayRateBps,
    /// and the derived auctionStepDuration. The auction window (the Closed phase) derives its step duration by
    /// flooring `closedWindow / auctionStepCount`; the live step index is uncapped and can therefore exceed
    /// `auctionStepCount - 1` when the division has a remainder. The maximum live step is
    /// `(closedWindow - 1) / auctionStepDuration`. The protocol's retained share of the pool decays by
    /// auctionStepDecayRateBps each completed step. auctionStepCount == 0 permanently disables the auction machinery.
    LCCTypesLib.AuctionConfigStorage internal _auctionConfig;

    /// @dev Mutable risk configuration. Per-epoch exit capacity is `exitCapBps` of the greater of the configured
    /// protocol cap and live active commitment, clamped to at least one funding-asset unit. The live-utilization
    /// floor deliberately makes assignment path-dependent and ensures capacity never falls below the configured-cap
    /// value at request time. Capacity is recomputed per request and can decline as active commitment declines.
    /// `activeCommitment` is aggregate and may conservatively include unattributed return commitment, which only
    /// widens capacity. `maxAuctionAwardBps` is the runtime auction-kicker off-switch. `slashFeeBps` is charged on
    /// auction-awarded slashed margin and capped by the unawarded surplus.
    RiskConfig internal _riskConfig;

    /// @dev Packed aggregate totals. Commitment totals are cap-bounded by `protocolCommitmentCap <=
    /// type(uint128).max`; margin totals rely on the aggregate deployment invariant and fail safely via SafeCast.
    Totals internal _totals;

    /// @dev Packed fold cursors and single live-auction slot (epoch + 1; 0 = none). Safe because calls are
    /// sequential: an auction for epoch E exists only during E's Closed window, and a later kick happens inside
    /// _syncGlobal after _settleDueAuction has already swept E.
    LCCTypesLib.SyncStateStorage internal _syncState;

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

    /// @dev Packed pending margin and commitment keyed by activation epoch. Exposed through the hand-written per-field
    /// uint256 view getters below, which form the stable external ABI.
    mapping(uint256 => LCCTypesLib.Bucket) internal pendingBucketByActivationEpoch;
    /// @dev Distinct activation epochs with nonzero pending buckets (swap-remove tracked; bounds the fold scan).
    uint256[] internal activationEpochList;
    /// @dev 1-based index of an activation epoch in `activationEpochList` (0 = absent).
    mapping(uint256 => uint256) internal activationEpochIndexPlusOne;
    /// @dev Packed exit margin and commitment keyed by maturity epoch. Exposed through the hand-written per-field
    /// uint256 view getters below, which form the stable external ABI.
    mapping(uint256 => LCCTypesLib.Bucket) internal exitBucketByMaturity;
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

    LCCTypesLib.PauseState internal _pause;

    /// @inheritdoc ILCCVault
    uint256 public pendingTreasuryMargin;

    /// @dev Epoch in which each call's nonzero return pool was created.
    mapping(uint256 => uint256) internal returnCreditEpochByCall;

    /// @dev Margin-oracle price frozen when each epoch call opens.
    mapping(uint256 => uint256) internal marginPriceAtCallOpen;

    /// @dev Reserved storage for future versions. Pre-deployment additions are declared above this gap so the
    /// post-deployment reserve stays at its full 50 slots; only upgrades after deployment consume gap slots.
    uint256[50] private __gap;

    /* CONSTRUCTOR / INITIALIZER */

    /// @notice Deploys the shared beacon implementation with protocol-wide integration addresses.
    /// @dev The implementation is not usable directly; beacon proxies are initialized atomically by the factory.
    /// @param notificationVault_ ERC-4626 wrapper over USD3 that receives funded amounts.
    /// @param treasury_ Protocol-wide recipient of slashed margin and unsold auction collateral.
    constructor(address notificationVault_, address treasury_) Ownable(address(1)) {
        if (notificationVault_ == address(0) || treasury_ == address(0)) revert LCCErrorsLib.ZeroAddress();

        notificationVault = IERC4626(notificationVault_);
        address usd3_ = notificationVault.asset();
        if (usd3_ == address(0)) revert LCCErrorsLib.InvalidParams();
        usd3 = IERC4626(usd3_);
        address fundingAsset_ = usd3.asset();
        if (fundingAsset_ == address(0)) revert LCCErrorsLib.InvalidParams();
        fundingAsset = IERC20(fundingAsset_);
        treasury = treasury_;

        _disableInitializers();
    }

    /// @inheritdoc ILCCVault
    /// @dev Grants standing max allowances to the trusted USD3 and notification vault spenders. USD3 short-circuits
    /// max allowance as permanently infinite; USDC decrements max allowance, but type(uint256).max is inexhaustible
    /// in practice. The vault holds no fundingAsset or USD3 between transactions, so the allowances expose no idle
    /// balance.
    function initialize(VaultParams calldata params) external initializer {
        uint256 auctionStepDuration_ = LCCConfigLib.validate(params);
        _transferOwnership(params.owner);

        fundingAsset.forceApprove(address(usd3), type(uint256).max);
        IERC20(address(usd3)).forceApprove(address(notificationVault), type(uint256).max);

        _clockConfig = LCCTypesLib.ClockConfig({
            startTimestamp: uint64(params.startTimestamp),
            maxEpochs: uint64(params.maxEpochs),
            epochLength: uint32(params.epochLength),
            normalDuration: uint32(params.normalDuration),
            preCallDuration: uint32(params.preCallDuration),
            fundingDuration: uint32(params.fundingDuration)
        });
        _assetConfig = LCCTypesLib.AssetConfigStorage({
            marginAsset: params.marginAsset,
            marginRatioBps: uint16(params.marginRatioBps),
            exitDelayEpochs: uint16(params.exitDelayEpochs),
            minCommitmentEpochs: uint16(params.minCommitmentEpochs)
        });
        _auctionConfig = LCCTypesLib.AuctionConfigStorage({
            marginOracle: params.marginOracle,
            auctionStepCount: uint32(params.auctionStepCount),
            auctionStepDecayRateBps: uint16(params.auctionStepDecayRateBps),
            auctionStepDuration: uint32(auctionStepDuration_)
        });

        _riskConfig = RiskConfig({
            protocolCommitmentCap: params.protocolCommitmentCap,
            userCommitmentCap: params.userCommitmentCap,
            exitCapBps: params.exitCapBps,
            minDepositAssets: params.minDepositAssets,
            maxAuctionAwardBps: params.maxAuctionAwardBps,
            slashFeeBps: params.slashFeeBps
        });

        uint256 epoch = _currentEpoch();
        _syncState.lastFolded = epoch.toUint64();
    }

    /* MODIFIERS */

    modifier synced() {
        _sync();
        _;
    }

    /* CLOCK VIEWS */

    /// @inheritdoc ILCCVault
    function currentEpoch() external view returns (uint256) {
        return _currentEpoch();
    }

    /// @inheritdoc ILCCVault
    function currentPhase() external view returns (Phase) {
        return _phaseAt(_now());
    }

    /// @inheritdoc ILCCVault
    function phaseEndsAt(uint256 epoch, Phase phase) external view returns (uint256) {
        uint256 effectiveEnd = _phaseEnd(epoch, phase);
        return effectiveEnd + (block.timestamp - _now()); // deliberate wall-clock read
    }

    /// @inheritdoc ILCCVault
    function pauseState()
        external
        view
        returns (address guardian, bool paused, uint64 pausedAt, uint64 pausedAccumulated)
    {
        LCCTypesLib.PauseState memory p = _pause;
        return (p.guardian, p.paused, p.pausedAt, p.pausedAccumulated);
    }

    /* OWNER ACTIONS */

    /// @dev Ownership renunciation is disabled because an ownerless vault could never unpause, shut down, or open
    /// calls. Ownership remains transferable for incident recovery and governance rotation.
    function renounceOwnership() public pure override {
        revert LCCErrorsLib.Unauthorized();
    }

    /// @inheritdoc ILCCVault
    /// @dev Lowering caps below current utilization does not force existing positions or assigned exit buckets to
    /// unwind. Capacity is recomputed per request from live utilization, so it cannot be worse than the configured-cap
    /// formula at that request, but it can decline as active commitment declines through amortization or slashing.
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
        // Surplus disposal may be deferred past slash finalization only through the auction slot.
        if (newProtocolCommitmentCap < _riskConfig.protocolCommitmentCap && _syncState.pendingAuctionEpochPlusOne != 0) revert LCCErrorsLib.InvalidPhase();

        _riskConfig.protocolCommitmentCap = newProtocolCommitmentCap;
        _riskConfig.userCommitmentCap = newUserCommitmentCap;
        _riskConfig.exitCapBps = newExitCapBps;
        _riskConfig.minDepositAssets = newMinDeposit;

        emit LCCEventsLib.RiskCapUpdated(newProtocolCommitmentCap, newUserCommitmentCap, newExitCapBps, newMinDeposit);
    }

    /// @inheritdoc ILCCVault
    function setMaxAuctionAwardBps(uint256 newMaxAuctionAwardBps) external onlyOwner synced {
        if (newMaxAuctionAwardBps > BPS) revert LCCErrorsLib.InvalidParams();
        if (newMaxAuctionAwardBps != 0 && _auctionConfig.auctionStepCount == 0) revert LCCErrorsLib.InvalidParams();
        // No repricing while fillers are mid-auction.
        if (_syncState.pendingAuctionEpochPlusOne != 0) revert LCCErrorsLib.InvalidPhase();

        _riskConfig.maxAuctionAwardBps = newMaxAuctionAwardBps;

        emit LCCEventsLib.AuctionAwardCapUpdated(newMaxAuctionAwardBps);
    }

    /// @inheritdoc ILCCVault
    function setSlashFeeBps(uint256 newSlashFeeBps) external onlyOwner synced {
        if (newSlashFeeBps > BPS) revert LCCErrorsLib.InvalidParams();
        // The fee basis is auction-awarded margin, so a nonzero fee on an auction-disabled vault is dead config.
        if (newSlashFeeBps != 0 && _auctionConfig.auctionStepCount == 0) revert LCCErrorsLib.InvalidParams();
        if (_syncState.pendingAuctionEpochPlusOne != 0) revert LCCErrorsLib.InvalidPhase();

        _riskConfig.slashFeeBps = newSlashFeeBps;

        emit LCCEventsLib.SlashFeeUpdated(newSlashFeeBps);
    }

    /// @inheritdoc ILCCVault
    /// @dev Rotation is owner-trusted and reprices subsequent deposits and auction fill awards, but does not reprice
    /// conversion of an opened call's remaining return pool. The live-auction guard blocks rotation only while
    /// unpaused and the current oracle still returns a nonzero price for fills. While paused no fills can execute, so
    /// the owner may rotate even a responsive but compromised oracle before resuming the frozen auction. A
    /// zero-price, reverting, or otherwise unreadable current oracle never blocks rotation. The new oracle must return
    /// marginAsset-to-fundingAsset (USDC) prices at ORACLE_PRICE_SCALE with matching decimals; the vault can only
    /// check that the price is nonzero.
    function setMarginOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert LCCErrorsLib.ZeroAddress();
        uint256 auctionSlot = _syncState.pendingAuctionEpochPlusOne;
        if (auctionSlot != 0 && !_pause.paused && _now() < _phaseEnd(auctionSlot - 1, Phase.Closed)) {
            try IOracle(_auctionConfig.marginOracle).price() returns (uint256 oldPrice) {
                if (oldPrice != 0) revert LCCErrorsLib.InvalidPhase();
            } catch {}
        }
        if (IOracle(newOracle).price() == 0) revert LCCErrorsLib.OraclePriceInvalid();

        address oldOracle = _auctionConfig.marginOracle;
        _auctionConfig.marginOracle = newOracle;

        emit LCCEventsLib.MarginOracleUpdated(oldOracle, newOracle);
    }

    /// @inheritdoc ILCCVault
    function setGuardian(address newGuardian) external onlyOwner {
        emit LCCEventsLib.GuardianUpdated(_pause.guardian, newGuardian);
        _pause.guardian = newGuardian;
    }

    /// @inheritdoc ILCCVault
    function pause() external {
        LCCTypesLib.PauseState memory p = _pause;
        if (msg.sender != owner() && msg.sender != p.guardian) revert LCCErrorsLib.Unauthorized();
        if (p.paused) revert LCCErrorsLib.AlreadyPaused();

        p.paused = true;
        p.pausedAt = block.timestamp.toUint48(); // deliberate wall-clock read
        _pause = p;

        emit LCCEventsLib.Paused(msg.sender);
    }

    /// @inheritdoc ILCCVault
    function unpause() external onlyOwner {
        if (!_pause.paused) revert LCCErrorsLib.NotPaused();
        _endPause();
    }

    /// @inheritdoc ILCCVault
    function shutdown() external onlyOwner {
        if (_shutdown.active) revert LCCErrorsLib.ShutdownActive();
        if (_pause.paused) _endPause();
        _shutdown.active = true;
        _shutdown.timestamp = uint64(_now());
        _shutdown.epoch = uint64(_currentEpoch());
        emit LCCEventsLib.EmergencyShutdown(_shutdown.epoch, _shutdown.timestamp);
        // Shutdown is recorded before the sync so in-flight finalizations see it: mid-window epochs finalize
        // with slash disabled, and legitimate called epochs dispose from their stored price snapshots.
        _syncGlobal();
    }

    /* USER ACTIONS */

    /// @inheritdoc ILCCVault
    /// @dev The margin oracle is fully trusted to return a fresh marginAsset-to-fundingAsset price scaled by
    /// ORACLE_PRICE_SCALE, including any token decimal conversion.
    function deposit(
        uint256 assets,
        uint256 minCommitment,
        uint256 maxCommitment,
        bool allowPendingActivation,
        uint256 deadline
    ) external nonReentrant synced returns (uint256 commitment) {
        if (_syncState.pendingAuctionEpochPlusOne != 0) revert LCCErrorsLib.InvalidPhase();
        if (_shutdown.active) revert LCCErrorsLib.ShutdownActive();

        (uint256 activationEpoch, bool immediate) = _depositActivation();
        if (_clockConfig.maxEpochs != 0 && activationEpoch >= _clockConfig.maxEpochs) {
            revert LCCErrorsLib.VaultTerminal();
        }

        if (minCommitment == 0 || minCommitment > maxCommitment) revert LCCErrorsLib.InvalidAmount();
        if (block.timestamp > deadline) revert LCCErrorsLib.DeadlineExpired(); // deliberate wall-clock read
        if (!immediate && !allowPendingActivation) revert LCCErrorsLib.InvalidPhase();
        if (assets == 0 || assets < _riskConfig.minDepositAssets) revert LCCErrorsLib.InvalidAmount();
        if (
            uint256(_totals.activeMargin).saturatingAdd(_totals.pendingMargin).saturatingAdd(assets) > type(uint128).max
        ) revert LCCErrorsLib.CapExceeded();

        Account memory account = _replayForUpdate(msg.sender);
        if (account.exitRequested && !account.exitClaimed) revert LCCErrorsLib.ExitInProgress();

        uint256 price = _marginOraclePrice();

        uint256 marginValue;
        (marginValue, commitment) = _marginValueAndCommitment(assets, price);
        if (commitment < minCommitment || commitment > maxCommitment) revert LCCErrorsLib.InvalidAmount();

        if (
            _totals.activeCommitment + _totals.pendingCommitment + commitment > _riskConfig.protocolCommitmentCap
                || account.activeCommitment + account.pendingCommitment + commitment > _riskConfig.userCommitmentCap
        ) {
            revert LCCErrorsLib.CapExceeded();
        }

        IERC20(_assetConfig.marginAsset).safeTransferFrom(msg.sender, address(this), assets);

        if (immediate) {
            account.activeMargin += assets;
            account.activeCommitment += commitment;
            _increaseGlobalActive(assets, commitment);
        } else {
            _addPending(account, assets, commitment, activationEpoch);
        }
        // commitmentStartEpoch is monotone: a deposit only ever moves it forward, and it never drops below a
        // staged deposit's activation epoch.
        account.commitmentStartEpoch =
            Math.max(account.commitmentStartEpoch, Math.max(activationEpoch, account.pendingActivationEpoch));
        _storeAccount(msg.sender, account);

        emit LCCEventsLib.DepositCheckpointed(msg.sender, assets, marginValue, commitment, activationEpoch, immediate);
    }

    /// @inheritdoc ILCCVault
    function requestExit(uint256 maxDeferralEpochs, uint256 deadline)
        external
        nonReentrant
        synced
        returns (uint256 maturityEpoch)
    {
        if (_terminal()) revert LCCErrorsLib.VaultTerminal();
        if (block.timestamp > deadline) revert LCCErrorsLib.DeadlineExpired(); // deliberate wall-clock read
        Account memory account = _replayForUpdate(msg.sender);
        if (account.exitRequested && !account.exitClaimed) revert LCCErrorsLib.ExitInProgress();
        if (account.pendingMargin != 0 || account.pendingCommitment != 0) revert LCCErrorsLib.PendingDepositExists();

        uint256 accountCommitment = account.activeCommitment;
        uint256 accountMargin = account.activeMargin;
        if (accountCommitment == 0 || accountMargin == 0) revert LCCErrorsLib.InvalidAmount();
        if (_currentEpoch() < account.commitmentStartEpoch + _assetConfig.minCommitmentEpochs) {
            revert LCCErrorsLib.CommitmentNotMature();
        }

        maturityEpoch = _assignExitMaturity(accountCommitment, maxDeferralEpochs);
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

        LCCTypesLib.Bucket storage bucket = exitBucketByMaturity[maturityEpoch];
        _increaseBucket(bucket, accountMargin, accountCommitment);
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

        if (assets != 0) _transferMargin(receiver, assets);

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
            LCCTypesLib.Bucket storage bucket = exitBucketByMaturity[maturity];
            _decreaseBucket(bucket, account.exitBucketMargin, account.exitBucketCommitment);
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

        _transferMargin(receiver, assets);

        emit LCCEventsLib.RemainingMarginClaimed(msg.sender, receiver, assets);
    }

    /// @inheritdoc ILCCVault
    function sweepTreasury() external nonReentrant {
        uint256 amount = pendingTreasuryMargin;
        if (amount == 0) return;
        pendingTreasuryMargin = 0;
        _transferMargin(treasury, amount);
        emit LCCEventsLib.TreasurySwept(amount);
    }

    /* CALL, FUNDING & AUCTION ACTIONS */

    /// @inheritdoc ILCCVault
    function openEpochCall(uint256 epoch, uint256 callAmount) external onlyOwner synced {
        if (_shutdown.active) revert LCCErrorsLib.ShutdownActive();
        if (_terminal()) revert LCCErrorsLib.VaultTerminal();
        if (epoch != _currentEpoch()) revert LCCErrorsLib.InvalidEpoch();
        if (_phaseAt(_now()) != Phase.PreCall) revert LCCErrorsLib.InvalidPhase();
        if (callAmount == 0) revert LCCErrorsLib.InvalidAmount();

        _requireNoPriorUnsettledCall(epoch);

        EpochState storage state = epochs[epoch];
        if (state.callOpened) revert LCCErrorsLib.CallAlreadyOpened();
        if (callAmount > _totals.activeCommitment) revert LCCErrorsLib.InvalidAmount();

        uint256 marginPrice = _marginOraclePrice();
        marginPriceAtCallOpen[epoch] = marginPrice;
        state.callOpened = true;
        state.commitmentDenominator = _totals.activeCommitment;
        state.callAmount = callAmount;
        state.marginAtCallOpen = _totals.activeMargin;
        calledEpochList.push(epoch);
        _snapshotExitBucketsForCall(epoch);

        emit LCCEventsLib.EpochCallOpened(epoch, callAmount, _totals.activeCommitment, marginPrice);
    }

    /// @inheritdoc ILCCVault
    function fundCall(bool roll) external nonReentrant synced returns (uint256 obligationAmount) {
        return _fund(msg.sender, msg.sender, roll);
    }

    /// @inheritdoc ILCCVault
    /// @dev Push-based third-party funding: the caller pays; released margin, wrapped USD3n delivery, and funded
    /// status always accrue to `user`.
    function fundCall(address user) external nonReentrant synced returns (uint256 obligationAmount) {
        if (user == address(0)) revert LCCErrorsLib.ZeroAddress();
        return _fund(msg.sender, user, false);
    }

    /// @inheritdoc ILCCVault
    /// @dev If USD3 or the notification vault cannot deliver wrapped USD3n, the take reverts. The fill targets
    /// whichever auction is live, following Yearn-take semantics. The execution-time award must meet the caller's
    /// minimum. The wall-clock deadline is checked first in the function body, after `synced` runs; an expired
    /// deadline reverts that sync work along with the fill.
    function takeAuction(uint256 maxFillAmount, uint256 minMarginAward, uint256 deadline)
        external
        nonReentrant
        synced
        returns (uint256 filledAmount, uint256 marginAward)
    {
        if (block.timestamp > deadline) revert LCCErrorsLib.DeadlineExpired(); // deliberate wall-clock read
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

        uint256 price = _marginOraclePrice();

        marginAward = LCCAuctionLib.applyFill(
            state,
            filledAmount,
            _now() - _fundingDeadline(epoch),
            _auctionConfig.auctionStepDuration,
            _auctionConfig.auctionStepDecayRateBps,
            _riskConfig.maxAuctionAwardBps,
            price
        );
        if (marginAward < minMarginAward) revert LCCErrorsLib.InsufficientMarginAward();

        fundingAsset.safeTransferFrom(msg.sender, address(this), filledAmount);
        _deliverWrapped(msg.sender, filledAmount);
        if (marginAward != 0) _transferMargin(msg.sender, marginAward);

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
        LCCTypesLib.AccountReplay memory replay = _replayAndRecordDefaults(user, account);
        _storeAccount(user, replay.account);
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
            marginAsset: _assetConfig.marginAsset,
            fundingAsset: address(fundingAsset),
            usd3: address(usd3),
            notificationVault: address(notificationVault),
            marginOracle: _auctionConfig.marginOracle,
            treasury: treasury
        });
    }

    /// @inheritdoc ILCCVault
    function epochConfig() external view returns (EpochConfig memory) {
        return EpochConfig({
            startTimestamp: _clockConfig.startTimestamp,
            maxEpochs: _clockConfig.maxEpochs,
            epochLength: _clockConfig.epochLength,
            normalDuration: _clockConfig.normalDuration,
            preCallDuration: _clockConfig.preCallDuration,
            fundingDuration: _clockConfig.fundingDuration,
            marginRatioBps: _assetConfig.marginRatioBps,
            exitDelayEpochs: _assetConfig.exitDelayEpochs,
            minCommitmentEpochs: _assetConfig.minCommitmentEpochs
        });
    }

    /// @inheritdoc ILCCVault
    function auctionConfig() external view returns (AuctionConfig memory) {
        return AuctionConfig({
            auctionStepCount: _auctionConfig.auctionStepCount,
            auctionStepDecayRateBps: _auctionConfig.auctionStepDecayRateBps,
            auctionStepDuration: _auctionConfig.auctionStepDuration
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
        uint64 lastFolded = _syncState.lastFolded;
        return SyncState({
            lastActivationFolded: lastFolded,
            lastMaturityFolded: lastFolded,
            finalizedCallPrefix: _syncState.finalizedCallPrefix,
            pendingAuctionEpochPlusOne: _syncState.pendingAuctionEpochPlusOne
        });
    }

    /// @inheritdoc ILCCVault
    function shutdownState() external view returns (ShutdownState memory) {
        return _shutdown;
    }

    /// @inheritdoc ILCCVault
    function pendingMarginByActivationEpoch(uint256 epoch) external view returns (uint256) {
        return pendingBucketByActivationEpoch[epoch].margin;
    }

    /// @inheritdoc ILCCVault
    function pendingCommitmentByActivationEpoch(uint256 epoch) external view returns (uint256) {
        return pendingBucketByActivationEpoch[epoch].commitment;
    }

    /// @inheritdoc ILCCVault
    function exitBucketMarginByMaturity(uint256 epoch) external view returns (uint256) {
        return exitBucketByMaturity[epoch].margin;
    }

    /// @inheritdoc ILCCVault
    function exitBucketCommitmentByMaturity(uint256 epoch) external view returns (uint256) {
        return exitBucketByMaturity[epoch].commitment;
    }

    /* FUNDING INTERNALS */

    function _fund(address payer, address user, bool roll) internal returns (uint256 obligationAmount) {
        uint256 epoch = _currentEpoch();
        if (_phaseAt(_now()) != Phase.Funding) revert LCCErrorsLib.InvalidPhase();

        EpochState storage state = epochs[epoch];
        // Terminal needs no explicit guard: no call can open for epoch maxEpochs, so this check is inert.
        if (!state.callOpened || state.slashFinalized) revert LCCErrorsLib.InvalidEpoch();
        if (fundedEpoch[epoch][user]) revert LCCErrorsLib.AlreadyFunded();

        Account memory account = _replayForUpdate(user);
        obligationAmount = _obligation(state, account.activeCommitment);
        if (obligationAmount == 0) revert LCCErrorsLib.InvalidAmount();
        if (roll && account.exitRequested && !account.exitClaimed) revert LCCErrorsLib.ExitInProgress();

        uint256 minimumFundingAmount = usd3.previewMint(1);
        if (minimumFundingAmount == 0) revert LCCErrorsLib.FundingDeliveryImpossible();
        uint256 fundingAmount = Math.max(obligationAmount, minimumFundingAmount);
        if (fundingAmount - obligationAmount > MAX_FUNDING_TOP_UP) {
            revert LCCErrorsLib.FundingTopUpExcessive();
        }

        uint256 releasedMargin = roll ? 0 : account.activeMargin.mulDiv(obligationAmount, account.activeCommitment);
        uint256 remainingMargin = account.activeMargin - releasedMargin;
        uint256 remainingCommitment = account.activeCommitment - obligationAmount;

        _recordExitingFund(epoch, account, obligationAmount, releasedMargin, remainingMargin, remainingCommitment);

        if (!roll) {
            account.activeMargin = remainingMargin;
            account.activeCommitment = remainingCommitment;
        }
        _storeAccount(user, account);
        fundedEpoch[epoch][user] = true;

        state.fundedAmount += obligationAmount;
        state.marginReleased += releasedMargin;
        state.fundedUsersRemainingMargin += remainingMargin;
        state.fundedUsersRemainingCommitment += remainingCommitment;

        if (!roll) _decreaseGlobalActive(releasedMargin, obligationAmount);

        fundingAsset.safeTransferFrom(payer, address(this), fundingAmount);
        _deliverWrapped(user, fundingAmount);

        if (releasedMargin != 0) _transferMargin(user, releasedMargin);

        emit LCCEventsLib.CallFunded(payer, user, epoch, obligationAmount, fundingAmount);
        emit LCCEventsLib.MarginReleased(user, epoch, releasedMargin);
    }

    /// @dev Delivers funded USDC as wrapped USD3n. The LCC vault is the USD3 receiver, so deployments must grant
    /// the vault the USD3 supply-cap exemption.
    function _deliverWrapped(address receiver, uint256 fundingAmount) internal {
        uint256 usd3Assets = usd3.deposit(fundingAmount, address(this));
        notificationVault.deposit(usd3Assets, receiver);
    }

    function _transferMargin(address receiver, uint256 assets) internal {
        IERC20(_assetConfig.marginAsset).safeTransfer(receiver, assets);
    }

    /* SYNC, FOLD & SLASH INTERNALS */

    /// @dev Ends a known-active pause. Callers decide whether an inactive pause should revert or be skipped.
    function _endPause() internal {
        LCCTypesLib.PauseState memory p = _pause;
        p.paused = false;
        uint256 wallTimestamp = block.timestamp; // deliberate wall-clock read
        p.pausedAccumulated = (uint256(p.pausedAccumulated) + wallTimestamp - p.pausedAt).toUint40();
        _pause = p;

        emit LCCEventsLib.Unpaused(msg.sender);
    }

    function _sync() internal {
        if (_pause.paused) revert LCCErrorsLib.Paused();
        _syncGlobal();
    }

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

        // Slash finalization must run before maturity folds so defaulted exiter exposure is carved out of exit buckets
        // before those buckets decrement global active totals.
        _foldDueMaturities(current);
        _syncState.lastFolded = current.toUint64();
    }

    function _foldDueActivations(uint256 current) internal {
        // `pruneIfEmpty` swap-removes by moving the tail into the pruned index. Iterating tail-to-head means the
        // moved element was already examined: a due tail removed itself, while a future tail was correctly retained.
        for (uint256 i = activationEpochList.length; i != 0;) {
            unchecked {
                --i;
            }
            uint256 epoch = activationEpochList[i];
            if (epoch <= current) _foldActivation(epoch);
        }
    }

    function _foldDueMaturities(uint256 current) internal {
        // See `_foldDueActivations`: reverse iteration makes swap-removal safe without a temporary due-bucket array.
        for (uint256 i = exitMaturityList.length; i != 0;) {
            unchecked {
                --i;
            }
            uint256 epoch = exitMaturityList[i];
            if (epoch <= current) _foldMaturity(epoch);
        }
    }

    function _foldActivation(uint256 epoch) internal {
        LCCTypesLib.Bucket memory bucket = pendingBucketByActivationEpoch[epoch];
        uint256 margin = bucket.margin;
        uint256 commitment = bucket.commitment;
        if (margin == 0 && commitment == 0) return;

        delete pendingBucketByActivationEpoch[epoch];
        _pruneActivationEpochIfEmpty(epoch);
        _decreasePendingTotals(margin, commitment);
        _increaseGlobalActive(margin, commitment);

        emit LCCEventsLib.PendingActivated(epoch, margin, commitment);
    }

    function _foldMaturity(uint256 epoch) internal {
        LCCTypesLib.Bucket memory bucket = exitBucketByMaturity[epoch];
        uint256 margin = bucket.margin;
        uint256 commitment = bucket.commitment;
        if (margin == 0 && commitment == 0) return;

        delete exitBucketByMaturity[epoch];
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

        if (disabled) {
            state.slashDisabledByShutdown = true;
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
                    && _now() < _phaseEnd(epoch, Phase.Closed)
            ) {
                epochAuctions[epoch] = LCCAuctionLib.AuctionState({
                    shortfallAmount: shortfallAmount.toUint128(),
                    filledAmount: 0,
                    marginPool: slashedMargin.toUint128(),
                    marginAwarded: 0
                });
                _syncState.pendingAuctionEpochPlusOne = (epoch + 1).toUint64();
                emit LCCEventsLib.AuctionKicked(epoch, shortfallAmount, slashedMargin);
            } else {
                // No auction was kicked for this epoch, so its recorded award is zero. Reading it from storage
                // rather than passing a literal keeps the optimizer from specializing a second copy of the
                // disposal body for the constant-zero argument (~600 bytes of runtime code).
                _disposeSlashSurplus(epoch, slashedMargin, epochAuctions[epoch].marginAwarded);
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
        if (!_shutdown.active && _now() < _phaseEnd(epoch, Phase.Closed)) return;
        _settleAuction(epoch);
    }

    function _settleAuction(uint256 epoch) internal {
        LCCAuctionLib.AuctionState storage state = epochAuctions[epoch];
        _syncState.pendingAuctionEpochPlusOne = 0;

        uint256 remainder = state.marginPool - state.marginAwarded;
        _disposeSlashSurplus(epoch, remainder, state.marginAwarded);

        emit LCCEventsLib.AuctionSettled(epoch, state.filledAmount, state.marginAwarded);
    }

    /// @dev Values `assets` of margin at `price` (scaled by ORACLE_PRICE_SCALE) and leverages the value into a
    /// fundingAsset commitment via `marginRatioBps`.
    function _marginValueAndCommitment(uint256 assets, uint256 price)
        internal
        view
        returns (uint256 marginValue, uint256 commitment)
    {
        return LCCAuctionLib.valueAndCommitment(assets, price, _assetConfig.marginRatioBps);
    }

    function _marginOraclePrice() internal view returns (uint256 price) {
        price = IOracle(_auctionConfig.marginOracle).price();
        if (price == 0) revert LCCErrorsLib.OraclePriceInvalid();
    }

    /// @dev Charges the slash fee on auction-awarded collateral and caps it by the unawarded surplus being disposed.
    /// Any surplus not consumed by the fee is valued from the call-open price snapshot. A missing snapshot is an
    /// invalid storage state: going-concern disposal is recoverable from the live oracle only when owner-triggered,
    /// while wind-down remains tolerant of a missing, reverting, zero, or overflow-risk selected price.
    /// A positive commitment clamp preserves the full post-fee pool; zero or dust commitment headroom zeroes its
    /// paired pool and diverts the surplus to treasury.
    function _disposeSlashSurplus(uint256 epoch, uint256 surplus, uint256 auctionedMargin) internal {
        if (surplus == 0) return;

        EpochState storage state = epochs[epoch];
        uint256 marginPriceSnapshot = marginPriceAtCallOpen[epoch];

        // Wind-down disposal skips the going-concern missing-snapshot revert and protocol-cap clamp so recoverable
        // margin is never bricked or diverted to treasury once no future call can ever use the returned
        // commitment. That property is a function of the current clock, not the disposed epoch: it holds once
        // the last epoch's call-opening window has passed (`_callWindowClosed`), which covers both an early
        // settlement in the last epoch's own Closed phase and a lazy finalization of any older epoch disposed
        // for the first time in that late window (or at/after terminal).
        bool windDown = _shutdown.active || _callWindowClosed();
        uint256 packingHeadroom;
        {
            uint256 usedCommitment = uint256(_totals.activeCommitment) + uint256(_totals.pendingCommitment);
            packingHeadroom = uint256(type(uint128).max).saturatingSub(usedCommitment);
        }
        uint256 usedMargin = uint256(_totals.activeMargin) + uint256(_totals.pendingMargin);
        uint256 fundedCallOpenCommitment = state.fundedAmount + state.fundedUsersRemainingCommitment;
        uint256 slashedCommitment = state.commitmentDenominator - fundedCallOpenCommitment;
        // The call-local bound is frozen against unrelated deposits. During wind-down no future call can use the
        // returned commitment, so the current protocol cap is intentionally omitted.
        uint256 headroom = Math.min(slashedCommitment, packingHeadroom);
        if (!windDown) {
            headroom = Math.min(
                Math.min(slashedCommitment, _riskConfig.protocolCommitmentCap.saturatingSub(fundedCallOpenCommitment)),
                packingHeadroom
            );
        }

        (uint256 returnPool, uint256 returnCommitment) = LCCAuctionLib.disposeValuation(
            surplus,
            auctionedMargin,
            _riskConfig.slashFeeBps,
            marginPriceSnapshot,
            _auctionConfig.marginOracle,
            msg.sender == owner(),
            windDown,
            _assetConfig.marginRatioBps,
            usedMargin,
            headroom,
            MIN_RETURN_COMMITMENT
        );

        state.returnPool = returnPool;
        state.returnCommitment = returnCommitment;
        if (returnPool != 0) {
            returnCreditEpochByCall[epoch] = _currentEpoch();
            _increaseGlobalActive(returnPool, returnCommitment);
        }
        uint256 toTreasury = surplus - returnPool;
        pendingTreasuryMargin += toTreasury;
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
        account.commitmentStartEpoch = stored.commitmentStartEpoch;
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
            exitMatured: account.exitMatured,
            commitmentStartEpoch: account.commitmentStartEpoch.toUint64()
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

            bool shouldDefault = _shouldDefault(replay.account, state, epoch, user);
            if (_syncState.pendingAuctionEpochPlusOne == epoch + 1 && shouldDefault) break;

            if (shouldDefault) {
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
                if ((marginShare | commitmentShare) != 0) {
                    replay.account.commitmentStartEpoch =
                        Math.max(replay.account.commitmentStartEpoch, Math.max(epoch, returnCreditEpochByCall[epoch]));
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

        uint256 current = _currentEpoch();
        uint256 folded = current > _syncState.lastFolded ? current : _syncState.lastFolded;
        if (stoppedAtUnfinalized && _slashEligible(unfinalizedEpoch) && folded > unfinalizedEpoch) {
            folded = unfinalizedEpoch;
        }

        replay.account.activatePendingForEpoch(folded);
        replay.account.matureExitForEpoch(folded);
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
        // Keep the tuple literal so this helper never returns a margin-only share when commitment rounds to zero.
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
        LCCTypesLib.Bucket storage bucket = pendingBucketByActivationEpoch[activationEpoch];
        bool empty = bucket.margin == 0 && bucket.commitment == 0;
        LCCBucketListLib.pruneIfEmpty(activationEpochList, activationEpochIndexPlusOne, activationEpoch, empty);
    }

    function _pruneExitMaturityIfEmpty(uint256 maturityEpoch) internal {
        LCCTypesLib.Bucket storage bucket = exitBucketByMaturity[maturityEpoch];
        bool empty = bucket.margin == 0 && bucket.commitment == 0;
        LCCBucketListLib.pruneIfEmpty(exitMaturityList, exitMaturityIndexPlusOne, maturityEpoch, empty);
    }

    function _snapshotExitBucketsForCall(uint256 epoch) internal {
        for (uint256 i = 0; i < exitMaturityList.length; ++i) {
            uint256 maturity = exitMaturityList[i];
            if (maturity <= epoch) continue;

            LCCTypesLib.Bucket storage bucket = exitBucketByMaturity[maturity];
            uint256 margin = bucket.margin;
            uint256 commitment = bucket.commitment;
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
        exposure.margin = (uint256(exposure.margin) + margin).toUint128();
        exposure.commitment = (uint256(exposure.commitment) + commitment).toUint128();
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
        LCCTypesLib.Bucket storage bucket = exitBucketByMaturity[maturity];
        _decreaseBucket(bucket, releasedMargin, obligationAmount);
        _pruneExitMaturityIfEmpty(maturity);
        account.exitBucketMargin -= releasedMargin;
        account.exitBucketCommitment -= obligationAmount;

        LCCTypesLib.ExitExposure storage exposure = exitExposureByCallAndMaturity[epoch][maturity];
        if (!exposure.listed) return;

        exposure.fundedAmount = (uint256(exposure.fundedAmount) + obligationAmount).toUint128();
        exposure.marginReleased = (uint256(exposure.marginReleased) + releasedMargin).toUint128();
        exposure.fundedUsersRemainingMargin =
            (uint256(exposure.fundedUsersRemainingMargin) + remainingMargin).toUint128();
        exposure.fundedUsersRemainingCommitment =
            (uint256(exposure.fundedUsersRemainingCommitment) + remainingCommitment).toUint128();
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

            LCCTypesLib.Bucket storage bucket = exitBucketByMaturity[maturity];
            _decreaseBucket(bucket, slashedMargin, slashedCommitment);
            _pruneExitMaturityIfEmpty(maturity);
        }
    }

    function _addPending(Account memory account, uint256 margin, uint256 commitment, uint256 activationEpoch) internal {
        if (account.pendingActivationEpoch != 0 && account.pendingActivationEpoch != activationEpoch) {
            revert LCCErrorsLib.InvalidEpoch();
        }

        account.pendingMargin += margin;
        account.pendingCommitment += commitment;
        account.pendingActivationEpoch = activationEpoch;

        _increasePendingTotals(margin, commitment);
        LCCTypesLib.Bucket storage bucket = pendingBucketByActivationEpoch[activationEpoch];
        _increaseBucket(bucket, margin, commitment);
        if (activationEpoch > _syncState.lastFolded) _trackActivationEpoch(activationEpoch);
    }

    function _decreasePending(Account memory account, uint256 margin, uint256 commitment) internal {
        if (margin == 0 && commitment == 0) return;

        uint256 activationEpoch = account.pendingActivationEpoch;
        _decreasePendingTotals(margin, commitment);

        if (activationEpoch > _syncState.lastFolded) {
            LCCTypesLib.Bucket storage bucket = pendingBucketByActivationEpoch[activationEpoch];
            _decreaseBucket(bucket, margin, commitment);
            _pruneActivationEpochIfEmpty(activationEpoch);
        }
    }

    function _increaseBucket(LCCTypesLib.Bucket storage bucket, uint256 margin, uint256 commitment) internal {
        bucket.margin = (uint256(bucket.margin) + margin).toUint128();
        bucket.commitment = (uint256(bucket.commitment) + commitment).toUint128();
    }

    function _decreaseBucket(LCCTypesLib.Bucket storage bucket, uint256 margin, uint256 commitment) internal {
        bucket.margin = (uint256(bucket.margin) - margin).toUint128();
        bucket.commitment = (uint256(bucket.commitment) - commitment).toUint128();
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

    /// @dev Assignment is first-fit by request time, not strict FIFO. Capacity is recomputed from live active
    /// commitment for every request, ensuring it is never below the configured-cap value at that request while
    /// deliberately making later assignments path-dependent. It can decline as active commitment declines through
    /// amortization or slashing. Aggregate active commitment may conservatively include unattributed return
    /// commitment, which only widens capacity. Funded or slashed amounts can free bucket room retroactively, and a
    /// request larger than the whole per-epoch capacity takes the first bucket with any remaining room. Cap-raise
    /// sequences can still reach the 128-bucket limit.
    ///
    /// Termination invariant: the `Math.max(1, ...)` clamp below is load-bearing and must not be removed. Capacity of
    /// at least one makes any empty bucket terminate the scan; only nonzero-commitment buckets are skipped.
    /// `_trackExitMaturity` and `_pruneExitMaturityIfEmpty` keep those buckets in the 128-entry maturity list, so the
    /// scan takes at most 129 iterations.
    function _assignExitMaturity(uint256 accountCommitment, uint256 maxDeferralEpochs)
        internal
        view
        returns (uint256 maturityEpoch)
    {
        uint256 capacity = Math.max(
            1,
            Math.max(_riskConfig.protocolCommitmentCap, uint256(_totals.activeCommitment))
                .mulDiv(_riskConfig.exitCapBps, BPS)
        );

        maturityEpoch = _currentEpoch() + _assetConfig.exitDelayEpochs;
        while (true) {
            uint256 assigned = exitBucketByMaturity[maturityEpoch].commitment;
            if (assigned < capacity) {
                uint256 remaining = capacity - assigned;
                if (accountCommitment <= remaining || accountCommitment > capacity) return maturityEpoch;
            }
            if (maxDeferralEpochs == 0) revert LCCErrorsLib.ExitDeferralExceeded();
            unchecked {
                --maxDeferralEpochs;
                ++maturityEpoch;
            }
        }
    }

    /* EPOCH & PHASE MATH */

    function _depositActivation() internal view returns (uint256 activationEpoch, bool immediate) {
        uint256 epoch = _currentEpoch();
        immediate = _phaseAt(_now()) == Phase.Normal && !epochs[epoch].callOpened;
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
        return _now() >= _fundingDeadline(epoch);
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
        return Phase(LCCAuctionLib.phaseAt(timestamp, _packedClockConfig()));
    }

    function _currentEpoch() internal view returns (uint256) {
        LCCTypesLib.ClockConfig memory clock = _clockConfig;
        uint256 timestamp = _now();
        if (timestamp < clock.startTimestamp) return 0;
        return (timestamp - clock.startTimestamp) / clock.epochLength;
    }

    function _terminal() internal view returns (bool) {
        uint256 maxEpochs = _clockConfig.maxEpochs;
        return maxEpochs != 0 && _currentEpoch() >= maxEpochs;
    }

    /// @dev True once no call can ever open again: calls open only in a PreCall phase, so once the last callable
    /// epoch's PreCall window (`maxEpochs - 1`) has elapsed nothing can open a call. Perpetual vaults (`maxEpochs ==
    /// 0`) never close. Past this point a returned slash commitment can never back a future call, so surplus disposal
    /// drops the going-concern missing-snapshot revert and protocol-cap clamp. Monotonic and strictly before the
    /// terminal boundary, so this also covers every disposal that runs once terminal.
    function _callWindowClosed() internal view returns (bool) {
        uint256 maxEpochs = _clockConfig.maxEpochs;
        if (maxEpochs == 0) return false;
        uint256 current = _currentEpoch();
        // No call can open past the last callable epoch's PreCall window: either terminal, or in epoch
        // `maxEpochs - 1` with its PreCall phase already elapsed (calls open only during PreCall). Expressed via
        // the epoch clock, which is bounded by effective time, so an unbounded `maxEpochs` cannot overflow.
        return current >= maxEpochs || (current == maxEpochs - 1 && _phaseAt(_now()) >= Phase.Funding);
    }

    function _now() internal view returns (uint256) {
        LCCTypesLib.PauseState memory p = _pause;
        uint256 frozenAt = p.paused ? p.pausedAt : block.timestamp; // deliberate wall-clock read
        return frozenAt - p.pausedAccumulated;
    }

    function _phaseEnd(uint256 epoch, Phase phase) internal view returns (uint256) {
        return LCCAuctionLib.phaseEndsAt(epoch, uint8(phase), _packedClockConfig());
    }

    function _fundingDeadline(uint256 epoch) internal view returns (uint256) {
        return _phaseEnd(epoch, Phase.Funding);
    }

    function _packedClockConfig() internal view returns (uint256 packedClock) {
        assembly {
            packedClock := sload(_clockConfig.slot)
        }
    }
}
