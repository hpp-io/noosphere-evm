// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

/// @notice A subscription is the fundamental unit of Infernet
/// @dev A subscription represents some request configuration for off-chain compute via containers on Infernet nodes
/// @dev A subscription with `frequency == 1` is a one-time subscription (a callback)
/// @dev A subscription with `frequency > 1` is a recurring subscription (many callbacks)
/// @dev Tightly-packed struct:
///      - [owner, activeAt, period, frequency]: [160, 32, 32, 32] = 256
///      - [redundancy, containerId, lazy, verifier]: [16, 32, 8, 160] = 216
///      - [paymentAmount]: [256] = 256
///      - [paymentToken]: [160] = 160
///      - [wallet]: [160] = 160
struct Subscription {
    /// @notice Subscription owner + recipient
    /// @dev This is the address called to fulfill a subscription request and must inherit `BaseConsumer`
    address owner;

    /// @notice Timestamp when subscription is first active and an off-chain Infernet node can respond
    /// @dev When `period == 0`, the subscription is immediately active
    /// @dev When `period > 0`, subscription is active at `createdAt + period`
    /// @dev Cancelled subscriptions update `activeAt` to `type(uint32).max` effectively restricting all future submissions
    uint32 activeAt;

    /// @notice Time, in seconds, between each subscription interval
    /// @dev At worst, assuming subscription occurs once/year << uint32
    uint32 period;

    /// @notice Number of times a subscription is processed
    /// @dev At worst, assuming 30 req/min * 60 min * 24 hours * 365 days * 10 years << uint32
    uint32 frequency;

    /// @notice Number of unique nodes that can fulfill a subscription at each `interval`
    /// @dev uint16 allows for >255 nodes (uint8) but <65,535
    uint16 redundancy;

    /// @notice Container identifier used by off-chain Infernet nodes to determine which container is used to fulfill a subscription
    /// @dev Represented as fixed size hash of stringified list of containers
    /// @dev Can be used to specify a linear DAG of containers by seperating container names with a "," delimiter ("A,B,C")
    /// @dev Better represented by a string[] type but constrained to hash(string) to keep struct and functions simple
    bytes32 containerId;

    /// @notice `true` if container compute responses lazily stored as an `InboxItem`(s) in `Inbox`, else `false`
    /// @dev When `true`, container compute outputs are stored in `Inbox` and not delivered eagerly to a consumer
    /// @dev When `false`, container compute outputs are not stored in `Inbox` and are delivered eagerly to a consumer
    bool lazy;

    /// @notice Optional verifier contract to restrict subscription payment on the basis of proof verification
    /// @dev If `address(0)`, we assume that no proof contract is necessary, and disperse supplied payment immediately
    /// @dev If verifier contract is supplied, it must implement the `IVerifier` interface
    /// @dev Eager verifier contracts disperse payment immediately to relevant `Wallet`(s)
    /// @dev Lazy verifier contracts disperse payment after a delay (max. 1-week) to relevant `Wallet`(s)
    /// @dev Notice that consumer contracts can still independently implement their own 0-cost proof verification within their contracts
    address payable verifier;

    /// @notice Optional amount to pay in `paymentToken` each time a subscription is processed
    /// @dev If `0`, subscription has no associated payment
    /// @dev uint256 since we allow `paymentToken`(s) to have arbitrary ERC20 implementations (unknown `decimal`s)
    /// @dev In theory, this could be a {dynamic pricing mechanism, reverse auction, etc.} but kept simple for now (abstractions can be built later)
    uint256 paymentAmount;

    /// @notice Optional payment token
    /// @dev If `address(0)`, payment is in Ether (or no payment in conjunction with `paymentAmount == 0`)
    /// @dev Else, `paymentToken` must be an ERC20-compatible token contract
    address paymentToken;

    /// @notice Optional `Wallet` to pay for compute payments; `owner` must be approved spender
    /// @dev Defaults to `address(0)` when no payment specified
    address payable wallet;
}