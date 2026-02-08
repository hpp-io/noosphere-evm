// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {INoosphereVRF} from "./INoosphereVRF.sol";
import {ITypeAndVersion} from "../interfaces/ITypeAndVersion.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @dev Arbitrum ArbSys predeploy for L2 block number/hash
interface ArbSys {
    function arbBlockNumber() external view returns (uint256);
    function arbBlockHash(uint256 arbBlockNum) external view returns (bytes32);
}

/// @title NoosphereVRF
/// @notice Singleton contract for Noosphere VRF — shared across all consumer dApps.
/// @dev Manages epoch roots, global request IDs, Merkle proof verification, and replay prevention.
///      Deployed once per chain. Consumer dApps (NoosphereVRFConsumer) call this contract
///      to request and fulfill random values.
///
///      Security model:
///      - Random values are pre-committed via Merkle tree root (one-time, per epoch)
///      - Each request is bound to a unique index in the epoch
///      - Merkle proof ensures the random value matches the committed root
///      - Block hash adds 2-party entropy (neither VRNG operator nor sequencer can predict both)
///      - Replay prevention via delete-after-use pattern (Chainlink VRF Coordinator pattern)
contract NoosphereVRF is INoosphereVRF, ITypeAndVersion {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant BLOCKHASH_TIMEOUT = 256;
    uint256 public constant EPOCH_SIZE = 1000;

    /// @dev Arbitrum ArbSys predeploy at 0x64
    ArbSys private constant ARB_SYS = ArbSys(address(0x0000000000000000000000000000000000000064));

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract owner (can register epochs and manage consumers)
    address public owner;

    /// @notice Next request ID (monotonically increasing, global across all consumers)
    uint256 private _nextRequestId;

    /// @notice Merkle roots for each epoch
    mapping(uint256 => bytes32) public epochRoots;

    /// @notice Block number when each request was made (deleted after fulfillment)
    mapping(uint256 => uint256) public requestBlocks;

    /// @notice Callback routing: (subscriptionId, interval) → requestId+1
    /// @dev Stored as requestId+1 so that 0 means "empty/fulfilled".
    ///      Deleted after fulfillment for replay prevention + gas refund.
    mapping(uint64 => mapping(uint32 => uint256)) private intervalToRequestId;

    /// @notice Authorized consumer contracts (whitelist)
    mapping(address => bool) public authorizedConsumers;

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotOwner();
    error NotAuthorizedConsumer();
    error EpochAlreadyRegistered();
    error EpochNotRegistered();
    error AlreadyFulfilledOrInvalid();
    error InvalidRequestId();
    error InvalidMerkleProof();
    error InvalidOutputData();

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyConsumer() {
        if (!authorizedConsumers[msg.sender]) revert NotAuthorizedConsumer();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner) {
        owner = _owner;
    }

    /*//////////////////////////////////////////////////////////////
                          EPOCH MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INoosphereVRF
    function registerEpoch(uint256 epoch, bytes32 merkleRoot) external onlyOwner {
        if (epochRoots[epoch] != bytes32(0)) revert EpochAlreadyRegistered();
        epochRoots[epoch] = merkleRoot;
        emit EpochRegistered(epoch, merkleRoot, EPOCH_SIZE);
    }

    /*//////////////////////////////////////////////////////////////
                        REQUEST LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INoosphereVRF
    function reserveRequestId() external onlyConsumer returns (uint256 requestId) {
        requestId = _nextRequestId++;
        uint256 epoch = requestId / EPOCH_SIZE;
        if (epochRoots[epoch] == bytes32(0)) revert EpochNotRegistered();

        // Record block number for 2-party entropy
        requestBlocks[requestId] = ARB_SYS.arbBlockNumber();

        // Warn when epoch is running low
        uint256 usedInEpoch = requestId % EPOCH_SIZE + 1;
        if (EPOCH_SIZE >= 100 && EPOCH_SIZE - usedInEpoch < 100) {
            emit EpochRunningLow(epoch, EPOCH_SIZE - usedInEpoch);
        }
    }

    /// @inheritdoc INoosphereVRF
    function bindRequest(uint64 subscriptionId, uint32 interval, uint256 requestId) external onlyConsumer {
        if (requestBlocks[requestId] == 0) revert InvalidRequestId();
        intervalToRequestId[subscriptionId][interval] = requestId + 1;
    }

    /// @inheritdoc INoosphereVRF
    function fulfillRandomValue(uint64 subscriptionId, uint32 interval, bytes calldata outputUri)
        external
        onlyConsumer
        returns (uint256 requestId, bytes32 randomValue, bytes32 blockHash, bool expired)
    {
        // ① Resolve requestId (replay prevention: delete after read)
        uint256 stored = intervalToRequestId[subscriptionId][interval];
        if (stored == 0) revert AlreadyFulfilledOrInvalid();
        requestId = stored - 1;
        delete intervalToRequestId[subscriptionId][interval]; // replay prevention + gas refund

        // ② Decode packed hex from data URI
        bytes32[] memory proof;
        (randomValue, proof) = _decodeRevealOutput(outputUri);

        // ③ Verify Merkle proof (leaf bound to index within epoch)
        uint256 epoch = requestId / EPOCH_SIZE;
        uint256 indexInEpoch = requestId % EPOCH_SIZE;
        bytes32 leaf = keccak256(abi.encodePacked(indexInEpoch, randomValue));
        if (!MerkleProof.verify(proof, epochRoots[epoch], leaf)) revert InvalidMerkleProof();

        // ④ Get L2 blockhash for 2-party entropy (via ArbSys)
        blockHash = ARB_SYS.arbBlockHash(requestBlocks[requestId]);
        delete requestBlocks[requestId]; // gas refund — no longer needed

        expired = (blockHash == bytes32(0));

        if (expired) {
            emit RandomValueExpired(requestId);
        } else {
            emit RandomValueVerified(requestId, randomValue, blockHash);
        }
    }

    /*//////////////////////////////////////////////////////////////
                      CONSUMER MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INoosphereVRF
    function addConsumer(address consumer) external onlyOwner {
        authorizedConsumers[consumer] = true;
        emit ConsumerAdded(consumer);
    }

    /// @inheritdoc INoosphereVRF
    function removeConsumer(address consumer) external onlyOwner {
        authorizedConsumers[consumer] = false;
        emit ConsumerRemoved(consumer);
    }

    /// @inheritdoc INoosphereVRF
    function isAuthorizedConsumer(address consumer) external view returns (bool) {
        return authorizedConsumers[consumer];
    }

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INoosphereVRF
    function nextRequestId() external view returns (uint256) {
        return _nextRequestId;
    }

    /// @inheritdoc INoosphereVRF
    function isRequestExpired(uint256 requestId) external view returns (bool) {
        uint256 blockNum = requestBlocks[requestId];
        if (blockNum == 0) return true; // already fulfilled or never existed
        return ARB_SYS.arbBlockNumber() > blockNum + BLOCKHASH_TIMEOUT;
    }

    /// @inheritdoc INoosphereVRF
    function getRequestBlock(uint256 requestId) external view returns (uint256) {
        return requestBlocks[requestId];
    }

    /// @inheritdoc INoosphereVRF
    function getEpochRoot(uint256 epoch) external view returns (bytes32) {
        return epochRoots[epoch];
    }

    /// @inheritdoc INoosphereVRF
    function getEpochRemaining() external view returns (uint256) {
        uint256 currentEpoch = _nextRequestId / EPOCH_SIZE;
        uint256 usedInEpoch = _nextRequestId % EPOCH_SIZE;
        if (epochRoots[currentEpoch] == bytes32(0)) return 0;
        return EPOCH_SIZE - usedInEpoch;
    }

    /// @inheritdoc INoosphereVRF
    function getCurrentEpoch() external view returns (uint256) {
        return _nextRequestId / EPOCH_SIZE;
    }

    /// @notice Transfer ownership
    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    /// @inheritdoc ITypeAndVersion
    function typeAndVersion() external pure returns (string memory) {
        return "NoosphereVRF_v1.0.0";
    }

    /*//////////////////////////////////////////////////////////////
            RAW BYTES DECODE (DATA URI → randomValue + proof)
    //////////////////////////////////////////////////////////////*/

    /// @notice Decode reveal output from data URI: base64(raw bytes) → (randomValue, proof[])
    /// @dev Raw bytes format: randomValue(32 bytes) + proof[0](32 bytes) + ...
    ///      Agent wraps container output: data:;base64,<base64(base64(rawBytes))>
    ///      This function does double base64 decode in a single assembly block
    ///      with one shared lookup table for maximum gas efficiency.
    function _decodeRevealOutput(bytes calldata uri)
        internal
        pure
        returns (bytes32 randomValue, bytes32[] memory proof)
    {
        uint256 decodedLen;
        assembly {
            // ── Build base64 lookup table (256 bytes) ──
            let table := mload(0x40)
            // Zero-fill 256 bytes (8 × 32-byte words)
            for { let i := 0 } lt(i, 8) { i := add(i, 1) } {
                mstore(add(table, mul(i, 32)), 0)
            }
            // A-Z → 0-25
            for { let i := 0 } lt(i, 26) { i := add(i, 1) } { mstore8(add(table, add(65, i)), i) }
            // a-z → 26-51
            for { let i := 0 } lt(i, 26) { i := add(i, 1) } { mstore8(add(table, add(97, i)), add(26, i)) }
            // 0-9 → 52-61
            for { let i := 0 } lt(i, 10) { i := add(i, 1) } { mstore8(add(table, add(48, i)), add(52, i)) }
            // + → 62, / → 63
            mstore8(add(table, 43), 62)
            mstore8(add(table, 47), 63)

            // ── Step 1: Copy outer base64 from calldata to memory ──
            // URI format: "data:;base64," (13 bytes) + base64 content
            let outerLen := sub(uri.length, 13)
            let outerSrc := add(uri.offset, 13)
            // Allocate memory for outer base64 data
            let outerMem := add(table, 256)
            calldatacopy(outerMem, outerSrc, outerLen)

            // ── Step 2: Decode outer base64 → inner base64 string ──
            let outerDecLen := mul(div(outerLen, 4), 3)
            // Check padding
            let outerEnd := add(outerMem, sub(outerLen, 1))
            if eq(byte(0, mload(outerEnd)), 0x3d) { outerDecLen := sub(outerDecLen, 1) }
            if eq(byte(0, mload(sub(outerEnd, 1))), 0x3d) { outerDecLen := sub(outerDecLen, 1) }

            let innerB64 := add(outerMem, outerLen) // place after outer data (reuse memory)
            let rp := innerB64
            let dp := outerMem
            let dpEnd := add(dp, outerLen)
            for {} lt(dp, dpEnd) { dp := add(dp, 4) } {
                let a := byte(0, mload(add(table, byte(0, mload(dp)))))
                let b := byte(0, mload(add(table, byte(0, mload(add(dp, 1))))))
                let c := byte(0, mload(add(table, byte(0, mload(add(dp, 2))))))
                let d := byte(0, mload(add(table, byte(0, mload(add(dp, 3))))))
                let triple := or(or(shl(18, a), shl(12, b)), or(shl(6, c), d))
                mstore8(rp, shr(16, triple))
                mstore8(add(rp, 1), and(shr(8, triple), 0xFF))
                mstore8(add(rp, 2), and(triple, 0xFF))
                rp := add(rp, 3)
            }

            // ── Step 3: Decode inner base64 → raw bytes ──
            let innerLen := outerDecLen
            let innerDecLen := mul(div(innerLen, 4), 3)
            let innerEnd := add(innerB64, sub(innerLen, 1))
            if eq(byte(0, mload(innerEnd)), 0x3d) { innerDecLen := sub(innerDecLen, 1) }
            if eq(byte(0, mload(sub(innerEnd, 1))), 0x3d) { innerDecLen := sub(innerDecLen, 1) }

            let rawBytes := add(innerB64, innerLen)
            rp := rawBytes
            dp := innerB64
            dpEnd := add(dp, innerLen)
            for {} lt(dp, dpEnd) { dp := add(dp, 4) } {
                let a := byte(0, mload(add(table, byte(0, mload(dp)))))
                let b := byte(0, mload(add(table, byte(0, mload(add(dp, 1))))))
                let c := byte(0, mload(add(table, byte(0, mload(add(dp, 2))))))
                let d := byte(0, mload(add(table, byte(0, mload(add(dp, 3))))))
                let triple := or(or(shl(18, a), shl(12, b)), or(shl(6, c), d))
                mstore8(rp, shr(16, triple))
                mstore8(add(rp, 1), and(shr(8, triple), 0xFF))
                mstore8(add(rp, 2), and(triple, 0xFF))
                rp := add(rp, 3)
            }

            // Store decoded length for post-assembly validation
            decodedLen := innerDecLen

            // ── Step 4: Extract randomValue (first 32 bytes) ──
            // EVM mload works at any memory offset — no alignment copy needed
            randomValue := mload(rawBytes)

            // ── Step 5: Build proof array ──
            let proofBytes := 0
            let proofCount := 0
            if gt(innerDecLen, 31) {
                proofBytes := sub(innerDecLen, 32)
                proofCount := div(proofBytes, 32)
            }

            // Allocate proof array after raw data region
            let proofArrayStart := add(rawBytes, innerDecLen)
            proof := proofArrayStart
            mstore(proof, proofCount)
            let proofData := add(proof, 32)
            let rawProofStart := add(rawBytes, 32)
            // Single mload+mstore per 32-byte element (replaces 32x byte-by-byte copy)
            for { let i := 0 } lt(i, proofCount) { i := add(i, 1) } {
                mstore(add(proofData, mul(i, 32)), mload(add(rawProofStart, mul(i, 32))))
            }

            // Update free memory pointer
            mstore(0x40, add(proofData, mul(proofCount, 32)))
        }

        // Validate decoded output has at least 32 bytes (randomValue)
        if (decodedLen < 32) revert InvalidOutputData();
    }
}
