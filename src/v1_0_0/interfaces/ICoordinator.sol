// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import "../types/Commitment.sol";

// Note: It's often better to define shared structs in a separate file
// (e.g., ./types/Commitment.sol) and import them here.

/**
 * @title ICoordinator
 * @notice Interface for the Coordinator contract, which is responsible for
 * managing the lifecycle of computation requests, from initiation to fulfillment
 * and verification.
 */
interface ICoordinator {
    /**
     * @notice Starts a new computation request and returns a commitment.
     * @param containerId The identifier for the computation container.
     * @param interval The interval for which the request is being made.
     * @param redundancy The number of nodes required to fulfill the request.
     * @param lazy A flag indicating if the request is lazy.
     * @param paymentToken The address of the token used for payment.
     * @param paymentAmount The amount of payment for the request.
     * @param wallet The wallet address associated with the subscription.
     * @param verifier The address of the verifier for this request.
     * @return A Commitment struct containing details of the request.
     */
    function startRequest(
        bytes32 requestId,
        uint64 subscriptionId,
        bytes32 containerId,
        uint32 interval,
        uint16 redundancy,
        bool lazy,
        address paymentToken,
        uint256 paymentAmount,
        address wallet,
        address verifier
    ) external returns (Commitment memory);

    /**
     * @notice Cancels a pending request.
     * @param requestId The ID of the request to be cancelled.
     */
    function cancelRequest(bytes32 requestId) external;

    /**
     * @notice Delivers the result of a computation to the Coordinator.
     * @param deliveryInterval The interval for which the computation was performed.
     * @param input The input data used for the computation.
     * @param output The output data resulting from the computation.
     * @param proof The cryptographic proof of computation.
     * @param commitmentData Additional data related to the commitment.
     * @param nodeWallet The wallet address of the node delivering the compute.
     * @dev This function is typically called by a compute node after completing a request.
     */
    function deliverCompute(
        uint32 deliveryInterval,
        bytes memory input,
        bytes memory output,
        bytes memory proof,
        bytes memory commitmentData,
        address nodeWallet
    ) external;

    /**
     * @notice Finalizes the proof verification process for a specific node's work.
     * @param subscriptionId The ID of the subscription.
     * @param interval The interval of the computation.
     * @param node The address of the node whose work was verified.
     * @param valid A boolean indicating if the proof was valid.
     */
    function finalizeProofVerification(uint64 subscriptionId, uint32 interval, address node, bool valid) external;

    /**
     * @notice Prepares the system for the next computation interval of a subscription.
     * @param subscriptionId The ID of the subscription to prepare.
     * @param nextInterval The upcoming interval number.
     */
//    function prepareNextInterval(uint64 subscriptionId, uint32 nextInterval) external;
}