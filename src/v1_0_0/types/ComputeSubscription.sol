// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

/// @notice Compute subscription configuration for off-chain compute callbacks.
/// @dev Field ordering chosen to minimize wasted bytes across 32-byte storage slots
///      while keeping readability. Do **NOT** reorder fields after deployment if using a proxy.
struct ComputeSubscription {
    /// @notice Routing identifier: which route / node-set to send requests to.
    bytes32 routeId; // slot 0
    /// @notice Off-chain container/image identifier for compute (e.g., container id or image hash).
    bytes32 containerId; // slot 1
    /// @notice Total fee amount to pay per execution (token decimals apply).
    uint256 feeAmount; // slot 2
    /// @notice Primary client address that will receive callbacks / read responses.
    address client; // slot 3 (part)
    /// @notice Subscription start timestamp (POSIX seconds). First valid execution time.
    uint32 activeAt; // slot 3 (part)
    /// @notice Execution interval in seconds between repeats.
    uint32 intervalSeconds; // slot 3 (part)
    /// @notice Maximum number of executions for this subscription. 0 = policy dependent (commonly "unlimited").
    uint32 maxExecutions; // slot 3 (part)
    /// @notice Payment wallet (escrow) used to source payments for executions.
    address payable wallet; // slot 4 (part)
    /// @notice Token used for fee payments (ERC-20). `address(0)` means native currency (ETH).
    address feeToken; // slot 5 (part)
    /// @notice Verifier address (optional). If non-zero, used to verify node responses before delivery.
    address payable verifier; // slot 5 (part)
    /// @notice Number of required unique node responses per execution (redundancy).
    uint16 redundancy; // slot 6 (part)
    /// @notice If true, responses should be stored in the client's inbox/pending queue instead of immediate callback.
    bool useDeliveryInbox; // slot 6 (part)
}
