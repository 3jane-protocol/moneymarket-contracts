// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test} from "../../../lib/forge-std/src/Test.sol";

import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCConfigLib} from "../../../src/lcc/libraries/LCCConfigLib.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {BPS} from "../../../src/libraries/ConstantsLib.sol";

contract LCCConfigHarness {
    function validate(ILCCVault.VaultParams memory params) external pure {
        LCCConfigLib.validate(params);
    }

    function auctionStepDuration(ILCCVault.VaultParams memory params) external pure returns (uint256) {
        return LCCConfigLib.auctionStepDuration(params);
    }
}

contract LCCConfigLibTest is Test {
    uint256 internal constant START = 1_000;
    uint256 internal constant MIN_EXIT_CAP_BPS = 313;
    uint256 internal constant MAX_EXIT_DELAY_EPOCHS = 64;
    uint256 internal constant MAX_EPOCH_LENGTH = 30 days;
    uint256 internal constant MIN_PROTOCOL_CAP = 4_000_000e18;
    uint256 internal constant MAX_PROTOCOL_CAP = 100_000_000e18;
    uint256 internal constant MIN_USER_CAP = 1_000_000e18;

    address internal owner = makeAddr("owner");
    address internal margin = makeAddr("margin");
    address internal oracle = makeAddr("oracle");
    LCCConfigHarness internal validator = new LCCConfigHarness();

    struct ParamSeed {
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
        uint256 auctionMode;
        uint256 auctionStepCount;
        uint256 auctionStepDecayRateBps;
        uint256 maxAuctionAwardBps;
        uint256 slashFeeBps;
    }

    function testFuzzValidateAcceptsBoundedParams(ParamSeed memory seed) public view {
        ILCCVault.VaultParams memory params = _boundParams(seed);

        validator.validate(params);
    }

    function testFuzzAuctionStepDurationDerivedFromClosedWindow(ParamSeed memory seed) public view {
        seed.auctionMode = 1;
        seed.epochLength = bound(seed.epochLength, 5, MAX_EPOCH_LENGTH);
        ILCCVault.VaultParams memory params = _boundParams(seed);

        uint256 closedWindow =
            params.epochLength - params.normalDuration - params.preCallDuration - params.fundingDuration;
        uint256 stepDuration = validator.auctionStepDuration(params);

        assertGe(stepDuration, 1);
        assertLe(params.auctionStepCount * stepDuration, closedWindow);
    }

    function testFuzzValidateRejectsZeroAddresses(ParamSeed memory seed, uint256 field) public {
        ILCCVault.VaultParams memory params = _boundParams(seed);
        field = bound(field, 0, 2);
        if (field == 0) params.owner = address(0);
        if (field == 1) params.marginAsset = address(0);
        if (field == 2) params.marginOracle = address(0);

        vm.expectRevert(LCCErrorsLib.ZeroAddress.selector);
        validator.validate(params);
    }

    function testFuzzValidateRejectsWidthOverflow(ParamSeed memory seed, uint256 field) public {
        ILCCVault.VaultParams memory params = _boundParams(seed);
        field = bound(field, 0, 5);
        if (field == 0) params.startTimestamp = uint256(type(uint64).max) + 1;
        if (field == 1) params.maxEpochs = uint256(type(uint64).max) + 1;
        if (field == 2) params.epochLength = uint256(type(uint32).max) + 1;
        if (field == 3) params.normalDuration = uint256(type(uint32).max) + 1;
        if (field == 4) params.preCallDuration = uint256(type(uint32).max) + 1;
        if (field == 5) params.fundingDuration = uint256(type(uint32).max) + 1;

        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        validator.validate(params);
    }

    function testFuzzValidateRejectsInvalidPhaseDurations(ParamSeed memory seed, uint256 field) public {
        ILCCVault.VaultParams memory params = _boundParams(seed);
        field = bound(field, 0, 3);
        if (field == 0) params.normalDuration = 0;
        if (field == 1) params.preCallDuration = 0;
        if (field == 2) params.fundingDuration = 0;
        if (field == 3) {
            params.auctionStepCount = 0;
            params.auctionStepDecayRateBps = 0;
            params.maxAuctionAwardBps = 0;
            params.slashFeeBps = 0;
            params.normalDuration = params.epochLength;
        }

        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        validator.validate(params);
    }

    function testFuzzValidateRejectsInvalidCapsAndRatios(ParamSeed memory seed, uint256 field) public {
        ILCCVault.VaultParams memory params = _boundParams(seed);
        field = bound(field, 0, 5);
        if (field == 0) params.marginRatioBps = 0;
        if (field == 1) params.marginRatioBps = BPS + 1;
        if (field == 2) params.protocolCommitmentCap = 0;
        if (field == 3) params.userCommitmentCap = 0;
        if (field == 4) params.protocolCommitmentCap = uint256(type(uint128).max) + 1;
        if (field == 5) params.exitCapBps = BPS + 1;

        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        validator.validate(params);
    }

    function testFuzzValidateRejectsInvalidExitConfig(ParamSeed memory seed, uint256 field) public {
        ILCCVault.VaultParams memory params = _boundParams(seed);
        field = bound(field, 0, 3);
        if (field == 0) params.exitCapBps = MIN_EXIT_CAP_BPS - 1;
        if (field == 1) params.exitDelayEpochs = 0;
        if (field == 2) params.exitDelayEpochs = MAX_EXIT_DELAY_EPOCHS + 1;
        if (field == 3) params.minCommitmentEpochs = MAX_EXIT_DELAY_EPOCHS + 1;

        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        validator.validate(params);
    }

    function testFuzzValidateRejectsDisabledAuctionOnlyFields(ParamSeed memory seed, uint256 field) public {
        ILCCVault.VaultParams memory params = _boundParams(seed);
        params.auctionStepCount = 0;
        params.auctionStepDecayRateBps = 0;
        params.maxAuctionAwardBps = 0;
        params.slashFeeBps = 0;

        field = bound(field, 0, 2);
        if (field == 0) params.auctionStepDecayRateBps = 1;
        if (field == 1) params.maxAuctionAwardBps = 1;
        if (field == 2) params.slashFeeBps = 1;

        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        validator.validate(params);
    }

    function testFuzzValidateRejectsOneStepAuction(ParamSeed memory seed) public {
        ILCCVault.VaultParams memory params = _auctionParams(seed);
        params.auctionStepCount = 1;

        _expectInvalidParams(params);
    }

    function testFuzzValidateRejectsZeroAuctionDecay(ParamSeed memory seed) public {
        ILCCVault.VaultParams memory params = _auctionParams(seed);
        params.auctionStepDecayRateBps = 0;

        _expectInvalidParams(params);
    }

    function testFuzzValidateRejectsHighAuctionDecay(ParamSeed memory seed) public {
        ILCCVault.VaultParams memory params = _auctionParams(seed);
        params.auctionStepDecayRateBps = BPS + 1;

        _expectInvalidParams(params);
    }

    function testFuzzValidateRejectsHighAuctionAwardCap(ParamSeed memory seed) public {
        ILCCVault.VaultParams memory params = _auctionParams(seed);
        params.maxAuctionAwardBps = BPS + 1;

        _expectInvalidParams(params);
    }

    function testFuzzValidateRejectsAuctionWithoutClosedWindow(ParamSeed memory seed) public {
        ILCCVault.VaultParams memory params = _auctionParams(seed);
        params.normalDuration = params.epochLength - params.preCallDuration - params.fundingDuration;

        _expectInvalidParams(params);
    }

    function testFuzzValidateRejectsAuctionStepCountAboveClosedWindow(ParamSeed memory seed) public {
        ILCCVault.VaultParams memory params = _auctionParams(seed);
        uint256 closedWindow =
            params.epochLength - params.normalDuration - params.preCallDuration - params.fundingDuration;
        params.auctionStepCount = closedWindow + 1;

        _expectInvalidParams(params);
    }

    function _boundParams(ParamSeed memory seed) internal view returns (ILCCVault.VaultParams memory params) {
        // Keep this in sync with LCCLifecycleFuzz.t.sol's _boundParams copy.
        params = _baseParams();
        params.epochLength = bound(seed.epochLength, 4, MAX_EPOCH_LENGTH);
        bool auctionEnabled = seed.auctionMode % 2 == 1 && params.epochLength >= 5;
        (params.normalDuration, params.preCallDuration, params.fundingDuration) =
            _boundPhaseDurations(seed, params.epochLength, auctionEnabled);
        params.marginRatioBps = bound(seed.marginRatioBps, 1, BPS);
        params.protocolCommitmentCap = bound(seed.protocolCommitmentCap, MIN_PROTOCOL_CAP, MAX_PROTOCOL_CAP);
        params.userCommitmentCap = bound(seed.userCommitmentCap, MIN_USER_CAP, params.protocolCommitmentCap);
        params.exitCapBps = bound(seed.exitCapBps, MIN_EXIT_CAP_BPS, BPS);
        params.exitDelayEpochs = bound(seed.exitDelayEpochs, 1, MAX_EXIT_DELAY_EPOCHS);
        params.minCommitmentEpochs = bound(seed.minCommitmentEpochs, 0, MAX_EXIT_DELAY_EPOCHS);
        params.minDepositAssets = bound(seed.minDepositAssets, 0, 1e18);

        if (auctionEnabled) {
            uint256 closedWindow =
                params.epochLength - params.normalDuration - params.preCallDuration - params.fundingDuration;
            params.auctionStepCount = bound(seed.auctionStepCount, 2, closedWindow);
            params.auctionStepDecayRateBps = bound(seed.auctionStepDecayRateBps, 1, BPS);
            params.maxAuctionAwardBps = bound(seed.maxAuctionAwardBps, 1, BPS);
            params.slashFeeBps = bound(seed.slashFeeBps, 0, BPS);
        } else {
            params.auctionStepCount = 0;
            params.auctionStepDecayRateBps = 0;
            params.maxAuctionAwardBps = 0;
            params.slashFeeBps = 0;
        }
    }

    function _auctionParams(ParamSeed memory seed) internal view returns (ILCCVault.VaultParams memory params) {
        seed.auctionMode = 1;
        seed.epochLength = bound(seed.epochLength, 5, MAX_EPOCH_LENGTH);
        params = _boundParams(seed);
    }

    function _expectInvalidParams(ILCCVault.VaultParams memory params) internal {
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        validator.validate(params);
    }

    function _boundPhaseDurations(ParamSeed memory seed, uint256 epochLength, bool auctionEnabled)
        internal
        view
        returns (uint256 normal, uint256 preCall, uint256 funding)
    {
        uint256 phaseBudget = auctionEnabled ? epochLength - 2 : epochLength;
        normal = bound(seed.normalDuration, 1, phaseBudget - 2);
        preCall = bound(seed.preCallDuration, 1, phaseBudget - normal - 1);
        funding = bound(seed.fundingDuration, 1, phaseBudget - normal - preCall);
    }

    function _baseParams() internal view returns (ILCCVault.VaultParams memory) {
        return ILCCVault.VaultParams({
            owner: owner,
            marginAsset: margin,
            marginOracle: oracle,
            startTimestamp: START,
            maxEpochs: 0,
            epochLength: 100,
            normalDuration: 40,
            preCallDuration: 20,
            fundingDuration: 20,
            marginRatioBps: 5_000,
            protocolCommitmentCap: MIN_PROTOCOL_CAP,
            userCommitmentCap: MIN_USER_CAP,
            exitCapBps: MIN_EXIT_CAP_BPS,
            exitDelayEpochs: 1,
            minCommitmentEpochs: 0,
            minDepositAssets: 0,
            auctionStepCount: 0,
            auctionStepDecayRateBps: 0,
            maxAuctionAwardBps: 0,
            slashFeeBps: 0
        });
    }
}
