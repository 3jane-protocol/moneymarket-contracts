// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {RewardsDistributorSetup} from "./utils/RewardsDistributorSetup.sol";
import {RewardsDistributor} from "../../../../src/jane/RewardsDistributor.sol";
import {MerkleTreeHelper} from "./mocks/MerkleTreeHelper.sol";
import {Jane} from "../../../../src/jane/Jane.sol";

contract RewardsDistributorIntegrationTest is RewardsDistributorSetup {
    function setUp() public override {
        super.setUp();
    }

    /// @notice Test complete lifecycle: weekly reward updates
    function test_weeklyRewardsLifecycle() public {
        // Week 1: Initial allocations
        MerkleTreeHelper.Claim[] memory week1 = new MerkleTreeHelper.Claim[](3);
        week1[0] = MerkleTreeHelper.Claim(alice, 100e18);
        week1[1] = MerkleTreeHelper.Claim(bob, 200e18);
        week1[2] = MerkleTreeHelper.Claim(charlie, 300e18);
        (bytes32 root1, bytes32[][] memory proofs1) = updateRoot(week1);

        distributor.claim(alice, 100e18, proofs1[0]);
        distributor.claim(bob, 200e18, proofs1[1]);

        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(bob), 200e18);

        // Week 2: Increased allocations
        MerkleTreeHelper.Claim[] memory week2 = new MerkleTreeHelper.Claim[](3);
        week2[0] = MerkleTreeHelper.Claim(alice, 250e18);
        week2[1] = MerkleTreeHelper.Claim(bob, 400e18);
        week2[2] = MerkleTreeHelper.Claim(charlie, 600e18);
        (bytes32 root2, bytes32[][] memory proofs2) = updateRoot(week2);

        distributor.claim(alice, 250e18, proofs2[0]);
        distributor.claim(charlie, 600e18, proofs2[2]);

        assertEq(token.balanceOf(alice), 250e18);
        assertEq(token.balanceOf(charlie), 600e18);

        // Week 3: More increases
        MerkleTreeHelper.Claim[] memory week3 = new MerkleTreeHelper.Claim[](3);
        week3[0] = MerkleTreeHelper.Claim(alice, 500e18);
        week3[1] = MerkleTreeHelper.Claim(bob, 800e18);
        week3[2] = MerkleTreeHelper.Claim(charlie, 1000e18);
        (bytes32 root3, bytes32[][] memory proofs3) = updateRoot(week3);

        distributor.claim(bob, 800e18, proofs3[1]);

        assertEq(token.balanceOf(bob), 800e18);
    }

    /// @notice Test multi-user scenario with various claim patterns
    function test_multiUserScenario() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](6);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        claims[1] = MerkleTreeHelper.Claim(bob, 200e18);
        claims[2] = MerkleTreeHelper.Claim(charlie, 300e18);
        claims[3] = MerkleTreeHelper.Claim(dave, 400e18);
        claims[4] = MerkleTreeHelper.Claim(eve, 500e18);
        claims[5] = MerkleTreeHelper.Claim(frank, 600e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        // Users claim in different order
        distributor.claim(charlie, 300e18, proofs[2]);
        distributor.claim(alice, 100e18, proofs[0]);
        distributor.claim(frank, 600e18, proofs[5]);
        distributor.claim(bob, 200e18, proofs[1]);
        distributor.claim(eve, 500e18, proofs[4]);
        distributor.claim(dave, 400e18, proofs[3]);

        // Verify all balances
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(bob), 200e18);
        assertEq(token.balanceOf(charlie), 300e18);
        assertEq(token.balanceOf(dave), 400e18);
        assertEq(token.balanceOf(eve), 500e18);
        assertEq(token.balanceOf(frank), 600e18);
    }

    /// @notice Test relayer pattern - claiming on behalf of others
    function test_relayerPattern() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](3);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        claims[1] = MerkleTreeHelper.Claim(bob, 200e18);
        claims[2] = MerkleTreeHelper.Claim(charlie, 300e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        address relayer = makeAddr("relayer");

        // Relayer claims for all users
        vm.startPrank(relayer);

        vm.expectEmit(true, false, false, true);
        emit Claimed(alice, 100e18, 100e18);
        distributor.claim(alice, 100e18, proofs[0]);

        vm.expectEmit(true, false, false, true);
        emit Claimed(bob, 200e18, 200e18);
        distributor.claim(bob, 200e18, proofs[1]);

        vm.expectEmit(true, false, false, true);
        emit Claimed(charlie, 300e18, 300e18);
        distributor.claim(charlie, 300e18, proofs[2]);

        vm.stopPrank();

        // Verify tokens went to correct recipients
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(bob), 200e18);
        assertEq(token.balanceOf(charlie), 300e18);
        assertEq(token.balanceOf(relayer), 0);
    }

    /// @notice Test large scale with 100 users
    function test_largeCampaign_100Users() public {
        uint256 userCount = 100;
        MerkleTreeHelper.Claim[] memory claims = merkleHelper.generateLargeClaims(userCount, 100e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        // Claim for first 10 users and measure gas
        for (uint256 i = 0; i < 10; i++) {
            address user = claims[i].user;
            uint256 amount = claims[i].amount;

            uint256 gasBefore = gasleft();
            distributor.claim(user, amount, proofs[i]);
            uint256 gasUsed = gasBefore - gasleft();

            if (i == 0) {
                emit log_named_uint("Gas for first claim (100 users)", gasUsed);
            }

            assertEq(token.balanceOf(user), amount);
            assertEq(distributor.claimed(user), amount);
        }
    }

    /// @notice Test gas measurement for different tree sizes
    function test_gasMeasurement_variousTreeSizes() public {
        uint256 userCount = 50;
        MerkleTreeHelper.Claim[] memory claims = merkleHelper.generateLargeClaims(userCount, 100e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        // Test claims at different positions
        uint256[] memory testIndices = new uint256[](3);
        testIndices[0] = 0; // First user
        testIndices[1] = 24; // Middle
        testIndices[2] = 49; // Last user

        for (uint256 i = 0; i < testIndices.length; i++) {
            uint256 idx = testIndices[i];
            address user = claims[idx].user;
            uint256 amount = claims[idx].amount;

            uint256 gasBefore = gasleft();
            distributor.claim(user, amount, proofs[idx]);
            uint256 gasUsed = gasBefore - gasleft();

            emit log_named_uint(string.concat("Gas for claim at index ", vm.toString(idx), " (50 users)"), gasUsed);

            assertEq(distributor.claimed(user), amount);
        }
    }

    /// @notice Test sweep functionality with multiple tokens
    function test_sweepMultipleTokens() public {
        Jane token2 = new Jane(owner, minter, burner);
        Jane token3 = new Jane(owner, minter, burner);

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

        assertEq(token2.balanceOf(owner), 1000e18);
        assertEq(token3.balanceOf(owner), 2000e18);
        assertEq(token2.balanceOf(address(distributor)), 0);
        assertEq(token3.balanceOf(address(distributor)), 0);
    }

    /// @notice Test progressive weekly updates over time
    function test_progressiveWeeklyUpdates() public {
        uint256 numWeeks = 5;

        for (uint256 i = 0; i < numWeeks; i++) {
            if (i > 0) {
                advanceTime(7 days);
            }

            MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
            claims[0] = MerkleTreeHelper.Claim(alice, 100e18 * (i + 1));
            (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

            distributor.claim(alice, 100e18 * (i + 1), proofs[0]);

            emit log_named_uint(string.concat("Week ", vm.toString(i + 1), " timestamp"), block.timestamp);
        }

        // Final balance should be last allocation amount
        assertEq(token.balanceOf(alice), 500e18);
        assertEq(distributor.claimed(alice), 500e18);
    }

    /// @notice Test emergency withdrawal scenario
    function test_emergencyWithdrawal() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](3);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        claims[1] = MerkleTreeHelper.Claim(bob, 200e18);
        claims[2] = MerkleTreeHelper.Claim(charlie, 300e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        // Alice claims before emergency
        distributor.claim(alice, 100e18, proofs[0]);

        // Simulate emergency: sweep remaining tokens
        uint256 distributorBalance = token.balanceOf(address(distributor));
        uint256 ownerBalanceBefore = token.balanceOf(owner);

        sweep(address(token));

        assertEq(token.balanceOf(owner), ownerBalanceBefore + distributorBalance);
        assertEq(token.balanceOf(address(distributor)), 0);
    }

    /// @notice Test partial claims scenario
    function test_partialClaims() public {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](10);
        for (uint256 i = 0; i < 10; i++) {
            claims[i] = MerkleTreeHelper.Claim(address(uint160(0x2000 + i)), 100e18);
        }
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        // Only half of users claim
        for (uint256 i = 0; i < 5; i++) {
            distributor.claim(claims[i].user, claims[i].amount, proofs[i]);
        }

        // Check claimed status
        for (uint256 i = 0; i < 10; i++) {
            if (i < 5) {
                assertEq(distributor.claimed(claims[i].user), 100e18);
            } else {
                assertEq(distributor.claimed(claims[i].user), 0);
            }
        }

        // Calculate unclaimed amount
        uint256 unclaimedAmount = 500e18; // 5 users * 100e18
        uint256 distributorBalance = token.balanceOf(address(distributor));
        assertTrue(distributorBalance >= unclaimedAmount);
    }

    /// @notice Test mode switching full lifecycle
    function test_modeSwitch_fullLifecycle() public {
        addMinter(address(distributor));

        // Phase 1: Transfer mode
        assertFalse(distributor.useMint());
        MerkleTreeHelper.Claim[] memory claims1 = new MerkleTreeHelper.Claim[](2);
        claims1[0] = MerkleTreeHelper.Claim(alice, 100e18);
        claims1[1] = MerkleTreeHelper.Claim(bob, 200e18);
        (bytes32 root1, bytes32[][] memory proofs1) = updateRoot(claims1);

        uint256 distributorBalanceBefore = token.balanceOf(address(distributor));
        distributor.claim(alice, 100e18, proofs1[0]);
        assertEq(token.balanceOf(address(distributor)), distributorBalanceBefore - 100e18);

        // Switch to mint mode
        toggleMintMode(true);

        // Phase 2: Mint mode
        MerkleTreeHelper.Claim[] memory claims2 = new MerkleTreeHelper.Claim[](2);
        claims2[0] = MerkleTreeHelper.Claim(charlie, 300e18);
        claims2[1] = MerkleTreeHelper.Claim(dave, 400e18);
        (bytes32 root2, bytes32[][] memory proofs2) = updateRoot(claims2);

        uint256 supplyBefore = token.totalSupply();
        distributor.claim(charlie, 300e18, proofs2[0]);
        assertEq(token.totalSupply(), supplyBefore + 300e18);

        // Switch back to transfer mode
        toggleMintMode(false);

        // Update root with new allocation for bob
        MerkleTreeHelper.Claim[] memory claims3 = new MerkleTreeHelper.Claim[](1);
        claims3[0] = MerkleTreeHelper.Claim(bob, 200e18);
        (bytes32 root3, bytes32[][] memory proofs3) = updateRoot(claims3);

        distributor.claim(bob, 200e18, proofs3[0]);
        assertEq(token.balanceOf(bob), 200e18);
    }

    /// @notice Test incremental claiming over multiple updates
    function test_incrementalClaiming() public {
        // Update 1: alice = 100
        MerkleTreeHelper.Claim[] memory claims1 = new MerkleTreeHelper.Claim[](1);
        claims1[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root1, bytes32[][] memory proofs1) = updateRoot(claims1);
        distributor.claim(alice, 100e18, proofs1[0]);

        assertEq(token.balanceOf(alice), 100e18);
        assertEq(distributor.claimed(alice), 100e18);

        // Update 2: alice = 250 (increase by 150)
        MerkleTreeHelper.Claim[] memory claims2 = new MerkleTreeHelper.Claim[](1);
        claims2[0] = MerkleTreeHelper.Claim(alice, 250e18);
        (bytes32 root2, bytes32[][] memory proofs2) = updateRoot(claims2);
        distributor.claim(alice, 250e18, proofs2[0]);

        assertEq(token.balanceOf(alice), 250e18);
        assertEq(distributor.claimed(alice), 250e18);

        // Update 3: alice = 500 (increase by 250)
        MerkleTreeHelper.Claim[] memory claims3 = new MerkleTreeHelper.Claim[](1);
        claims3[0] = MerkleTreeHelper.Claim(alice, 500e18);
        (bytes32 root3, bytes32[][] memory proofs3) = updateRoot(claims3);
        distributor.claim(alice, 500e18, proofs3[0]);

        assertEq(token.balanceOf(alice), 500e18);
        assertEq(distributor.claimed(alice), 500e18);
    }

    /// @notice Test staggered user onboarding
    function test_staggeredUserOnboarding() public {
        // Week 1: Just Alice
        MerkleTreeHelper.Claim[] memory week1 = new MerkleTreeHelper.Claim[](1);
        week1[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (bytes32 root1, bytes32[][] memory proofs1) = updateRoot(week1);
        distributor.claim(alice, 100e18, proofs1[0]);

        // Week 2: Alice + Bob
        MerkleTreeHelper.Claim[] memory week2 = new MerkleTreeHelper.Claim[](2);
        week2[0] = MerkleTreeHelper.Claim(alice, 250e18);
        week2[1] = MerkleTreeHelper.Claim(bob, 150e18);
        (bytes32 root2, bytes32[][] memory proofs2) = updateRoot(week2);
        distributor.claim(alice, 250e18, proofs2[0]);
        distributor.claim(bob, 150e18, proofs2[1]);

        // Week 3: Alice + Bob + Charlie
        MerkleTreeHelper.Claim[] memory week3 = new MerkleTreeHelper.Claim[](3);
        week3[0] = MerkleTreeHelper.Claim(alice, 400e18);
        week3[1] = MerkleTreeHelper.Claim(bob, 300e18);
        week3[2] = MerkleTreeHelper.Claim(charlie, 200e18);
        (bytes32 root3, bytes32[][] memory proofs3) = updateRoot(week3);
        distributor.claim(alice, 400e18, proofs3[0]);
        distributor.claim(bob, 300e18, proofs3[1]);
        distributor.claim(charlie, 200e18, proofs3[2]);

        assertEq(token.balanceOf(alice), 400e18);
        assertEq(token.balanceOf(bob), 300e18);
        assertEq(token.balanceOf(charlie), 200e18);
    }

    /// @notice Test catching up on missed claims
    function test_catchUpMissedClaims() public {
        // Week 1
        MerkleTreeHelper.Claim[] memory week1 = new MerkleTreeHelper.Claim[](2);
        week1[0] = MerkleTreeHelper.Claim(alice, 100e18);
        week1[1] = MerkleTreeHelper.Claim(bob, 100e18);
        updateRoot(week1);

        // Week 2 (Alice doesn't claim)
        MerkleTreeHelper.Claim[] memory week2 = new MerkleTreeHelper.Claim[](2);
        week2[0] = MerkleTreeHelper.Claim(alice, 250e18);
        week2[1] = MerkleTreeHelper.Claim(bob, 250e18);
        updateRoot(week2);

        // Week 3 (Alice doesn't claim)
        MerkleTreeHelper.Claim[] memory week3 = new MerkleTreeHelper.Claim[](2);
        week3[0] = MerkleTreeHelper.Claim(alice, 500e18);
        week3[1] = MerkleTreeHelper.Claim(bob, 500e18);
        (bytes32 root3, bytes32[][] memory proofs3) = updateRoot(week3);

        // Alice finally claims in week 3 - gets full cumulative amount
        distributor.claim(alice, 500e18, proofs3[0]);
        assertEq(token.balanceOf(alice), 500e18);

        // Bob has been claiming regularly
        distributor.claim(bob, 500e18, proofs3[1]);
        assertEq(token.balanceOf(bob), 500e18);
    }

    /// @notice Test complex multi-week scenario with varied allocations
    function test_complexMultiWeek() public {
        address[] memory users = new address[](4);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;
        users[3] = dave;

        // Week 1
        MerkleTreeHelper.Claim[] memory week1 = new MerkleTreeHelper.Claim[](4);
        for (uint256 i = 0; i < 4; i++) {
            week1[i] = MerkleTreeHelper.Claim(users[i], 100e18 * (i + 1));
        }
        (bytes32 root1, bytes32[][] memory proofs1) = updateRoot(week1);
        for (uint256 i = 0; i < 4; i++) {
            distributor.claim(users[i], 100e18 * (i + 1), proofs1[i]);
        }

        // Week 2: Double allocations
        MerkleTreeHelper.Claim[] memory week2 = new MerkleTreeHelper.Claim[](4);
        for (uint256 i = 0; i < 4; i++) {
            week2[i] = MerkleTreeHelper.Claim(users[i], 200e18 * (i + 1));
        }
        (bytes32 root2, bytes32[][] memory proofs2) = updateRoot(week2);
        for (uint256 i = 0; i < 4; i++) {
            distributor.claim(users[i], 200e18 * (i + 1), proofs2[i]);
        }

        // Verify final balances
        assertEq(token.balanceOf(alice), 200e18);
        assertEq(token.balanceOf(bob), 400e18);
        assertEq(token.balanceOf(charlie), 600e18);
        assertEq(token.balanceOf(dave), 800e18);
    }

    /*//////////////////////////////////////////////////////////////
                    EPOCH EMISSIONS LIFECYCLE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test weekly lifecycle with epoch emissions
    function test_epochEmissions_weeklyLifecycle() public {
        // Deploy fresh distributor for clean testing
        distributor = new RewardsDistributor(owner, address(token), false, START);
        fundDistributor(1_000_000e18);

        // Set emissions for weeks 0-4
        setEpochEmissions(0, 1000e18);
        setEpochEmissions(1, 1500e18);
        setEpochEmissions(2, 2000e18);
        setEpochEmissions(3, 2500e18);
        setEpochEmissions(4, 3000e18);

        assertEq(distributor.maxClaimable(), 10000e18);

        // Week 0: Distribute 800e18
        warpTo(START);
        MerkleTreeHelper.Claim[] memory week0 = new MerkleTreeHelper.Claim[](4);
        week0[0] = MerkleTreeHelper.Claim(alice, 100e18);
        week0[1] = MerkleTreeHelper.Claim(bob, 200e18);
        week0[2] = MerkleTreeHelper.Claim(charlie, 300e18);
        week0[3] = MerkleTreeHelper.Claim(dave, 200e18);
        (bytes32 root0, bytes32[][] memory proofs0) = updateRoot(week0);

        for (uint256 i = 0; i < 4; i++) {
            address user = i == 0 ? alice : i == 1 ? bob : i == 2 ? charlie : dave;
            distributor.claim(user, week0[i].amount, proofs0[i]);
        }
        assertEq(distributor.totalClaimed(), 800e18);

        // Week 2: Distribute additional 1200e18 (total: 2000e18)
        warpTo(START + 604800 * 2);
        MerkleTreeHelper.Claim[] memory week2 = new MerkleTreeHelper.Claim[](4);
        week2[0] = MerkleTreeHelper.Claim(alice, 400e18);
        week2[1] = MerkleTreeHelper.Claim(bob, 600e18);
        week2[2] = MerkleTreeHelper.Claim(charlie, 800e18);
        week2[3] = MerkleTreeHelper.Claim(dave, 400e18); // Increased from 200e18
        (bytes32 root2, bytes32[][] memory proofs2) = updateRoot(week2);

        for (uint256 i = 0; i < 4; i++) {
            address user = i == 0 ? alice : i == 1 ? bob : i == 2 ? charlie : dave;
            distributor.claim(user, week2[i].amount, proofs2[i]);
        }
        assertEq(distributor.totalClaimed(), 2200e18); // alice: 400, bob: 600, charlie: 800, dave: 400

        // Week 4: Try to claim beyond cap
        warpTo(START + 604800 * 4);
        MerkleTreeHelper.Claim[] memory week4 = new MerkleTreeHelper.Claim[](1);
        week4[0] = MerkleTreeHelper.Claim(eve, 9000e18);
        (bytes32 root4, bytes32[][] memory proofs4) = updateRoot(week4);

        // Can only claim 7800e18 more (maxClaimable - totalClaimed = 10000 - 2200)
        distributor.claim(eve, 9000e18, proofs4[0]);
        assertEq(distributor.totalClaimed(), 10000e18);
        assertEq(token.balanceOf(eve), 7800e18);
    }

    /// @notice Test insufficient cap scenario
    function test_epochEmissions_insufficientCap() public {
        // Deploy fresh distributor for clean testing
        distributor = new RewardsDistributor(owner, address(token), false, START);
        fundDistributor(1_000_000e18);

        // Set low cap
        setEpochEmissions(0, 500e18);

        // Create allocations exceeding cap
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](4);
        claims[0] = MerkleTreeHelper.Claim(alice, 200e18);
        claims[1] = MerkleTreeHelper.Claim(bob, 200e18);
        claims[2] = MerkleTreeHelper.Claim(charlie, 200e18);
        claims[3] = MerkleTreeHelper.Claim(dave, 200e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        // First two can claim
        distributor.claim(alice, 200e18, proofs[0]);
        distributor.claim(bob, 200e18, proofs[1]);
        assertEq(distributor.totalClaimed(), 400e18);

        // Third can claim partial
        distributor.claim(charlie, 200e18, proofs[2]);
        assertEq(distributor.totalClaimed(), 500e18);
        assertEq(token.balanceOf(charlie), 100e18);

        // Fourth cannot claim at all
        vm.expectRevert(RewardsDistributor.MaxClaimableExceeded.selector);
        distributor.claim(dave, 200e18, proofs[3]);
    }

    /// @notice Test dynamic emissions adjustment mid-cycle
    function test_epochEmissions_dynamicAdjustment() public {
        // Deploy fresh distributor for clean testing
        distributor = new RewardsDistributor(owner, address(token), false, START);
        fundDistributor(1_000_000e18);

        // Set initial low cap
        setEpochEmissions(0, 300e18);

        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](3);
        claims[0] = MerkleTreeHelper.Claim(alice, 200e18);
        claims[1] = MerkleTreeHelper.Claim(bob, 200e18);
        claims[2] = MerkleTreeHelper.Claim(charlie, 200e18);
        (bytes32 root, bytes32[][] memory proofs) = updateRoot(claims);

        // Alice claims
        distributor.claim(alice, 200e18, proofs[0]);
        assertEq(distributor.totalClaimed(), 200e18);

        // Bob can only partially claim
        distributor.claim(bob, 200e18, proofs[1]);
        assertEq(distributor.totalClaimed(), 300e18);
        assertEq(token.balanceOf(bob), 100e18);

        // Owner increases epoch 0 emissions
        setEpochEmissions(0, 600e18);
        assertEq(distributor.maxClaimable(), 600e18);

        // Bob can now claim remaining
        distributor.claim(bob, 200e18, proofs[1]);
        assertEq(distributor.totalClaimed(), 400e18);
        assertEq(token.balanceOf(bob), 200e18);

        // Charlie can claim
        distributor.claim(charlie, 200e18, proofs[2]);
        assertEq(distributor.totalClaimed(), 600e18);
        assertEq(token.balanceOf(charlie), 200e18);
    }

    /// @notice Test multiple epoch emissions with progressive claiming
    function test_epochEmissions_progressiveClaiming() public {
        // Set emissions for epochs 0-2
        setEpochEmissions(0, 1000e18);
        setEpochEmissions(1, 1500e18);
        setEpochEmissions(2, 2000e18);

        // Warp to epoch 0
        warpTo(START);
        assertEq(distributor.epoch(), 0);

        // Create progressive claims
        MerkleTreeHelper.Claim[] memory claims1 = new MerkleTreeHelper.Claim[](2);
        claims1[0] = MerkleTreeHelper.Claim(alice, 500e18);
        claims1[1] = MerkleTreeHelper.Claim(bob, 500e18);
        (bytes32 root1, bytes32[][] memory proofs1) = updateRoot(claims1);

        distributor.claim(alice, 500e18, proofs1[0]);
        distributor.claim(bob, 500e18, proofs1[1]);
        assertEq(distributor.totalClaimed(), 1000e18);

        // Warp to epoch 1
        warpTo(START + 604800);
        assertEq(distributor.epoch(), 1);

        // Update allocations
        MerkleTreeHelper.Claim[] memory claims2 = new MerkleTreeHelper.Claim[](2);
        claims2[0] = MerkleTreeHelper.Claim(alice, 1250e18);
        claims2[1] = MerkleTreeHelper.Claim(bob, 1250e18);
        (bytes32 root2, bytes32[][] memory proofs2) = updateRoot(claims2);

        distributor.claim(alice, 1250e18, proofs2[0]);
        distributor.claim(bob, 1250e18, proofs2[1]);
        assertEq(distributor.totalClaimed(), 2500e18);

        // Warp to epoch 2
        warpTo(START + 604800 * 2);
        assertEq(distributor.epoch(), 2);

        // Final claims
        MerkleTreeHelper.Claim[] memory claims3 = new MerkleTreeHelper.Claim[](2);
        claims3[0] = MerkleTreeHelper.Claim(alice, 2250e18);
        claims3[1] = MerkleTreeHelper.Claim(bob, 2250e18);
        (bytes32 root3, bytes32[][] memory proofs3) = updateRoot(claims3);

        distributor.claim(alice, 2250e18, proofs3[0]);
        distributor.claim(bob, 2250e18, proofs3[1]);
        assertEq(distributor.totalClaimed(), 4500e18);

        assertEq(token.balanceOf(alice), 2250e18);
        assertEq(token.balanceOf(bob), 2250e18);
    }
}
