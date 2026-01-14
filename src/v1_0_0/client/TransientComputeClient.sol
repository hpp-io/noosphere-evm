// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {Commitment} from "../types/Commitment.sol";
import {ComputeClient} from "./ComputeClient.sol";
import {InputType} from "../types/PayloadRef.sol";

/**
 * @title TransientComputeClient
 * @dev This abstract contract provides a client for interacting with the Noosphere compute network.
 * It extends `ComputeClient` and adds functionality for managing transient compute subscriptions,
 * where the inputs for a computation are stored temporarily on-chain.
 * Supports Hybrid input mode: raw data, URI string, or PayloadRef.
 */
abstract contract TransientComputeClient is ComputeClient {
    /// @dev Stores the inputs for each transient compute request, mapped by subscription ID and a unique interval.
    mapping(uint64 => mapping(uint32 => bytes)) private _subscriptionInputs;
    /// @dev Stores the input type for each request
    mapping(uint64 => mapping(uint32 => InputType)) private _inputTypes;

    /// @dev A counter to ensure a unique interval for each transient request within a subscription.
    mapping(uint64 => uint32) private _requestNonces;

    error DataTooLarge();
    error AmbiguousDataSize();
    error InvalidPayloadRefSize();

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
        _inputTypes[subscriptionId][interval] = InputType.RAW_DATA;
        (, Commitment memory commitment) = _getRouter().sendRequest(subscriptionId, interval);
        return (subscriptionId, commitment);
    }

    /*//////////////////////////////////////////////////////////////
                            INPUT SETTERS (Hybrid)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Request compute with URI string input
     * @param subscriptionId The subscription ID
     * @param uri The URI string pointing to off-chain data
     * @return interval The interval number for this request
     * @return commitment The commitment for this request
     */
    function _requestComputeWithUri(uint64 subscriptionId, string memory uri)
        internal
        returns (uint32 interval, Commitment memory commitment)
    {
        interval = ++_requestNonces[subscriptionId];
        _subscriptionInputs[subscriptionId][interval] = bytes(uri);
        _inputTypes[subscriptionId][interval] = InputType.URI_STRING;
        (, commitment) = _getRouter().sendRequest(subscriptionId, interval);
    }

    /**
     * @notice Request compute with encoded PayloadRef input
     * @param subscriptionId The subscription ID
     * @param ref The encoded PayloadRef (must be exactly 65 bytes)
     * @return interval The interval number for this request
     * @return commitment The commitment for this request
     */
    function _requestComputeWithRef(uint64 subscriptionId, bytes memory ref)
        internal
        returns (uint32 interval, Commitment memory commitment)
    {
        if (ref.length != 65) {
            revert InvalidPayloadRefSize();
        }
        interval = ++_requestNonces[subscriptionId];
        _subscriptionInputs[subscriptionId][interval] = ref;
        _inputTypes[subscriptionId][interval] = InputType.PAYLOAD_REF;
        (, commitment) = _getRouter().sendRequest(subscriptionId, interval);
    }

    /*//////////////////////////////////////////////////////////////
                            INPUT GETTER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get compute inputs with type information
     * @param subscriptionId The subscription ID
     * @param interval The interval number
     * @param timestamp The current timestamp (unused)
     * @param caller The caller address (unused)
     * @return data The input data
     * @return inputType The type of input data
     */
    function getComputeInputs(uint64 subscriptionId, uint32 interval, uint32 timestamp, address caller)
        external
        view
        override
        returns (bytes memory data, InputType inputType)
    {
        return (_subscriptionInputs[subscriptionId][interval], _inputTypes[subscriptionId][interval]);
    }
}
