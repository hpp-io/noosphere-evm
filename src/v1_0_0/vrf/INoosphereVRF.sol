// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

/// @title INoosphereVRF
/// @notice Public interface for Noosphere VRF singleton
/// @dev Manages epoch-based Merkle tree random values shared across all consumer dApps.
///      Provides global request ID assignment, Merkle proof verification, and replay prevention.
interface INoosphereVRF {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event EpochRegistered(uint256 indexed epoch, bytes32 merkleRoot, uint256 size);
    event EpochRunningLow(uint256 indexed epoch, uint256 remaining);
    event RandomValueVerified(uint256 indexed requestId, bytes32 randomValue, bytes32 blockHash);
    event RandomValueExpired(uint256 indexed requestId);
    event ConsumerAdded(address indexed consumer);
    event ConsumerRemoved(address indexed consumer);

    /*//////////////////////////////////////////////////////////////
                          EPOCH MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a Merkle root for an epoch (owner only, one-time per epoch)
    function registerEpoch(uint256 epoch, bytes32 merkleRoot) external;

    /// @notice Get the Merkle root for an epoch
    function getEpochRoot(uint256 epoch) external view returns (bytes32);

    /// @notice Get remaining slots in the current epoch
    function getEpochRemaining() external view returns (uint256);

    /// @notice Get the current epoch number
    function getCurrentEpoch() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                        REQUEST LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Assign a global request ID and record block number (called by VRFConsumer)
    /// @param subscriptionId The Noosphere subscription ID
    /// @param interval The interval assigned by _requestCompute()
    /// @return requestId The globally unique request ID
    function requestRandomValue(uint64 subscriptionId, uint32 interval) external returns (uint256 requestId);

    /// @notice Verify Merkle proof and return random value (called by VRFConsumer callback)
    /// @param subscriptionId The Noosphere subscription ID
    /// @param interval The interval from the callback
    /// @param outputUri The raw output URI from the VRNG container
    /// @return requestId The resolved request ID
    /// @return randomValue The verified random value from the Merkle tree
    /// @return blockHash The L2 block hash for 2-party entropy
    /// @return expired Whether the request expired (blockHash unavailable)
    function fulfillRandomValue(uint64 subscriptionId, uint32 interval, bytes calldata outputUri)
        external
        returns (uint256 requestId, bytes32 randomValue, bytes32 blockHash, bool expired);

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the next request ID that will be assigned
    function nextRequestId() external view returns (uint256);

    /// @notice Check if a request has expired (block hash no longer available)
    function isRequestExpired(uint256 requestId) external view returns (bool);

    /// @notice Get the block number when a request was made
    function getRequestBlock(uint256 requestId) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                              CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Number of random values per epoch
    function EPOCH_SIZE() external view returns (uint256);

    /// @notice Number of blocks before block hash becomes unavailable
    function BLOCKHASH_TIMEOUT() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                      CONSUMER MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Add an authorized consumer contract (owner only)
    function addConsumer(address consumer) external;

    /// @notice Remove an authorized consumer contract (owner only)
    function removeConsumer(address consumer) external;

    /// @notice Check if an address is an authorized consumer
    function isAuthorizedConsumer(address consumer) external view returns (bool);
}
