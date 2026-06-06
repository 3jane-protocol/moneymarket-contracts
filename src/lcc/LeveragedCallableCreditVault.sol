// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Ownable} from "../../lib/openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "../../lib/openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "../../lib/openzeppelin/contracts/utils/math/Math.sol";

import {IOracle} from "../interfaces/IOracle.sol";
import {ORACLE_PRICE_SCALE} from "../libraries/ConstantsLib.sol";
import {ILeveragedCallableCreditVault} from "./interfaces/ILeveragedCallableCreditVault.sol";

contract LeveragedCallableCreditVault is ILeveragedCallableCreditVault, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

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

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_MATERIALIZE_STEPS = 64;

    struct ExitExposure {
        uint256 margin;
        uint256 callable;
        uint256 fundedUsdc;
        uint256 rawMarginReleased;
        uint256 honoredRawMarginRemaining;
        uint256 honoredCallableRemaining;
        bool listed;
    }

    struct AccountReplay {
        Account account;
        uint256[] defaultedEpochs;
        uint256 defaultCount;
        bool complete;
    }

    IERC20 public immutable marginAsset;
    IERC20 public immutable callableAsset;
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

    uint256 public protocolCallableCapUsdc;
    uint256 public userCallableCapUsdc;
    uint256 public exitCapBps;

    uint256 public totalActiveMargin;
    uint256 public totalActiveCallableUsdc;
    uint256 public totalPendingMargin;
    uint256 public totalPendingCallableUsdc;

    uint256 public lastActivationFolded;
    uint256 public lastMaturityFolded;
    uint256 public finalizedCallPrefix;

    bool public shutdownActive;
    uint256 public shutdownTimestamp;
    uint256 public shutdownEpoch;

    mapping(address => Account) internal accounts;
    mapping(uint256 => EpochState) internal epochs;
    uint256[] internal calledEpochList;

    mapping(uint256 => uint256) public pendingMarginByActivationEpoch;
    mapping(uint256 => uint256) public pendingCallableByActivationEpoch;
    mapping(uint256 => uint256) public exitRequestedMarginByMaturity;
    mapping(uint256 => uint256) public exitRequestedCallableByMaturity;
    uint256[] internal exitMaturityList;
    mapping(uint256 => uint256) internal exitMaturityIndexPlusOne;

    mapping(uint256 => mapping(uint256 => ExitExposure)) internal exitExposureByCallAndMaturity;
    mapping(uint256 => uint256[]) internal exitMaturitiesByCall;

    mapping(uint256 => mapping(address => bool)) public fundedEpoch;
    mapping(uint256 => mapping(address => bool)) public defaultedEpoch;

    constructor(VaultParams memory params) Ownable(params.owner) {
        _validateParams(params);

        marginAsset = IERC20(params.marginAsset);
        callableAsset = IERC20(params.callableAsset);
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

        protocolCallableCapUsdc = params.protocolCallableCapUsdc;
        userCallableCapUsdc = params.userCallableCapUsdc;
        exitCapBps = params.exitCapBps;

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

    function setRiskCaps(uint256 newProtocolCap, uint256 newUserCap, uint256 newExitCapBps) external onlyOwner synced {
        if (newProtocolCap == 0 || newUserCap == 0 || newExitCapBps == 0 || newExitCapBps > BPS) {
            revert InvalidParams();
        }

        protocolCallableCapUsdc = newProtocolCap;
        userCallableCapUsdc = newUserCap;
        exitCapBps = newExitCapBps;

        emit RiskCapUpdated(newProtocolCap, newUserCap, newExitCapBps);
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

    function deposit(uint256 assets, address receiver) external nonReentrant synced returns (uint256 callableUsdc) {
        if (shutdownActive) revert ShutdownActive();
        if (receiver == address(0)) revert ZeroAddress();
        if (assets == 0) revert InvalidAmount();

        _materializeAccount(receiver);
        Account storage account = accounts[receiver];
        if (account.exitRequested && !account.exitClaimed) revert ExitInProgress();

        uint256 price = marginOracle.price();
        if (price == 0) revert OraclePriceInvalid();

        uint256 marginValueUsdc = assets.mulDiv(price, ORACLE_PRICE_SCALE);
        callableUsdc = marginValueUsdc.mulDiv(BPS, marginRatioBps);
        if (callableUsdc == 0) revert InvalidAmount();

        if (totalActiveCallableUsdc + totalPendingCallableUsdc + callableUsdc > protocolCallableCapUsdc) {
            revert CapExceeded();
        }
        if (account.activeCallableUsdc + account.pendingCallableUsdc + callableUsdc > userCallableCapUsdc) {
            revert CapExceeded();
        }

        marginAsset.safeTransferFrom(msg.sender, address(this), assets);

        (uint256 activationEpoch, bool immediate) = _depositActivation();
        if (immediate) {
            account.activeMargin += assets;
            account.activeCallableUsdc += callableUsdc;
            totalActiveMargin += assets;
            totalActiveCallableUsdc += callableUsdc;
        } else {
            _addPending(account, assets, callableUsdc, activationEpoch);
        }

        emit DepositCheckpointed(receiver, assets, callableUsdc, activationEpoch, immediate);
    }

    function requestExit() external nonReentrant synced returns (uint256 maturityEpoch) {
        _materializeAccount(msg.sender);
        Account storage account = accounts[msg.sender];
        if (account.exitRequested && !account.exitClaimed) revert ExitInProgress();
        if (account.pendingMargin != 0 || account.pendingCallableUsdc != 0) revert PendingDepositExists();

        uint256 accountCallable = account.activeCallableUsdc;
        uint256 accountMargin = account.activeMargin;
        if (accountCallable == 0 || accountMargin == 0) revert InvalidAmount();

        maturityEpoch = _assignExitMaturity(accountCallable);
        account.exitRequested = true;
        account.exitMaturityEpoch = maturityEpoch;
        account.exitClaimed = false;
        account.exitMatured = false;
        account.claimableExitMargin = 0;
        account.exitBucketMargin = accountMargin;
        account.exitBucketCallable = accountCallable;

        exitRequestedMarginByMaturity[maturityEpoch] += accountMargin;
        exitRequestedCallableByMaturity[maturityEpoch] += accountCallable;
        _trackExitMaturity(maturityEpoch);
        _addCurrentCallExitExposure(account, maturityEpoch);

        emit ExitRequested(msg.sender, maturityEpoch, accountCallable);
    }

    function claimExitedMargin(address receiver) external nonReentrant synced returns (uint256 assets) {
        if (receiver == address(0)) revert ZeroAddress();

        _materializeAccount(msg.sender);
        Account storage account = accounts[msg.sender];
        if (!account.exitRequested || account.exitClaimed) revert NoExitRequested();
        if (_currentEpoch() < account.exitMaturityEpoch) revert ExitNotMature();

        assets = account.claimableExitMargin;
        if (assets == 0) revert NothingToClaim();

        account.claimableExitMargin = 0;
        _clearExit(account);

        marginAsset.safeTransfer(receiver, assets);

        emit ExitedMarginClaimed(msg.sender, receiver, assets);
    }

    function claimEmergencyMargin(address receiver) external nonReentrant synced returns (uint256 assets) {
        if (!shutdownActive) revert ShutdownRequired();
        if (receiver == address(0)) revert ZeroAddress();

        _materializeAccount(msg.sender);
        Account storage account = accounts[msg.sender];

        assets = account.activeMargin + account.pendingMargin;
        if (assets == 0) revert NothingToClaim();

        uint256 maturity = account.exitMaturityEpoch;
        if (account.exitRequested && !account.exitClaimed && !account.exitMatured) {
            exitRequestedMarginByMaturity[maturity] -= account.exitBucketMargin;
            exitRequestedCallableByMaturity[maturity] -= account.exitBucketCallable;
            _pruneExitMaturityIfEmpty(maturity);
        }

        _decreaseGlobalActive(account.activeMargin, account.activeCallableUsdc);
        _decreasePending(account, account.pendingMargin, account.pendingCallableUsdc);

        account.activeMargin = 0;
        account.activeCallableUsdc = 0;
        account.pendingMargin = 0;
        account.pendingCallableUsdc = 0;
        account.pendingActivationEpoch = 0;
        _clearExit(account);

        marginAsset.safeTransfer(receiver, assets);

        emit EmergencyMarginClaimed(msg.sender, receiver, assets);
    }

    function openEpochCall(uint256 epoch, uint256 totalCallAmountUsdc) external onlyOwner synced {
        if (shutdownActive) revert ShutdownActive();
        if (epoch != _currentEpoch()) revert InvalidEpoch();
        if (_phaseAt(block.timestamp) != Phase.PreCall) revert InvalidPhase();
        if (totalCallAmountUsdc == 0) revert InvalidAmount();

        _requireNoPriorUnsettledCall(epoch);

        EpochState storage state = epochs[epoch];
        if (state.callOpened) revert CallAlreadyOpened();
        if (totalCallAmountUsdc > totalActiveCallableUsdc) revert InvalidAmount();

        state.callOpened = true;
        state.callableDenominator = totalActiveCallableUsdc;
        state.callAmount = totalCallAmountUsdc;
        state.rawMarginAtCallOpen = totalActiveMargin;
        calledEpochList.push(epoch);
        _snapshotExitBucketsForCall(epoch);

        emit EpochCallOpened(epoch, totalCallAmountUsdc, totalActiveCallableUsdc);
    }

    function fundEpochCall(uint256 epoch) external nonReentrant synced returns (uint256 obligationUsdc) {
        if (epoch != _currentEpoch()) revert InvalidEpoch();
        if (_phaseAt(block.timestamp) != Phase.Funding) revert InvalidPhase();

        _materializeAccount(msg.sender);
        Account storage account = accounts[msg.sender];
        EpochState storage state = epochs[epoch];
        if (!state.callOpened || state.slashFinalized) revert InvalidEpoch();
        if (fundedEpoch[epoch][msg.sender]) revert AlreadyFunded();

        obligationUsdc = _obligation(state, account.activeCallableUsdc);
        if (obligationUsdc == 0) revert InvalidAmount();

        uint256 releasedMargin = account.activeMargin.mulDiv(obligationUsdc, account.activeCallableUsdc);
        uint256 remainingMargin = account.activeMargin - releasedMargin;
        uint256 remainingCallable = account.activeCallableUsdc - obligationUsdc;

        _recordExitingFund(epoch, account, obligationUsdc, releasedMargin, remainingMargin, remainingCallable);

        account.activeMargin = remainingMargin;
        account.activeCallableUsdc = remainingCallable;
        fundedEpoch[epoch][msg.sender] = true;

        state.fundedUsdc += obligationUsdc;
        state.rawMarginReleased += releasedMargin;
        state.honoredRawMarginRemaining += remainingMargin;
        state.honoredCallableRemaining += remainingCallable;

        _decreaseGlobalActive(releasedMargin, obligationUsdc);

        callableAsset.safeTransferFrom(msg.sender, address(this), obligationUsdc);
        callableAsset.forceApprove(address(usd3), obligationUsdc);
        usd3.deposit(obligationUsdc, msg.sender);

        marginAsset.safeTransfer(msg.sender, releasedMargin);

        emit CallFunded(msg.sender, epoch, obligationUsdc);
        emit MarginReleased(msg.sender, epoch, releasedMargin);
    }

    function finalizeEpochSlash(uint256 epoch) external nonReentrant synced {
        if (!epochs[epoch].slashFinalized) {
            if (!_slashEligible(epoch)) revert SlashNotEligible();
            _finalizeEpochSlash(epoch);
        }
    }

    function materializeAccount(address user) external synced {
        if (user == address(0)) revert ZeroAddress();
        // Accounts with live historical exposure may need repeated calls; empty accounts fast-forward.
        _materializeAccountPartial(user, MAX_MATERIALIZE_STEPS);
    }

    function getAccount(address user) external view returns (Account memory) {
        return _derivedAccount(user);
    }

    function getEpochState(uint256 epoch) external view returns (EpochState memory) {
        return epochs[epoch];
    }

    function obligationOf(uint256 epoch, address user) external view returns (uint256) {
        EpochState storage state = epochs[epoch];
        if (!state.callOpened || state.slashFinalized || fundedEpoch[epoch][user]) return 0;
        Account memory account = _derivedAccount(user);
        return _obligation(state, account.activeCallableUsdc);
    }

    function claimableExitedMargin(address user) external view returns (uint256) {
        Account memory account = _derivedAccount(user);
        if (!account.exitRequested || account.exitClaimed || _currentEpoch() < account.exitMaturityEpoch) return 0;
        return account.claimableExitMargin;
    }

    function calledEpochs() external view returns (uint256[] memory) {
        return calledEpochList;
    }

    function _syncGlobal() internal {
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
        while (lastActivationFolded < current) {
            unchecked {
                ++lastActivationFolded;
            }
            _foldActivation(lastActivationFolded);
        }

        while (lastMaturityFolded < current) {
            unchecked {
                ++lastMaturityFolded;
            }
            _foldMaturity(lastMaturityFolded);
        }
    }

    function _foldActivation(uint256 epoch) internal {
        uint256 margin = pendingMarginByActivationEpoch[epoch];
        uint256 callable = pendingCallableByActivationEpoch[epoch];
        if (margin == 0 && callable == 0) return;

        pendingMarginByActivationEpoch[epoch] = 0;
        pendingCallableByActivationEpoch[epoch] = 0;
        totalPendingMargin -= margin;
        totalPendingCallableUsdc -= callable;
        totalActiveMargin += margin;
        totalActiveCallableUsdc += callable;

        emit PendingActivated(epoch, margin, callable);
    }

    function _foldMaturity(uint256 epoch) internal {
        uint256 margin = exitRequestedMarginByMaturity[epoch];
        uint256 callable = exitRequestedCallableByMaturity[epoch];
        if (margin == 0 && callable == 0) return;

        exitRequestedMarginByMaturity[epoch] = 0;
        exitRequestedCallableByMaturity[epoch] = 0;
        _pruneExitMaturityIfEmpty(epoch);
        _decreaseGlobalActive(margin, callable);

        emit ExitMatured(epoch, margin, callable);
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

        uint256 slashedMargin = state.rawMarginAtCallOpen - state.rawMarginReleased - state.honoredRawMarginRemaining;
        uint256 slashedCallable = state.callableDenominator - state.fundedUsdc - state.honoredCallableRemaining;

        _reduceExitBucketsForSlash(epoch);

        _decreaseGlobalActive(slashedMargin, slashedCallable);
        if (slashedMargin != 0) marginAsset.safeTransfer(treasury, slashedMargin);

        emit EpochSlashFinalized(epoch, slashedMargin, slashedCallable, false);
    }

    function _materializeAccount(address user) internal {
        if (!_materializeAccountPartial(user, MAX_MATERIALIZE_STEPS)) revert AccountMaterializationIncomplete();
    }

    function _materializeAccountPartial(address user, uint256 maxSteps) internal returns (bool complete) {
        AccountReplay memory replay = _replayAccount(accounts[user], user, maxSteps, true, true);
        accounts[user] = replay.account;

        for (uint256 i = 0; i < replay.defaultCount; ++i) {
            uint256 epoch = replay.defaultedEpochs[i];
            defaultedEpoch[epoch][user] = true;
            emit UserDefaulted(user, epoch);
        }

        return replay.complete;
    }

    function _derivedAccount(address user) internal view returns (Account memory account) {
        return _replayAccount(accounts[user], user, 0, false, false).account;
    }

    function _replayAccount(Account memory account, address user, uint256 maxSteps, bool bounded, bool recordDefaults)
        internal
        view
        returns (AccountReplay memory replay)
    {
        replay.account = account;
        if (recordDefaults) replay.defaultedEpochs = new uint256[](maxSteps);

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
                _defaultAccount(replay.account);
                if (recordDefaults) {
                    replay.defaultedEpochs[replay.defaultCount] = epoch;
                    unchecked {
                        ++replay.defaultCount;
                    }
                }
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

        _activateDuePending(replay.account, activationFolded);
        _matureDueExit(replay.account, maturityFolded);
    }

    function _activatePendingForEpoch(Account memory account, uint256 epoch) internal pure {
        if (account.pendingActivationEpoch != 0 && account.pendingActivationEpoch <= epoch) _activatePending(account);
    }

    function _activateDuePending(Account memory account, uint256 foldedEpoch) internal pure {
        if (account.pendingActivationEpoch != 0 && account.pendingActivationEpoch <= foldedEpoch) {
            _activatePending(account);
        }
    }

    function _activatePending(Account memory account) internal pure {
        account.activeMargin += account.pendingMargin;
        account.activeCallableUsdc += account.pendingCallableUsdc;
        account.pendingMargin = 0;
        account.pendingCallableUsdc = 0;
        account.pendingActivationEpoch = 0;
    }

    function _matureExitForEpoch(Account memory account, uint256 epoch) internal pure {
        if (account.exitRequested && !account.exitMatured && !account.exitClaimed && account.exitMaturityEpoch <= epoch)
        {
            _matureExit(account);
        }
    }

    function _matureDueExit(Account memory account, uint256 foldedEpoch) internal pure {
        if (
            account.exitRequested && !account.exitMatured && !account.exitClaimed
                && account.exitMaturityEpoch <= foldedEpoch
        ) {
            _matureExit(account);
        }
    }

    function _matureExit(Account memory account) internal pure {
        account.claimableExitMargin += account.activeMargin;
        account.activeMargin = 0;
        account.activeCallableUsdc = 0;
        account.exitBucketMargin = 0;
        account.exitBucketCallable = 0;
        account.exitMatured = true;
    }

    function _shouldDefault(Account memory account, EpochState storage state, uint256 epoch, address user)
        internal
        view
        returns (bool)
    {
        if (state.slashDisabledByShutdown || fundedEpoch[epoch][user] || account.activeCallableUsdc == 0) {
            return false;
        }
        return !account.exitRequested || account.exitMaturityEpoch > epoch;
    }

    function _defaultAccount(Account memory account) internal pure {
        account.activeMargin = 0;
        account.activeCallableUsdc = 0;
        account.exitBucketMargin = 0;
        account.exitBucketCallable = 0;
        account.claimableExitMargin = 0;
        if (account.exitRequested && !account.exitClaimed) _clearExitMemory(account);
    }

    function _isZeroExposure(Account memory account) internal pure returns (bool) {
        return account.activeMargin == 0 && account.activeCallableUsdc == 0 && account.pendingMargin == 0
            && account.pendingCallableUsdc == 0 && account.claimableExitMargin == 0
            && (!account.exitRequested || account.exitClaimed);
    }

    function _clearExit(Account storage account) internal {
        account.exitRequested = false;
        account.exitMaturityEpoch = 0;
        account.exitClaimed = true;
        account.exitMatured = false;
        account.exitBucketMargin = 0;
        account.exitBucketCallable = 0;
    }

    function _clearExitMemory(Account memory account) internal pure {
        account.exitRequested = false;
        account.exitMaturityEpoch = 0;
        account.exitClaimed = true;
        account.exitMatured = false;
        account.exitBucketMargin = 0;
        account.exitBucketCallable = 0;
    }

    function _trackExitMaturity(uint256 maturityEpoch) internal {
        if (exitMaturityIndexPlusOne[maturityEpoch] != 0) return;
        exitMaturityIndexPlusOne[maturityEpoch] = exitMaturityList.length + 1;
        exitMaturityList.push(maturityEpoch);
    }

    function _pruneExitMaturityIfEmpty(uint256 maturityEpoch) internal {
        if (
            exitMaturityIndexPlusOne[maturityEpoch] == 0 || exitRequestedMarginByMaturity[maturityEpoch] != 0
                || exitRequestedCallableByMaturity[maturityEpoch] != 0
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

            uint256 margin = exitRequestedMarginByMaturity[maturity];
            uint256 callable = exitRequestedCallableByMaturity[maturity];
            if (margin == 0 && callable == 0) continue;

            _addCallExitExposure(epoch, maturity, margin, callable);
        }
    }

    function _addCurrentCallExitExposure(Account storage account, uint256 maturityEpoch) internal {
        uint256 epoch = _currentEpoch();
        EpochState storage state = epochs[epoch];
        if (!state.callOpened || state.slashFinalized || fundedEpoch[epoch][msg.sender] || maturityEpoch <= epoch) {
            return;
        }
        _addCallExitExposure(epoch, maturityEpoch, account.activeMargin, account.activeCallableUsdc);
    }

    function _addCallExitExposure(uint256 epoch, uint256 maturity, uint256 margin, uint256 callable) internal {
        ExitExposure storage exposure = exitExposureByCallAndMaturity[epoch][maturity];
        if (!exposure.listed) {
            exposure.listed = true;
            exitMaturitiesByCall[epoch].push(maturity);
        }
        exposure.margin += margin;
        exposure.callable += callable;
    }

    function _recordExitingFund(
        uint256 epoch,
        Account storage account,
        uint256 obligationUsdc,
        uint256 releasedMargin,
        uint256 remainingMargin,
        uint256 remainingCallable
    ) internal {
        if (!account.exitRequested || account.exitClaimed || account.exitMatured) return;

        uint256 maturity = account.exitMaturityEpoch;
        exitRequestedMarginByMaturity[maturity] -= releasedMargin;
        exitRequestedCallableByMaturity[maturity] -= obligationUsdc;
        _pruneExitMaturityIfEmpty(maturity);
        account.exitBucketMargin -= releasedMargin;
        account.exitBucketCallable -= obligationUsdc;

        ExitExposure storage exposure = exitExposureByCallAndMaturity[epoch][maturity];
        if (!exposure.listed) return;

        exposure.fundedUsdc += obligationUsdc;
        exposure.rawMarginReleased += releasedMargin;
        exposure.honoredRawMarginRemaining += remainingMargin;
        exposure.honoredCallableRemaining += remainingCallable;
    }

    function _reduceExitBucketsForSlash(uint256 epoch) internal {
        uint256[] storage maturities = exitMaturitiesByCall[epoch];
        for (uint256 i = 0; i < maturities.length; ++i) {
            uint256 maturity = maturities[i];
            ExitExposure storage exposure = exitExposureByCallAndMaturity[epoch][maturity];

            uint256 slashedMargin = exposure.margin - exposure.rawMarginReleased - exposure.honoredRawMarginRemaining;
            uint256 slashedCallable = exposure.callable - exposure.fundedUsdc - exposure.honoredCallableRemaining;
            if (slashedMargin == 0 && slashedCallable == 0) continue;

            exitRequestedMarginByMaturity[maturity] -= slashedMargin;
            exitRequestedCallableByMaturity[maturity] -= slashedCallable;
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

    function _addPending(Account storage account, uint256 margin, uint256 callable, uint256 activationEpoch) internal {
        if (account.pendingActivationEpoch != 0 && account.pendingActivationEpoch != activationEpoch) {
            revert InvalidEpoch();
        }

        account.pendingMargin += margin;
        account.pendingCallableUsdc += callable;
        account.pendingActivationEpoch = activationEpoch;

        totalPendingMargin += margin;
        totalPendingCallableUsdc += callable;
        pendingMarginByActivationEpoch[activationEpoch] += margin;
        pendingCallableByActivationEpoch[activationEpoch] += callable;
    }

    function _decreasePending(Account storage account, uint256 margin, uint256 callable) internal {
        if (margin == 0 && callable == 0) return;

        uint256 activationEpoch = account.pendingActivationEpoch;
        totalPendingMargin -= margin;
        totalPendingCallableUsdc -= callable;

        if (activationEpoch > lastActivationFolded) {
            pendingMarginByActivationEpoch[activationEpoch] -= margin;
            pendingCallableByActivationEpoch[activationEpoch] -= callable;
        }
    }

    function _decreaseGlobalActive(uint256 margin, uint256 callable) internal {
        if (margin != 0) totalActiveMargin -= margin;
        if (callable != 0) totalActiveCallableUsdc -= callable;
    }

    function _assignExitMaturity(uint256 accountCallable) internal view returns (uint256 maturityEpoch) {
        uint256 capacity = protocolCallableCapUsdc.mulDiv(exitCapBps, BPS);
        if (capacity == 0) revert InvalidParams();

        maturityEpoch = _currentEpoch() + exitDelayEpochs;
        while (true) {
            uint256 assigned = exitRequestedCallableByMaturity[maturityEpoch];
            if (assigned < capacity) {
                uint256 remaining = capacity - assigned;
                if (accountCallable <= remaining || accountCallable > capacity) return maturityEpoch;
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

    function _obligation(EpochState storage state, uint256 activeCallable) internal view returns (uint256) {
        if (activeCallable == 0 || state.callableDenominator == 0) return 0;
        return activeCallable.mulDiv(state.callAmount, state.callableDenominator, Math.Rounding.Ceil);
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
            params.owner == address(0) || params.marginAsset == address(0) || params.callableAsset == address(0)
                || params.usd3 == address(0) || params.marginOracle == address(0) || params.treasury == address(0)
        ) revert ZeroAddress();
        if (params.callableAsset != IERC4626(params.usd3).asset()) revert InvalidParams();
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
        if (params.protocolCallableCapUsdc == 0 || params.userCallableCapUsdc == 0) revert InvalidParams();
        if (params.exitCapBps == 0 || params.exitCapBps > BPS) revert InvalidParams();
        if (params.exitDelayEpochs == 0) revert InvalidParams();
    }
}
