// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Setup} from "../../usd3/utils/Setup.sol";
import {MockERC20} from "../../usd3/mocks/MockERC20.sol";

import {NotificationVault} from "../../../../src/usd3/NotificationVault.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {ProtocolConfigLib} from "../../../../src/libraries/ProtocolConfigLib.sol";

import {BeaconProxy} from "../../../../lib/openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "../../../../lib/openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    TransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

// ABI-load-bearing mirror of ILCCVault.VaultParams. Keep the field order and types identical.
struct VaultParams {
    address owner;
    address marginAsset;
    address marginOracle;
    uint256 startTimestamp;
    uint256 maxEpochs;
    uint256 epochLength;
    uint256 normalDuration;
    uint256 preCallDuration;
    uint256 fundingDuration;
    uint256 marginRatioBps;
    uint256 protocolCommitmentCap;
    uint256 userCommitmentCap;
    uint256 exitCapBps;
    uint256 exitDelayEpochs;
    uint256 minCommitmentEpochs;
    uint256 minDepositAssets;
    uint256 auctionStepCount;
    uint256 auctionStepDecayRateBps;
    uint256 maxAuctionAwardBps;
    uint256 slashFeeBps;
}

struct AssetConfig {
    address marginAsset;
    address fundingAsset;
    address usd3;
    address notificationVault;
    address marginOracle;
    address treasury;
}

struct EpochConfig {
    uint256 startTimestamp;
    uint256 maxEpochs;
    uint256 epochLength;
    uint256 normalDuration;
    uint256 preCallDuration;
    uint256 fundingDuration;
    uint256 marginRatioBps;
    uint256 exitDelayEpochs;
    uint256 minCommitmentEpochs;
}

struct AuctionConfig {
    uint256 auctionStepCount;
    uint256 auctionStepDecayRateBps;
    uint256 auctionStepDuration;
}

struct RiskConfig {
    uint256 protocolCommitmentCap;
    uint256 userCommitmentCap;
    uint256 exitCapBps;
    uint256 minDepositAssets;
    uint256 maxAuctionAwardBps;
    uint256 slashFeeBps;
}

struct LCCAccount {
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
    uint256 commitmentStartEpoch;
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
    uint256 slashedMargin;
    uint256 returnPool;
    uint256 returnCommitment;
}

struct AuctionState {
    uint128 shortfallAmount;
    uint128 filledAmount;
    uint128 marginPool;
    uint128 marginAwarded;
}

interface ILCCVaultLike {
    function initialize(VaultParams calldata params) external;
    function owner() external view returns (address);
    function deposit(
        uint256 assets,
        uint256 minCommitment,
        uint256 maxCommitment,
        bool allowPendingActivation,
        uint256 deadline
    ) external returns (uint256 commitment);
    function openEpochCall(uint256 epoch, uint256 callAmount) external;
    function fundCall(bool roll) external returns (uint256 obligationAmount);
    function fundCall(address user) external returns (uint256 obligationAmount);
    function takeAuction(uint256 maxFillAmount, uint256 minMarginAward, uint256 deadline)
        external
        returns (uint256 filledAmount, uint256 marginAward);
    function finalizeEpochSlash(uint256 epoch) external;
    function materializeAccount(address user) external;
    function requestExit(uint256 maxDeferralEpochs, uint256 deadline) external returns (uint256 maturityEpoch);
    function claimExitedMargin(address receiver) external returns (uint256 assets);
    function fundedEpoch(uint256 epoch, address user) external view returns (bool);
    function getAccount(address user) external view returns (LCCAccount memory);
    function getEpochState(uint256 epoch) external view returns (EpochState memory);
    function getAuctionState(uint256 epoch) external view returns (AuctionState memory);
    function assetConfig() external view returns (AssetConfig memory);
    function epochConfig() external view returns (EpochConfig memory);
    function auctionConfig() external view returns (AuctionConfig memory);
    function riskConfig() external view returns (RiskConfig memory);
}

contract LCCRealStackOracle {
    uint256 public price;

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }
}

contract LCCRealStackFundingIntegrationTest is Setup {
    event CallFunded(
        address indexed payer,
        address indexed user,
        uint256 indexed epoch,
        uint256 obligationAmount,
        uint256 fundingAmount
    );

    string internal constant AUCTION_LIB_FQN = "src/lcc/libraries/LCCAuctionLib.sol:LCCAuctionLib";
    string internal constant CONFIG_LIB_FQN = "src/lcc/libraries/LCCConfigLib.sol:LCCConfigLib";

    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    uint256 internal constant USD3_SUPPLY_CAP = 100e6;
    uint256 internal constant FACILITY_CAP = 10_000_000e6;
    uint256 internal constant ACTOR_BALANCE = 1_000_000e6;
    uint256 internal constant EPOCH = 100;
    uint256 internal constant NORMAL = 40;
    uint256 internal constant PRE_CALL = 20;
    uint256 internal constant FUNDING = 20;

    address internal alice;
    address internal bob;
    address internal carol;
    address internal filler;
    address internal seeder;
    address internal lccOwner;
    address internal treasury;

    uint256 internal startTimestamp;

    USD3 internal usd3;
    NotificationVault internal notificationVault;
    MockERC20 internal margin;
    LCCRealStackOracle internal oracle;
    UpgradeableBeacon internal beacon;
    ILCCVaultLike internal vault;

    function setUp() public override {
        super.setUp();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        filler = makeAddr("filler");
        seeder = makeAddr("seeder");
        lccOwner = makeAddr("lccOwner");
        treasury = makeAddr("treasury");

        usd3 = USD3(address(strategy));
        notificationVault = _deployNotificationVault();

        margin = new MockERC20("Margin", "MRG", 6);
        oracle = new LCCRealStackOracle();
        oracle.setPrice(ORACLE_PRICE_SCALE);

        // Anchor the LCC clock to the live TokenizedStrategy fixture timestamp and only warp forward from it.
        startTimestamp = block.timestamp + 1 hours;

        address implementation = _deployLinkedLCCVaultImpl(address(notificationVault), treasury);
        beacon = new UpgradeableBeacon(implementation, lccOwner);

        testProtocolConfig.setConfig(ProtocolConfigLib.USD3_SUPPLY_CAP, USD3_SUPPLY_CAP);
        vault = _newVault(_baseParams(), true);

        _fundActor(alice);
        _fundActor(bob);
        _fundActor(carol);
        _fundActor(filler);
    }

    function testInitializeParamsRoundTripTripsOnShimDrift() public {
        VaultParams memory params = _driftTripwireParams();
        ILCCVaultLike driftVault = _newVault(params, true);

        assertEq(driftVault.owner(), params.owner);

        AssetConfig memory assets = driftVault.assetConfig();
        assertEq(assets.marginAsset, params.marginAsset);
        assertEq(assets.fundingAsset, address(underlyingAsset));
        assertEq(assets.usd3, address(strategy));
        assertEq(assets.notificationVault, address(notificationVault));
        assertEq(assets.marginOracle, params.marginOracle);
        assertEq(assets.treasury, treasury);

        EpochConfig memory epoch = driftVault.epochConfig();
        assertEq(epoch.startTimestamp, params.startTimestamp);
        assertEq(epoch.maxEpochs, params.maxEpochs);
        assertEq(epoch.epochLength, params.epochLength);
        assertEq(epoch.normalDuration, params.normalDuration);
        assertEq(epoch.preCallDuration, params.preCallDuration);
        assertEq(epoch.fundingDuration, params.fundingDuration);
        assertEq(epoch.marginRatioBps, params.marginRatioBps);
        assertEq(epoch.exitDelayEpochs, params.exitDelayEpochs);
        assertEq(epoch.minCommitmentEpochs, params.minCommitmentEpochs);

        RiskConfig memory risk = driftVault.riskConfig();
        assertEq(risk.protocolCommitmentCap, params.protocolCommitmentCap);
        assertEq(risk.userCommitmentCap, params.userCommitmentCap);
        assertEq(risk.exitCapBps, params.exitCapBps);
        assertEq(risk.minDepositAssets, params.minDepositAssets);
        assertEq(risk.maxAuctionAwardBps, params.maxAuctionAwardBps);
        assertEq(risk.slashFeeBps, params.slashFeeBps);

        AuctionConfig memory auction = driftVault.auctionConfig();
        assertEq(auction.auctionStepCount, params.auctionStepCount);
        assertEq(auction.auctionStepDecayRateBps, params.auctionStepDecayRateBps);
        uint256 closedDuration =
            params.epochLength - params.normalDuration - params.preCallDuration - params.fundingDuration;
        assertEq(auction.auctionStepDuration, closedDuration / params.auctionStepCount);

        assertTrue(strategy.supplyCapExempt(address(driftVault)));
        assertFalse(strategy.ringFenceConduit(address(driftVault)));
    }

    function testViewShimFieldOrderTripwire() public {
        ILCCVaultLike shimVault = _newVault(_auctionParams(), true);
        _approveVault(shimVault, alice);
        _approveVault(shimVault, bob);
        _approveVault(shimVault, filler);

        _deposit(shimVault, alice, 100e6);
        _deposit(shimVault, bob, 50e6);
        _openCall(shimVault, 123e6);
        assertEq(_fund(shimVault, alice, false), 82e6);

        vm.warp(startTimestamp + NORMAL + PRE_CALL + FUNDING);
        shimVault.finalizeEpochSlash(0);
        vm.warp(startTimestamp + NORMAL + PRE_CALL + FUNDING + 5);
        vm.startPrank(filler);
        (uint256 filled, uint256 award) = shimVault.takeAuction(10e6, 6_097_560, type(uint256).max);
        assertEq(filled, 10e6);
        assertEq(award, 6_097_560);
        (filled, award) = shimVault.takeAuction(31e6, 18_902_439, type(uint256).max);
        assertEq(filled, 31e6);
        assertEq(award, 18_902_439);
        vm.stopPrank();

        // Once the call and auction are settled, a Closed-phase deposit can safely remain pending for epoch 1,
        // giving every adjacent amount/cursor field a distinct independently-derived value.
        _deposit(shimVault, alice, 13e6);
        _assertAccountEq(
            shimVault.getAccount(alice),
            LCCAccount({
                activeMargin: 59e6,
                activeCommitment: 118e6,
                pendingMargin: 13e6,
                pendingCommitment: 26e6,
                pendingActivationEpoch: 1,
                calledEpochCursor: 1,
                claimableExitMargin: 0,
                exitBucketMargin: 0,
                exitBucketCommitment: 0,
                exitRequested: false,
                exitMaturityEpoch: 0,
                exitClaimed: false,
                exitMatured: false,
                commitmentStartEpoch: 1
            })
        );

        vm.warp(startTimestamp + EPOCH);
        shimVault.materializeAccount(filler);

        _assertEpochStateEq(
            shimVault.getEpochState(0),
            EpochState({
                callOpened: true,
                commitmentDenominator: 300e6,
                callAmount: 123e6,
                marginAtCallOpen: 150e6,
                fundedAmount: 82e6,
                marginReleased: 41e6,
                fundedUsersRemainingMargin: 59e6,
                fundedUsersRemainingCommitment: 118e6,
                slashFinalized: true,
                slashDisabledByShutdown: false,
                slashedMargin: 50e6,
                returnPool: 22_500_002,
                returnCommitment: 45_000_004
            })
        );
        _assertAuctionStateEq(
            shimVault.getAuctionState(0),
            AuctionState({
                shortfallAmount: uint128(41e6),
                filledAmount: uint128(41e6),
                marginPool: uint128(50e6),
                marginAwarded: uint128(24_999_999)
            })
        );

        shimVault.materializeAccount(alice);
        vm.prank(alice);
        assertEq(shimVault.requestExit(type(uint256).max, type(uint256).max), 2);
        _assertAccountEq(
            shimVault.getAccount(alice),
            LCCAccount({
                activeMargin: 72e6,
                activeCommitment: 144e6,
                pendingMargin: 0,
                pendingCommitment: 0,
                pendingActivationEpoch: 0,
                calledEpochCursor: 1,
                claimableExitMargin: 0,
                exitBucketMargin: 72e6,
                exitBucketCommitment: 144e6,
                exitRequested: true,
                exitMaturityEpoch: 2,
                exitClaimed: false,
                exitMatured: false,
                commitmentStartEpoch: 1
            })
        );

        vm.warp(startTimestamp + 2 * EPOCH);
        shimVault.materializeAccount(alice);
        _assertAccountEq(
            shimVault.getAccount(alice),
            LCCAccount({
                activeMargin: 0,
                activeCommitment: 0,
                pendingMargin: 0,
                pendingCommitment: 0,
                pendingActivationEpoch: 0,
                calledEpochCursor: 1,
                claimableExitMargin: 72e6,
                exitBucketMargin: 0,
                exitBucketCommitment: 0,
                exitRequested: true,
                exitMaturityEpoch: 2,
                exitClaimed: false,
                exitMatured: true,
                commitmentStartEpoch: 1
            })
        );

        vm.prank(alice);
        assertEq(shimVault.claimExitedMargin(alice), 72e6);
        LCCAccount memory claimed = shimVault.getAccount(alice);
        assertFalse(claimed.exitRequested);
        assertEq(claimed.exitMaturityEpoch, 0);
        assertTrue(claimed.exitClaimed);
        assertFalse(claimed.exitMatured);
        assertEq(claimed.commitmentStartEpoch, 1);
    }

    function testSelfFundAmortizePullsObligationDeliversUSD3n() public {
        _deposit(vault, alice, 100e6);
        _deposit(vault, bob, 50e6);
        _openCall(vault, 75e6);

        uint256 payerBefore = underlyingAsset.balanceOf(alice);
        uint256 marginBefore = margin.balanceOf(alice);
        uint256 wrappedBefore = _wrappedWaUSDC();

        uint256 obligation = _fund(vault, alice, false);

        assertEq(obligation, 50e6);
        assertEq(payerBefore - underlyingAsset.balanceOf(alice), 50e6);
        assertEq(IERC20(address(notificationVault)).balanceOf(alice), 50e6);
        assertEq(margin.balanceOf(alice) - marginBefore, 25e6);
        assertEq(_wrappedWaUSDC() - wrappedBefore, 50e6);
        assertTrue(vault.fundedEpoch(0, alice));

        LCCAccount memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 75e6);
        assertEq(account.activeCommitment, 150e6);
        assertEq(vault.getEpochState(0).fundedAmount, 50e6);
    }

    function testSelfFundRollingRetainsMarginAndCommitment() public {
        _deposit(vault, alice, 100e6);
        _openCall(vault, 50e6);

        uint256 payerBefore = underlyingAsset.balanceOf(alice);
        uint256 marginBefore = margin.balanceOf(alice);
        uint256 obligation = _fund(vault, alice, true);

        assertEq(obligation, 50e6);
        assertEq(payerBefore - underlyingAsset.balanceOf(alice), 50e6);
        assertEq(margin.balanceOf(alice), marginBefore);
        assertEq(IERC20(address(notificationVault)).balanceOf(alice), 50e6);

        LCCAccount memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 100e6);
        assertEq(account.activeCommitment, 200e6);
        assertEq(vault.getEpochState(0).fundedAmount, 50e6);
    }

    function testPushFundingThirdPartyPaysBeneficiaryReceives() public {
        _deposit(vault, alice, 100e6);
        _openCall(vault, 50e6);

        uint256 payerBefore = underlyingAsset.balanceOf(carol);
        uint256 beneficiaryMarginBefore = margin.balanceOf(alice);
        vm.warp(startTimestamp + NORMAL + PRE_CALL);
        vm.prank(carol);
        uint256 obligation = vault.fundCall(alice);

        assertEq(obligation, 50e6);
        assertEq(payerBefore - underlyingAsset.balanceOf(carol), 50e6);
        assertEq(IERC20(address(notificationVault)).balanceOf(carol), 0);
        assertEq(IERC20(address(notificationVault)).balanceOf(alice), 50e6);
        assertEq(margin.balanceOf(alice) - beneficiaryMarginBefore, 25e6);

        LCCAccount memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 75e6);
        assertEq(account.activeCommitment, 150e6);
    }

    /// @dev Deployment-error guard: LCC funding is intended to be ring-fenced (the runbook registers each proxy as
    /// a conduit). This characterizes the failure mode where that registration is OMITTED — USD3 then silently does
    /// not fence, leaving funder liquidity unreserved. The opted-in counterpart is the reference behavior below.
    function testUnregisteredConduitsDoNotFenceOrdinaryDustOrAuctionFunding() public {
        ILCCVaultLike dustVault = _newVault(_baseParams(), true);
        ILCCVaultLike auctionVault = _newVault(_auctionParams(), true);
        _approveVault(dustVault, carol);
        _approveVault(auctionVault, alice);
        _approveVault(auctionVault, bob);
        _approveVault(auctionVault, filler);

        assertFalse(strategy.ringFenceConduit(address(vault)));
        assertFalse(strategy.ringFenceConduit(address(dustVault)));
        assertFalse(strategy.ringFenceConduit(address(auctionVault)));

        _deposit(vault, alice, 100e6);
        _deposit(dustVault, carol, 1e6);
        _deposit(auctionVault, alice, 100e6);
        _deposit(auctionVault, bob, 50e6);
        _seedUsd3RealPps(100e6, 100e6);

        _openCall(vault, 50e6);
        _openCall(dustVault, 1);
        _openCall(auctionVault, 150e6);

        uint256 fenceBefore = strategy.ringFencedLiquidity();
        assertEq(_fund(vault, alice, false), 50e6);
        assertEq(strategy.ringFencedLiquidity(), fenceBefore, "ordinary funding unregistered");
        assertEq(_fund(dustVault, carol, false), 1);
        assertEq(strategy.ringFencedLiquidity(), fenceBefore, "dust funding unregistered");
        assertEq(_fund(auctionVault, alice, false), 100e6);
        assertEq(strategy.ringFencedLiquidity(), fenceBefore, "auction setup funding unregistered");

        vm.warp(startTimestamp + NORMAL + PRE_CALL + FUNDING);
        auctionVault.finalizeEpochSlash(0);
        vm.warp(startTimestamp + NORMAL + PRE_CALL + FUNDING + 5);
        vm.prank(filler);
        (uint256 filled,) = auctionVault.takeAuction(type(uint256).max, 0, type(uint256).max);
        assertEq(filled, 50e6);
        assertEq(strategy.ringFencedLiquidity(), fenceBefore, "auction take unregistered");
    }

    function testDustFundingRealPpsTopUpSettlesObligationAndOptedInFenceTracksFundingAmount() public {
        _seedUsd3RealPps(100e6, 100e6);
        assertEq(strategy.previewMint(1), 2);

        vm.prank(management);
        strategy.setRingFenceConduit(address(vault), true);
        assertTrue(strategy.ringFenceConduit(address(vault)));

        _deposit(vault, alice, 1e6);
        _openCall(vault, 1);

        uint256 payerBefore = underlyingAsset.balanceOf(alice);
        uint256 notificationBefore = IERC20(address(notificationVault)).balanceOf(alice);
        uint256 wrappedBefore = _wrappedWaUSDC();
        uint256 fenceBefore = strategy.ringFencedLiquidity();

        vm.warp(startTimestamp + NORMAL + PRE_CALL);
        vm.expectEmit(true, true, true, true, address(vault));
        emit CallFunded(alice, alice, 0, 1, 2);
        vm.prank(alice);
        uint256 obligation = vault.fundCall(false);

        assertEq(obligation, 1);
        assertEq(payerBefore - underlyingAsset.balanceOf(alice), 2);
        assertEq(IERC20(address(notificationVault)).balanceOf(alice) - notificationBefore, 1);
        assertEq(_wrappedWaUSDC() - wrappedBefore, 2);
        assertEq(strategy.ringFencedLiquidity() - fenceBefore, 2);
        assertEq(vault.getEpochState(0).fundedAmount, 1);
        assertEq(vault.getAccount(alice).activeCommitment, 2e6 - 1);
    }

    function testResidualCeilDustAggregateFundingExceedsCall() public {
        _seedUsd3RealPps(100e6, 100e6);
        _deposit(vault, alice, 1e6);
        _deposit(vault, bob, 1e6);

        // Each account owes ceil(2e6 * 3 / 4e6) = 2 base units, so aggregate settlement exceeds the call.
        _openCall(vault, 3);
        uint256 alicePayerBefore = underlyingAsset.balanceOf(alice);
        uint256 aliceObligation = _fund(vault, alice, false);
        uint256 bobPayerBefore = underlyingAsset.balanceOf(bob);
        uint256 bobObligation = _fund(vault, bob, false);

        assertEq(aliceObligation, 2);
        assertEq(bobObligation, 2);
        assertEq(alicePayerBefore - underlyingAsset.balanceOf(alice), 2);
        assertEq(bobPayerBefore - underlyingAsset.balanceOf(bob), 2);
        assertEq(IERC20(address(notificationVault)).balanceOf(alice), 1);
        assertEq(IERC20(address(notificationVault)).balanceOf(bob), 1);

        EpochState memory state = vault.getEpochState(0);
        assertEq(state.callAmount, 3);
        assertEq(state.fundedAmount, 4);
        assertGt(state.fundedAmount, state.callAmount);
    }

    function testAuctionTakeDeliversRealUSD3nAndAwardsMargin() public {
        ILCCVaultLike auctionVault = _newVault(_auctionParams(), true);
        _approveVault(auctionVault, alice);
        _approveVault(auctionVault, bob);
        _approveVault(auctionVault, filler);

        _deposit(auctionVault, alice, 100e6);
        _deposit(auctionVault, bob, 50e6);
        _openCall(auctionVault, 150e6);
        assertEq(_fund(auctionVault, alice, false), 100e6);

        vm.warp(startTimestamp + NORMAL + PRE_CALL + FUNDING);
        auctionVault.finalizeEpochSlash(0);
        vm.warp(startTimestamp + NORMAL + PRE_CALL + FUNDING + 5);

        uint256 payerBefore = underlyingAsset.balanceOf(filler);
        uint256 notificationBefore = IERC20(address(notificationVault)).balanceOf(filler);
        uint256 marginBefore = margin.balanceOf(filler);
        uint256 wrappedBefore = _wrappedWaUSDC();

        vm.prank(filler);
        (uint256 filled, uint256 marginAward) = auctionVault.takeAuction(type(uint256).max, 25e6, type(uint256).max);

        assertEq(filled, 50e6);
        assertEq(marginAward, 25e6);
        assertEq(payerBefore - underlyingAsset.balanceOf(filler), 50e6);
        assertEq(IERC20(address(notificationVault)).balanceOf(filler) - notificationBefore, 50e6);
        assertEq(margin.balanceOf(filler) - marginBefore, 25e6);
        assertEq(_wrappedWaUSDC() - wrappedBefore, 50e6);

        AuctionState memory auction = auctionVault.getAuctionState(0);
        assertEq(auction.shortfallAmount, 50e6);
        assertEq(auction.filledAmount, 50e6);
        assertEq(auction.marginAwarded, 25e6);
    }

    function testSupplyCapExemptionIsLoadBearing() public {
        ILCCVaultLike nonExemptVault = _newVault(_baseParams(), false);
        _approveVault(nonExemptVault, alice);

        assertFalse(strategy.supplyCapExempt(address(nonExemptVault)));
        assertFalse(strategy.ringFenceConduit(address(nonExemptVault)));

        _deposit(nonExemptVault, alice, 100e6);
        _openCall(nonExemptVault, 150e6);
        assertEq(strategy.availableDepositLimit(address(nonExemptVault)), USD3_SUPPLY_CAP);

        uint256 payerBefore = underlyingAsset.balanceOf(alice);
        vm.warp(startTimestamp + NORMAL + PRE_CALL);
        vm.expectRevert(bytes("ERC4626: deposit more than max"));
        vm.prank(alice);
        nonExemptVault.fundCall(false);

        assertEq(underlyingAsset.balanceOf(alice), payerBefore);
        _assertFundingUntouched(nonExemptVault, alice, 200e6);

        vm.prank(management);
        strategy.setSupplyCapExempt(address(nonExemptVault), true);
        vm.prank(alice);
        assertEq(nonExemptVault.fundCall(false), 150e6);

        assertTrue(strategy.supplyCapExempt(address(nonExemptVault)));
        assertEq(IERC20(address(notificationVault)).balanceOf(alice), 150e6);
        assertEq(strategy.ringFencedLiquidity(), 0);
    }

    function testDeliveryFailureUsd3CapZeroRollsBackThenRetrySucceeds() public {
        _deposit(vault, alice, 100e6);
        _openCall(vault, 100e6);
        testProtocolConfig.setConfig(ProtocolConfigLib.USD3_SUPPLY_CAP, 0);

        uint256 payerBefore = underlyingAsset.balanceOf(alice);
        uint256 wrappedBefore = _wrappedWaUSDC();
        uint256 fenceBefore = strategy.ringFencedLiquidity();
        vm.warp(startTimestamp + NORMAL + PRE_CALL);
        vm.expectRevert(bytes("ERC4626: deposit more than max"));
        vm.prank(alice);
        vault.fundCall(false);

        assertEq(underlyingAsset.balanceOf(alice), payerBefore);
        assertEq(_wrappedWaUSDC(), wrappedBefore);
        assertEq(strategy.ringFencedLiquidity(), fenceBefore);
        assertEq(IERC20(address(strategy)).balanceOf(address(vault)), 0);
        _assertFundingUntouched(vault, alice, 200e6);

        testProtocolConfig.setConfig(ProtocolConfigLib.USD3_SUPPLY_CAP, USD3_SUPPLY_CAP);
        vm.prank(alice);
        assertEq(vault.fundCall(false), 100e6);
        assertTrue(vault.fundedEpoch(0, alice));
        assertEq(IERC20(address(notificationVault)).balanceOf(alice), 100e6);
    }

    function testDeliveryFailureNotificationVaultShutdownRollsBackWithoutRetry() public {
        _deposit(vault, alice, 100e6);
        _openCall(vault, 100e6);

        vm.prank(management);
        ITokenizedStrategy(address(notificationVault)).shutdownStrategy();

        uint256 payerBefore = underlyingAsset.balanceOf(alice);
        uint256 totalAssetsBefore = strategy.totalAssets();
        uint256 wrappedBefore = _wrappedWaUSDC();
        uint256 fenceBefore = strategy.ringFencedLiquidity();
        vm.warp(startTimestamp + NORMAL + PRE_CALL);
        vm.expectRevert(bytes("ERC4626: deposit more than max"));
        vm.prank(alice);
        vault.fundCall(false);

        assertEq(underlyingAsset.balanceOf(alice), payerBefore);
        assertEq(strategy.totalAssets(), totalAssetsBefore);
        assertEq(_wrappedWaUSDC(), wrappedBefore);
        assertEq(strategy.ringFencedLiquidity(), fenceBefore);
        assertEq(IERC20(address(strategy)).balanceOf(address(vault)), 0);
        assertEq(IERC20(address(notificationVault)).balanceOf(alice), 0);
        _assertFundingUntouched(vault, alice, 200e6);
    }

    function _deployNotificationVault() internal returns (NotificationVault deployed) {
        NotificationVault implementation = new NotificationVault(address(strategy));
        ProxyAdmin proxyAdmin = new ProxyAdmin(management);
        bytes memory initData =
            abi.encodeCall(NotificationVault.initialize, (management, keeper, uint64(7 days), uint64(2 days)));
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);
        deployed = NotificationVault(address(proxy));
    }

    function _deployLinkedLCCVaultImpl(address notificationVault_, address treasury_)
        internal
        returns (address implementation)
    {
        string memory outDir = vm.envOr("FOUNDRY_OUT", string("out"));
        string memory auctionArtifact = string.concat(outDir, "/LCCAuctionLib.sol/LCCAuctionLib.json");
        string memory configArtifact = string.concat(outDir, "/LCCConfigLib.sol/LCCConfigLib.json");
        string memory vaultArtifact = string.concat(outDir, "/LCCVault.sol/LCCVault.json");

        // Use the explicit artifact path because the LCC size profile emits a second artifact with the same FQN.
        address auctionLibrary = vm.deployCode(auctionArtifact);
        address configLibrary = vm.deployCode(configArtifact);

        // The test profile artifact is via-IR-OFF and non-canonical. The same test exercises the canonical via-IR
        // release settings when it runs under the test-lcc-ir profile.
        string memory artifact = vm.readFile(vaultArtifact);
        string memory hexCode = vm.parseJsonString(artifact, ".bytecode.object");
        string memory auctionPlaceholder = string.concat("__$", _hexN(keccak256(bytes(AUCTION_LIB_FQN)), 17), "$__");
        string memory configPlaceholder = string.concat("__$", _hexN(keccak256(bytes(CONFIG_LIB_FQN)), 17), "$__");
        require(vm.contains(hexCode, auctionPlaceholder), "LCCAuctionLib link placeholder not found");
        require(vm.contains(hexCode, configPlaceholder), "LCCConfigLib link placeholder not found");

        hexCode = vm.replace(hexCode, auctionPlaceholder, _hexAddress(auctionLibrary));
        hexCode = vm.replace(hexCode, configPlaceholder, _hexAddress(configLibrary));
        require(!vm.contains(hexCode, "__$"), "unlinked references remain");

        bytes memory initCode = abi.encodePacked(vm.parseBytes(hexCode), abi.encode(notificationVault_, treasury_));
        assembly ("memory-safe") {
            implementation := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(implementation != address(0), "LCCVault implementation deployment failed");
    }

    function _newVault(VaultParams memory params, bool supplyCapExempt) internal returns (ILCCVaultLike deployed) {
        deployed = ILCCVaultLike(
            address(new BeaconProxy(address(beacon), abi.encodeCall(ILCCVaultLike.initialize, (params))))
        );

        if (supplyCapExempt) {
            vm.prank(management);
            strategy.setSupplyCapExempt(address(deployed), true);
        }

        // Ring fencing of LCC funding is intended: the production deployment runbook MUST call
        // strategy.setRingFenceConduit(vault, true) for each LCC proxy so funder USD3 liquidity is reserved.
        // USD3 only fences when ringFenceConduit[receiver] is true (USD3.sol:530-535); if the deployment omits
        // the registration, funding silently is not fenced (see testUnregisteredConduitsDoNotFence*, a
        // deployment-error guard). LCCMockUSD3 fences unconditionally, which approximates the intended
        // registered behavior modulo the conditional gate.
    }

    function _baseParams() internal view returns (VaultParams memory) {
        return VaultParams({
            owner: lccOwner,
            marginAsset: address(margin),
            marginOracle: address(oracle),
            startTimestamp: startTimestamp,
            maxEpochs: 0,
            epochLength: EPOCH,
            normalDuration: NORMAL,
            preCallDuration: PRE_CALL,
            fundingDuration: FUNDING,
            marginRatioBps: 5_000,
            protocolCommitmentCap: FACILITY_CAP,
            userCommitmentCap: FACILITY_CAP,
            exitCapBps: 2_000,
            exitDelayEpochs: 1,
            minCommitmentEpochs: 0,
            minDepositAssets: 0,
            auctionStepCount: 0,
            auctionStepDecayRateBps: 0,
            maxAuctionAwardBps: 0,
            slashFeeBps: 0
        });
    }

    function _auctionParams() internal view returns (VaultParams memory params) {
        params = _baseParams();
        params.auctionStepCount = 4;
        params.auctionStepDecayRateBps = 5_000;
        params.maxAuctionAwardBps = 10_000;
        params.slashFeeBps = 1_000;
    }

    function _driftTripwireParams() internal view returns (VaultParams memory params) {
        params = VaultParams({
            owner: lccOwner,
            marginAsset: address(margin),
            marginOracle: address(oracle),
            startTimestamp: startTimestamp,
            maxEpochs: 23,
            epochLength: 100,
            normalDuration: 41,
            preCallDuration: 19,
            fundingDuration: 17,
            marginRatioBps: 5_001,
            protocolCommitmentCap: 10_000_019e6,
            userCommitmentCap: 9_000_017e6,
            exitCapBps: 2_001,
            exitDelayEpochs: 2,
            minCommitmentEpochs: 3,
            minDepositAssets: 13,
            auctionStepCount: 4,
            auctionStepDecayRateBps: 4_321,
            maxAuctionAwardBps: 8_765,
            slashFeeBps: 1_234
        });
    }

    function _fundActor(address actor) internal {
        margin.mint(actor, ACTOR_BALANCE);
        airdrop(underlyingAsset, actor, ACTOR_BALANCE);
        _approveVault(vault, actor);
    }

    function _approveVault(ILCCVaultLike target, address actor) internal {
        vm.startPrank(actor);
        margin.approve(address(target), type(uint256).max);
        underlyingAsset.approve(address(target), type(uint256).max);
        vm.stopPrank();
    }

    function _deposit(ILCCVaultLike target, address actor, uint256 amount) internal returns (uint256 commitment) {
        vm.prank(actor);
        commitment = target.deposit(amount, 1, type(uint256).max, true, type(uint256).max);
    }

    function _openCall(ILCCVaultLike target, uint256 amount) internal {
        vm.warp(startTimestamp + NORMAL);
        vm.prank(lccOwner);
        target.openEpochCall(0, amount);
    }

    function _fund(ILCCVaultLike target, address actor, bool roll) internal returns (uint256 obligation) {
        vm.warp(startTimestamp + NORMAL + PRE_CALL);
        vm.prank(actor);
        obligation = target.fundCall(roll);
    }

    function _assertFundingUntouched(ILCCVaultLike target, address actor, uint256 expectedCommitment) internal view {
        assertFalse(target.fundedEpoch(0, actor));
        assertEq(target.getEpochState(0).fundedAmount, 0);
        assertEq(target.getAccount(actor).activeCommitment, expectedCommitment);
    }

    function _assertAccountEq(LCCAccount memory actual, LCCAccount memory expected) internal pure {
        assertEq(actual.activeMargin, expected.activeMargin);
        assertEq(actual.activeCommitment, expected.activeCommitment);
        assertEq(actual.pendingMargin, expected.pendingMargin);
        assertEq(actual.pendingCommitment, expected.pendingCommitment);
        assertEq(actual.pendingActivationEpoch, expected.pendingActivationEpoch);
        assertEq(actual.calledEpochCursor, expected.calledEpochCursor);
        assertEq(actual.claimableExitMargin, expected.claimableExitMargin);
        assertEq(actual.exitBucketMargin, expected.exitBucketMargin);
        assertEq(actual.exitBucketCommitment, expected.exitBucketCommitment);
        assertEq(actual.exitRequested, expected.exitRequested);
        assertEq(actual.exitMaturityEpoch, expected.exitMaturityEpoch);
        assertEq(actual.exitClaimed, expected.exitClaimed);
        assertEq(actual.exitMatured, expected.exitMatured);
        assertEq(actual.commitmentStartEpoch, expected.commitmentStartEpoch);
    }

    function _assertEpochStateEq(EpochState memory actual, EpochState memory expected) internal pure {
        assertEq(actual.callOpened, expected.callOpened);
        assertEq(actual.commitmentDenominator, expected.commitmentDenominator);
        assertEq(actual.callAmount, expected.callAmount);
        assertEq(actual.marginAtCallOpen, expected.marginAtCallOpen);
        assertEq(actual.fundedAmount, expected.fundedAmount);
        assertEq(actual.marginReleased, expected.marginReleased);
        assertEq(actual.fundedUsersRemainingMargin, expected.fundedUsersRemainingMargin);
        assertEq(actual.fundedUsersRemainingCommitment, expected.fundedUsersRemainingCommitment);
        assertEq(actual.slashFinalized, expected.slashFinalized);
        assertEq(actual.slashDisabledByShutdown, expected.slashDisabledByShutdown);
        assertEq(actual.slashedMargin, expected.slashedMargin);
        assertEq(actual.returnPool, expected.returnPool);
        assertEq(actual.returnCommitment, expected.returnCommitment);
    }

    function _assertAuctionStateEq(AuctionState memory actual, AuctionState memory expected) internal pure {
        assertEq(uint256(actual.shortfallAmount), uint256(expected.shortfallAmount));
        assertEq(uint256(actual.filledAmount), uint256(expected.filledAmount));
        assertEq(uint256(actual.marginPool), uint256(expected.marginPool));
        assertEq(uint256(actual.marginAwarded), uint256(expected.marginAwarded));
    }

    function _seedUsd3RealPps(uint256 seedAssets, uint256 profit) internal {
        vm.prank(management);
        strategy.setPerformanceFee(0);
        vm.prank(management);
        strategy.setProfitMaxUnlockTime(0);

        mintAndDepositIntoStrategy(strategy, seeder, seedAssets);
        airdrop(underlyingAsset, address(strategy), profit);
        vm.prank(keeper);
        strategy.report();
    }

    // USD3 deploys at MAX_ON_CREDIT=10_000, so the real delivery assertion includes local and Morpho-held waUSDC.
    function _wrappedWaUSDC() internal view returns (uint256) {
        return usd3.balanceOfWaUSDC() + usd3.suppliedWaUSDC();
    }

    function _hexAddress(address account) internal pure returns (string memory) {
        return vm.replace(vm.toLowercase(vm.toString(account)), "0x", "");
    }

    function _hexN(bytes32 value, uint256 bytesLength) internal pure returns (string memory) {
        bytes memory table = "0123456789abcdef";
        bytes memory output = new bytes(2 * bytesLength);
        for (uint256 i = 0; i < bytesLength; ++i) {
            output[2 * i] = table[uint8(value[i]) >> 4];
            output[2 * i + 1] = table[uint8(value[i]) & 0x0f];
        }
        return string(output);
    }
}
