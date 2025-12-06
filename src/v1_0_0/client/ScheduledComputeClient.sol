// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {Commitment} from "../types/Commitment.sol";
import {ComputeClient} from "./ComputeClient.sol";

/**
 * @title ScheduledComputeClient.sol
 * @dev Abstract contract for interacting with the Noosphere Router to manage compute subscriptions.
 */
abstract contract ScheduledComputeClient is ComputeClient {
    /// @dev Stores the inputs for each compute subscription, keyed by subscriptionId.
    mapping(uint64 => bytes) private _subscriptionInputs;
    /// @dev Flags to prevent multiple compute requests for a single subscription, keyed by subscriptionId.
    mapping(uint64 => bool) private _computeRequested;

    error ComputeAlreadyRequested();

    constructor(address router) ComputeClient(router) {}

    function _createComputeSubscription(
        string memory containerId,
        uint32 maxExecutions,
        uint32 intervalSeconds,
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
                containerId,
                maxExecutions,
                intervalSeconds,
                redundancy,
                useDeliveryInbox,
                feeToken,
                feeAmount,
                wallet,
                verifier,
                routeId
            );
    }

    function _requestCompute(uint64 subscriptionId, bytes memory inputs) internal returns (uint64, Commitment memory) {
        if (_computeRequested[subscriptionId]) {
            revert ComputeAlreadyRequested();
        }
        _subscriptionInputs[subscriptionId] = inputs;
        (, Commitment memory commitment) = _getRouter().sendRequest(subscriptionId, 1);
        _computeRequested[subscriptionId] = true;
        return (subscriptionId, commitment);
    }

    function getComputeInputs(uint64 subscriptionId, uint32 interval, uint32 timestamp, address caller)
        external
        view
        override
        returns (bytes memory)
    {
        return _subscriptionInputs[subscriptionId];
    }
}
