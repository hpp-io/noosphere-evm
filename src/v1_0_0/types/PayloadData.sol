// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

/**
 * @title InputType
 * @notice Input data type returned by getComputeInputs()
 * @dev Used by Agent to determine how to process the input data
 */
enum InputType {
    RAW_DATA, // 0: Raw inline data (<1KB)
    URI_STRING, // 1: URI string ("ipfs://...", "ar://...", etc.)
    PAYLOAD_DATA // 2: PayloadData struct
}

/**
 * @title PayloadData
 * @notice Structure for referencing off-chain payload data with integrity verification
 * @dev Simple design: contentHash for verification, uri for location
 *
 * Structure:
 * - contentHash (32 bytes): keccak256(content) for integrity verification
 * - uri (variable bytes): Full URI string ("ipfs://...", "https://...", "ar://...")
 *
 * Supported URI schemes (parsed from uri prefix):
 * - "data:": Inline data URI (<1KB)
 * - "ipfs://": IPFS CID
 * - "ar://": Arweave transaction ID
 * - "https://": HTTPS URL
 * - "chain://": On-chain transaction reference
 *
 * Benefits:
 * - Simple: No hash-to-URI reconstruction needed
 * - Extensible: New schemes work without contract changes
 * - Gas efficient: ~40% cheaper than PayloadRef + location
 * - Stack safe: Struct keeps stack depth under control (7 slots total)
 */
struct PayloadData {
    bytes32 contentHash; // keccak256(content) for integrity verification
    bytes uri; // Full URI ("ipfs://...", "https://...", "ar://...")
}
