// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

struct Commitment {
    /// @dev The unique identifier for the request.
    bytes32 requestId;
    /// @dev The unique identifier for the subscription.
    uint64 subscriptionId;
    /// @dev The unique identifier for the container.
    bytes32 containerId;
    /// @dev The interval at which the commitment is renewed, in seconds.
    uint32 interval;
    /// @dev Indicates if the commitment is useDeliveryInbox (i.e., renewed only when needed).
    bool useDeliveryInbox;
    /// @dev The number of redundant nodes for the commitment.
    uint16 redundancy;
    /// @dev The wallet address associated with the commitment.
    address walletAddress;
    /// @dev The amount of payment for the commitment.
    uint256 feeAmount;
    /// @dev The address of the payment token.
    address feeToken;
    /// @dev The address of the verifier contract.
    address verifier;
    /// @dev The address of the coordinator contract.
    address coordinator;
}
