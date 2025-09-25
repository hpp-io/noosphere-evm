// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Commitment} from "../types/Commitment.sol";
import {ComputeClient} from "./ComputeClient.sol";

/// @title TransientComputeClient.sol
/// @notice Allows creating one-time requests for off-chain container compute, delivered via callback
/// @dev Inherits `ComputeClient.sol` to inherit functions to receive container compute responses and emit container inputs
abstract contract TransientComputeClient is ComputeClient {
    /*//////////////////////////////////////////////////////////////
                                MUTABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice subscriptionId => callback input data
    /// @dev Could be restricted to `private` visibility but kept `internal` for better testing/downstream modification support
    mapping(uint64 => bytes) internal subscriptionInputs;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize new TransientComputeClient.sol
    /// @param router router address
    constructor(address router) ComputeClient(router) {}

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _createComputeSubscription(
        string memory containerId,
        uint16 redundancy,
        bool lazy,
        address paymentToken,
        uint256 paymentAmount,
        address wallet,
        address verifier,
        bytes32 routeId
    ) internal returns (uint64) {
        return _getRouter().createSubscription(
            containerId, 1, 0, redundancy, lazy, paymentToken, paymentAmount, wallet, verifier, routeId
        );
    }

    /// @notice Requests off-chain compute for a given subscription
    /// @dev Stores the provided inputs in `subscriptionInputs` and then calls the router's `sendRequest`
    /// @param subscriptionId The ID of the subscription to request compute for
    /// @param inputs The input data for the off-chain compute
    /// @return subscriptionId The ID of the subscription
    /// @return commitment The commitment for the request
    function _requestCompute(uint64 subscriptionId, bytes memory inputs) internal returns (uint64, Commitment memory) {
        subscriptionInputs[subscriptionId] = inputs;
        (bytes32 requestId, Commitment memory commitment) =_getRouter().sendRequest(subscriptionId, 1);
        return (subscriptionId, commitment);
    }

    /*//////////////////////////////////////////////////////////////
                           OVERRIDE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice View function to broadcast dynamic container inputs to off-chain Infernet nodes
    /// @dev Modified from `ComputeClient.sol` to expose callback input data, indexed by subscriptionId
    /// @param subscriptionId subscription ID to collect container inputs for
    /// @param interval subscription interval to collect container inputs for
    /// @param timestamp timestamp at which container inputs are collected
    /// @param caller calling address
    function getContainerInputs(uint64 subscriptionId, uint32 interval, uint32 timestamp, address caller)
        external
        view
        override
        returns (bytes memory)
    {
        // {interval, timestamp, caller} unnecessary for simple callback request
        return subscriptionInputs[subscriptionId];
    }
}
