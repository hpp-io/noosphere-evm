// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.23;

/// @title Merkle
/// @notice A utility library for creating Merkle trees and proofs for testing purposes.
/// @dev This is a simplified implementation for tests and may not be gas-optimal for production.
/// It assumes sorted pairs for hashing.
library Merkle {
    /// @notice Calculates the Merkle root for a given array of leaves.
    /// @param leaves An array of `bytes32` leaves.
    /// @return The Merkle root as a `bytes32` hash.
    function getMerkleRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        if (leaves.length == 0) {
            return bytes32(0);
        }
        if (leaves.length == 1) {
            return leaves[0];
        }

        bytes32[] memory nextLayer = new bytes32[]((leaves.length + 1) / 2);

        for (uint256 i = 0; i < nextLayer.length; i++) {
            uint256 leftIndex = i * 2;
            uint256 rightIndex = leftIndex + 1;

            if (rightIndex < leaves.length) {
                bytes32 left = leaves[leftIndex];
                bytes32 right = leaves[rightIndex];
                if (left < right) {
                    nextLayer[i] = keccak256(abi.encodePacked(left, right));
                } else {
                    nextLayer[i] = keccak256(abi.encodePacked(right, left));
                }
            } else {
                nextLayer[i] = leaves[leftIndex];
            }
        }

        return getMerkleRoot(nextLayer);
    }

    /// @notice Generates a Merkle proof for a specific leaf.
    /// @param leaves The full list of leaves in the tree.
    /// @param leaf The leaf for which to generate the proof.
    /// @return proof An array of `bytes32` hashes representing the Merkle proof.
    function getMerkleProof(bytes32[] memory leaves, bytes32 leaf) internal pure returns (bytes32[] memory proof) {
        uint256 leafIndex = _findLeafIndex(leaves, leaf);
        require(leafIndex != type(uint256).max, "Leaf not found in leaves array");

        uint256 numLevels = 0;
        uint256 n = leaves.length;
        while (n > 1) {
            numLevels++;
            n = (n + 1) / 2;
        }

        proof = new bytes32[](numLevels);
        uint256 proofIndex = 0;

        bytes32[] memory currentLayer = leaves;

        while (currentLayer.length > 1) {
            if (leafIndex % 2 == 0) {
                // Left node
                if (leafIndex + 1 < currentLayer.length) {
                    // Has a right sibling
                    proof[proofIndex] = currentLayer[leafIndex + 1];
                }
            } else {
                // Right node
                proof[proofIndex] = currentLayer[leafIndex - 1];
            }
            proofIndex++;

            bytes32[] memory nextLayer = new bytes32[]((currentLayer.length + 1) / 2);
            for (uint256 i = 0; i < nextLayer.length; i++) {
                uint256 leftIdx = i * 2;
                uint256 rightIdx = leftIdx + 1;
                if (rightIdx < currentLayer.length) {
                    bytes32 left = currentLayer[leftIdx];
                    bytes32 right = currentLayer[rightIdx];
                    if (left < right) {
                        nextLayer[i] = keccak256(abi.encodePacked(left, right));
                    } else {
                        nextLayer[i] = keccak256(abi.encodePacked(right, left));
                    }
                } else {
                    nextLayer[i] = currentLayer[leftIdx];
                }
            }
            currentLayer = nextLayer;
            leafIndex /= 2;
        }
    }

    /// @dev Internal helper to find the index of a leaf in an array.
    function _findLeafIndex(bytes32[] memory leaves, bytes32 leaf) private pure returns (uint256) {
        for (uint256 i = 0; i < leaves.length; i++) {
            if (leaves[i] == leaf) {
                return i;
            }
        }
        return type(uint256).max; // Sentinel for not found
    }
}
