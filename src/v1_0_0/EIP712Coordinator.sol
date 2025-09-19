// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Coordinator} from "./Coordinator.sol";
import {Subscription} from "./types/Subscription.sol";
import {Commitment} from "./types/Commitment.sol";

/// @title EIP712Coordinator
/// @notice Coordinator enhanced with the ability to create subscriptions and deliver compute atomically via off-chain EIP-712 signatures.
/// @dev Allows nodes to atomically create subscriptions and deliver compute responses.
contract EIP712Coordinator is Coordinator {
    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes a new EIP712Coordinator.
    /// @param routerAddress The address of the Router contract.
    /// @param initialOwner The initial owner of this Coordinator.
    constructor(address routerAddress, address initialOwner) Coordinator(routerAddress, initialOwner) {}

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/


    /// @notice Atomically creates a subscription and delivers compute using an EIP-712 signature.
    /// @dev This function is intended to be called by a delegatee (e.g., a node operator) on behalf of a user.
    /// @param nonce A unique nonce for the EIP-712 signature, preventing replay attacks.
    /// @param expiry The timestamp after which the EIP-712 signature is no longer valid.
    /// @param sub The `Subscription` struct containing details for the new subscription.
    /// @param v The 'v' component of the EIP-712 signature.
    /// @param r The 'r' component of the EIP-712 signature.
    /// @param s The 's' component of the EIP-712 signature.
    /// @param deliveryInterval The interval (in seconds) at which compute is delivered.
    /// @param input The input data for the compute request.
    /// @param output The output data from the compute request.
    /// @param proof The proof of computation.
    /// @param nodeWallet The address of the node's wallet that performed the compute.
    function deliverComputeDelegatee(
        uint32 nonce,
        uint32 expiry,
        Subscription calldata sub,
        uint8 v,
        bytes32 r,
        bytes32 s,
        uint32 deliveryInterval,
        bytes calldata input,
        bytes calldata output,
        bytes calldata proof,
        address nodeWallet
    ) external {
        // By breaking the logic into helper functions, we reduce the stack depth in any single function.
        bytes memory commitmentData =
            _createSubscriptionAndGetCommitmentData(nonce, expiry, sub, v, r, s, deliveryInterval);
        _deliverCompute(deliveryInterval, input, output, proof, commitmentData, nodeWallet);
    }

    /**
     * @dev Internal helper to create the subscription and fetch the commitment data, reducing stack depth.
     */
    function _createSubscriptionAndGetCommitmentData(
        uint32 nonce,
        uint32 expiry,
        Subscription calldata sub,
        uint8 v,
        bytes32 r,
        bytes32 s,
        uint32 deliveryInterval
    ) internal returns (bytes memory) {
        uint64 subscriptionId = _getRouter().createSubscriptionDelegatee(nonce, expiry, sub, v, r, s);
        (, Commitment memory commitment) = _getRouter().sendRequest(subscriptionId, deliveryInterval);
        return abi.encode(commitment);
    }
}