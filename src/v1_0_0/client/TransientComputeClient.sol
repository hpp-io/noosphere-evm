// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {Commitment} from "../types/Commitment.sol";
import {ComputeClient} from "./ComputeClient.sol";

/**
 * @title TransientComputeClient
 * @dev This abstract contract provides a client for interacting with the Noosphere compute network.
 * It extends `ComputeClient` and adds functionality for managing transient compute subscriptions,
 * where the inputs for a computation are stored temporarily on-chain.
 */
abstract contract TransientComputeClient is ComputeClient {
    /// @dev Stores the inputs for each transient compute request, mapped by subscription ID and a unique interval.
    mapping(uint64 => mapping(uint32 => bytes)) private _subscriptionInputs;

    /// @dev A counter to ensure a unique interval for each transient request within a subscription.
    mapping(uint64 => uint32) private _requestNonces;

    constructor(address router) ComputeClient(router) {}

    function _createComputeSubscription(
        string memory containerId,
        uint16 redundancy,
        bool useDeliveryInbox,
        address feeToken,
        uint256 feeAmount,
        address wallet,
        address verifier,
        bytes32 routeId
    ) internal returns (uint64) {
        return _getRouter()
            .createComputeSubscription(
                containerId, 1, 0, redundancy, useDeliveryInbox, feeToken, feeAmount, wallet, verifier, routeId
            );
    }

    function _requestCompute(uint64 subscriptionId, bytes memory inputs) internal returns (uint64, Commitment memory) {
        // Increment the nonce for the subscription to get a unique interval for this request.
        // For transient subscriptions, the 'interval' field is used as a nonce to ensure request uniqueness,
        // rather than representing a time-based interval.
        uint32 interval = ++_requestNonces[subscriptionId];
        _subscriptionInputs[subscriptionId][interval] = inputs;
        (, Commitment memory commitment) = _getRouter().sendRequest(subscriptionId, interval);
        return (subscriptionId, commitment);
    }

    function getComputeInputs(uint64 subscriptionId, uint32 interval, uint32 timestamp, address caller)
        external
        view
        override
        returns (bytes memory)
    {
        // Returns the inputs stored for a specific subscription and interval.
        return _subscriptionInputs[subscriptionId][interval];
    }
}
