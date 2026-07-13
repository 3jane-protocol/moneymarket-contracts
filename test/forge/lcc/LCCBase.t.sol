// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {Vm} from "../../../lib/forge-std/src/Vm.sol";
import {BeaconProxy} from "../../../lib/openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "../../../lib/openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "../../../lib/openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {LCCEventsLib} from "../../../src/lcc/libraries/LCCEventsLib.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCAuctionLib} from "../../../src/lcc/libraries/LCCAuctionLib.sol";
import {OracleMock} from "../../../src/mocks/OracleMock.sol";
import {ORACLE_PRICE_SCALE, BPS} from "../../../src/libraries/ConstantsLib.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";

contract LCCMockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}

contract LCCBlacklistMockToken is LCCMockToken {
    address internal blockedRecipient;

    constructor(string memory name_, string memory symbol_) LCCMockToken(name_, symbol_) {}

    function setBlockedRecipient(address recipient) external {
        blockedRecipient = recipient;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(blockedRecipient == address(0) || to != blockedRecipient, "BLOCKED_RECIPIENT");
        super._update(from, to, value);
    }
}

contract LCCMockUSD3 is ERC4626 {
    uint256 internal depositLimit = type(uint256).max;
    uint256 internal minDeposit;
    bool internal depositHookReverts;
    mapping(address => bool) internal supplyCapExempt;
    uint256 public ringFencedLiquidity;

    constructor(IERC20 asset_) ERC20("Mock USD3", "mUSD3") ERC4626(asset_) {}

    function setDepositLimit(uint256 limit) external {
        depositLimit = limit;
    }

    function setDepositHookReverts(bool reverts) external {
        depositHookReverts = reverts;
    }

    function setMinDeposit(uint256 minDeposit_) external {
        minDeposit = minDeposit_;
    }

    function setSupplyCapExempt(address account, bool exempt) external {
        supplyCapExempt[account] = exempt;
    }

    function reportProfit(uint256 assets) external {
        LCCMockToken(asset()).mint(address(this), assets);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return assets;
        uint256 managedAssets = totalAssets();
        if (managedAssets == 0) return 0;
        return Math.mulDiv(assets, supply, managedAssets, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return shares;
        uint256 managedAssets = totalAssets();
        return Math.mulDiv(shares, managedAssets, supply, rounding);
    }

    function maxDeposit(address) public view override returns (uint256) {
        return depositLimit;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        require(!depositHookReverts, "!allowed");
        if (balanceOf(receiver) == 0 && !supplyCapExempt[receiver]) require(assets >= minDeposit, "<min");
        require(previewDeposit(assets) != 0, "ZERO_SHARES");
        uint256 shares = super.deposit(assets, receiver);
        ringFencedLiquidity += assets;
        return shares;
    }
}

contract LCCMockNotificationVault is ERC4626 {
    bool internal depositHookReverts;

    constructor(IERC20 asset_) ERC20("Mock Notification USD3", "mnUSD3") ERC4626(asset_) {}

    function setDepositHookReverts(bool reverts) external {
        depositHookReverts = reverts;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        require(!depositHookReverts, "!notification");
        return super.deposit(assets, receiver);
    }
}

contract LCCRevertingOracle is IOracle {
    function price() external pure returns (uint256) {
        revert("ORACLE_DOWN");
    }
}

contract LCCAssetOnlyVault {
    address internal immutable asset_;

    constructor(address asset__) {
        asset_ = asset__;
    }

    function asset() external view returns (address) {
        return asset_;
    }
}

contract LCCBase is Test {
    uint256 internal constant START = 1_000;
    uint256 internal constant EPOCH = 100;
    uint256 internal constant NORMAL = 40;
    uint256 internal constant PRE_CALL = 20;
    uint256 internal constant FUNDING = 20;
    uint256 internal constant CAP = 10_000_000e18;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    LCCMockToken internal margin;
    LCCMockToken internal usdc;
    LCCMockUSD3 internal usd3;
    LCCMockNotificationVault internal notificationVault;
    OracleMock internal oracle;
    LCCVault internal vaultImplementation;
    UpgradeableBeacon internal beacon;
    LCCVault internal vault;

    struct MarginSums {
        uint256 activeMargin;
        uint256 activeCommitment;
        uint256 pendingMargin;
        uint256 pendingCommitment;
        uint256 claimableMargin;
    }

    function setUp() public virtual {
        vm.warp(START);
        margin = new LCCMockToken("Margin", "MRG");
        usdc = new LCCMockToken("USD Coin", "USDC");
        usd3 = new LCCMockUSD3(IERC20(address(usdc)));
        notificationVault = new LCCMockNotificationVault(IERC20(address(usd3)));
        oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE_SCALE);
        vaultImplementation = new LCCVault(address(notificationVault), treasury);
        beacon = new UpgradeableBeacon(address(vaultImplementation), owner);

        vault = _newVault(_params(address(oracle), CAP, CAP, 2_000));

        _mintAndApprove(alice, 1_000_000e18, 1_000_000e18);
        _mintAndApprove(bob, 1_000_000e18, 1_000_000e18);
        _mintAndApprove(carol, 1_000_000e18, 1_000_000e18);
    }

    function _params(uint256 protocolCap, uint256 userCap) internal view returns (ILCCVault.VaultParams memory) {
        return _params(address(oracle), protocolCap, userCap, 2_000);
    }

    function _params(address oracle_, uint256 protocolCap, uint256 userCap, uint256 exitCapBps)
        internal
        view
        returns (ILCCVault.VaultParams memory)
    {
        return ILCCVault.VaultParams({
            owner: owner,
            marginAsset: address(margin),
            marginOracle: oracle_,
            startTimestamp: START,
            maxEpochs: 0,
            epochLength: EPOCH,
            normalDuration: NORMAL,
            preCallDuration: PRE_CALL,
            fundingDuration: FUNDING,
            marginRatioBps: 5_000,
            protocolCommitmentCap: protocolCap,
            userCommitmentCap: userCap,
            exitCapBps: exitCapBps,
            exitDelayEpochs: 1,
            minCommitmentEpochs: 0,
            minDepositAssets: 0,
            auctionStepCount: 0,
            auctionStepDecayRateBps: 0,
            maxAuctionAwardBps: 0,
            slashFeeBps: 0
        });
    }

    function _auctionParams() internal view returns (ILCCVault.VaultParams memory params) {
        params = _params(CAP, CAP);
        // 20s Closed window split into 4 steps of 5s, halving the retained share each step.
        params.auctionStepCount = 4;
        params.auctionStepDecayRateBps = 5_000;
        params.maxAuctionAwardBps = 10_000;
        params.slashFeeBps = 1_000;
    }

    function _termParams(uint256 maxEpochs) internal view returns (ILCCVault.VaultParams memory params) {
        params = _params(CAP, CAP);
        params.maxEpochs = maxEpochs;
    }

    function _deployAuctionVault() internal {
        _deployVaultWithParams(_auctionParams());
    }

    function _deployVaultWithParams(ILCCVault.VaultParams memory params) internal {
        vault = _newVault(params);
        _mintAndApprove(alice, 0, 0);
        _mintAndApprove(bob, 0, 0);
        _mintAndApprove(carol, 0, 0);
    }

    function _newVault(ILCCVault.VaultParams memory params) internal returns (LCCVault) {
        return LCCVault(address(new BeaconProxy(address(beacon), abi.encodeCall(ILCCVault.initialize, (params)))));
    }

    /// @dev Asserts a hardcoded storage-slot constant against the reviewer-controlled layout baseline, so slot
    /// drift fails tests loudly instead of degrading raw-slot assertions into vacuous passes.
    function _assertLayoutSlot(string memory label, uint256 expectedSlot) internal view {
        string memory json = vm.readFile("docs/lcc-vault-storage-layout.json");
        for (uint256 i = 0;; ++i) {
            string memory base = string.concat(".storage[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, string.concat(base, ".label"))) break;
            if (keccak256(bytes(vm.parseJsonString(json, string.concat(base, ".label")))) == keccak256(bytes(label))) {
                assertEq(vm.parseUint(vm.parseJsonString(json, string.concat(base, ".slot"))), expectedSlot, label);
                return;
            }
        }
        revert(string.concat("layout label missing: ", label));
    }

    function _mappingSlot(uint256 key, uint256 slot) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, slot));
    }

    function _isUserDefaulted(Vm.Log memory entry, address emitter) internal pure returns (bool) {
        return
            entry.emitter == emitter && entry.topics.length == 3
                && entry.topics[0] == LCCEventsLib.UserDefaulted.selector;
    }

    function _assertNoUserDefaulted(Vm.Log[] memory logs, address emitter, address user, uint256 epoch) internal pure {
        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            bool matches = _isUserDefaulted(entry, emitter) && address(uint160(uint256(entry.topics[1]))) == user
                && uint256(entry.topics[2]) == epoch;
            assertFalse(matches, "unexpected UserDefaulted event");
        }
    }

    function _normalizedUserDefaultedEventsHash(Vm.Log[] memory logs, address emitter)
        internal
        pure
        returns (bytes32 hash)
    {
        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (!_isUserDefaulted(entry, emitter)) continue;

            address user = address(uint160(uint256(entry.topics[1])));
            uint256 epoch = uint256(entry.topics[2]);
            (uint256 slashedMargin, uint256 slashedCommitment) = abi.decode(entry.data, (uint256, uint256));
            hash = keccak256(abi.encode(hash, user, epoch, slashedMargin, slashedCommitment));
        }
    }

    function _mintAndApprove(address user, uint256 marginAmount, uint256 usdcAmount) internal {
        _mintAndApprove(vault, user, marginAmount, usdcAmount);
    }

    function _mintAndApprove(LCCVault target, address user, uint256 marginAmount, uint256 usdcAmount) internal {
        margin.mint(user, marginAmount);
        usdc.mint(user, usdcAmount);

        vm.startPrank(user);
        margin.approve(address(target), type(uint256).max);
        usdc.approve(address(target), type(uint256).max);
        vm.stopPrank();
    }

    function _seedUsd3(uint256 assets, uint256 profit) internal {
        usdc.mint(address(this), assets);
        usdc.approve(address(usd3), assets);
        usd3.deposit(assets, address(this));
        usd3.reportProfit(profit);
        assertEq(usd3.previewMint(1), Math.ceilDiv(assets + profit, assets));
    }

    function _effectiveTime(LCCVault target) internal view returns (uint256) {
        (, bool paused, uint64 pausedAt, uint64 pausedAccumulated) = target.pauseState();
        return (paused ? pausedAt : block.timestamp) - pausedAccumulated;
    }

    function _deposit(address user, uint256 assets) internal returns (uint256 commitment) {
        vm.prank(user);
        commitment = vault.deposit(assets);
    }

    function _openCall(uint256 amount) internal {
        _openCallAtEpoch(0, amount);
    }

    function _openCallAtEpoch(uint256 epoch, uint256 amount) internal {
        vm.warp(START + EPOCH * epoch + NORMAL);
        vm.prank(owner);
        vault.openEpochCall(epoch, amount);
    }

    function _fund(address user) internal returns (uint256 obligation) {
        return _fundAtEpoch(user, 0);
    }

    function _fundAtEpoch(address user, uint256 epoch) internal returns (uint256 obligation) {
        vm.warp(START + EPOCH * epoch + NORMAL + PRE_CALL);
        vm.prank(user);
        obligation = vault.fundCall(false);
    }

    function _fundRolling(address user) internal returns (uint256 obligation) {
        return _fundRollingAtEpoch(user, 0);
    }

    function _fundRollingAtEpoch(address user, uint256 epoch) internal returns (uint256 obligation) {
        vm.warp(START + EPOCH * epoch + NORMAL + PRE_CALL);
        vm.prank(user);
        obligation = vault.fundCall(true);
    }

    function _fundFor(address payer, address user) internal returns (uint256 obligation) {
        vm.warp(START + NORMAL + PRE_CALL);
        vm.prank(payer);
        obligation = vault.fundCall(user);
    }

    function _finishFunding() internal {
        _finishFundingAtEpoch(0);
    }

    function _finishFundingAtEpoch(uint256 epoch) internal {
        vm.warp(START + EPOCH * epoch + NORMAL + PRE_CALL + FUNDING);
    }

    function _syncAs(address user) internal {
        vm.prank(user);
        vault.materializeAccount(user);
    }

    function _marginSums(address[] memory actors) internal view returns (MarginSums memory sums) {
        for (uint256 i = 0; i < actors.length; ++i) {
            ILCCVault.Account memory account = vault.getAccount(actors[i]);
            sums.activeMargin += account.activeMargin;
            sums.activeCommitment += account.activeCommitment;
            sums.pendingMargin += account.pendingMargin;
            sums.pendingCommitment += account.pendingCommitment;
            sums.claimableMargin += account.claimableExitMargin;
        }
    }

    function _assertTreasuryAndEpochConservation(uint256[] memory called, uint256 initialTreasuryMargin)
        internal
        view
        returns (uint256 returnPoolEpochs, uint256 marginRatioSum)
    {
        uint256 expectedTreasury;
        uint256 liveAuctionSlot = vault.syncState().pendingAuctionEpochPlusOne;
        ILCCVault.RiskConfig memory riskConfig = vault.riskConfig();

        for (uint256 i = 0; i < called.length; ++i) {
            uint256 epoch = called[i];
            ILCCVault.EpochState memory state = vault.getEpochState(epoch);
            if (state.returnPool != 0) {
                ++returnPoolEpochs;
                marginRatioSum += Math.ceilDiv(state.returnPool, state.returnCommitment);
            }
            if (!state.slashFinalized || state.slashDisabledByShutdown || liveAuctionSlot == epoch + 1) continue;

            LCCAuctionLib.AuctionState memory auction = vault.getAuctionState(epoch);
            assertEq(
                state.marginReleased + state.fundedUsersRemainingMargin + state.slashedMargin, state.marginAtCallOpen
            );

            assertLe(auction.marginAwarded, state.slashedMargin);
            uint256 surplus = state.slashedMargin - auction.marginAwarded;
            assertLe(state.returnPool, surplus);

            uint256 toTreasury = surplus - state.returnPool;
            if (state.returnPool != 0) {
                uint256 minimumFee = Math.min(Math.mulDiv(auction.marginAwarded, riskConfig.slashFeeBps, BPS), surplus);
                assertGe(toTreasury, minimumFee);
            }
            expectedTreasury += toTreasury;
        }

        assertEq(margin.balanceOf(treasury) + vault.pendingTreasuryMargin(), initialTreasuryMargin + expectedTreasury);
    }

    function _accruedTreasuryMargin() internal view returns (uint256) {
        return margin.balanceOf(treasury) + vault.pendingTreasuryMargin();
    }

    /// @dev Upper bound on the margin the return-pool re-attribution can leave orphaned in the global totals: one
    /// flooring unit per defaulter per return-pool epoch, plus a dust slice scaled by the returnPool/returnCommitment
    /// (inverse price*leverage) ratio. No amount-scale term, so it cannot mask a real margin over-count.
    function _marginDustBound(uint256 actorCount) internal view returns (uint256) {
        uint256[] memory called = vault.calledEpochs();
        uint256 returnPoolEpochs;
        uint256 marginRatioSum;
        for (uint256 i = 0; i < called.length; ++i) {
            ILCCVault.EpochState memory state = vault.getEpochState(called[i]);
            if (state.returnPool != 0) {
                ++returnPoolEpochs;
                marginRatioSum += Math.ceilDiv(state.returnPool, state.returnCommitment);
            }
        }
        return actorCount * (returnPoolEpochs + marginRatioSum);
    }
}
