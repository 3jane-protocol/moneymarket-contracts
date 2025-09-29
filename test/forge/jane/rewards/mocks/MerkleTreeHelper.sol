// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";

/**
 * @title MerkleTreeHelper
 * @notice Helper contract for generating merkle trees and proofs in tests
 */
contract MerkleTreeHelper is Test {
    struct Claim {
        address user;
        uint256 amount;
    }

    /**
     * @notice Generates a merkle tree from an array of claims
     * @param claims Array of claims to include in the tree
     * @return root The merkle root of the tree
     * @return proofs Array of proofs for each claim
     */
    function generateMerkleTree(Claim[] memory claims) public pure returns (bytes32 root, bytes32[][] memory proofs) {
        uint256 n = claims.length;
        require(n > 0, "Empty claims");

        // Generate leaves
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            leaves[i] = computeLeaf(claims[i].user, claims[i].amount);
        }

        // Sort leaves for consistent tree generation
        leaves = sortBytes32Array(leaves);

        // Generate proofs for each leaf
        proofs = new bytes32[][](n);
        for (uint256 i = 0; i < n; i++) {
            bytes32 targetLeaf = computeLeaf(claims[i].user, claims[i].amount);
            uint256 leafIndex = findLeafIndex(leaves, targetLeaf);
            proofs[i] = generateProof(leaves, leafIndex);
        }

        // Calculate root
        root = computeMerkleRoot(leaves);
    }

    /**
     * @notice Generates a proof for a specific leaf in the tree
     * @param leaves All leaves in the tree
     * @param index Index of the leaf to generate proof for
     * @return proof The merkle proof for the leaf
     */
    function generateProof(bytes32[] memory leaves, uint256 index) public pure returns (bytes32[] memory proof) {
        uint256 n = leaves.length;
        require(index < n, "Index out of bounds");

        // Calculate proof size (log2(n) rounded up)
        uint256 proofSize = 0;
        uint256 temp = n - 1;
        while (temp > 0) {
            proofSize++;
            temp >>= 1;
        }

        proof = new bytes32[](proofSize);
        uint256 proofIndex = 0;

        // Build the tree level by level
        bytes32[] memory currentLevel = leaves;
        uint256 currentIndex = index;

        while (currentLevel.length > 1) {
            bytes32[] memory nextLevel = new bytes32[]((currentLevel.length + 1) / 2);

            for (uint256 i = 0; i < currentLevel.length; i += 2) {
                uint256 pairIndex = i / 2;
                if (i + 1 < currentLevel.length) {
                    // Add sibling to proof if needed
                    if (i == currentIndex || i + 1 == currentIndex) {
                        if (proofIndex < proofSize) {
                            proof[proofIndex++] = (i == currentIndex) ? currentLevel[i + 1] : currentLevel[i];
                        }
                    }
                    // Compute parent hash
                    nextLevel[pairIndex] = hashPair(currentLevel[i], currentLevel[i + 1]);
                } else {
                    // Odd number of elements, promote the last one
                    nextLevel[pairIndex] = currentLevel[i];
                }
            }

            // Update index for next level
            currentIndex = currentIndex / 2;
            currentLevel = nextLevel;
        }

        // Resize proof array if needed
        if (proofIndex < proofSize) {
            bytes32[] memory resizedProof = new bytes32[](proofIndex);
            for (uint256 i = 0; i < proofIndex; i++) {
                resizedProof[i] = proof[i];
            }
            proof = resizedProof;
        }
    }

    /**
     * @notice Computes a leaf hash from user address and amount
     * @param user The user address
     * @param amount The claim amount
     * @return The leaf hash
     */
    function computeLeaf(address user, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(user, amount))));
    }

    /**
     * @notice Computes the merkle root from an array of leaves
     * @param leaves The array of leaf hashes
     * @return The merkle root
     */
    function computeMerkleRoot(bytes32[] memory leaves) public pure returns (bytes32) {
        uint256 n = leaves.length;
        require(n > 0, "Empty leaves");

        if (n == 1) return leaves[0];

        // Build tree level by level
        bytes32[] memory currentLevel = leaves;

        while (currentLevel.length > 1) {
            bytes32[] memory nextLevel = new bytes32[]((currentLevel.length + 1) / 2);

            for (uint256 i = 0; i < currentLevel.length; i += 2) {
                if (i + 1 < currentLevel.length) {
                    nextLevel[i / 2] = hashPair(currentLevel[i], currentLevel[i + 1]);
                } else {
                    nextLevel[i / 2] = currentLevel[i];
                }
            }

            currentLevel = nextLevel;
        }

        return currentLevel[0];
    }

    /**
     * @notice Hashes a pair of bytes32 values
     * @param a First value
     * @param b Second value
     * @return The hash of the pair
     */
    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /**
     * @notice Finds the index of a leaf in the sorted array
     * @param leaves Sorted array of leaves
     * @param target Target leaf to find
     * @return Index of the target leaf
     */
    function findLeafIndex(bytes32[] memory leaves, bytes32 target) internal pure returns (uint256) {
        for (uint256 i = 0; i < leaves.length; i++) {
            if (leaves[i] == target) return i;
        }
        revert("Leaf not found");
    }

    /**
     * @notice Sorts an array of bytes32 values
     * @param arr Array to sort
     * @return Sorted array
     */
    function sortBytes32Array(bytes32[] memory arr) internal pure returns (bytes32[] memory) {
        uint256 n = arr.length;
        for (uint256 i = 0; i < n - 1; i++) {
            for (uint256 j = 0; j < n - i - 1; j++) {
                if (arr[j] > arr[j + 1]) {
                    bytes32 temp = arr[j];
                    arr[j] = arr[j + 1];
                    arr[j + 1] = temp;
                }
            }
        }
        return arr;
    }

    /**
     * @notice Generates a large set of claims for gas testing
     * @param userCount Number of users to generate claims for
     * @param baseAmount Base amount for claims
     * @return claims Array of generated claims
     */
    function generateLargeClaims(uint256 userCount, uint256 baseAmount) public pure returns (Claim[] memory claims) {
        claims = new Claim[](userCount);
        for (uint256 i = 0; i < userCount; i++) {
            claims[i] = Claim({user: address(uint160(0x1000000 + i)), amount: baseAmount + (i * 1e18)});
        }
    }
}
