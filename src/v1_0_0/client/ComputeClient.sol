// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {Routable} from "../utility/Routable.sol";
import {DeliveryInbox} from "./DeliveryInbox.sol";
import {Commitment} from "../types/Commitment.sol";
import {RequestIdUtils} from "../utility/RequestIdUtils.sol";
import {PayloadData, InputType} from "../types/PayloadData.sol";

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
        bool useDeliveryInbox,
        address feeToken,
        uint256 feeAmount,
        address wallet,
        address verifier,
        bytes32 routeId
    ) external returns (uint64) {
        return _getRouter().createComputeSubscription(
            containerId, maxExecutions, intervalSeconds, useDeliveryInbox, feeToken, feeAmount, wallet, verifier, routeId
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
        bool useDeliveryInbox,
        address node,
        PayloadData calldata input,
        PayloadData calldata output,
        PayloadData calldata proof,
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
            _receiveCompute(subscriptionId, interval, useDeliveryInbox, node, input, output, proof, containerId);
        }
    }

    /**
     * @notice Get compute inputs with type information (Hybrid mode)
     * @dev Agent uses inputType to determine how to process the input:
     *      - RAW_DATA (0): Raw inline data, use directly
     *      - URI_STRING (1): URI string, resolve via off-chain storage
     *      - PAYLOAD_DATA (2): Encoded PayloadData, decode and resolve
     * @param subscriptionId The subscription ID
     * @param interval The interval number
     * @param timestamp The current timestamp
     * @param caller The address of the caller (typically the node)
     * @return data The input data (raw bytes, URI string, or encoded PayloadData)
     * @return inputType The type of input data
     */
    function getComputeInputs(uint64 subscriptionId, uint32 interval, uint32 timestamp, address caller)
        external
        view
        virtual
        returns (bytes memory data, InputType inputType)
    {}

    function _receiveCompute(
        uint64 subscriptionId,
        uint32 interval,
        bool useDeliveryInbox,
        address node,
        PayloadData calldata input,
        PayloadData calldata output,
        PayloadData calldata proof,
        bytes32 containerId
    ) internal virtual {}

    function _cancelComputeSubscription(uint64 subscriptionId) internal {
        _getRouter().cancelComputeSubscription(subscriptionId);
    }
}
