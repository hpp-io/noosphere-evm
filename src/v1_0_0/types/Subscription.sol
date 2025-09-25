// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

/// @notice A subscription represents a configuration for off-chain compute requests.
/// @dev A subscription with `frequency == 1` is a one-time subscription (a callback)
/// @dev A subscription with `frequency > 1` is a recurring subscription (many callbacks)
struct Subscription {
    /// @notice Subscription owner + recipient
    /// @dev This is the address called to fulfill a subscription request and must inherit `ComputeClient.sol`.
    address owner;

    /// @notice Timestamp when the subscription first becomes active.
    /// @dev If `period == 0`, the subscription is active immediately.
    /// @dev If `period > 0`, the subscription is active at `createdAt + period`.
    /// @dev Cancelled subscriptions have `activeAt` set to `type(uint32).max`.
    uint32 activeAt;

    /// @notice Time in seconds between each subscription interval.
    uint32 period;

    /// @notice Number of times a subscription is processed.
    uint32 frequency;

    /// @notice Number of unique nodes that can fulfill a subscription at each `interval`.
    uint16 redundancy;

    /// @notice Identifier for the container used for off-chain compute.
    /// @dev Represented as a fixed-size hash of a string (e.g., a container name or a comma-separated list for a DAG).
    bytes32 containerId;

    /// @notice If `true`, compute responses are stored for later retrieval (lazy delivery).
    /// @dev If `false`, compute responses are delivered eagerly to the consumer.
    bool lazy;

    /// @notice Optional verifier contract for proof verification to manage payments.
    /// @dev If `address(0)`, no external verifier is used.
    /// @dev If a verifier is supplied, it must implement the `IVerifier` interface.
    address payable verifier;

    /// @notice Amount to pay in `paymentToken` each time a subscription is processed.
    /// @dev If `0`, the subscription has no associated payment.
    uint256 paymentAmount;

    /// @notice The token used for payment.
    /// @dev If `address(0)`, payment is in the native currency (e.g., ETH).
    address paymentToken;

    /// @notice The `Wallet` used for compute payments. The `owner` must be an approved spender.
    address payable wallet;

    /// @notice Identifier for the specific route configuration to be used for this subscription.
    bytes32 routeId;
}