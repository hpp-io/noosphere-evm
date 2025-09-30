// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Commitment} from "../types/Commitment.sol";
import {TransientComputeClient} from "../client/TransientComputeClient.sol";

/// @title MyTransientClient
/// @notice An example implementation of a TransientComputeClient.
/// @dev This contract provides a public interface to create, request, and cancel subscriptions,
///      and demonstrates how to receive compute results.
contract MyTransientClient is TransientComputeClient {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    // State variables to store the result of the last compute callback for testing purposes.
    uint64 public lastReceivedSubscriptionId;
    uint32 public lastReceivedInterval;
    address public lastReceivedNode;
    bytes public lastReceivedOutput;
    bytes32 public lastReceivedContainerId;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param router The address of the main Router contract.
    constructor(address router) TransientComputeClient(router) {}

    /*//////////////////////////////////////////////////////////////
                               PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice A public function to create a new transient compute subscription.
    /// @dev This function wraps the internal `_createComputeSubscription` from the parent contract.
    function createSubscription(
        string memory containerId,
        uint16 redundancy,
        bool useDeliveryInbox,
        address feeToken,
        uint256 feeAmount,
        address wallet,
        address verifier,
        bytes32 routeId
    ) external returns (uint64) {
        // Call the internal function provided by TransientComputeClient
        return _createComputeSubscription(
            containerId, redundancy, useDeliveryInbox, feeToken, feeAmount, wallet, verifier, routeId
        );
    }

    function requestCompute(uint64 subscriptionId, bytes memory inputs)
        external
        returns (uint64 id, Commitment memory)
    {
        return _requestCompute(subscriptionId, inputs);
    }

    /// @notice A public function to request a compute job for an existing subscription.
    /// @dev Wraps the internal `_requestCompute` function.
    function MockDelegatorScheduledComputeClient(uint64 subscriptionId, bytes memory inputs)
        external
        returns (uint64, Commitment memory)
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

    /// @notice Overrides the internal virtual function to handle the result of a compute request.
    /// @dev This function is called by the Router upon successful fulfillment.
    ///      Here, we simply store the received data in public state variables for easy verification.
    function _receiveCompute(
        uint64 subscriptionId,
        uint32 interval,
        uint16, /* numRedundantDeliveries */
        bool, /* useDeliveryInbox */
        address node,
        bytes calldata, /* input */
        bytes calldata output,
        bytes calldata, /* proof */
        bytes32 containerId
    ) internal override {
        lastReceivedSubscriptionId = subscriptionId;
        lastReceivedInterval = interval;
        lastReceivedNode = node;
        lastReceivedOutput = output;
        lastReceivedContainerId = containerId;
    }

    /*//////////////////////////////////////////////////////////////
                            TYPE & VERSION
    //////////////////////////////////////////////////////////////*/
    function typeAndVersion() external pure override returns (string memory) {
        return "MyTransientClient_v1.0.0";
    }
}
