// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Routable} from "../utility/Routable.sol";
import {DeliveryInbox} from "./DeliveryInbox.sol";
import {Commitment} from "../types/Commitment.sol";
import {RequestIdUtils} from "../utility/RequestIdUtils.sol";

/**
 * @title ComputeClient
 * @dev Abstract contract for interacting with the Noosphere compute network.
 */
abstract contract ComputeClient is Routable, DeliveryInbox {
    error NotRouter();

    constructor(address router) Routable(router) {}

    function createComputeSubscription(
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
    ) external returns (uint64) {
        return _getRouter().createComputeSubscription(
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

    function sendRequest(uint64 subscriptionId, uint32 interval)
        external
        returns (bytes32 requestKey, Commitment memory commitment)
    {
        return _getRouter().sendRequest(subscriptionId, interval);
    }

    function receiveRequestCompute(
        uint64 subscriptionId,
        uint32 interval,
        uint16 numRedundantDeliveries,
        bool useDeliveryInbox,
        address node,
        bytes calldata input,
        bytes calldata output,
        bytes calldata proof,
        bytes32 containerId
    ) external {
        // Note: The original check was against a `COORDINATOR` variable that is no longer defined.
        // This check should be updated to reflect the current authorization mechanism, likely via the router.
        if (msg.sender != address(_getRouter())) {
            // Example check, might need adjustment based on router logic.
            revert NotRouter();
        }

        if (useDeliveryInbox) {
            bytes32 requestId = RequestIdUtils.requestIdPacked(subscriptionId, interval);
            _enqueuePendingDelivery(requestId, node, subscriptionId, interval, input, output, proof);
        } else {
            // Call internal receive function, since caller is validated
            _receiveCompute(
                subscriptionId,
                interval,
                numRedundantDeliveries,
                useDeliveryInbox,
                node,
                input,
                output,
                proof,
                containerId
            );
        }
    }

    function getComputeInputs(uint64 subscriptionId) external view virtual returns (bytes memory) {}

    function _receiveCompute(
        uint64 subscriptionId,
        uint32 interval,
        uint16 numRedundantDeliveries,
        bool useDeliveryInbox,
        address node,
        bytes calldata input,
        bytes calldata output,
        bytes calldata proof,
        bytes32 containerId
    ) internal virtual {}

    function _cancelComputeSubscription(uint64 subscriptionId) internal {
        _getRouter().cancelComputeSubscription(subscriptionId);
    }
}
