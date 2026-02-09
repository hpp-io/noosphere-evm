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
    function fulfillRandomValue(uint64 subscriptionId, uint32 interval, bytes32 randomValue, bytes32[] calldata proof)
        external
        onlyConsumer
        returns (uint256 requestId, bytes32 blockHash, bool expired)
    {
        // ① Resolve requestId (replay prevention: delete after read)
        uint256 stored = intervalToRequestId[subscriptionId][interval];
        if (stored == 0) revert AlreadyFulfilledOrInvalid();
        requestId = stored - 1;
        delete intervalToRequestId[subscriptionId][interval]; // replay prevention + gas refund

        // ② Verify Merkle proof (leaf bound to index within epoch)
        uint256 epoch = requestId / EPOCH_SIZE;
        uint256 indexInEpoch = requestId % EPOCH_SIZE;
        bytes32 leaf = keccak256(abi.encodePacked(indexInEpoch, randomValue));
        if (!MerkleProof.verify(proof, epochRoots[epoch], leaf)) revert InvalidMerkleProof();

        // ③ Get L2 blockhash for 2-party entropy (via ArbSys)
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

}
