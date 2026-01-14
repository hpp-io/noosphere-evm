// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

/**
 * @title PayloadScheme
 * @notice URI scheme types for off-chain payload references
 */
enum PayloadScheme {
    DATA_INLINE, // 0: data: URI (inline, <1KB)
    IPFS,        // 1: ipfs://CID
    ARWEAVE,     // 2: ar://txId
    HTTPS,       // 3: https://url?integrity=hash
    CHAIN        // 4: chain://chainId/txHash
}

/**
 * @title InputType
 * @notice Input data type returned by getComputeInputsWithType()
 * @dev Used by Agent to determine how to process the input data
 */
enum InputType {
    RAW_DATA,    // 0: Raw inline data (<1KB)
    URI_STRING,  // 1: URI string ("ipfs://...", "ar://...", etc.)
    PAYLOAD_REF  // 2: PayloadRef (65 bytes encoded)
}

/**
 * @title PayloadRef
 * @notice 65-byte compact structure for referencing off-chain payload data
 * @dev Replaces variable-size bytes with fixed-size reference to reduce gas costs
 *
 * Structure (65 bytes total):
 * - schemeType (1 byte): URI scheme identifier
 * - contentHash (32 bytes): Content integrity hash (keccak256 or CID)
 * - locationData (32 bytes): Location info (varies by scheme)
 *
 * Gas Optimization:
 * - Before: O(data size) - calldata costs scale with payload size
 * - After: O(1) - fixed 65 bytes regardless of actual data size
 *
 * Scheme-specific locationData encoding:
 * - DATA_INLINE: unused (0x0)
 * - IPFS: CID prefix + padding
 * - ARWEAVE: Transaction ID (base64url → hex)
 * - HTTPS: keccak256(URL)
 * - CHAIN: chainId (8 bytes) + txHash prefix (24 bytes)
 */
struct PayloadRef {
    uint8 schemeType;      // 1 byte: PayloadScheme enum value
    bytes32 contentHash;   // 32 bytes: Content integrity hash
    bytes32 locationData;  // 32 bytes: Scheme-specific location info
}
