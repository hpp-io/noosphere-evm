// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {Commitment} from "../types/Commitment.sol";
import {ComputeClient} from "./ComputeClient.sol";
import {InputType} from "../types/PayloadRef.sol";

/**
 * @title ScheduledComputeClient.sol
 * @dev Abstract contract for interacting with the Noosphere Router to manage compute subscriptions.
 *      Supports Hybrid input mode: raw data, URI string, or PayloadRef.
 */
abstract contract ScheduledComputeClient is ComputeClient {
    /// @dev Stores the inputs for each compute subscription, keyed by subscriptionId.
    mapping(uint64 => bytes) private _subscriptionInputs;
    /// @dev Stores the input type for each subscription (default: RAW_DATA)
    mapping(uint64 => InputType) private _inputTypes;
    /// @dev Flags to prevent multiple compute requests for a single subscription, keyed by subscriptionId.
    mapping(uint64 => bool) private _computeRequested;

    error ComputeAlreadyRequested();
    error DataTooLarge();
    error AmbiguousDataSize();
    error InvalidPayloadRefSize();

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
        _inputTypes[subscriptionId] = InputType.RAW_DATA;
        (, Commitment memory commitment) = _getRouter().sendRequest(subscriptionId, 1);
        _computeRequested[subscriptionId] = true;
        return (subscriptionId, commitment);
    }

    /*//////////////////////////////////////////////////////////////
                            INPUT SETTERS (Hybrid)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set input as URI string (e.g., "ipfs://...", "ar://...")
     * @dev Use for off-chain data references. More readable but variable gas cost.
     * @param subscriptionId The subscription ID
     * @param uri The URI string pointing to off-chain data
     */
    function _setInputUri(uint64 subscriptionId, string memory uri) internal {
        _subscriptionInputs[subscriptionId] = bytes(uri);
        _inputTypes[subscriptionId] = InputType.URI_STRING;
    }

    /**
     * @notice Set input as encoded PayloadRef (65 bytes)
     * @dev Use for gas-optimized production deployments. Fixed 65 bytes.
     * @param subscriptionId The subscription ID
     * @param ref The encoded PayloadRef (must be exactly 65 bytes)
     */
    function _setInputRef(uint64 subscriptionId, bytes memory ref) internal {
        if (ref.length != 65) {
            revert InvalidPayloadRefSize();
        }
        _subscriptionInputs[subscriptionId] = ref;
        _inputTypes[subscriptionId] = InputType.PAYLOAD_REF;
    }

    /**
     * @notice Set input as raw inline data
     * @dev Use for small data (<1KB). Data stored directly on-chain.
     * @param subscriptionId The subscription ID
     * @param inputData The raw input data
     */
    function _setInputData(uint64 subscriptionId, bytes memory inputData) internal {
        if (inputData.length >= 1024) {
            revert DataTooLarge();
        }
        if (inputData.length == 65) {
            revert AmbiguousDataSize();
        }
        _subscriptionInputs[subscriptionId] = inputData;
        _inputTypes[subscriptionId] = InputType.RAW_DATA;
    }

    /*//////////////////////////////////////////////////////////////
                            INPUT GETTER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get compute inputs with type information
     * @param subscriptionId The subscription ID
     * @param interval The interval number (unused for scheduled)
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
        return (_subscriptionInputs[subscriptionId], _inputTypes[subscriptionId]);
    }
}
