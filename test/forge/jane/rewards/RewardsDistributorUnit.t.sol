// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {RewardsDistributorSetup} from "./utils/RewardsDistributorSetup.sol";
import {RewardsDistributor} from "../../../../src/jane/RewardsDistributor.sol";
import {MerkleTreeHelper} from "./mocks/MerkleTreeHelper.sol";
import {Jane} from "../../../../src/jane/Jane.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RewardsDistributorUnitTest is RewardsDistributorSetup {
    function setUp() public override {
        super.setUp();
    }

    /// @notice Test constructor sets correct values
    function test_constructor() public view {
        assertEq(address(distributor.jane()), address(token));
        assertEq(distributor.owner(), owner);
        assertFalse(distributor.useMint());
        assertEq(distributor.merkleRoot(), bytes32(0));
    }

    /// @notice Test updateRoot success
    function test_updateRoot_success() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root,) = merkleHelper.generateMerkleTree(claims);

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit RootUpdated(bytes32(0), root);
        distributor.updateRoot(root);

        assertEq(distributor.merkleRoot(), root);
    }

    /// @notice Test only owner can update root
    function test_updateRoot_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        distributor.updateRoot(bytes32(uint256(1)));
    }

    /// @notice Test basic claim success
    function test_claim_success() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        vm.expectEmit(true, false, false, true);
        emit Claimed(alice, 100e18, 100e18);

        distributor.claim(alice, 100e18, proofs[0]);

        assertEq(token.balanceOf(alice), 100e18);
        assertEq(distributor.claimed(alice), 100e18);
    }

    /// @notice Test anyone can call claim for any user
    function test_claim_anyoneCanCall() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        // Bob claims for Alice
        vm.prank(bob);
        distributor.claim(alice, 100e18, proofs[0]);

        // Tokens go to Alice
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(bob), 0);
    }

    /// @notice Test claim reverts with invalid proof
    function test_claim_invalidProof() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        // Try with wrong amount
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        distributor.claim(alice, 200e18, proofs[0]);
    }

    /// @notice Test claim reverts when nothing to claim
    function test_claim_nothingToClaim() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        // First claim succeeds
        distributor.claim(alice, 100e18, proofs[0]);

        // Second claim with same allocation reverts
        vm.expectRevert(RewardsDistributor.NothingToClaim.selector);
        distributor.claim(alice, 100e18, proofs[0]);
    }

    /// @notice Test allocation increases work correctly
    function test_claim_allocationIncreases() public {
        // Week 1: alice = 100
        MerkleTreeHelper.Claim[] memory claims1 = new MerkleTreeHelper.Claim[](1);
        claims1[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root1, bytes32[][] memory proofs1) = updateRoot(claims1);

        distributor.claim(alice, 100e18, proofs1[0]);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(distributor.claimed(alice), 100e18);

        // Week 2: alice = 250
        MerkleTreeHelper.Claim[] memory claims2 = new MerkleTreeHelper.Claim[](1);
        claims2[0] = MerkleTreeHelper.Claim(alice, 250e18);
        (bytes32 root2, bytes32[][] memory proofs2) = updateRoot(claims2);

        distributor.claim(alice, 250e18, proofs2[0]);
        assertEq(token.balanceOf(alice), 250e18);
        assertEq(distributor.claimed(alice), 250e18);
    }

    /// @notice Test allocation decrease (claimed > new allocation)
    function test_claim_allocationDecreases() public {
        // Alice allocated 500, claims all
        MerkleTreeHelper.Claim[] memory claims1 = new MerkleTreeHelper.Claim[](1);
        claims1[0] = MerkleTreeHelper.Claim(alice, 500e18);
        (bytes32 root1, bytes32[][] memory proofs1) = updateRoot(claims1);

        distributor.claim(alice, 500e18, proofs1[0]);
        assertEq(distributor.claimed(alice), 500e18);

        // Root updated: Alice reduced to 200
        MerkleTreeHelper.Claim[] memory claims2 = new MerkleTreeHelper.Claim[](1);
        claims2[0] = MerkleTreeHelper.Claim(alice, 200e18);
        (bytes32 root2, bytes32[][] memory proofs2) = updateRoot(claims2);

        // Cannot claim (200 <= 500)
        vm.expectRevert(RewardsDistributor.NothingToClaim.selector);
        distributor.claim(alice, 200e18, proofs2[0]);

        // Alice keeps what she claimed
        assertEq(token.balanceOf(alice), 500e18);
    }

    /// @notice Test multiple updates and partial claims
    function test_claim_multipleUpdates() public {
        // Week 1: alice = 100
        MerkleTreeHelper.Claim[] memory claims1 = new MerkleTreeHelper.Claim[](1);
        claims1[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root1, bytes32[][] memory proofs1) = updateRoot(claims1);

        distributor.claim(alice, 100e18, proofs1[0]);

        // Week 2: alice = 250
        MerkleTreeHelper.Claim[] memory claims2 = new MerkleTreeHelper.Claim[](1);
        claims2[0] = MerkleTreeHelper.Claim(alice, 250e18);
        (bytes32 root2, bytes32[][] memory proofs2) = updateRoot(claims2);

        distributor.claim(alice, 250e18, proofs2[0]);

        // Week 3: alice = 500
        MerkleTreeHelper.Claim[] memory claims3 = new MerkleTreeHelper.Claim[](1);
        claims3[0] = MerkleTreeHelper.Claim(alice, 500e18);
        (bytes32 root3, bytes32[][] memory proofs3) = updateRoot(claims3);

        distributor.claim(alice, 500e18, proofs3[0]);

        assertEq(token.balanceOf(alice), 500e18);
        assertEq(distributor.claimed(alice), 500e18);
    }

    /// @notice Test setUseMint success
    function test_setUseMint_success() public {
        assertFalse(distributor.useMint());

        vm.prank(owner);
        distributor.setUseMint(true);

        assertTrue(distributor.useMint());
    }

    /// @notice Test only owner can call setUseMint
    function test_setUseMint_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        distributor.setUseMint(true);
    }

    /// @notice Test setUseMint can toggle back and forth
    function test_setUseMint_canToggle() public {
        vm.startPrank(owner);

        distributor.setUseMint(true);
        assertTrue(distributor.useMint());

        distributor.setUseMint(false);
        assertFalse(distributor.useMint());

        distributor.setUseMint(true);
        assertTrue(distributor.useMint());

        vm.stopPrank();
    }

    /// @notice Test mint mode mints new tokens
    function test_mintMode_mints() public {
        addMinter(address(distributor));
        toggleMintMode(true);

        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        uint256 supplyBefore = token.totalSupply();
        distributor.claim(alice, 100e18, proofs[0]);

        assertEq(token.totalSupply(), supplyBefore + 100e18);
        assertEq(token.balanceOf(alice), 100e18);
    }

    /// @notice Test transfer mode transfers from balance
    function test_transferMode_transfers() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        uint256 supplyBefore = token.totalSupply();
        uint256 distributorBalanceBefore = token.balanceOf(address(distributor));

        distributor.claim(alice, 100e18, proofs[0]);

        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.balanceOf(address(distributor)), distributorBalanceBefore - 100e18);
        assertEq(token.balanceOf(alice), 100e18);
    }

    /// @notice Test getClaimable returns correct amount
    function test_getClaimable() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        updateRoot(claims);

        assertEq(distributor.getClaimable(alice, 100e18), 100e18);
    }

    /// @notice Test getClaimable returns zero when fully claimed
    function test_getClaimable_fullyClaimedReturnsZero() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        distributor.claim(alice, 100e18, proofs[0]);

        assertEq(distributor.getClaimable(alice, 100e18), 0);
    }

    /// @notice Test getClaimable with increased allocation
    function test_getClaimable_afterIncrease() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        distributor.claim(alice, 100e18, proofs[0]);

        // Allocation increases to 250
        assertEq(distributor.getClaimable(alice, 250e18), 150e18);
    }

    /// @notice Test verify function
    function test_verify() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](2);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        claims[1] = MerkleTreeHelper.Claim(bob, 200e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        assertTrue(distributor.verify(alice, 100e18, proofs[0]));
        assertTrue(distributor.verify(bob, 200e18, proofs[1]));
        assertFalse(distributor.verify(alice, 200e18, proofs[0]));
    }

    /// @notice Test sweep function
    function test_sweep() public {
        Jane otherToken = new Jane(owner, minter, burner);
        vm.prank(owner);
        otherToken.setTransferable();

        vm.prank(minter);
        otherToken.mint(address(distributor), 500e18);

        uint256 ownerBalanceBefore = otherToken.balanceOf(owner);

        vm.prank(owner);
        distributor.sweep(IERC20(address(otherToken)));

        assertEq(otherToken.balanceOf(owner), ownerBalanceBefore + 500e18);
        assertEq(otherToken.balanceOf(address(distributor)), 0);
    }

    /// @notice Test only owner can sweep
    function test_sweep_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        distributor.sweep(IERC20(address(token)));
    }

    /// @notice Test claimMultiple success
    function test_claimMultiple_success() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](3);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        claims[1] = MerkleTreeHelper.Claim(bob, 200e18);
        claims[2] = MerkleTreeHelper.Claim(charlie, 300e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;

        uint256[] memory allocations = new uint256[](3);
        allocations[0] = 100e18;
        allocations[1] = 200e18;
        allocations[2] = 300e18;

        distributor.claimMultiple(users, allocations, proofs);

        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(bob), 200e18);
        assertEq(token.balanceOf(charlie), 300e18);
    }

    /// @notice Test claimMultiple with length mismatch
    function test_claimMultiple_lengthMismatch() public {
        address[] memory users = new address[](2);
        uint256[] memory allocations = new uint256[](3);
        bytes32[][] memory proofs = new bytes32[][](2);

        vm.expectRevert(RewardsDistributor.LengthMismatch.selector);
        distributor.claimMultiple(users, allocations, proofs);
    }

    /// @notice Test claimMultiple with invalid proof
    function test_claimMultiple_invalidProof() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](2);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        claims[1] = MerkleTreeHelper.Claim(bob, 200e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 100e18;
        allocations[1] = 300e18; // Wrong amount

        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        distributor.claimMultiple(users, allocations, proofs);
    }

    /// @notice Test claimMultiple partial success reverts entire batch
    function test_claimMultiple_partialFailure() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](2);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        claims[1] = MerkleTreeHelper.Claim(bob, 200e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        // Alice claims first
        distributor.claim(alice, 100e18, proofs[0]);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 100e18;
        allocations[1] = 200e18;

        // Should revert because alice already claimed
        vm.expectRevert(RewardsDistributor.NothingToClaim.selector);
        distributor.claimMultiple(users, allocations, proofs);

        // Bob should not have received tokens
        assertEq(token.balanceOf(bob), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        EPOCH FUNCTIONALITY TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test epoch calculation at START
    function test_epoch_atStart() public {
        warpTo(START);
        assertEq(distributor.epoch(), 0);
    }

    /// @notice Test epoch calculation after 1 week
    function test_epoch_afterOneWeek() public {
        warpTo(START + 604800); // 7 days
        assertEq(distributor.epoch(), 1);
    }

    /// @notice Test epoch calculation after multiple weeks
    function test_epoch_afterMultipleWeeks() public {
        warpTo(START + (604800 * 10)); // 10 weeks
        assertEq(distributor.epoch(), 10);
    }

    /// @notice Test epoch calculation with arbitrary timestamp
    function test_epoch_withTimestamp() public view {
        uint256 timestamp = START + (604800 * 5) + 86400; // 5 weeks + 1 day
        assertEq(distributor.epoch(timestamp), 5);
    }

    /// @notice Test setEpochEmissions for new epoch
    function test_setEpochEmissions_newEpoch() public {
        setEpochEmissions(0, 1000e18);

        assertEq(distributor.epochEmissions(0), 1000e18);
        assertEq(distributor.maxClaimable(), 1000e18);
    }

    /// @notice Test setEpochEmissions for multiple epochs
    function test_setEpochEmissions_multipleEpochs() public {
        setEpochEmissions(0, 1000e18);
        setEpochEmissions(1, 2000e18);
        setEpochEmissions(2, 3000e18);

        assertEq(distributor.epochEmissions(0), 1000e18);
        assertEq(distributor.epochEmissions(1), 2000e18);
        assertEq(distributor.epochEmissions(2), 3000e18);
        assertEq(distributor.maxClaimable(), 6000e18);
    }

    /// @notice Test setEpochEmissions increases existing epoch
    function test_setEpochEmissions_increaseExisting() public {
        setEpochEmissions(0, 1000e18);
        assertEq(distributor.maxClaimable(), 1000e18);

        setEpochEmissions(0, 1500e18);
        assertEq(distributor.epochEmissions(0), 1500e18);
        assertEq(distributor.maxClaimable(), 1500e18);
    }

    /// @notice Test setEpochEmissions decreases existing epoch
    function test_setEpochEmissions_decreaseExisting() public {
        setEpochEmissions(0, 1000e18);
        assertEq(distributor.maxClaimable(), 1000e18);

        setEpochEmissions(0, 600e18);
        assertEq(distributor.epochEmissions(0), 600e18);
        assertEq(distributor.maxClaimable(), 600e18);
    }

    /// @notice Test setEpochEmissions only callable by owner
    function test_setEpochEmissions_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        distributor.setEpochEmissions(0, 1000e18);
    }

    /*//////////////////////////////////////////////////////////////
                      MAX CLAIMABLE CAP TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test claim respects maxClaimable cap
    function test_maxClaimable_exceedsLimit() public {
        // Set low cap
        setEpochEmissions(0, 150e18);

        // Setup claims that would exceed cap
        bytes32[][] memory proofs = setupSimpleRoot(); // alice: 100e18, bob: 200e18, charlie: 300e18

        // Alice can claim (total: 100e18)
        claimAs(alice, alice, 100e18, proofs[0]);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(distributor.totalClaimed(), 100e18);

        // Bob can only claim partial (50e18 to reach cap)
        claimAs(bob, bob, 200e18, proofs[1]);
        assertEq(token.balanceOf(bob), 50e18);
        assertEq(distributor.totalClaimed(), 150e18);
        assertEq(distributor.claimed(bob), 50e18); // Only 50e18 was claimed, not full 200e18

        // Charlie cannot claim anything (cap reached)
        vm.prank(charlie);
        vm.expectRevert(RewardsDistributor.MaxClaimableExceeded.selector);
        distributor.claim(charlie, 300e18, proofs[2]);
    }

    /// @notice Test totalClaimed tracks correctly
    function test_totalClaimed_tracks() public {
        setEpochEmissions(0, 1000e18);

        bytes32[][] memory proofs = setupSimpleRoot();

        assertEq(distributor.totalClaimed(), 0);

        claimAs(alice, alice, 100e18, proofs[0]);
        assertEq(distributor.totalClaimed(), 100e18);

        claimAs(bob, bob, 200e18, proofs[1]);
        assertEq(distributor.totalClaimed(), 300e18);

        claimAs(charlie, charlie, 300e18, proofs[2]);
        assertEq(distributor.totalClaimed(), 600e18);
    }

    /// @notice Test claim at exact limit works
    function test_maxClaimable_exactLimit() public {
        setEpochEmissions(0, 600e18);

        bytes32[][] memory proofs = setupSimpleRoot();

        claimAs(alice, alice, 100e18, proofs[0]);
        claimAs(bob, bob, 200e18, proofs[1]);
        claimAs(charlie, charlie, 300e18, proofs[2]);

        assertEq(distributor.totalClaimed(), 600e18);
    }

    /// @notice Test partial claims respect cap
    function test_maxClaimable_partialClaims() public {
        // Deploy fresh distributor for clean testing
        distributor = new RewardsDistributor(owner, address(token), false, START);
        fundDistributor(1_000_000e18);

        // Set specific cap
        setEpochEmissions(0, 250e18);

        // Update root with higher allocations over time
        MerkleTreeHelper.Claim[] memory claims1 = new MerkleTreeHelper.Claim[](1);
        claims1[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (, bytes32[][] memory proofs1) = updateRoot(claims1);

        claimAs(alice, alice, 100e18, proofs1[0]);
        assertEq(distributor.totalClaimed(), 100e18);

        // Update alice's allocation
        MerkleTreeHelper.Claim[] memory claims2 = new MerkleTreeHelper.Claim[](1);
        claims2[0] = MerkleTreeHelper.Claim(alice, 200e18);
        (, bytes32[][] memory proofs2) = updateRoot(claims2);

        claimAs(alice, alice, 200e18, proofs2[0]);
        assertEq(distributor.totalClaimed(), 200e18);

        // Update alice's allocation again - can only claim 50e18 more
        MerkleTreeHelper.Claim[] memory claims3 = new MerkleTreeHelper.Claim[](1);
        claims3[0] = MerkleTreeHelper.Claim(alice, 400e18);
        (, bytes32[][] memory proofs3) = updateRoot(claims3);

        claimAs(alice, alice, 400e18, proofs3[0]);
        assertEq(distributor.totalClaimed(), 250e18);
        assertEq(token.balanceOf(alice), 250e18);
    }

    /// @notice Test maxClaimable with zero cap blocks all claims
    function test_maxClaimable_zeroCap() public {
        // Deploy fresh distributor without setting emissions (maxClaimable = 0)
        distributor = new RewardsDistributor(owner, address(token), false, START);
        fundDistributor(1_000_000e18);

        bytes32[][] memory proofs = setupSimpleRoot();

        vm.prank(alice);
        vm.expectRevert(RewardsDistributor.MaxClaimableExceeded.selector);
        distributor.claim(alice, 100e18, proofs[0]);
    }
}
