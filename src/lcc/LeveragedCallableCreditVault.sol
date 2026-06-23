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
import {ORACLE_PRICE_SCALE} from "../libraries/ConstantsLib.sol";
import {LCCAuctionLib} from "./libraries/LCCAuctionLib.sol";
import {ILeveragedCallableCreditVault} from "./interfaces/ILeveragedCallableCreditVault.sol";

contract LeveragedCallableCreditVault is ILeveragedCallableCreditVault, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using SafeCast for uint256;

    error ZeroAddress();
    error InvalidParams();
    error ShutdownActive();
    error ExitInProgress();
    error CapExceeded();
    error InvalidPhase();
    error InvalidEpoch();
    error CallAlreadyOpened();
    error PriorCallUnsettled();
    error InvalidAmount();
    error OraclePriceInvalid();
    error AlreadyFunded();
    error NothingToClaim();
    error NoExitRequested();
    error ExitNotMature();
    error SlashNotEligible();
    error ShutdownRequired();
    error AuctionNotLive();

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_MATERIALIZE_STEPS = 64;

    struct AccountStorage {
        uint128 activeMargin;
        uint128 activeCommitment;
        uint128 pendingMargin;
        uint128 pendingCommitment;
        uint128 claimableExitMargin;
        uint128 exitBucketMargin;
        uint128 exitBucketCommitment;
        uint64 pendingActivationEpoch;
        uint64 calledEpochCursor;
        uint64 exitMaturityEpoch;
        bool exitRequested;
        bool exitClaimed;
        bool exitMatured;
    }

    struct ExitExposure {
        uint256 margin;
        uint256 commitment;
        uint256 fundedAmount;
        uint256 marginReleased;
        uint256 fundedUsersRemainingMargin;
        uint256 fundedUsersRemainingCommitment;
        bool listed;
    }

    struct DefaultRecord {
        uint256 epoch;
        uint256 slashedMargin;
        uint256 slashedCommitment;
    }

    struct AccountReplay {
        Account account;
        DefaultRecord[] defaults;
        uint256 defaultCount;
        bool complete;
    }

    /// @dev Must be a standard ERC20: fee-on-transfer and rebasing tokens break margin conservation. Deployments
    /// must also keep the maximum margin balance reachable under the commitment caps below type(uint128).max (a
    /// constraint on margin decimals, the oracle price floor, marginRatioBps, and protocolCommitmentCap) or
    /// deposits revert on the packed-storage cast.
    IERC20 public immutable marginAsset;
    IERC20 public immutable fundingAsset;
    IERC4626 public immutable usd3;
    IOracle public immutable marginOracle;
    address public immutable treasury;

    uint256 public immutable startTimestamp;
    uint256 public immutable epochLength;
    uint256 public immutable normalDuration;
    uint256 public immutable preCallDuration;
    uint256 public immutable fundingDuration;
    uint256 public immutable marginRatioBps;
    uint256 public immutable exitDelayEpochs;
    /// @dev The auction window (the Closed phase) is divided into auctionStepCount price steps; the protocol's
    /// retained share of the pool decays by auctionStepDecayRateBps each step, so the curve completes exactly over
    /// every auction window. auctionStepCount == 0 permanently disables the auction machinery.
    uint256 public immutable auctionStepCount;
    uint256 public immutable auctionStepDecayRateBps;
    /// @dev Derived: closed-window seconds / auctionStepCount.
    uint256 public immutable auctionStepDuration;

    uint256 public protocolCommitmentCap;
    uint256 public userCommitmentCap;
    /// @dev Per-epoch exit capacity is `protocolCommitmentCap * exitCapBps / BPS`. The protocol cap is used as the
    /// base (rather than live active commitment) so bucket assignment is deterministic and not path-dependent.
    uint256 public exitCapBps;
    uint256 public minDepositAssets;
    /// @dev Oracle-valued award cap per funding-asset amount filled in the auction; 0 is the runtime off-switch.
    uint256 public maxAuctionAwardBps;

    uint256 public totalActiveMargin;
    uint256 public totalActiveCommitment;
    uint256 public totalPendingMargin;
    uint256 public totalPendingCommitment;
    uint256 public totalEscrowedFundingAmount;

    uint256 public lastActivationFolded;
    uint256 public lastMaturityFolded;
    uint256 public finalizedCallPrefix;

    bool public shutdownActive;
    uint256 public shutdownTimestamp;
    uint256 public shutdownEpoch;

    /// @dev Single live-auction slot (epoch + 1; 0 = none). Safe because calls are sequential: an auction for epoch
    /// E exists only during E's Closed window, and a later kick happens inside _syncGlobal after _settleDueAuction
    /// has already swept E.
    uint256 public pendingAuctionEpochPlusOne;
    mapping(uint256 => LCCAuctionLib.AuctionState) internal epochAuctions;

    mapping(address => AccountStorage) internal accounts;
    mapping(uint256 => EpochState) internal epochs;
    uint256[] internal calledEpochList;

    mapping(uint256 => uint256) public pendingMarginByActivationEpoch;
    mapping(uint256 => uint256) public pendingCommitmentByActivationEpoch;
    uint256[] internal activationEpochList;
    mapping(uint256 => uint256) internal activationEpochIndexPlusOne;
    mapping(uint256 => uint256) public exitBucketMarginByMaturity;
    mapping(uint256 => uint256) public exitBucketCommitmentByMaturity;
    uint256[] internal exitMaturityList;
    mapping(uint256 => uint256) internal exitMaturityIndexPlusOne;

    mapping(uint256 => mapping(uint256 => ExitExposure)) internal exitExposureByCallAndMaturity;
    mapping(uint256 => uint256[]) internal exitMaturitiesByCall;

    mapping(uint256 => mapping(address => bool)) public fundedEpoch;
    mapping(uint256 => mapping(address => bool)) public defaultedEpoch;

    /// @notice Funding asset held by the vault for `user` because USD3 could not accept the deposit at funding time.
    mapping(address => uint256) public escrowedFundingAmount;

    constructor(VaultParams memory params) Ownable(params.owner) {
        _validateParams(params);

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

        protocolCommitmentCap = params.protocolCommitmentCap;
        userCommitmentCap = params.userCommitmentCap;
        exitCapBps = params.exitCapBps;
        minDepositAssets = params.minDepositAssets;
        maxAuctionAwardBps = params.maxAuctionAwardBps;

        uint256 epoch = _currentEpoch();
        lastActivationFolded = epoch;
        lastMaturityFolded = epoch;
    }

    modifier synced() {
        _syncGlobal();
        _;
    }

    function currentEpoch() external view returns (uint256) {
        return _currentEpoch();
    }

    function currentPhase() external view returns (Phase) {
        return _phaseAt(block.timestamp);
    }

    function phaseEndsAt(uint256 epoch, Phase phase) external view returns (uint256) {
        uint256 start = _epochStart(epoch);
        if (phase == Phase.Normal) return start + normalDuration;
        if (phase == Phase.PreCall) return start + normalDuration + preCallDuration;
        if (phase == Phase.Funding) return _fundingDeadline(epoch);
        return start + epochLength;
    }

    /// @notice Updates risk caps for future deposits and future exit bucket assignment.
    /// @dev Lowering caps below current utilization does not force existing positions or assigned exit buckets to
    /// unwind.
    function setRiskCaps(
        uint256 newProtocolCommitmentCap,
        uint256 newUserCommitmentCap,
        uint256 newExitCapBps,
        uint256 newMinDeposit
    ) external onlyOwner synced {
        if (newProtocolCommitmentCap == 0 || newProtocolCommitmentCap > type(uint128).max) {
            revert InvalidParams();
        }
        if (newUserCommitmentCap == 0 || newExitCapBps == 0 || newExitCapBps > BPS) revert InvalidParams();

        protocolCommitmentCap = newProtocolCommitmentCap;
        userCommitmentCap = newUserCommitmentCap;
        exitCapBps = newExitCapBps;
        minDepositAssets = newMinDeposit;

        emit RiskCapUpdated(newProtocolCommitmentCap, newUserCommitmentCap, newExitCapBps, newMinDeposit);
    }

    function setMaxAuctionAwardBps(uint256 newMaxAuctionAwardBps) external onlyOwner synced {
        if (newMaxAuctionAwardBps > BPS) revert InvalidParams();
        if (newMaxAuctionAwardBps != 0 && auctionStepCount == 0) revert InvalidParams();
        // No repricing while fillers are mid-auction.
        if (pendingAuctionEpochPlusOne != 0) revert InvalidPhase();

        maxAuctionAwardBps = newMaxAuctionAwardBps;

        emit AuctionAwardCapUpdated(newMaxAuctionAwardBps);
    }

    function shutdown() external onlyOwner synced {
        if (shutdownActive) revert ShutdownActive();
        shutdownActive = true;
        shutdownTimestamp = block.timestamp;
        shutdownEpoch = _currentEpoch();
        // Re-run after recording shutdown so in-flight calls can finalize with slash disabled.
        _syncGlobal();
        emit EmergencyShutdown(shutdownEpoch, shutdownTimestamp);
    }

    /// @dev The margin oracle is fully trusted to return a fresh marginAsset-to-fundingAsset price scaled by
    /// ORACLE_PRICE_SCALE, including any token decimal conversion.
    function deposit(uint256 assets, address receiver) external nonReentrant synced returns (uint256 commitment) {
        if (shutdownActive) revert ShutdownActive();
        if (receiver == address(0)) revert ZeroAddress();
        if (assets == 0 || assets < minDepositAssets) revert InvalidAmount();

        Account memory account = _replayForUpdate(receiver);
        if (account.exitRequested && !account.exitClaimed) revert ExitInProgress();

        uint256 price = marginOracle.price();
        if (price == 0) revert OraclePriceInvalid();

        uint256 marginValue = assets.mulDiv(price, ORACLE_PRICE_SCALE);
        commitment = marginValue.mulDiv(BPS, marginRatioBps);
        if (commitment == 0) revert InvalidAmount();

        if (totalActiveCommitment + totalPendingCommitment + commitment > protocolCommitmentCap) {
            revert CapExceeded();
        }
        if (account.activeCommitment + account.pendingCommitment + commitment > userCommitmentCap) {
            revert CapExceeded();
        }

        marginAsset.safeTransferFrom(msg.sender, address(this), assets);

        (uint256 activationEpoch, bool immediate) = _depositActivation();
        if (immediate) {
            account.activeMargin += assets;
            account.activeCommitment += commitment;
            totalActiveMargin += assets;
            totalActiveCommitment += commitment;
        } else {
            _addPending(account, assets, commitment, activationEpoch);
        }
        _storeAccount(receiver, account);

        emit DepositCheckpointed(receiver, assets, marginValue, commitment, activationEpoch, immediate);
    }

    function requestExit() external nonReentrant synced returns (uint256 maturityEpoch) {
        Account memory account = _replayForUpdate(msg.sender);
        if (account.exitRequested && !account.exitClaimed) revert ExitInProgress();
        if (account.pendingMargin != 0 || account.pendingCommitment != 0) revert PendingDepositExists();

        uint256 accountCommitment = account.activeCommitment;
        uint256 accountMargin = account.activeMargin;
        if (accountCommitment == 0 || accountMargin == 0) revert InvalidAmount();

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

        emit ExitRequested(msg.sender, maturityEpoch, accountMargin, accountCommitment);
    }

    function claimExitedMargin(address receiver) external nonReentrant synced returns (uint256 assets) {
        if (receiver == address(0)) revert ZeroAddress();

        Account memory account = _replayForUpdate(msg.sender);
        if (!account.exitRequested || account.exitClaimed) revert NoExitRequested();
        if (_currentEpoch() < account.exitMaturityEpoch) revert ExitNotMature();

        assets = account.claimableExitMargin;
        if (assets == 0) revert NothingToClaim();

        account.claimableExitMargin = 0;
        _clearExit(account);
        _storeAccount(msg.sender, account);

        marginAsset.safeTransfer(receiver, assets);

        emit ExitedMarginClaimed(msg.sender, receiver, assets);
    }

    function claimEmergencyMargin(address receiver) external nonReentrant synced returns (uint256 assets) {
        if (!shutdownActive) revert ShutdownRequired();
        if (receiver == address(0)) revert ZeroAddress();

        Account memory account = _replayForUpdate(msg.sender);

        assets = account.activeMargin + account.pendingMargin;
        if (assets == 0) revert NothingToClaim();

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
        _clearExit(account);
        _storeAccount(msg.sender, account);

        marginAsset.safeTransfer(receiver, assets);

        emit EmergencyMarginClaimed(msg.sender, receiver, assets);
    }

    function openEpochCall(uint256 epoch, uint256 callAmount) external onlyOwner synced {
        if (shutdownActive) revert ShutdownActive();
        if (epoch != _currentEpoch()) revert InvalidEpoch();
        if (_phaseAt(block.timestamp) != Phase.PreCall) revert InvalidPhase();
        if (callAmount == 0) revert InvalidAmount();

        _requireNoPriorUnsettledCall(epoch);

        EpochState storage state = epochs[epoch];
        if (state.callOpened) revert CallAlreadyOpened();
        if (callAmount > totalActiveCommitment) revert InvalidAmount();

        state.callOpened = true;
        state.commitmentDenominator = totalActiveCommitment;
        state.callAmount = callAmount;
        state.marginAtCallOpen = totalActiveMargin;
        calledEpochList.push(epoch);
        _snapshotExitBucketsForCall(epoch);

        emit EpochCallOpened(epoch, callAmount, totalActiveCommitment);
    }

    function fundEpochCall(uint256 epoch) external nonReentrant synced returns (uint256 obligationAmount) {
        return _fund(epoch, msg.sender, msg.sender);
    }

    /// @notice Funds `user`'s current-epoch obligation with funding asset supplied by the caller.
    /// @dev Push-based third-party funding: the caller pays; released margin, the USD3 position (or escrow credit),
    /// and funded status always accrue to `user`. Escrow credit is never refundable to the payer.
    function fundEpochCallFor(uint256 epoch, address user)
        external
        nonReentrant
        synced
        returns (uint256 obligationAmount)
    {
        if (user == address(0)) revert ZeroAddress();
        return _fund(epoch, msg.sender, user);
    }

    /// @notice Fills up to `maxFillAmount` of the live auction's shortfall: the fill is deposited into USD3 for the
    /// caller, and a collateral kicker from the slashed margin pool is awarded at the current ramp, capped by
    /// `maxAuctionAwardBps` of the fill at the fill-time oracle price.
    /// @dev No escrow fallback for fillers — they are volunteers, not obligated funders: if USD3 cannot accept the
    /// deposit (capacity, depositor whitelist, first-time minimum) the take reverts. Fills require the vault to be
    /// on USD3's depositorWhitelist while commitment enforcement is active.
    function takeAuction(uint256 epoch, uint256 maxFillAmount)
        external
        nonReentrant
        synced
        returns (uint256 filledAmount, uint256 marginAward)
    {
        if (shutdownActive) revert ShutdownActive();
        // synced settled any past-window auction, so a live slot implies the window is open.
        if (pendingAuctionEpochPlusOne != epoch + 1) revert AuctionNotLive();

        LCCAuctionLib.AuctionState storage state = epochAuctions[epoch];
        uint256 remainingShortfallAmount = state.shortfallAmount - state.filledAmount;
        filledAmount = maxFillAmount < remainingShortfallAmount ? maxFillAmount : remainingShortfallAmount;
        if (filledAmount == 0) revert InvalidAmount();

        uint256 price = marginOracle.price();
        if (price == 0) revert OraclePriceInvalid();

        marginAward = LCCAuctionLib.computeAward(
            state,
            filledAmount,
            block.timestamp - _fundingDeadline(epoch),
            auctionStepDuration,
            auctionStepDecayRateBps,
            maxAuctionAwardBps,
            price
        );

        state.filledAmount += filledAmount.toUint128();
        state.marginAwarded += marginAward;

        fundingAsset.safeTransferFrom(msg.sender, address(this), filledAmount);
        _depositToUsd3(msg.sender, filledAmount);
        if (marginAward != 0) marginAsset.safeTransfer(msg.sender, marginAward);

        emit AuctionFill(msg.sender, epoch, filledAmount, marginAward);

        if (state.filledAmount == state.shortfallAmount) _settleAuction(epoch);
    }

    /// @notice Deposits escrowed funding asset into USD3 for `user`, up to USD3's current deposit capacity.
    function depositEscrowedFunding(address user) external nonReentrant synced returns (uint256 placedAmount) {
        if (user == address(0)) revert ZeroAddress();

        uint256 escrowAmount = escrowedFundingAmount[user];
        if (escrowAmount == 0) revert NothingToClaim();

        placedAmount = escrowAmount.min(usd3.maxDeposit(user));
        if (placedAmount == 0) revert InvalidAmount();

        _removeEscrow(user, placedAmount);
        _depositToUsd3(user, placedAmount);

        emit EscrowedFundingPlaced(user, placedAmount);
    }

    /// @notice Returns escrowed funding asset to the funder after terminal shutdown, when USD3 placement can no
    /// longer be forced.
    function claimEscrowedFunding(address receiver) external nonReentrant synced returns (uint256 assets) {
        if (!shutdownActive) revert ShutdownRequired();
        if (receiver == address(0)) revert ZeroAddress();

        assets = escrowedFundingAmount[msg.sender];
        if (assets == 0) revert NothingToClaim();

        _removeEscrow(msg.sender, assets);

        fundingAsset.safeTransfer(receiver, assets);

        emit EscrowedFundingClaimed(msg.sender, receiver, assets);
    }

    function finalizeEpochSlash(uint256 epoch) external nonReentrant synced {
        if (!epochs[epoch].slashFinalized) {
            if (!_slashEligible(epoch)) revert SlashNotEligible();
            _finalizeEpochSlash(epoch);
        }
    }

    function materializeAccount(address user) external nonReentrant synced {
        if (user == address(0)) revert ZeroAddress();
        // Accounts with live historical exposure may need repeated calls; empty accounts fast-forward.
        Account memory account = _loadAccount(user);
        bytes32 beforeHash = keccak256(abi.encode(account));
        AccountReplay memory replay = _replayAndRecordDefaults(user, account);
        if (keccak256(abi.encode(replay.account)) != beforeHash) _storeAccount(user, replay.account);
    }

    function getAccount(address user) external view returns (Account memory) {
        return _previewAccount(user);
    }

    function getEpochState(uint256 epoch) external view returns (EpochState memory) {
        return epochs[epoch];
    }

    function getAuctionState(uint256 epoch) external view returns (LCCAuctionLib.AuctionState memory) {
        return epochAuctions[epoch];
    }

    function obligationOf(uint256 epoch, address user) external view returns (uint256) {
        EpochState storage state = epochs[epoch];
        if (!state.callOpened || state.slashFinalized || fundedEpoch[epoch][user]) return 0;
        Account memory account = _previewAccount(user);
        return _obligation(state, account.activeCommitment);
    }

    function claimableExitedMargin(address user) external view returns (uint256) {
        Account memory account = _previewAccount(user);
        if (!account.exitRequested || account.exitClaimed || _currentEpoch() < account.exitMaturityEpoch) return 0;
        return account.claimableExitMargin;
    }

    function calledEpochs() external view returns (uint256[] memory) {
        return calledEpochList;
    }

    function _fund(uint256 epoch, address payer, address user) internal returns (uint256 obligationAmount) {
        if (epoch != _currentEpoch()) revert InvalidEpoch();
        if (_phaseAt(block.timestamp) != Phase.Funding) revert InvalidPhase();

        EpochState storage state = epochs[epoch];
        if (!state.callOpened || state.slashFinalized) revert InvalidEpoch();
        if (fundedEpoch[epoch][user]) revert AlreadyFunded();

        Account memory account = _replayForUpdate(user);
        uint256 activeMargin = account.activeMargin;
        uint256 activeCommitment = account.activeCommitment;
        obligationAmount = _obligation(state, activeCommitment);
        if (obligationAmount == 0) revert InvalidAmount();

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

        emit CallFunded(user, epoch, obligationAmount);
        emit MarginReleased(user, epoch, releasedMargin);
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
        emit EscrowedFundingCreated(user, epoch, fundingAmount);
    }

    function _depositToUsd3(address receiver, uint256 fundingAmount) internal {
        fundingAsset.forceApprove(address(usd3), fundingAmount);
        usd3.deposit(fundingAmount, receiver);
    }

    function _addEscrow(address user, uint256 fundingAmount) internal {
        escrowedFundingAmount[user] += fundingAmount;
        totalEscrowedFundingAmount += fundingAmount;
    }

    function _removeEscrow(address user, uint256 fundingAmount) internal {
        escrowedFundingAmount[user] -= fundingAmount;
        totalEscrowedFundingAmount -= fundingAmount;
    }

    function _syncGlobal() internal {
        _settleDueAuction();

        while (finalizedCallPrefix < calledEpochList.length) {
            uint256 epoch = calledEpochList[finalizedCallPrefix];
            if (!epochs[epoch].slashFinalized) {
                if (!_slashEligible(epoch)) break;
                _finalizeEpochSlash(epoch);
            }
            if (epochs[epoch].slashFinalized) {
                unchecked {
                    ++finalizedCallPrefix;
                }
            }
        }

        uint256 current = _currentEpoch();
        _foldDueActivations(current);
        lastActivationFolded = current;

        // Slash finalization must run before maturity folds so defaulted exiter exposure is carved out of exit buckets
        // before those buckets decrement global active totals.
        _foldDueMaturities(current);
        lastMaturityFolded = current;
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
        totalPendingMargin -= margin;
        totalPendingCommitment -= commitment;
        totalActiveMargin += margin;
        totalActiveCommitment += commitment;

        emit PendingActivated(epoch, margin, commitment);
    }

    function _foldMaturity(uint256 epoch) internal {
        uint256 margin = exitBucketMarginByMaturity[epoch];
        uint256 commitment = exitBucketCommitmentByMaturity[epoch];
        if (margin == 0 && commitment == 0) return;

        exitBucketMarginByMaturity[epoch] = 0;
        exitBucketCommitmentByMaturity[epoch] = 0;
        _pruneExitMaturityIfEmpty(epoch);
        _decreaseGlobalActive(margin, commitment);

        emit ExitMatured(epoch, margin, commitment);
    }

    function _finalizeEpochSlash(uint256 epoch) internal {
        EpochState storage state = epochs[epoch];
        if (!state.callOpened || state.slashFinalized) return;

        bool disabled = shutdownActive && shutdownTimestamp <= _fundingDeadline(epoch);
        state.slashFinalized = true;
        state.slashDisabledByShutdown = disabled;

        if (disabled) {
            emit EpochSlashFinalized(epoch, 0, 0, true);
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
                shortfallAmount != 0 && maxAuctionAwardBps != 0 && !shutdownActive
                    && block.timestamp < _epochStart(epoch) + epochLength
            ) {
                epochAuctions[epoch] = LCCAuctionLib.AuctionState({
                    shortfallAmount: shortfallAmount.toUint128(),
                    filledAmount: 0,
                    marginPool: slashedMargin,
                    marginAwarded: 0
                });
                pendingAuctionEpochPlusOne = epoch + 1;
                emit AuctionKicked(epoch, shortfallAmount, slashedMargin);
            } else {
                marginAsset.safeTransfer(treasury, slashedMargin);
            }
        }

        emit EpochSlashFinalized(epoch, slashedMargin, slashedCommitment, false);
    }

    /// @dev Sweeps the live auction once its window has passed (or once shutdown blocks takes). Runs before slash
    /// finalization in _syncGlobal so a prior epoch's auction always settles before a new one can be kicked.
    /// Settlement touches no active totals or exit buckets, so the slash-before-maturity-folds ordering below is
    /// unaffected.
    function _settleDueAuction() internal {
        uint256 slot = pendingAuctionEpochPlusOne;
        if (slot == 0) return;

        uint256 epoch = slot - 1;
        if (!shutdownActive && block.timestamp < _epochStart(epoch) + epochLength) return;
        _settleAuction(epoch);
    }

    function _settleAuction(uint256 epoch) internal {
        LCCAuctionLib.AuctionState storage state = epochAuctions[epoch];
        pendingAuctionEpochPlusOne = 0;

        uint256 remainder = state.marginPool - state.marginAwarded;
        if (remainder != 0) marginAsset.safeTransfer(treasury, remainder);

        emit AuctionSettled(epoch, state.filledAmount, state.marginAwarded, remainder);
    }

    function _replayForUpdate(address user) internal returns (Account memory account) {
        AccountReplay memory replay = _replayAndRecordDefaults(user, _loadAccount(user));
        if (!replay.complete) revert AccountMaterializationIncomplete();
        // Callers mutate the returned account and are responsible for the single _storeAccount write.
        return replay.account;
    }

    function _replayAndRecordDefaults(address user, Account memory account)
        internal
        returns (AccountReplay memory replay)
    {
        replay = _replayAccount(account, user, MAX_MATERIALIZE_STEPS);
        _recordDefaults(user, replay);
    }

    function _recordDefaults(address user, AccountReplay memory replay) internal {
        for (uint256 i = 0; i < replay.defaultCount; ++i) {
            DefaultRecord memory record = replay.defaults[i];
            defaultedEpoch[record.epoch][user] = true;
            emit UserDefaulted(user, record.epoch, record.slashedMargin, record.slashedCommitment);
        }
    }

    function _loadAccount(address user) internal view returns (Account memory account) {
        AccountStorage storage stored = accounts[user];
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
        accounts[user] = AccountStorage({
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
        returns (AccountReplay memory replay)
    {
        bool bounded = maxSteps != 0;
        replay.account = account;

        if (_isZeroExposure(replay.account)) {
            replay.account.calledEpochCursor = finalizedCallPrefix;
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

            _activatePendingForEpoch(replay.account, epoch);
            _matureExitForEpoch(replay.account, epoch);

            if (_shouldDefault(replay.account, state, epoch, user)) {
                if (bounded) {
                    if (replay.defaults.length == 0) replay.defaults = new DefaultRecord[](maxSteps);
                    replay.defaults[replay.defaultCount] =
                        DefaultRecord(epoch, replay.account.activeMargin, replay.account.activeCommitment);
                    unchecked {
                        ++replay.defaultCount;
                    }
                }
                _defaultAccount(replay.account);
            }

            unchecked {
                ++cursor;
                ++steps;
            }

            if (_isZeroExposure(replay.account)) {
                cursor = finalizedCallPrefix;
                break;
            }
        }

        replay.account.calledEpochCursor = cursor;
        replay.complete = cursor >= finalizedCallPrefix;
        if (!replay.complete) return replay;

        uint256 activationFolded = _effectiveLastActivationFolded();
        uint256 maturityFolded = _effectiveLastMaturityFolded();
        if (stoppedAtUnfinalized && _slashEligible(unfinalizedEpoch)) {
            if (activationFolded > unfinalizedEpoch) activationFolded = unfinalizedEpoch;
            if (maturityFolded > unfinalizedEpoch) maturityFolded = unfinalizedEpoch;
        }

        _activatePendingForEpoch(replay.account, activationFolded);
        _matureExitForEpoch(replay.account, maturityFolded);
    }

    function _activatePendingForEpoch(Account memory account, uint256 epoch) internal pure {
        if (account.pendingActivationEpoch != 0 && account.pendingActivationEpoch <= epoch) _activatePending(account);
    }

    function _activatePending(Account memory account) internal pure {
        account.activeMargin += account.pendingMargin;
        account.activeCommitment += account.pendingCommitment;
        account.pendingMargin = 0;
        account.pendingCommitment = 0;
        account.pendingActivationEpoch = 0;
    }

    function _matureExitForEpoch(Account memory account, uint256 epoch) internal pure {
        if (account.exitRequested && !account.exitMatured && !account.exitClaimed && account.exitMaturityEpoch <= epoch)
        {
            _matureExit(account);
        }
    }

    function _matureExit(Account memory account) internal pure {
        account.claimableExitMargin += account.activeMargin;
        account.activeMargin = 0;
        account.activeCommitment = 0;
        account.exitBucketMargin = 0;
        account.exitBucketCommitment = 0;
        account.exitMatured = true;
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

    function _defaultAccount(Account memory account) internal pure {
        account.activeMargin = 0;
        account.activeCommitment = 0;
        account.exitBucketMargin = 0;
        account.exitBucketCommitment = 0;
        account.claimableExitMargin = 0;
        if (account.exitRequested && !account.exitClaimed) _clearExit(account);
    }

    function _isZeroExposure(Account memory account) internal pure returns (bool) {
        return account.activeMargin == 0 && account.activeCommitment == 0 && account.pendingMargin == 0
            && account.pendingCommitment == 0 && account.claimableExitMargin == 0
            && (!account.exitRequested || account.exitClaimed);
    }

    function _clearExit(Account memory account) internal pure {
        account.exitRequested = false;
        account.exitMaturityEpoch = 0;
        account.exitClaimed = true;
        account.exitMatured = false;
        account.exitBucketMargin = 0;
        account.exitBucketCommitment = 0;
    }

    function _trackExitMaturity(uint256 maturityEpoch) internal {
        if (exitMaturityIndexPlusOne[maturityEpoch] != 0) return;
        exitMaturityIndexPlusOne[maturityEpoch] = exitMaturityList.length + 1;
        exitMaturityList.push(maturityEpoch);
    }

    function _trackActivationEpoch(uint256 activationEpoch) internal {
        if (activationEpochIndexPlusOne[activationEpoch] != 0) return;
        activationEpochIndexPlusOne[activationEpoch] = activationEpochList.length + 1;
        activationEpochList.push(activationEpoch);
    }

    function _pruneActivationEpochIfEmpty(uint256 activationEpoch) internal {
        if (
            activationEpochIndexPlusOne[activationEpoch] == 0 || pendingMarginByActivationEpoch[activationEpoch] != 0
                || pendingCommitmentByActivationEpoch[activationEpoch] != 0
        ) {
            return;
        }

        uint256 index = activationEpochIndexPlusOne[activationEpoch] - 1;
        uint256 lastIndex = activationEpochList.length - 1;
        if (index != lastIndex) {
            uint256 moved = activationEpochList[lastIndex];
            activationEpochList[index] = moved;
            activationEpochIndexPlusOne[moved] = index + 1;
        }
        activationEpochList.pop();
        activationEpochIndexPlusOne[activationEpoch] = 0;
    }

    function _pruneExitMaturityIfEmpty(uint256 maturityEpoch) internal {
        if (
            exitMaturityIndexPlusOne[maturityEpoch] == 0 || exitBucketMarginByMaturity[maturityEpoch] != 0
                || exitBucketCommitmentByMaturity[maturityEpoch] != 0
        ) {
            return;
        }

        uint256 index = exitMaturityIndexPlusOne[maturityEpoch] - 1;
        uint256 lastIndex = exitMaturityList.length - 1;
        if (index != lastIndex) {
            uint256 moved = exitMaturityList[lastIndex];
            exitMaturityList[index] = moved;
            exitMaturityIndexPlusOne[moved] = index + 1;
        }
        exitMaturityList.pop();
        exitMaturityIndexPlusOne[maturityEpoch] = 0;
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
        ExitExposure storage exposure = exitExposureByCallAndMaturity[epoch][maturity];
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

        ExitExposure storage exposure = exitExposureByCallAndMaturity[epoch][maturity];
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
            ExitExposure storage exposure = exitExposureByCallAndMaturity[epoch][maturity];

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
        return current > lastActivationFolded ? current : lastActivationFolded;
    }

    function _effectiveLastMaturityFolded() internal view returns (uint256) {
        uint256 current = _currentEpoch();
        return current > lastMaturityFolded ? current : lastMaturityFolded;
    }

    function _addPending(Account memory account, uint256 margin, uint256 commitment, uint256 activationEpoch) internal {
        if (account.pendingActivationEpoch != 0 && account.pendingActivationEpoch != activationEpoch) {
            revert InvalidEpoch();
        }

        account.pendingMargin += margin;
        account.pendingCommitment += commitment;
        account.pendingActivationEpoch = activationEpoch;

        totalPendingMargin += margin;
        totalPendingCommitment += commitment;
        pendingMarginByActivationEpoch[activationEpoch] += margin;
        pendingCommitmentByActivationEpoch[activationEpoch] += commitment;
        if (activationEpoch > lastActivationFolded) _trackActivationEpoch(activationEpoch);
    }

    function _decreasePending(Account memory account, uint256 margin, uint256 commitment) internal {
        if (margin == 0 && commitment == 0) return;

        uint256 activationEpoch = account.pendingActivationEpoch;
        totalPendingMargin -= margin;
        totalPendingCommitment -= commitment;

        if (activationEpoch > lastActivationFolded) {
            pendingMarginByActivationEpoch[activationEpoch] -= margin;
            pendingCommitmentByActivationEpoch[activationEpoch] -= commitment;
            _pruneActivationEpochIfEmpty(activationEpoch);
        }
    }

    function _decreaseGlobalActive(uint256 margin, uint256 commitment) internal {
        if (margin != 0) totalActiveMargin -= margin;
        if (commitment != 0) totalActiveCommitment -= commitment;
    }

    /// @dev Assignment is first-fit by request time, not strict FIFO: funded or slashed amounts can free bucket
    /// capacity retroactively, and a request larger than the whole per-epoch capacity takes the first bucket with any
    /// remaining room.
    function _assignExitMaturity(uint256 accountCommitment) internal view returns (uint256 maturityEpoch) {
        uint256 capacity = protocolCommitmentCap.mulDiv(exitCapBps, BPS);
        if (capacity == 0) revert InvalidParams();

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

    function _depositActivation() internal view returns (uint256 activationEpoch, bool immediate) {
        uint256 epoch = _currentEpoch();
        immediate = _phaseAt(block.timestamp) == Phase.Normal && !epochs[epoch].callOpened;
        activationEpoch = immediate ? epoch : epoch + 1;
    }

    function _requireNoPriorUnsettledCall(uint256 epoch) internal view {
        if (finalizedCallPrefix < calledEpochList.length && calledEpochList[finalizedCallPrefix] < epoch) {
            revert PriorCallUnsettled();
        }
    }

    function _slashEligible(uint256 epoch) internal view returns (bool) {
        EpochState storage state = epochs[epoch];
        if (!state.callOpened || state.slashFinalized) return false;
        if (shutdownActive && shutdownTimestamp <= _fundingDeadline(epoch)) return true;
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

    function _validateParams(VaultParams memory params) internal view {
        if (
            params.owner == address(0) || params.marginAsset == address(0) || params.fundingAsset == address(0)
                || params.usd3 == address(0) || params.marginOracle == address(0) || params.treasury == address(0)
        ) revert ZeroAddress();
        if (params.fundingAsset != IERC4626(params.usd3).asset()) revert InvalidParams();
        if (params.marginRatioBps == 0 || params.marginRatioBps > BPS) revert InvalidParams();
        if (params.epochLength == 0 || params.normalDuration == 0 || params.preCallDuration == 0) {
            revert InvalidParams();
        }
        if (
            params.fundingDuration == 0
                || params.normalDuration + params.preCallDuration + params.fundingDuration > params.epochLength
        ) {
            revert InvalidParams();
        }
        if (params.protocolCommitmentCap == 0 || params.userCommitmentCap == 0) revert InvalidParams();
        // Commitment totals are bounded by the (historical) protocol cap; capping it at uint128 keeps the auction
        // kick's casts from ever reverting inside _syncGlobal.
        if (params.protocolCommitmentCap > type(uint128).max) revert InvalidParams();
        if (params.exitCapBps == 0 || params.exitCapBps > BPS) revert InvalidParams();
        if (params.exitDelayEpochs == 0) revert InvalidParams();

        if (params.auctionStepCount == 0) {
            if (params.auctionStepDecayRateBps != 0 || params.maxAuctionAwardBps != 0) revert InvalidParams();
        } else {
            if (params.auctionStepDecayRateBps == 0 || params.auctionStepDecayRateBps > BPS) revert InvalidParams();
            if (params.maxAuctionAwardBps > BPS) revert InvalidParams();
            // The auction needs a nonzero Closed window, and at least one second per step so the full curve fits
            // inside every auction window.
            uint256 phaseDurations = params.normalDuration + params.preCallDuration + params.fundingDuration;
            if (phaseDurations >= params.epochLength) revert InvalidParams();
            if (params.auctionStepCount > params.epochLength - phaseDurations) revert InvalidParams();
        }
    }
}
