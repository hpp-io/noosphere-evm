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
///
///      Access control: Blacklist model (default allow, owner can block bad actors)
///      Rate limit: Per-consumer per-block cap on reserveRequestId to prevent epoch exhaustion
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

    /// @notice requestId → the consumer that reserved it (gates binding; deleted after fulfillment)
    mapping(uint256 => address) public requestOwner;

    /// @notice Callback routing: (consumer, subscriptionId, interval) → requestId+1
    /// @dev Scoped by the calling consumer (msg.sender) so a caller can only write/read its
    ///      own bindings — this prevents cross-consumer binding overwrites and fulfillment
    ///      hijacking (a third party cannot consume or delete a binding it did not create).
    ///      Stored as requestId+1 so that 0 means "empty/fulfilled".
    ///      Deleted after fulfillment for replay prevention + gas refund.
    mapping(address => mapping(uint64 => mapping(uint32 => uint256))) private intervalToRequestId;

    /// @notice Blocked consumer contracts (blacklist — default: all allowed)
    mapping(address => bool) public blockedConsumers;

    /// @notice Per-consumer per-block rate limit for reserveRequestId
    uint256 public constant MAX_RESERVES_PER_BLOCK = 10;
    mapping(address => mapping(uint256 => uint256)) private _reservesInBlock;

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotOwner();
    error Blocked();
    error RateLimitExceeded();
    error EpochAlreadyRegistered();
    error EpochNotRegistered();
    error AlreadyFulfilledOrInvalid();
    error InvalidRequestId();
    error NotRequestOwner();
    error InvalidMerkleProof();
    error InvalidOutputData();

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier notBlocked() {
        if (blockedConsumers[msg.sender]) revert Blocked();
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
    function reserveRequestId() external notBlocked returns (uint256 requestId) {
        // Rate limit: max reserves per consumer per block
        uint256 currentBlock = ARB_SYS.arbBlockNumber();
        if (_reservesInBlock[msg.sender][currentBlock] >= MAX_RESERVES_PER_BLOCK) revert RateLimitExceeded();
        _reservesInBlock[msg.sender][currentBlock]++;

        requestId = _nextRequestId++;
        uint256 epoch = requestId / EPOCH_SIZE;
        if (epochRoots[epoch] == bytes32(0)) revert EpochNotRegistered();

        // Record block number for 2-party entropy and the reserving consumer (binding owner)
        requestBlocks[requestId] = ARB_SYS.arbBlockNumber();
        requestOwner[requestId] = msg.sender;

        // Warn when epoch is running low
        uint256 usedInEpoch = requestId % EPOCH_SIZE + 1;
        if (EPOCH_SIZE >= 100 && EPOCH_SIZE - usedInEpoch < 100) {
            emit EpochRunningLow(epoch, EPOCH_SIZE - usedInEpoch);
        }
    }

    /// @inheritdoc INoosphereVRF
    function bindRequest(uint64 subscriptionId, uint32 interval, uint256 requestId) external notBlocked {
        if (requestBlocks[requestId] == 0) revert InvalidRequestId();
        // Only the consumer that reserved this requestId may bind it, and the binding is
        // scoped to that consumer — a caller can neither bind someone else's requestId nor
        // overwrite another consumer's (subscriptionId, interval) routing slot.
        if (requestOwner[requestId] != msg.sender) revert NotRequestOwner();
        intervalToRequestId[msg.sender][subscriptionId][interval] = requestId + 1;
    }

    /// @inheritdoc INoosphereVRF
    function fulfillRandomValue(uint64 subscriptionId, uint32 interval, bytes calldata outputUri)
        external
        notBlocked
        returns (uint256 requestId, bytes32 randomValue, bytes32 blockHash, bool expired)
    {
        // ① Resolve requestId from the caller's own binding namespace (replay prevention:
        //    delete after read). Scoping by msg.sender means a third party cannot consume
        //    or delete a binding it did not create.
        uint256 stored = intervalToRequestId[msg.sender][subscriptionId][interval];
        if (stored == 0) revert AlreadyFulfilledOrInvalid();
        requestId = stored - 1;
        delete intervalToRequestId[msg.sender][subscriptionId][interval]; // replay prevention + gas refund

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
        delete requestOwner[requestId]; // gas refund — binding consumed

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
    function blockConsumer(address consumer) external onlyOwner {
        blockedConsumers[consumer] = true;
        emit ConsumerBlocked(consumer);
    }

    /// @inheritdoc INoosphereVRF
    function unblockConsumer(address consumer) external onlyOwner {
        blockedConsumers[consumer] = false;
        emit ConsumerUnblocked(consumer);
    }

    /// @inheritdoc INoosphereVRF
    function isBlocked(address consumer) external view returns (bool) {
        return blockedConsumers[consumer];
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
        return "NoosphereVRF_v1.1.0";
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
