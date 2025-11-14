// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {ComputeSubscription} from "../types/ComputeSubscription.sol";

/// @title ISubscriptionsManager
/// @notice Interface for managing compute subscriptions: read access, creation, cancellation and simple state checks.
/// @dev Functions are grouped by responsibility (events, read-only accessors, mutating operations, helpers).
interface ISubscriptionsManager {
    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new compute subscription is created.
    /// @param subscriptionId Assigned subscription identifier.
    event SubscriptionCreated(uint64 indexed subscriptionId);

    /// @notice Emitted when a subscription is cancelled.
    /// @param subscriptionId Identifier of the cancelled subscription.
    event SubscriptionCancelled(uint64 indexed subscriptionId);

    /// @notice Emitted when a subscription is fulfilled
    /// @param id subscription ID
    /// @param node address of fulfilling node
    event SubscriptionFulfilled(uint64 indexed id, address indexed node);

    /// @notice Emitted when a commitment times out and is cleaned up
    event CommitmentTimedOut(bytes32 indexed requestId, uint64 indexed subscriptionId, uint32 indexed interval);

    /*//////////////////////////////////////////////////////////////
                                READ-ONLY ACCESSORS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Retrieve the full subscription record for `subscriptionId`.
     * @dev Returns the on-chain `ComputeSubscription` struct as stored by the implementation.
     *      Callers should treat the returned struct as a snapshot; it may change after subsequent state updates.
     * @param subscriptionId Subscription identifier to query.
     * @return subscription The stored ComputeSubscription struct for `subscriptionId`.
     */
    function getComputeSubscription(uint64 subscriptionId)
        external
        view
        returns (ComputeSubscription memory subscription);

    /**
     * @notice Compute the current interval index for a subscription.
     * @dev Derived from subscription.activeAt and subscription.intervalSeconds using the same logic as the
     *      concrete implementation. Useful for clients and nodes to determine which interval to serve.
     * @param subscriptionId Subscription identifier to evaluate.
     * @return interval The computed interval index (1-based). Implementations may return 0 to indicate
     *                  "no active interval" (e.g., subscription not yet active).
     */
    function getComputeSubscriptionInterval(uint64 subscriptionId) external view returns (uint32 interval);

    /*//////////////////////////////////////////////////////////////
                           MUTATING OPERATIONS (TRANSACTIONS)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Create a new compute subscription with the provided parameters.
     * @dev Persists a new subscription record and emits SubscriptionCreated. Implementations must validate inputs,
     *      perform necessary authorization checks (caller is allowed to create on behalf of `wallet` if applicable),
     *      and return the assigned subscription identifier.
     *
     * IMPORTANT: `containerId` is passed as `string` here to match the existing function signature and expected caller usage.
     *            Implementations may hash or canonicalize it internally (e.g., bytes32) for storage efficiency.
     *
     * @param containerId identifier of the container .
     * @param maxExecutions Maximum allowed number of executions for this subscription
     * @param intervalSeconds Interval length in seconds between scheduled executions
     * @param redundancy Number of redundant node responses required per interval.
     * @param useDeliveryInbox If true, node responses will be stored for later pickup (lazy delivery).
     * @param feeToken Token used to pay per-execution fees (address(0) for native ETH).
     * @param feeAmount Fee amount per execution expressed in `feeToken` base units.
     * @param wallet Wallet address that funds this subscription (escrow / withdrawal recipient).
     * @param verifier Optional verifier contract address (address(0) if not used).
     * @param routeId Opaque routing identifier (passed through to subscription metadata).
     * @return subscriptionId The newly created subscription identifier.
     */
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
    ) external returns (uint64 subscriptionId);

    /**
     * @notice Cancel an active subscription.
     * @dev Implementations should mark the subscription as inactive (for example, set `activeAt` to max)
     *      and release any reserved funds or pending requests where appropriate. Emit SubscriptionCancelled.
     * @param subscriptionId Identifier of the subscription to cancel.
     */
    function cancelComputeSubscription(uint64 subscriptionId) external;

    /*//////////////////////////////////////////////////////////////
                                   HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check whether there are any pending (unfulfilled) requests for a given subscription.
     * @dev Useful for callers that want to determine whether it is safe to cancel a subscription or
     *      whether there is outstanding work to be completed.
     * @param subscriptionId Subscription identifier to inspect.
     * @return True if there exists at least one pending/unserved request for `subscriptionId`, false otherwise.
     */
    function pendingRequestExists(uint64 subscriptionId) external view returns (bool);
}
