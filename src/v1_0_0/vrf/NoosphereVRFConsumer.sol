// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {Commitment} from "../types/Commitment.sol";
import {PayloadData} from "../types/PayloadData.sol";
import {TransientComputeClient} from "../client/TransientComputeClient.sol";
import {Delegator} from "../utility/Delegator.sol";
import {INoosphereVRF} from "./INoosphereVRF.sol";

/// @title NoosphereVRFConsumer
/// @notice Abstract contract for dApps that consume Noosphere VRF random values.
/// @dev Inherit this contract and implement the two virtual hooks:
///      - `_onRandomValueReceived(requestId, randomValue, blockHash)` — called on successful verification
///      - `_onRandomValueExpired(requestId)` — called when blockhash is no longer available
///
///      Flow:
///      1. dApp calls `_requestRandomValue(subscriptionId)` — sends compute request + registers with NoosphereVRF
///      2. Node executes VRNG container, delivers result via Noosphere pipeline
///      3. `_receiveCompute()` delegates proof verification to NoosphereVRF singleton
///      4. NoosphereVRF verifies Merkle proof, returns random value + block hash
///      5. Appropriate hook is called based on expiry status
///
///      Subscription management (createSubscription, cancelSubscription) is also provided.
abstract contract NoosphereVRFConsumer is TransientComputeClient, Delegator {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The NoosphereVRF singleton (shared across all consumers)
    INoosphereVRF public immutable noosphereVRF;

    /// @notice Subscription ownership
    mapping(uint64 => address) public subscriptionOwner;

    /// @notice User → subscription IDs
    mapping(address => uint64[]) private userSubscriptions;

    /// @notice Contract owner
    address public owner;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event SubscriptionCreated(uint64 indexed subscriptionId, address indexed owner);
    event SubscriptionCancelled(uint64 indexed subscriptionId, address indexed owner);

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotOwner();
    error NotSubscriptionOwner();
    error InvalidOutputData();

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address router, address signer, address _noosphereVRF)
        TransientComputeClient(router)
        Delegator(signer)
    {
        noosphereVRF = INoosphereVRF(_noosphereVRF);
        owner = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                        SUBSCRIPTION MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function createSubscription(
        string memory containerId,
        bool useDeliveryInbox,
        address feeToken,
        uint256 feeAmount,
        address wallet,
        address verifier,
        bytes32 routeId
    ) external returns (uint64) {
        uint64 subscriptionId = _createComputeSubscription(
            containerId, useDeliveryInbox, feeToken, feeAmount, wallet, verifier, routeId
        );
        subscriptionOwner[subscriptionId] = msg.sender;
        userSubscriptions[msg.sender].push(subscriptionId);
        emit SubscriptionCreated(subscriptionId, msg.sender);
        return subscriptionId;
    }

    function cancelSubscription(uint64 subscriptionId) external {
        if (subscriptionOwner[subscriptionId] != msg.sender) revert NotSubscriptionOwner();
        _cancelComputeSubscription(subscriptionId);

        // Clean up: remove from userSubscriptions array (swap-and-pop)
        uint64[] storage subs = userSubscriptions[msg.sender];
        for (uint256 i = 0; i < subs.length; i++) {
            if (subs[i] == subscriptionId) {
                subs[i] = subs[subs.length - 1];
                subs.pop();
                break;
            }
        }

        // Clear ownership mapping
        delete subscriptionOwner[subscriptionId];

        emit SubscriptionCancelled(subscriptionId, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                         REQUEST RANDOM VALUE
    //////////////////////////////////////////////////////////////*/

    /// @notice Request a random value via the Noosphere VRF pipeline
    /// @dev Reserve-then-bind pattern: atomically reserves requestId first to avoid race conditions,
    ///      then uses the actual ID in the container input, then binds the interval for fulfillment routing.
    /// @param subscriptionId The subscription to use for VRNG
    /// @return requestId The globally unique request ID assigned by NoosphereVRF
    function _requestRandomValue(uint64 subscriptionId) internal returns (uint256 requestId) {
        // Atomically reserve request ID (no race condition — counter incremented in same tx)
        requestId = noosphereVRF.reserveRequestId();

        // Send compute request to VRNG container with the actual (not peeked) request ID
        bytes memory input = abi.encodePacked('{"action":"reveal","game_id":', _uint2str(requestId), "}");
        (, Commitment memory commitment) = _requestCompute(subscriptionId, input);

        // Bind interval to the reserved request ID for fulfillment routing
        noosphereVRF.bindRequest(subscriptionId, commitment.interval, requestId);
    }

    /*//////////////////////////////////////////////////////////////
                      CALLBACK (VRF VERIFICATION)
    //////////////////////////////////////////////////////////////*/

    /// @dev Callback from Noosphere compute pipeline. Decodes data URI internally (cheap internal call),
    ///      then passes pre-decoded values to NoosphereVRF (cheap external call).
    function _receiveCompute(
        uint64 subscriptionId,
        uint32 interval,
        bool,
        address,
        PayloadData calldata,
        PayloadData calldata output,
        PayloadData calldata,
        bytes32
    ) internal override {
        // Decode double base64 data URI internally (no EIP-150 1/64 gas overhead)
        (bytes32 randomValue, bytes32[] memory proof) = _decodeRevealOutput(output.uri);

        // External call to NoosphereVRF with pre-decoded values (only Merkle verify + storage)
        (uint256 requestId, bytes32 blockHash, bool expired) =
            noosphereVRF.fulfillRandomValue(subscriptionId, interval, randomValue, proof);

        if (expired) {
            _onRandomValueExpired(requestId);
        } else {
            _onRandomValueReceived(requestId, randomValue, blockHash);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          VIRTUAL HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Called when a random value is successfully received and verified
    /// @param requestId The globally unique request ID
    /// @param randomValue The verified random value from the Merkle tree
    /// @param blockHash The L2 block hash for 2-party entropy
    function _onRandomValueReceived(uint256 requestId, bytes32 randomValue, bytes32 blockHash) internal virtual;

    /// @notice Called when a request has expired (blockhash no longer available)
    /// @param requestId The globally unique request ID
    function _onRandomValueExpired(uint256 requestId) internal virtual;

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getUserSubscriptions(address user, uint256 offset, uint256 limit) external view returns (uint64[] memory) {
        uint64[] storage subs = userSubscriptions[user];
        uint256 total = subs.length;
        if (offset >= total) return new uint64[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 count = end - offset;
        uint64[] memory result = new uint64[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = subs[offset + i];
        }
        return result;
    }

    function getUserSubscriptionCount(address user) external view returns (uint256) {
        return userSubscriptions[user].length;
    }

    function getSubscriptionOwner(uint64 subscriptionId) external view returns (address) {
        return subscriptionOwner[subscriptionId];
    }

    function updateSigner(address newSigner) external onlyOwner {
        _updateSigner(newSigner);
    }

    function getRouterAddress() external view returns (address) {
        return address(_getRouter());
    }

    /*//////////////////////////////////////////////////////////////
            RAW BYTES DECODE (DATA URI → randomValue + proof)
    //////////////////////////////////////////////////////////////*/

    /// @notice Decode reveal output from data URI: base64(raw bytes) → (randomValue, proof[])
    /// @dev Raw bytes format: randomValue(32 bytes) + proof[0](32 bytes) + ...
    ///      Agent wraps container output: data:;base64,<base64(base64(rawBytes))>
    ///      This function does double base64 decode in a single assembly block
    ///      with one shared lookup table for maximum gas efficiency.
    ///      Runs as an INTERNAL call to avoid EIP-150 1/64 gas overhead.
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

    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _uint2str(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
