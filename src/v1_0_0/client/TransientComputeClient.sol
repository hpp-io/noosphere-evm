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
    mapping(uint64 => mapping(uint32 => bytes)) internal subscriptionInputs;

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
        // For a transient request, the interval is always 1.
        uint32 interval = 1;
        subscriptionInputs[subscriptionId][interval] = inputs;
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
        return subscriptionInputs[subscriptionId][interval];
    }
}
