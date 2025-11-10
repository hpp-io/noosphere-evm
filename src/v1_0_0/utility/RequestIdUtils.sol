// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

/// @title RequestId utils
/// @notice Utility helpers to compute requestId := keccak256(abi.encodePacked(...))
library RequestIdUtils {
    /// @notice Compute keccak256(abi.encodePacked(subscriptionId (uint64), interval (uint32)))
    /// @dev This matches abi.encodePacked(uint64, uint32) -> 12 bytes total.
    ///      Uses memory-safe inline assembly to avoid extra allocations and lint warnings.
    function requestIdPacked(uint64 subscriptionId, uint32 interval) internal pure returns (bytes32 rid) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            // put subscriptionId (8 bytes) and interval (4 bytes) into the high-order bytes of the word
            let s := shl(192, subscriptionId) // subscriptionId << 192
            let t := shl(160, interval) // interval << 160
            mstore(ptr, or(s, t))
            // HASH THE FIRST 12 BYTES (abi.encodePacked(uint64, uint32) order)
            rid := keccak256(ptr, 0x0c)
            // bump free memory pointer by 0x20 (we used 32 bytes)
            mstore(0x40, add(ptr, 0x20))
        }
    }

    /// @notice Compute keccak256(abi.encode(subscriptionId, interval))
    /// @dev Safe for cases where original code used abi.encode (32-byte padded per value).
    function requestIdEncoded(uint64 subscriptionId, uint32 interval) internal pure returns (bytes32 rid) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, subscriptionId)
            mstore(add(ptr, 0x20), interval)
            rid := keccak256(ptr, 0x40) // 2 * 32 bytes
            mstore(0x40, add(ptr, 0x40))
        }
    }

    /// @notice Convenience: for uint256 / uint256 encoded (most generic)
    function requestIdUint256(uint256 subscriptionId, uint256 interval) internal pure returns (bytes32 rid) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, subscriptionId)
            mstore(add(ptr, 0x20), interval)
            rid := keccak256(ptr, 0x40)
            mstore(0x40, add(ptr, 0x40))
        }
    }
}
