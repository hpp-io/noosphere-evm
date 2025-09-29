// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Commitment} from "../types/Commitment.sol";
import {ComputeClient} from "./ComputeClient.sol";

/**
 * @title TransientComputeClient
 * @dev This abstract contract provides a client for interacting with the Noosphere compute network.
 * It extends `ComputeClient` and adds functionality for managing transient compute subscriptions,
 * where the inputs for a computation are stored temporarily on-chain.
 */
abstract contract TransientComputeClient is ComputeClient {
    mapping(uint64 => bytes) internal subscriptionInputs;

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
        return _getRouter().createComputeSubscription(
            containerId, 1, 0, redundancy, useDeliveryInbox, feeToken, feeAmount, wallet, verifier, routeId
        );
    }

    function _requestCompute(uint64 subscriptionId, bytes memory inputs) internal returns (uint64, Commitment memory) {
        subscriptionInputs[subscriptionId] = inputs;
        (, Commitment memory commitment) = _getRouter().sendRequest(subscriptionId, 1);
        return (subscriptionId, commitment);
    }

    function getComputeInputs(uint64 subscriptionId) external view override returns (bytes memory) {
        // {interval, timestamp, caller} unnecessary for simple callback request
        return subscriptionInputs[subscriptionId];
    }
}
