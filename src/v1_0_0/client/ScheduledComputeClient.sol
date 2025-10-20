// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.4;

import {Commitment} from "../types/Commitment.sol";
import {ComputeClient} from "./ComputeClient.sol";

/**
 * @title ScheduledComputeClient.sol
 * @dev Abstract contract for interacting with the Noosphere Router to manage compute subscriptions.
 */
abstract contract ScheduledComputeClient is ComputeClient {
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

    function _requestCompute(uint64 subscriptionId, uint32 interval) internal returns (uint64, Commitment memory) {
        (, Commitment memory commitment) = _getRouter().sendRequest(subscriptionId, interval);
        return (subscriptionId, commitment);
    }
}
