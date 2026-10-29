// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {RewardsDistributorSetup} from "./utils/RewardsDistributorSetup.sol";
import {MerkleTreeHelper} from "./mocks/MerkleTreeHelper.sol";
import {Jane} from "../../../../src/jane/Jane.sol";
import {TransferControllerMock} from "../../../../src/mocks/TransferControllerMock.sol";

contract RewardsDistributorTransferControllerTest is RewardsDistributorSetup {
    TransferControllerMock internal controller;

    function setUp() public override {
        super.setUp();
        controller = new TransferControllerMock();
        controller.setAllowAll(false);
        vm.prank(owner);
        token.setTransferController(address(controller));
    }

    function _aliceProof() internal returns (bytes32[] memory) {
        MerkleTreeHelper.Claim[] memory claims = new MerkleTreeHelper.Claim[](1);
        claims[0] = MerkleTreeHelper.Claim(alice, 100e18);
        (, bytes32[][] memory proofs) = updateRoot(claims);
        return proofs[0];
    }

    function test_claim_transferMode_revertsWhenControllerDenies() public {
        bytes32[] memory proof = _aliceProof();
        uint256 distributorBefore = token.balanceOf(address(rewardsDistributor));

        vm.expectRevert(Jane.TransferNotAllowed.selector);
        rewardsDistributor.claim(alice, 100e18, proof);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(rewardsDistributor)), distributorBefore);
        assertEq(rewardsDistributor.claimed(alice), 0);
    }

    function test_claim_mintMode_bypassesController() public {
        addMinter(address(rewardsDistributor));
        toggleMintMode(true);
        bytes32[] memory proof = _aliceProof();

        rewardsDistributor.claim(alice, 100e18, proof);

        assertEq(token.balanceOf(alice), 100e18);
        assertEq(rewardsDistributor.claimed(alice), 100e18);
        assertEq(controller.didTransferCount(), 0);
    }
}
