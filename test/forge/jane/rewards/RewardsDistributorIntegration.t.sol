// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {RewardsDistributorSetup} from "./utils/RewardsDistributorSetup.sol";
import {RewardsDistributor} from "../../../../src/jane/RewardsDistributor.sol";
import {MerkleTreeHelper} from "./mocks/MerkleTreeHelper.sol";
import {JaneToken} from "../../../../src/jane/JaneToken.sol";

contract RewardsDistributorIntegrationTest is RewardsDistributorSetup {
    function setUp() public override {
        super.setUp();
    }

    /// @notice Test complete lifecycle: deploy, add campaigns, claim, invalidate
    function test_completeLifecycle() public {
        // Step 1: Create first campaign
        MerkleTreeHelper.Claim[] memory claims1 = new MerkleTreeHelper.Claim[](3);
        claims1[0] = MerkleTreeHelper.Claim(alice, 100e18);
        claims1[1] = MerkleTreeHelper.Claim(bob, 200e18);
        claims1[2] = MerkleTreeHelper.Claim(charlie, 300e18);

        (uint256 campaign1,, bytes32[][] memory proofs1) = createCampaign(claims1);

        // Step 2: Create second campaign
        MerkleTreeHelper.Claim[] memory claims2 = new MerkleTreeHelper.Claim[](3);
        claims2[0] = MerkleTreeHelper.Claim(alice, 150e18);
        claims2[1] = MerkleTreeHelper.Claim(dave, 250e18);
        claims2[2] = MerkleTreeHelper.Claim(eve, 350e18);

        (uint256 campaign2,, bytes32[][] memory proofs2) = createCampaign(claims2);

        // Step 3: Alice claims from both campaigns
        vm.prank(alice);
        distributor.claim(campaign1, proofs1[0], alice, 100e18);

        vm.prank(alice);
        distributor.claim(campaign2, proofs2[0], alice, 150e18);

        assertEq(getJaneBalance(alice), 250e18);

        // Step 4: Bob claims from first campaign
        vm.prank(bob);
        distributor.claim(campaign1, proofs1[1], bob, 200e18);
        assertEq(getJaneBalance(bob), 200e18);

        // Step 5: Invalidate second campaign
        invalidateCampaign(campaign2);

        // Step 6: Dave can't claim from invalidated campaign
        vm.prank(dave);
        vm.expectRevert(RewardsDistributor.InvalidCampaign.selector);
        distributor.claim(campaign2, proofs2[1], dave, 250e18);

        // Step 7: Charlie can still claim from first campaign
        vm.prank(charlie);
        distributor.claim(campaign1, proofs1[2], charlie, 300e18);
        assertEq(getJaneBalance(charlie), 300e18);
    }

    /// @notice Test claiming multiple rewards in one transaction
    function test_claimMultiple() public {
        // Create 3 campaigns
        MerkleTreeHelper.Claim[][] memory allClaims = new MerkleTreeHelper.Claim[][](3);
        uint256[] memory campaignIds = new uint256[](3);
        bytes32[][][] memory allProofs = new bytes32[][][](3);

        for (uint256 i = 0; i < 3; i++) {
            allClaims[i] = new MerkleTreeHelper.Claim[](1);
            allClaims[i][0] = MerkleTreeHelper.Claim(alice, (i + 1) * 100e18);

            bytes32 root;
            bytes32[][] memory proofs;
            (campaignIds[i], root, proofs) = createCampaign(allClaims[i]);
            allProofs[i] = proofs;
        }

        // Prepare arrays for claimMultiple
        uint256[] memory rootIds = new uint256[](3);
        uint256[] memory amounts = new uint256[](3);
        address[] memory addrs = new address[](3);
        bytes32[][] memory proofs = new bytes32[][](3);

        for (uint256 i = 0; i < 3; i++) {
            rootIds[i] = campaignIds[i];
            amounts[i] = (i + 1) * 100e18;
            addrs[i] = alice;
            proofs[i] = allProofs[i][0];
        }

        // Claim all at once
        uint256 aliceBalanceBefore = getJaneBalance(alice);

        vm.prank(alice);
        distributor.claimMultiple(rootIds, amounts, addrs, proofs);

        assertEq(getJaneBalance(alice), aliceBalanceBefore + 600e18); // 100 + 200 + 300

        // Verify all claimed
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(distributor.claimed(alice, campaignIds[i]));
        }
    }

    /// @notice Test claimMultiple with length mismatch
    function test_claimMultiple_lengthMismatch() public {
        uint256[] memory rootIds = new uint256[](2);
        uint256[] memory amounts = new uint256[](3); // Different length
        address[] memory addrs = new address[](2);
        bytes32[][] memory proofs = new bytes32[][](2);

        vm.expectRevert(RewardsDistributor.LengthMismatch.selector);
        distributor.claimMultiple(rootIds, amounts, addrs, proofs);
    }

    /// @notice Test multi-user scenario
    function test_multiUserScenario() public {
        // Create campaign with 6 users
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](6);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        claims[1] = MerkleTreeHelper.Claim(bob, 200e18);
        claims[2] = MerkleTreeHelper.Claim(charlie, 300e18);
        claims[3] = MerkleTreeHelper.Claim(dave, 400e18);
        claims[4] = MerkleTreeHelper.Claim(eve, 500e18);
        claims[5] = MerkleTreeHelper.Claim(frank, 600e18);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        // Users claim in different order
        vm.prank(charlie);
        distributor.claim(campaignId, proofs[2], charlie, 300e18);

        vm.prank(alice);
        distributor.claim(campaignId, proofs[0], alice, 100e18);

        vm.prank(frank);
        distributor.claim(campaignId, proofs[5], frank, 600e18);

        vm.prank(bob);
        distributor.claim(campaignId, proofs[1], bob, 200e18);

        vm.prank(eve);
        distributor.claim(campaignId, proofs[4], eve, 500e18);

        vm.prank(dave);
        distributor.claim(campaignId, proofs[3], dave, 400e18);

        // Verify all balances
        assertEq(getJaneBalance(alice), 100e18);
        assertEq(getJaneBalance(bob), 200e18);
        assertEq(getJaneBalance(charlie), 300e18);
        assertEq(getJaneBalance(dave), 400e18);
        assertEq(getJaneBalance(eve), 500e18);
        assertEq(getJaneBalance(frank), 600e18);
    }

    /// @notice Test relayer pattern - claiming on behalf of others
    function test_relayerPattern() public {
        // Create campaign
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](3);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        claims[1] = MerkleTreeHelper.Claim(bob, 200e18);
        claims[2] = MerkleTreeHelper.Claim(charlie, 300e18);

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        address relayer = makeAddr("relayer");

        // Relayer claims for all users
        vm.startPrank(relayer);

        vm.expectEmit(true, true, false, true);
        emit Claimed(alice, campaignId, 100e18, relayer);
        distributor.claim(campaignId, proofs[0], alice, 100e18);

        vm.expectEmit(true, true, false, true);
        emit Claimed(bob, campaignId, 200e18, relayer);
        distributor.claim(campaignId, proofs[1], bob, 200e18);

        vm.expectEmit(true, true, false, true);
        emit Claimed(charlie, campaignId, 300e18, relayer);
        distributor.claim(campaignId, proofs[2], charlie, 300e18);

        vm.stopPrank();

        // Verify tokens went to correct recipients
        assertEq(getJaneBalance(alice), 100e18);
        assertEq(getJaneBalance(bob), 200e18);
        assertEq(getJaneBalance(charlie), 300e18);
        assertEq(getJaneBalance(relayer), 0);
    }

    /// @notice Test large scale campaign with 100 users
    function test_largeCampaign_100Users() public {
        uint256 userCount = 100;
        MerkleTreeHelper.Claim[] memory claims = merkleHelper.generateLargeClaims(userCount, 100e18);

        (uint256 campaignId, bytes32 root, bytes32[][] memory proofs) = createCampaign(claims);

        // Claim for first 10 users and measure gas
        for (uint256 i = 0; i < 10; i++) {
            address user = claims[i].user;
            uint256 amount = claims[i].amount;

            uint256 gasBefore = gasleft();
            distributor.claim(campaignId, proofs[i], user, amount);
            uint256 gasUsed = gasBefore - gasleft();

            if (i == 0) {
                emit log_named_uint("Gas for first claim (100 users)", gasUsed);
            }

            assertEq(getJaneBalance(user), amount);
            assertTrue(distributor.claimed(user, campaignId));
        }
    }

    /// @notice Test large scale campaign (simplified due to gas limits)
    function test_largeCampaign_gasMeasurement() public {
        // Note: Large merkle tree generation (500+ users) exceeds gas limits
        // This test demonstrates gas measurement with a smaller set
        uint256 userCount = 50;
        MerkleTreeHelper.Claim[] memory claims = merkleHelper.generateLargeClaims(userCount, 100e18);

        (uint256 campaignId, bytes32 root, bytes32[][] memory proofs) = createCampaign(claims);

        // Claim for users at different positions
        uint256[] memory testIndices = new uint256[](3);
        testIndices[0] = 0; // First user
        testIndices[1] = 24; // Middle
        testIndices[2] = 49; // Last user

        for (uint256 i = 0; i < testIndices.length; i++) {
            uint256 idx = testIndices[i];
            address user = claims[idx].user;
            uint256 amount = claims[idx].amount;

            uint256 gasBefore = gasleft();
            distributor.claim(campaignId, proofs[idx], user, amount);
            uint256 gasUsed = gasBefore - gasleft();

            emit log_named_uint(string.concat("Gas for claim at index ", vm.toString(idx), " (50 users)"), gasUsed);

            assertTrue(distributor.claimed(user, campaignId));
        }
    }

    /// @notice Test BitMap efficiency across multiple campaigns
    function test_bitmapEfficiency() public {
        // Create 256 campaigns (to test multiple bitmap words)
        uint256 numCampaigns = 256;
        uint256[] memory campaignIds = new uint256[](numCampaigns);

        for (uint256 i = 0; i < numCampaigns; i++) {
            MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
            claims[0] = MerkleTreeHelper.Claim(alice, 1e18 * (i + 1));

            bytes32 root;
            bytes32[][] memory proofs;
            (campaignIds[i], root, proofs) = createCampaign(claims);

            // Claim every other campaign
            if (i % 2 == 0) {
                vm.prank(alice);
                distributor.claim(campaignIds[i], proofs[0], alice, 1e18 * (i + 1));
            }
        }

        // Verify bitmap status
        for (uint256 i = 0; i < numCampaigns; i++) {
            if (i % 2 == 0) {
                assertTrue(distributor.claimed(alice, campaignIds[i]));
            } else {
                assertFalse(distributor.claimed(alice, campaignIds[i]));
            }
        }
    }

    /// @notice Test sweep functionality with multiple tokens
    function test_sweepMultipleTokens() public {
        // Deploy additional tokens
        JaneToken token2 = new JaneToken(owner, minter, burner);
        JaneToken token3 = new JaneToken(owner, minter, burner);

        vm.startPrank(owner);
        token2.setTransferable();
        token3.setTransferable();
        vm.stopPrank();

        // Send tokens to distributor
        vm.startPrank(minter);
        token2.mint(address(distributor), 1000e18);
        token3.mint(address(distributor), 2000e18);
        vm.stopPrank();

        // Sweep all tokens
        sweep(address(token2));
        sweep(address(token3));

        // Verify owner received all tokens
        assertEq(token2.balanceOf(owner), 1000e18);
        assertEq(token3.balanceOf(owner), 2000e18);
        assertEq(token2.balanceOf(address(distributor)), 0);
        assertEq(token3.balanceOf(address(distributor)), 0);
    }

    /// @notice Test campaign progression over time
    function test_campaignProgression() public {
        uint256 numCampaigns = 5;
        uint256[] memory campaignIds = new uint256[](numCampaigns);
        bytes32[][][] memory allProofs = new bytes32[][][](numCampaigns);

        // Create campaigns over time
        for (uint256 i = 0; i < numCampaigns; i++) {
            // Advance time between campaigns
            if (i > 0) {
                advanceTime(7 days);
            }

            MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
            claims[0] = MerkleTreeHelper.Claim(alice, 100e18 * (i + 1));

            bytes32 root;
            bytes32[][] memory proofs;
            (campaignIds[i], root, proofs) = createCampaign(claims);
            allProofs[i] = proofs;

            emit log_named_uint(string.concat("Campaign ", vm.toString(i), " created at"), block.timestamp);
        }

        // Claim from all campaigns
        for (uint256 i = 0; i < numCampaigns; i++) {
            vm.prank(alice);
            distributor.claim(campaignIds[i], allProofs[i][0], alice, 100e18 * (i + 1));
        }

        // Verify total claimed
        uint256 expectedTotal = 0;
        for (uint256 i = 0; i < numCampaigns; i++) {
            expectedTotal += 100e18 * (i + 1);
        }
        assertEq(getJaneBalance(alice), expectedTotal);
    }

    /// @notice Test emergency withdrawal pattern
    function test_emergencyWithdrawal() public {
        // Create campaign
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](3);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        claims[1] = MerkleTreeHelper.Claim(bob, 200e18);
        claims[2] = MerkleTreeHelper.Claim(charlie, 300e18);

        (uint256 campaignId,,) = createCampaign(claims);

        // Simulate emergency: invalidate campaign and sweep tokens
        invalidateCampaign(campaignId);

        uint256 distributorBalance = getJaneBalance(address(distributor));
        uint256 ownerBalanceBefore = getJaneBalance(owner);

        sweep(address(token));

        assertEq(getJaneBalance(owner), ownerBalanceBefore + distributorBalance);
        assertEq(getJaneBalance(address(distributor)), 0);
    }

    /// @notice Test gas optimization for batch claims
    function test_gasOptimization_batchClaims() public {
        // Create campaign with 10 users
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](10);
        for (uint256 i = 0; i < 10; i++) {
            claims[i] = MerkleTreeHelper.Claim(address(uint160(0x1000 + i)), 100e18 * (i + 1));
        }

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        // Method 1: Individual claims
        uint256 totalGasIndividual = 0;
        for (uint256 i = 0; i < 5; i++) {
            uint256 gasBefore = gasleft();
            distributor.claim(campaignId, proofs[i], claims[i].user, claims[i].amount);
            totalGasIndividual += gasBefore - gasleft();
        }

        // Method 2: Batch claim using claimMultiple
        uint256[] memory rootIds = new uint256[](5);
        uint256[] memory amounts = new uint256[](5);
        address[] memory addrs = new address[](5);
        bytes32[][] memory batchProofs = new bytes32[][](5);

        for (uint256 i = 5; i < 10; i++) {
            rootIds[i - 5] = campaignId;
            amounts[i - 5] = claims[i].amount;
            addrs[i - 5] = claims[i].user;
            batchProofs[i - 5] = proofs[i];
        }

        uint256 gasBefore = gasleft();
        distributor.claimMultiple(rootIds, amounts, addrs, batchProofs);
        uint256 totalGasBatch = gasBefore - gasleft();

        emit log_named_uint("Total gas for 5 individual claims", totalGasIndividual);
        emit log_named_uint("Total gas for batch of 5 claims", totalGasBatch);
        emit log_named_uint("Gas saved with batch", totalGasIndividual - totalGasBatch);
    }

    /// @notice Test partial claims scenario
    function test_partialClaims() public {
        // Create campaign
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](10);
        for (uint256 i = 0; i < 10; i++) {
            claims[i] = MerkleTreeHelper.Claim(address(uint160(0x2000 + i)), 100e18);
        }

        (uint256 campaignId,, bytes32[][] memory proofs) = createCampaign(claims);

        // Only half of users claim
        for (uint256 i = 0; i < 5; i++) {
            distributor.claim(campaignId, proofs[i], claims[i].user, claims[i].amount);
        }

        // Check claimed status
        for (uint256 i = 0; i < 10; i++) {
            if (i < 5) {
                assertTrue(distributor.claimed(claims[i].user, campaignId));
            } else {
                assertFalse(distributor.claimed(claims[i].user, campaignId));
            }
        }

        // Calculate unclaimed amount
        uint256 unclaimedAmount = 500e18; // 5 users * 100e18
        uint256 distributorBalance = getJaneBalance(address(distributor));
        assertTrue(distributorBalance >= unclaimedAmount);
    }
}
