// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {IERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "../../../lib/openzeppelin/contracts/utils/math/SafeCast.sol";

import {LCCMockNotificationVault, LCCMockToken, LCCMockUSD3} from "./LCCBase.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCAuctionLib} from "../../../src/lcc/libraries/LCCAuctionLib.sol";
import {LCCTypesLib} from "../../../src/lcc/libraries/LCCTypesLib.sol";
import {BPS} from "../../../src/libraries/ConstantsLib.sol";

contract LCCTypesHarness is LCCVault {
    LCCTypesLib.Bucket internal bucket;
    LCCTypesLib.ExitExposure internal exitExposure;
    LCCAuctionLib.AuctionState internal auctionState;

    constructor(address notificationVault_, address treasury_) LCCVault(notificationVault_, treasury_) {}

    function storeLoad(ILCCVault.Account memory account) external returns (ILCCVault.Account memory) {
        _storeAccount(msg.sender, account);
        return _loadAccount(msg.sender);
    }

    function storeLoadBucket(LCCTypesLib.Bucket memory value) external returns (LCCTypesLib.Bucket memory) {
        bucket = value;
        return bucket;
    }

    function storeLoadExitExposure(LCCTypesLib.ExitExposure memory value)
        external
        returns (LCCTypesLib.ExitExposure memory)
    {
        exitExposure = value;
        return exitExposure;
    }

    function storeLoadAuctionState(LCCAuctionLib.AuctionState memory value)
        external
        returns (LCCAuctionLib.AuctionState memory)
    {
        auctionState = value;
        return auctionState;
    }

    function increaseBucket(uint256 margin, uint256 commitment) external {
        _increaseBucket(bucket, margin, commitment);
    }

    function applyFillOn(LCCAuctionLib.AuctionState memory seed, uint256 fillAmount, uint256 price)
        external
        returns (uint256)
    {
        auctionState = seed;
        return LCCAuctionLib.applyFill(auctionState, fillAmount, 1, 1, 1, BPS, price);
    }
}

contract LCCTypesRoundTripTest is Test {
    LCCTypesHarness internal harness;

    function setUp() public {
        LCCMockToken usdc = new LCCMockToken("USD Coin", "USDC");
        LCCMockUSD3 usd3 = new LCCMockUSD3(IERC20(address(usdc)));
        LCCMockNotificationVault notificationVault = new LCCMockNotificationVault(IERC20(address(usd3)));
        harness = new LCCTypesHarness(address(notificationVault), makeAddr("treasury"));
    }

    function testFuzzAccountStoreLoadRoundTrips(
        uint128[7] memory amounts,
        uint64[4] memory epochs,
        bool[3] memory flags
    ) public {
        ILCCVault.Account memory account = _account(amounts, epochs, flags);

        ILCCVault.Account memory loaded = harness.storeLoad(account);

        _assertAccountEq(loaded, account);
    }

    function testFuzzBucketStoreLoadRoundTrips(uint128 margin, uint128 commitment) public {
        LCCTypesLib.Bucket memory value = LCCTypesLib.Bucket({margin: margin, commitment: commitment});

        LCCTypesLib.Bucket memory loaded = harness.storeLoadBucket(value);

        assertEq(loaded.margin, value.margin);
        assertEq(loaded.commitment, value.commitment);
    }

    function testFuzzExitExposureStoreLoadRoundTrips(uint128[6] memory amounts, bool listed) public {
        LCCTypesLib.ExitExposure memory value = LCCTypesLib.ExitExposure({
            margin: amounts[0],
            commitment: amounts[1],
            fundedAmount: amounts[2],
            marginReleased: amounts[3],
            fundedUsersRemainingMargin: amounts[4],
            fundedUsersRemainingCommitment: amounts[5],
            listed: listed
        });

        LCCTypesLib.ExitExposure memory loaded = harness.storeLoadExitExposure(value);

        assertEq(loaded.margin, value.margin);
        assertEq(loaded.commitment, value.commitment);
        assertEq(loaded.fundedAmount, value.fundedAmount);
        assertEq(loaded.marginReleased, value.marginReleased);
        assertEq(loaded.fundedUsersRemainingMargin, value.fundedUsersRemainingMargin);
        assertEq(loaded.fundedUsersRemainingCommitment, value.fundedUsersRemainingCommitment);
        assertEq(loaded.listed, value.listed);
    }

    function testFuzzAuctionStateStoreLoadRoundTrips(uint128[4] memory amounts) public {
        LCCAuctionLib.AuctionState memory value = LCCAuctionLib.AuctionState({
            shortfallAmount: amounts[0], filledAmount: amounts[1], marginPool: amounts[2], marginAwarded: amounts[3]
        });

        LCCAuctionLib.AuctionState memory loaded = harness.storeLoadAuctionState(value);

        assertEq(loaded.shortfallAmount, value.shortfallAmount);
        assertEq(loaded.filledAmount, value.filledAmount);
        assertEq(loaded.marginPool, value.marginPool);
        assertEq(loaded.marginAwarded, value.marginAwarded);
    }

    function testFuzzBucketIncrementRevertsPastUint128(uint128 seedMargin, uint128 seedCommitment) public {
        harness.storeLoadBucket(LCCTypesLib.Bucket({margin: seedMargin, commitment: seedCommitment}));
        uint256 overwideMargin = uint256(type(uint128).max) - seedMargin + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.SafeCastOverflowedUintDowncast.selector, 128, uint256(seedMargin) + overwideMargin
            )
        );
        harness.increaseBucket(overwideMargin, 0);
    }

    function testFuzzApplyFillRevertsPastUint128Filled(uint128 seedFilled) public {
        LCCAuctionLib.AuctionState memory seed = LCCAuctionLib.AuctionState({
            shortfallAmount: type(uint128).max, filledAmount: seedFilled, marginPool: 0, marginAwarded: 0
        });
        uint256 overwideFill = uint256(type(uint128).max) - seedFilled + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.SafeCastOverflowedUintDowncast.selector, 128, uint256(seedFilled) + overwideFill
            )
        );
        harness.applyFillOn(seed, overwideFill, 1e36);
    }

    function testFuzzStoreLoadRevertsOnOverwideAmount(
        uint128[7] memory amounts,
        uint64[4] memory epochs,
        bool[3] memory flags,
        uint256 field
    ) public {
        ILCCVault.Account memory account = _account(amounts, epochs, flags);
        uint256 overwide = uint256(type(uint128).max) + 1;
        field = bound(field, 0, 6);
        if (field == 0) account.activeMargin = overwide;
        if (field == 1) account.activeCommitment = overwide;
        if (field == 2) account.pendingMargin = overwide;
        if (field == 3) account.pendingCommitment = overwide;
        if (field == 4) account.claimableExitMargin = overwide;
        if (field == 5) account.exitBucketMargin = overwide;
        if (field == 6) account.exitBucketCommitment = overwide;

        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, overwide));
        harness.storeLoad(account);
    }

    function testFuzzStoreLoadRevertsOnOverwideEpoch(
        uint128[7] memory amounts,
        uint64[4] memory epochs,
        bool[3] memory flags,
        uint256 field
    ) public {
        ILCCVault.Account memory account = _account(amounts, epochs, flags);
        uint256 overwide = uint256(type(uint64).max) + 1;
        field = bound(field, 0, 3);
        if (field == 0) account.pendingActivationEpoch = overwide;
        if (field == 1) account.calledEpochCursor = overwide;
        if (field == 2) account.exitMaturityEpoch = overwide;
        if (field == 3) account.commitmentStartEpoch = overwide;

        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 64, overwide));
        harness.storeLoad(account);
    }

    function _account(uint128[7] memory amounts, uint64[4] memory epochs, bool[3] memory flags)
        internal
        pure
        returns (ILCCVault.Account memory)
    {
        return ILCCVault.Account({
            activeMargin: amounts[0],
            activeCommitment: amounts[1],
            pendingMargin: amounts[2],
            pendingCommitment: amounts[3],
            pendingActivationEpoch: epochs[0],
            calledEpochCursor: epochs[1],
            claimableExitMargin: amounts[4],
            exitBucketMargin: amounts[5],
            exitBucketCommitment: amounts[6],
            exitRequested: flags[0],
            exitMaturityEpoch: epochs[2],
            exitClaimed: flags[1],
            exitMatured: flags[2],
            commitmentStartEpoch: epochs[3]
        });
    }

    function _assertAccountEq(ILCCVault.Account memory left, ILCCVault.Account memory right) internal pure {
        assertEq(left.activeMargin, right.activeMargin);
        assertEq(left.activeCommitment, right.activeCommitment);
        assertEq(left.pendingMargin, right.pendingMargin);
        assertEq(left.pendingCommitment, right.pendingCommitment);
        assertEq(left.pendingActivationEpoch, right.pendingActivationEpoch);
        assertEq(left.calledEpochCursor, right.calledEpochCursor);
        assertEq(left.claimableExitMargin, right.claimableExitMargin);
        assertEq(left.exitBucketMargin, right.exitBucketMargin);
        assertEq(left.exitBucketCommitment, right.exitBucketCommitment);
        assertEq(left.exitRequested, right.exitRequested);
        assertEq(left.exitMaturityEpoch, right.exitMaturityEpoch);
        assertEq(left.exitClaimed, right.exitClaimed);
        assertEq(left.exitMatured, right.exitMatured);
        assertEq(left.commitmentStartEpoch, right.commitmentStartEpoch);
    }
}
