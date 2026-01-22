// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {Commitment} from "../types/Commitment.sol";
import {TransientComputeClient} from "../client/TransientComputeClient.sol";
import {Delegator} from "../utility/Delegator.sol";
import {PayloadData} from "../types/PayloadData.sol";

/// @title MyTransientClient
/// @notice A gas-efficient implementation of a TransientComputeClient.
/// @dev This contract provides a public interface to create, request, and cancel subscriptions.
///      Optimized for minimal gas usage - stores only output hash, emits event for full data.
contract MyTransientClient is TransientComputeClient, Delegator {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when compute result is received (for off-chain indexing)
    event ComputeReceived(
        uint64 indexed subscriptionId, uint32 indexed interval, address node, bytes32 outputHash, bytes outputUri
    );

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Last received output hash (minimal storage for verification)
    bytes32 public lastReceivedOutputHash;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param router The address of the main Router contract.
    constructor(address router, address signer) TransientComputeClient(router) Delegator(signer) {}

    /*//////////////////////////////////////////////////////////////
                               PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice A public function to create a new transient compute subscription.
    /// @dev This function wraps the internal `_createComputeSubscription` from the parent contract.
    function createSubscription(
        string memory containerId,
        bool useDeliveryInbox,
        address feeToken,
        uint256 feeAmount,
        address wallet,
        address verifier,
        bytes32 routeId
    ) external returns (uint64) {
        // Call the internal function provided by TransientComputeClient
        return _createComputeSubscription(containerId, useDeliveryInbox, feeToken, feeAmount, wallet, verifier, routeId);
    }

    function requestCompute(uint64 subscriptionId, bytes memory inputs)
        external
        returns (uint64 id, Commitment memory)
    {
        return _requestCompute(subscriptionId, inputs);
    }

    /// @notice A public function to cancel a compute subscription.
    /// @dev Wraps the internal `_cancelComputeSubscription` function.
    function cancelSubscription(uint64 subscriptionId) external {
        _cancelComputeSubscription(subscriptionId);
    }

    /*//////////////////////////////////////////////////////////////
                            CALLBACK OVERRIDE
    //////////////////////////////////////////////////////////////*/

    /// @notice Gas-efficient callback - stores only output hash, emits event for full data.
    /// @dev Full output data available via ComputeReceived event for off-chain indexing.
    function _receiveCompute(
        uint64 subscriptionId,
        uint32 interval,
        bool, /* useDeliveryInbox */
        address node,
        PayloadData calldata, /* input */
        PayloadData calldata output,
        PayloadData calldata, /* proof */
        bytes32 /* containerId */
    ) internal override {
        // Single SSTORE: ~5,000 gas (update) or ~22,100 gas (new)
        lastReceivedOutputHash = output.contentHash;

        // Event emission: ~3,000-5,000 gas (cheaper than storage)
        emit ComputeReceived(subscriptionId, interval, node, output.contentHash, output.uri);
    }

    /// @notice Update new signer
    /// @param newSigner to update
    function updateSigner(address newSigner) external {
        _updateSigner(newSigner);
    }

    /*//////////////////////////////////////////////////////////////
                        BACKWARD COMPATIBILITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns a PayloadData with only the hash populated (for backward compatibility)
    /// @dev Full output data should be retrieved from ComputeReceived events
    function lastReceivedOutput() external view returns (PayloadData memory) {
        return PayloadData({contentHash: lastReceivedOutputHash, uri: bytes("")});
    }

    /*//////////////////////////////////////////////////////////////
                            TYPE & VERSION
    //////////////////////////////////////////////////////////////*/
    function typeAndVersion() external pure override returns (string memory) {
        return "MyTransientClient_v1.1.0";
    }
}
