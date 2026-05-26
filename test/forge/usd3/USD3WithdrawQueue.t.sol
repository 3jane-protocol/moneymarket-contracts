// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.22;

import {ProxyAdmin} from "../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721Receiver} from "../../../lib/openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {USD3} from "../../../src/usd3/USD3.sol";
import {USD3WithdrawQueue} from "../../../src/usd3/queue/USD3WithdrawQueue.sol";
import {Setup} from "./utils/Setup.sol";

contract USD3WithdrawQueueTest is Setup {
    USD3WithdrawQueue public queue;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    bytes32 internal constant ERC1967_ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);

    function setUp() public override {
        super.setUp();

        USD3WithdrawQueue queueImplementation = new USD3WithdrawQueue(address(strategy));
        bytes memory queueInitData = abi.encodeWithSelector(USD3WithdrawQueue.initialize.selector);
        TransparentUpgradeableProxy queueProxy =
            new TransparentUpgradeableProxy(address(queueImplementation), management, queueInitData);
        queue = USD3WithdrawQueue(address(queueProxy));

        USD3 newImplementation = new USD3(address(queue));

        address proxyAdmin = address(uint160(uint256(vm.load(address(strategy), ERC1967_ADMIN_SLOT))));
        address proxyAdminOwner = ProxyAdmin(proxyAdmin).owner();

        vm.prank(proxyAdminOwner);
        ProxyAdmin(proxyAdmin)
            .upgradeAndCall(ITransparentUpgradeableProxy(address(strategy)), address(newImplementation), "");

        assertEq(USD3(address(strategy)).withdrawQueue(), address(queue));

        vm.prank(management);
        queue.setEntriesPaused(false);
    }

    function test_requestRedeemTransfersSharesAndMintsReceipt() public {
        uint256 amount = 1_000e6;
        _depositUnlocked(alice, amount);
        uint256 shares = strategy.balanceOf(alice);

        vm.prank(alice);
        strategy.approve(address(queue), shares);

        vm.prank(alice);
        uint256 requestId = queue.requestRedeem(shares, alice, alice);

        assertEq(requestId, 1);
        assertEq(queue.ownerOf(requestId), alice);
        assertEq(strategy.balanceOf(alice), 0);
        assertEq(strategy.balanceOf(address(queue)), shares);
        assertEq(queue.totalPendingShares(), shares);
        assertEq(queue.pendingShares(requestId), shares);
    }

    function test_requestRedeemRespectsCommitmentGate() public {
        testProtocolConfig.setConfig(keccak256("USD3_COMMITMENT_TIME"), 7 days);

        uint256 amount = 1_000e6;
        mintAndDepositIntoStrategy(strategy, alice, amount);
        uint256 shares = strategy.balanceOf(alice);

        vm.prank(alice);
        strategy.approve(address(queue), shares);

        vm.prank(alice);
        vm.expectRevert("USD3: Cannot transfer during commitment period");
        queue.requestRedeem(shares, alice, alice);
    }

    function test_requestRedeemRejectsInvalidInputs() public {
        _depositUnlocked(alice, 1_000e6);
        uint256 shares = strategy.balanceOf(alice);

        vm.prank(alice);
        strategy.approve(address(queue), shares);

        vm.prank(alice);
        vm.expectRevert(USD3WithdrawQueue.ZeroShares.selector);
        queue.requestRedeem(0, alice, alice);

        vm.prank(alice);
        vm.expectRevert(USD3WithdrawQueue.ZeroReceiver.selector);
        queue.requestRedeem(shares, address(0), alice);

        vm.prank(alice);
        vm.expectRevert(USD3WithdrawQueue.ZeroOwner.selector);
        queue.requestRedeem(shares, alice, address(0));
    }

    function test_requestRedeemRejectsZeroAssetShares() public {
        ZeroPreviewUSD3 fakeUsd3 = new ZeroPreviewUSD3(address(asset), management, emergencyAdmin);
        USD3WithdrawQueue queueImplementation = new USD3WithdrawQueue(address(fakeUsd3));
        bytes memory queueInitData = abi.encodeWithSelector(USD3WithdrawQueue.initialize.selector);
        TransparentUpgradeableProxy queueProxy =
            new TransparentUpgradeableProxy(address(queueImplementation), management, queueInitData);
        USD3WithdrawQueue dustQueue = USD3WithdrawQueue(address(queueProxy));

        vm.prank(management);
        dustQueue.setEntriesPaused(false);

        fakeUsd3.mint(alice, 1);

        vm.prank(alice);
        fakeUsd3.approve(address(dustQueue), 1);

        vm.prank(alice);
        vm.expectRevert(USD3WithdrawQueue.ZeroAssets.selector);
        dustQueue.requestRedeem(1, alice, alice);
    }

    function test_thirdPartyCanRequestWithOwnerApproval() public {
        _depositUnlocked(alice, 1_000e6);
        uint256 shares = strategy.balanceOf(alice);

        vm.prank(alice);
        strategy.approve(address(queue), shares);

        vm.prank(bob);
        uint256 requestId = queue.requestRedeem(shares, bob, alice);

        assertEq(queue.ownerOf(requestId), bob);
        assertEq(strategy.balanceOf(alice), 0);
        assertEq(strategy.balanceOf(address(queue)), shares);
    }

    function test_receiptTransferDoesNotRequireWhitelist() public {
        uint256 requestId = _queueShares(alice, 1_000e6);

        vm.prank(management);
        USD3(address(strategy)).setWhitelistEnabled(true);

        assertFalse(USD3(address(strategy)).whitelist(bob));

        vm.prank(alice);
        queue.transferFrom(alice, bob, requestId);

        assertEq(queue.ownerOf(requestId), bob);
    }

    function test_safeTransferToReceiverContract() public {
        uint256 requestId = _queueShares(alice, 1_000e6);
        ReceiptReceiver receiver = new ReceiptReceiver();

        vm.prank(alice);
        queue.safeTransferFrom(alice, address(receiver), requestId);

        assertEq(queue.ownerOf(requestId), address(receiver));
    }

    function test_safeTransferToUnsafeReceiverReverts() public {
        uint256 requestId = _queueShares(alice, 1_000e6);
        UnsafeReceiptReceiver receiver = new UnsafeReceiptReceiver();

        vm.prank(alice);
        vm.expectRevert();
        queue.safeTransferFrom(alice, address(receiver), requestId);
    }

    function test_processAllocatesFifo() public {
        uint256 requestOne = _queueShares(alice, 700e6);
        uint256 requestTwo = _queueShares(bob, 300e6);

        (uint256 sharesProcessed, uint256 assetsAllocated) = queue.process(2);

        assertEq(
            sharesProcessed,
            queue.requestInfo(requestOne).sharesRequested + queue.requestInfo(requestTwo).sharesRequested
        );
        assertEq(assetsAllocated, 1_000e6);
        assertEq(queue.claimableAssets(requestOne), 700e6);
        assertEq(queue.claimableAssets(requestTwo), 300e6);
        assertEq(queue.queueHead(), 3);
        assertEq(queue.totalPendingShares(), 0);
    }

    function test_partiallyFulfilledHeadBlocksLaterRequests() public {
        _queueShares(alice, 700e6);
        uint256 requestTwo = _queueShares(bob, 300e6);

        _removeIdleUsdc(500e6);

        queue.process(2);

        assertEq(queue.queueHead(), 1);
        assertEq(queue.pendingShares(1), 200e6);
        assertEq(queue.claimableAssets(1), 500e6);
        assertEq(queue.claimableAssets(requestTwo), 0);
        assertEq(queue.pendingShares(requestTwo), 300e6);
    }

    function test_fullyFundedUnclaimedHeadDoesNotBlock() public {
        uint256 requestOne = _queueShares(alice, 400e6);
        uint256 requestTwo = _queueShares(bob, 600e6);

        queue.process(1);
        assertEq(queue.queueHead(), 2);
        assertEq(queue.claimableAssets(requestOne), 400e6);

        queue.process(1);
        assertEq(queue.queueHead(), 3);
        assertEq(queue.claimableAssets(requestTwo), 600e6);
    }

    function test_processBoundsStaleHeadWalk() public {
        USD3WithdrawQueueHarness harness = new USD3WithdrawQueueHarness(address(strategy));
        _depositUnlocked(address(harness), 1_000e6);
        harness.seedCursor(1, 4);
        harness.seedRequest(3, 1_000e6, 1_000e6);

        (uint256 sharesProcessed, uint256 assetsAllocated) = harness.process(1);
        assertEq(sharesProcessed, 0);
        assertEq(assetsAllocated, 0);
        assertEq(harness.queueHead(), 2);

        (sharesProcessed, assetsAllocated) = harness.process(1);
        assertEq(sharesProcessed, 0);
        assertEq(assetsAllocated, 0);
        assertEq(harness.queueHead(), 3);

        (sharesProcessed, assetsAllocated) = harness.process(1);
        assertEq(sharesProcessed, 1_000e6);
        assertEq(assetsAllocated, 1_000e6);
        assertEq(harness.queueHead(), 4);
    }

    function test_claimPaysAndBurnsFullyFulfilledReceipt() public {
        uint256 requestId = _queueShares(alice, 1_000e6);
        queue.process(1);

        uint256 balanceBefore = asset.balanceOf(bob);

        vm.prank(alice);
        uint256 claimed = queue.claim(requestId, bob);

        assertEq(claimed, 1_000e6);
        assertEq(asset.balanceOf(bob) - balanceBefore, 1_000e6);
        assertEq(queue.claimableAssets(requestId), 0);
        vm.expectRevert();
        queue.ownerOf(requestId);
    }

    function test_approvedOperatorCanClaim() public {
        uint256 requestId = _queueShares(alice, 1_000e6);
        queue.process(1);

        vm.prank(alice);
        queue.approve(bob, requestId);

        vm.prank(bob);
        uint256 claimed = queue.claim(requestId, bob);

        assertEq(claimed, 1_000e6);
        assertEq(asset.balanceOf(bob), 1_000e6);
    }

    function test_claimRejectsZeroReceiver() public {
        uint256 requestId = _queueShares(alice, 1_000e6);
        queue.process(1);

        vm.prank(alice);
        vm.expectRevert(USD3WithdrawQueue.ZeroReceiver.selector);
        queue.claim(requestId, address(0));
    }

    function test_partialClaimLeavesReceiptAlive() public {
        uint256 requestId = _queueShares(alice, 1_000e6);
        _removeIdleUsdc(500e6);
        queue.process(1);

        vm.prank(alice);
        queue.claim(requestId, alice);

        assertEq(queue.ownerOf(requestId), alice);
        assertEq(queue.pendingShares(requestId), 500e6);
        assertEq(queue.claimableAssets(requestId), 0);
    }

    function test_reclaimBurnedReceiptReverts() public {
        uint256 requestId = _queueShares(alice, 1_000e6);
        queue.process(1);

        vm.prank(alice);
        queue.claim(requestId, alice);

        vm.prank(alice);
        vm.expectRevert();
        queue.claim(requestId, alice);
    }

    function test_processAndClaimProcessesThenClaims() public {
        uint256 requestId = _queueShares(alice, 1_000e6);

        vm.prank(alice);
        uint256 claimed = queue.processAndClaim(requestId, alice, 1);

        assertEq(claimed, 1_000e6);
        assertEq(asset.balanceOf(alice), 1_000e6);
        assertEq(queue.totalPendingShares(), 0);
    }

    function test_processWithNoLiquidityReturnsZero() public {
        _queueShares(alice, 1_000e6);
        _removeIdleUsdc(1_000e6);

        (uint256 sharesProcessed, uint256 assetsAllocated) = queue.process(1);

        assertEq(sharesProcessed, 0);
        assertEq(assetsAllocated, 0);
    }

    function test_directRedeemNeverEnqueues() public {
        _depositUnlocked(alice, 1_000e6);
        uint256 shares = strategy.balanceOf(alice);

        vm.prank(alice);
        strategy.redeem(shares, alice, alice);

        assertEq(queue.nextRequestId(), 1);
        assertEq(queue.totalPendingShares(), 0);
    }

    function test_reservationReducesOrdinaryLimitsWithoutBinaryCliff() public {
        _queueShares(alice, 700e6);
        _depositUnlocked(bob, 300e6);

        assertEq(strategy.maxWithdraw(bob), 300e6);
        assertEq(strategy.maxRedeem(bob), 300e6);
        assertEq(strategy.maxRedeem(address(queue)), 700e6);
    }

    function test_reservationCanExhaustOrdinaryLiquidity() public {
        _queueShares(alice, 700e6);
        _depositUnlocked(bob, 300e6);
        _removeIdleUsdc(300e6);

        assertEq(strategy.maxWithdraw(bob), 0);
        assertEq(strategy.maxRedeem(bob), 0);
        assertEq(strategy.maxRedeem(address(queue)), 700e6);
    }

    function test_shutdownKeepsQueueReservationButAllowsQueueEntryDisabled() public {
        _queueShares(alice, 700e6);
        _depositUnlocked(bob, 300e6);
        _removeIdleUsdc(300e6);

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertEq(strategy.maxWithdraw(bob), 0);
        assertEq(strategy.maxRedeem(address(queue)), 700e6);

        vm.prank(bob);
        strategy.approve(address(queue), 300e6);

        vm.prank(bob);
        vm.expectRevert(USD3WithdrawQueue.Shutdown.selector);
        queue.requestRedeem(300e6, bob, bob);

        queue.process(1);
        assertEq(queue.claimableAssets(1), 700e6);

        vm.prank(alice);
        assertEq(queue.claim(1, alice), 700e6);
    }

    function test_entriesPausedOnlyBlocksRequests() public {
        uint256 requestId = _queueShares(alice, 1_000e6);

        vm.prank(management);
        queue.setEntriesPaused(true);

        _depositUnlocked(bob, 100e6);
        vm.prank(bob);
        strategy.approve(address(queue), 100e6);

        vm.prank(bob);
        vm.expectRevert(USD3WithdrawQueue.QueuePaused.selector);
        queue.requestRedeem(100e6, bob, bob);

        queue.process(1);

        vm.prank(alice);
        assertEq(queue.claim(requestId, alice), 1_000e6);
    }

    function test_setEntriesPausedRejectsUnauthorizedCaller() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(USD3WithdrawQueue.Unauthorized.selector, alice));
        queue.setEntriesPaused(true);
    }

    function test_reservationRoundsTowardQueue() public {
        _depositUnlocked(alice, 1e6);
        _depositUnlocked(bob, 10e6);
        airdrop(asset, address(strategy), 1);
        vm.prank(keeper);
        strategy.report();
        vm.warp(block.timestamp + strategy.profitMaxUnlockTime() + 1);

        vm.prank(alice);
        strategy.approve(address(queue), 1);

        vm.prank(alice);
        queue.requestRedeem(1, alice, alice);

        uint256 totalAssets = strategy.totalAssets();
        uint256 totalSupply = strategy.totalSupply();
        uint256 reservedAssets = (1 * totalAssets + totalSupply - 1) / totalSupply;
        uint256 availableWithoutReservation = USD3(address(strategy)).availableWithdrawLimit(address(queue));

        assertEq(reservedAssets, 2);
        assertEq(USD3(address(strategy)).availableWithdrawLimit(bob), availableWithoutReservation - reservedAssets);
    }

    function test_receiptValueFloatsWithPpsBeforeFulfillment() public {
        uint256 requestId = _queueShares(alice, 1_000e6);

        waUSDC.simulateYield(1000);
        airdrop(asset, address(waUSDC), 100e6);
        vm.prank(keeper);
        strategy.report();
        vm.warp(block.timestamp + strategy.profitMaxUnlockTime() + 1);

        queue.process(1);

        assertGt(queue.claimableAssets(requestId), 1_000e6);
    }

    function _queueShares(address owner, uint256 assets) internal returns (uint256 requestId) {
        _depositUnlocked(owner, assets);
        uint256 shares = strategy.balanceOf(owner);

        vm.prank(owner);
        strategy.approve(address(queue), shares);

        vm.prank(owner);
        requestId = queue.requestRedeem(shares, owner, owner);
    }

    function _depositUnlocked(address owner, uint256 assets) internal {
        mintAndDepositIntoStrategy(strategy, owner, assets);
        vm.warp(block.timestamp + USD3(address(strategy)).minCommitmentTime() + 1);
    }

    function _removeIdleUsdc(uint256 amount) internal {
        createMarketDebt(charlie, amount);
    }
}

contract USD3WithdrawQueueHarness is USD3WithdrawQueue {
    constructor(address usd3_) USD3WithdrawQueue(usd3_) {}

    function seedCursor(uint256 head, uint256 nextRequest) external {
        _queueHead = head;
        _nextRequestId = nextRequest;
    }

    function seedRequest(uint256 requestId, uint256 sharesRequested, uint256 sharesRemaining) external {
        _requests[requestId] = Request({
            sharesRequested: sharesRequested,
            sharesRemaining: sharesRemaining,
            claimableAssets: 0,
            claimedAssets: 0,
            createdAt: block.timestamp
        });
        totalPendingShares += sharesRemaining;
    }
}

contract ReceiptReceiver is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract UnsafeReceiptReceiver {}

contract ZeroPreviewUSD3 is ERC20 {
    address private immutable _asset;
    address private immutable _management;
    address private immutable _emergencyAdmin;

    constructor(address asset_, address management_, address emergencyAdmin_) ERC20("Zero Preview USD3", "zUSD3") {
        _asset = asset_;
        _management = management_;
        _emergencyAdmin = emergencyAdmin_;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function isShutdown() external pure returns (bool) {
        return false;
    }

    function previewRedeem(uint256) external pure returns (uint256) {
        return 0;
    }

    function maxRedeem(address owner) external view returns (uint256) {
        return balanceOf(owner);
    }

    function redeem(uint256, address, address, uint256) external pure returns (uint256) {
        revert("unused");
    }

    function management() external view returns (address) {
        return _management;
    }

    function emergencyAdmin() external view returns (address) {
        return _emergencyAdmin;
    }
}
