// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import "../types/ProofVerificationRequest.sol";
import {Commitment} from "../types/Commitment.sol";

/// @title ICoordinator
/// @notice Coordinator interface for managing the lifecycle of compute requests:
///         creation, cancellation, delivery, verification finalization and interval preparation.
/// @dev Functions are grouped by responsibility and documented to clarify intent (mutating vs read-only).
interface ICoordinator {
    /*//////////////////////////////////////////////////////////////////////////
                                      EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new request/commitment is started for a subscription interval.
    /// @param subscriptionId Subscription that requested the work.
    /// @param requestId Opaque request key assigned to this request.
    /// @param containerId Identifier of the compute container.
    /// @param commitment Full Commitment struct describing this request.
    event RequestStarted(
        bytes32 indexed requestId, uint64 indexed subscriptionId, bytes32 indexed containerId, Commitment commitment
    );

    /// @notice Emitted when a pending request is cancelled.
    /// @param requestId Opaque request key that was cancelled.
    event RequestCancelled(bytes32 indexed requestId);

    /// @notice Emitted when a node delivers a compute result.
    /// @param requestId Opaque request key for this delivery (ties to Commitment.requestId).
    /// @param nodeWallet Node wallet address that submitted the delivery.
    /// @param numRedundantDeliveries Number of redundant deliveries now recorded for the request.
    event ComputeDelivered(bytes32 indexed requestId, address indexed nodeWallet, uint16 numRedundantDeliveries);

    /// @notice Emitted when a proof verification outcome is processed.
    /// @param subscriptionId Subscription identifier.
    /// @param interval Interval index related to this verification.
    /// @param node Node address whose proof was verified.
    /// @param valid Whether the subscription / interval was considered active at verification time.
    /// @param verifier Address of the verifier that reported the result (msg.sender).
    event ProofVerified(
        uint64 indexed subscriptionId, uint32 indexed interval, address indexed node, bool valid, address verifier
    );

    /*//////////////////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    error IntervalMismatch(uint32 deliveryInterval);
    error IntervalCompleted();
    error NodeRespondedAlready();
    error InvalidWallet();
    error ProofVerificationRequestNotFound();

    /*//////////////////////////////////////////////////////////////////////////
                             REQUEST LIFECYCLE (CREATION/CANCELLATION)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Start a new request for a subscription interval.
    /// @dev This is a state-mutating operation. The Coordinator should persist a Commitment and emit RequestStarted.
    /// @param requestId Opaque request key / identifier for this request (caller-supplied or derived).
    /// @param subscriptionId Subscription the request belongs to.
    /// @param containerId Container identifier describing the compute target.
    /// @param interval Interval index (round) the request targets.
    /// @param redundancy Number of redundant node responses expected for this request.
    /// @param useDeliveryInbox If true, responses are saved to a delivery inbox rather than delivered immediately.
    /// @param feeToken Token used for payment for this request (address(0) for native ETH).
    /// @param feeAmount Fee amount associated with the request (in token base units).
    /// @param wallet Wallet address funding the request (consumer wallet).
    /// @param verifier Optional verifier address to be used for this request (address(0) if none).
    /// @return commitment Commitment struct describing the stored request metadata.
    function startRequest(
        bytes32 requestId,
        uint64 subscriptionId,
        bytes32 containerId,
        uint32 interval,
        uint16 redundancy,
        bool useDeliveryInbox,
        address feeToken,
        uint256 feeAmount,
        address wallet,
        address verifier
    ) external returns (Commitment memory commitment);

    /// @notice Cancel a pending request.
    /// @dev State-mutating. Coordinator should release any reserved state/escrow and emit RequestCancelled.
    /// @param requestId Opaque request key identifying the pending request.
    function cancelRequest(bytes32 requestId) external;

    /*//////////////////////////////////////////////////////////////////////////
                            DELIVERY & FULFILLMENT HANDLERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Called by nodes to deliver compute outputs for a given interval.
    /// @dev State-mutating. Coordinator will process the delivery, update commitment state and emit ComputeDelivered.
    /// @param deliveryInterval Interval index this delivery corresponds to.
    /// @param input Input bytes that were used for the compute (for auditing/verification).
    /// @param output Output bytes produced by the node.
    /// @param proof Proof bytes (protocol-specific) supporting the output.
    /// @param commitmentData ABI-encoded Commitment data that ties this delivery to a request.
    /// @param nodeWallet Wallet address of the delivering node (used for payment/escrow).
    function reportComputeResult(
        uint32 deliveryInterval,
        bytes memory input,
        bytes memory output,
        bytes memory proof,
        bytes memory commitmentData,
        address nodeWallet
    ) external;

    /*//////////////////////////////////////////////////////////////////////////
                                VERIFICATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Finalize the result of a proof verification for a node's delivery.
    /// @dev Called by verifier adapters (or mocks) after verification completes (sync or async).
    ///      Coordinator should act on `valid` (settle payments, mark interval completion, etc.).
    function reportVerificationResult(ProofVerificationRequest memory request, bool valid) external;
    /*//////////////////////////////////////////////////////////////////////////
                            INTERVAL / SCHEDULING HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Prepare internal state for the next interval of a subscription.
    /// @dev Used by nodes/tests to signal the coordinator to advance/prep interval scheduling.
    /// @param subscriptionId Subscription identifier to prepare.
    /// @param nextInterval Next interval index to prepare.
    /// @param nodeWallet Node wallet address associated with the preparation call.
    function prepareNextInterval(uint64 subscriptionId, uint32 nextInterval, address nodeWallet) external;

    /// @notice Retrieve the commitment for a specific subscription and interval.
    /// @dev This is a read-only operation.
    /// @param subscriptionId The ID of the subscription.
    /// @param interval The interval index.
    /// @return commitment The Commitment struct associated with the given subscription and interval.
    function getCommitment(uint64 subscriptionId, uint32 interval) external view returns (Commitment memory);

    /// @notice Retrieve the request ID associated with a given commitment.
    /// @dev This is a read-only operation.
    /// @param requestId The request ID to query.
    /// @return The request ID.
    function requestCommitments(bytes32 requestId) external view returns (bytes32);
}
