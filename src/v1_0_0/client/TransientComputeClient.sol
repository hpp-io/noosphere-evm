// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {Commitment} from "../types/Commitment.sol";
import {ComputeClient} from "./ComputeClient.sol";
import {InputType} from "../types/PayloadData.sol";

/**
 * @title TransientComputeClient
 * @dev This abstract contract provides a client for interacting with the Noosphere compute network.
 * It extends `ComputeClient` and adds functionality for managing transient compute subscriptions,
 * where the inputs for a computation are stored temporarily on-chain.
 * Supports Hybrid input mode: raw data, URI string, or PayloadData.
 *
 * Gas optimization: InputType is encoded as a 1-byte prefix in the input data,
 * eliminating the need for a separate storage mapping (~22k gas savings per request).
 * Storage format: [1-byte InputType][actual data...]
 */
abstract contract TransientComputeClient is ComputeClient {
    /// @dev Stores the inputs with 1-byte type prefix: [InputType][data...]
    mapping(uint64 => mapping(uint32 => bytes)) private _subscriptionInputs;

    /// @dev A counter to ensure a unique interval for each transient request within a subscription.
    mapping(uint64 => uint32) private _requestNonces;

    error DataTooLarge();
    error AmbiguousDataSize();
    error InvalidPayloadDataSize();

    constructor(address router) ComputeClient(router) {}

    function _createComputeSubscription(
        string memory containerId,
        bool useDeliveryInbox,
        address feeToken,
        uint256 feeAmount,
        address wallet,
        address verifier,
        bytes32 routeId
    ) internal returns (uint64) {
        return _getRouter().createComputeSubscription(
            containerId, 1, 0, useDeliveryInbox, feeToken, feeAmount, wallet, verifier, routeId
        );
    }

    function _requestCompute(uint64 subscriptionId, bytes memory inputs) internal returns (uint64, Commitment memory) {
        // Increment the nonce for the subscription to get a unique interval for this request.
        // For transient subscriptions, the 'interval' field is used as a nonce to ensure request uniqueness,
        // rather than representing a time-based interval.
        uint32 interval = ++_requestNonces[subscriptionId];
        // Store with 1-byte type prefix (gas optimization: eliminates separate _inputTypes mapping)
        _subscriptionInputs[subscriptionId][interval] = abi.encodePacked(uint8(InputType.RAW_DATA), inputs);
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
        // Store with 1-byte type prefix
        _subscriptionInputs[subscriptionId][interval] = abi.encodePacked(uint8(InputType.URI_STRING), bytes(uri));
        (, commitment) = _getRouter().sendRequest(subscriptionId, interval);
    }

    /**
     * @notice Request compute with encoded PayloadData input
     * @param subscriptionId The subscription ID
     * @param data The encoded PayloadData
     * @return interval The interval number for this request
     * @return commitment The commitment for this request
     */
    function _requestComputeWithPayloadData(uint64 subscriptionId, bytes memory data)
        internal
        returns (uint32 interval, Commitment memory commitment)
    {
        interval = ++_requestNonces[subscriptionId];
        // Store with 1-byte type prefix
        _subscriptionInputs[subscriptionId][interval] = abi.encodePacked(uint8(InputType.PAYLOAD_DATA), data);
        (, commitment) = _getRouter().sendRequest(subscriptionId, interval);
    }

    /*//////////////////////////////////////////////////////////////
                            INPUT GETTER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get compute inputs with type information
     * @dev Decodes the 1-byte type prefix from stored data
     * @param subscriptionId The subscription ID
     * @param interval The interval number
     * @param timestamp The current timestamp (unused)
     * @param caller The caller address (unused)
     * @return data The input data (without type prefix)
     * @return inputType The type of input data
     */
    function getComputeInputs(uint64 subscriptionId, uint32 interval, uint32 timestamp, address caller)
        external
        view
        override
        returns (bytes memory data, InputType inputType)
    {
        bytes memory stored = _subscriptionInputs[subscriptionId][interval];
        if (stored.length == 0) {
            return (data, InputType.RAW_DATA);
        }

        // Extract type from first byte
        inputType = InputType(uint8(stored[0]));

        // Extract data (skip first byte) using assembly for gas efficiency
        uint256 dataLen = stored.length - 1;
        data = new bytes(dataLen);
        if (dataLen > 0) {
            assembly {
                // Copy from stored[1:] to data[0:]
                // stored points to length, stored+32 is start of data, stored+33 skips type byte
                // data points to length, data+32 is start of data
                let src := add(stored, 33) // skip length (32) + type byte (1)
                let dst := add(data, 32) // skip length (32)
                // Copy in 32-byte chunks
                for { let i := 0 } lt(i, dataLen) { i := add(i, 32) } {
                    mstore(add(dst, i), mload(add(src, i)))
                }
            }
        }
        return (data, inputType);
    }
}
