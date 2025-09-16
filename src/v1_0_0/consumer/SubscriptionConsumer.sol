// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.4;

import {Commitment} from "../types/Commitment.sol";
import {BaseConsumer} from "./BaseConsumer.sol";

/// @title SubscriptionConsumer
/// @notice Allows creating recurring subscriptions for off-chain container compute
/// @dev Inherits `BaseConsumer` to inherit functions to receive container compute responses and emit container inputs
abstract contract SubscriptionConsumer is BaseConsumer {
    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize new SubscriptionConsumer
    /// @param router router address
    constructor(address router) BaseConsumer(router) {}

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a recurring request for off-chain container compute via callback response
    /// @param containerId compute container identifier(s) used by off-chain Infernet node
    /// @param frequency max number of times to process subscription (i.e, `frequency == 1` is a one-time request)
    /// @param period period, in seconds, at which to progress each responding `interval`
    /// @param redundancy number of unique responding Infernet nodes
    /// @param lazy whether to lazily store subscription responses in `Inbox`
    /// @param paymentToken If providing payment for compute, payment token address (address(0) for ETH, else ERC20 contract address)
    /// @param paymentAmount If providing payment for compute, payment in `paymentToken` per compute request fulfillment
    /// @param wallet If providing payment for compute, Infernet `Wallet` address; this contract must be approved spender of `Wallet`
    /// @param verifier optional verifier contract to restrict payment based on response proof verification
    /// @return subscription ID of newly-created subscription
    function _createComputeSubscription(
        string memory containerId,
        uint32 frequency,
        uint32 period,
        uint16 redundancy,
        bool lazy,
        address paymentToken,
        uint256 paymentAmount,
        address wallet,
        address verifier,
        bytes32 routeId
    ) internal returns (uint64) {
        return _getRouter().createSubscription(
            containerId, frequency, period, redundancy, lazy, paymentToken, paymentAmount, wallet, verifier, routeId
        );
    }

    /// @notice Cancels a created subscription
    /// @dev Can only cancel owned subscriptions (`address(this) == Coordinator.subscriptions[subscriptionId].owner`)
    /// @param subscriptionId ID of subscription to cancel
    function _cancelComputeSubscription(uint64 subscriptionId) internal {
        _getRouter().cancelSubscription(subscriptionId);
    }

    /// @notice Requests compute for a given subscription
    /// @dev This function is intended to be called by the subscription owner to trigger a new compute request
    /// @param subscriptionId ID of the subscription to request compute for
    /// @return subscriptionId The ID of the subscription for which compute was requested
    /// @return commitment The commitment for the newly created compute request, containing `requestId` and `submissionWindow`
    function _requestCompute(uint64 subscriptionId, uint32 interval) internal returns (uint64, Commitment memory) {
        (bytes32 requestId, Commitment memory commitment) = _getRouter().sendRequest(subscriptionId, interval);
        return (subscriptionId, commitment);
    }
}
