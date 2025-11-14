// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {StdAssertions} from "forge-std/StdAssertions.sol";
import {Router} from "../../src/v1_0_0/Router.sol";
import {DelegateeCoordinator} from "../../src/v1_0_0/DelegateeCoordinator.sol";
import {ComputeSubscription} from "../../src/v1_0_0/types/ComputeSubscription.sol";

/// @title MockAgent
/// @notice Minimal test helper that simulates an off-chain node calling into the DelegateeCoordinator.
/// @dev This contract is intended for tests only. It forwards calls to the Coordinator while preserving
///      `msg.sender` as the test caller (i.e., the mock acts as the node). The contract intentionally
///      contains no business logic — it merely wraps coordinator invocations so tests can exercise
///      coordinator entry points in isolation.
contract MockAgent is StdAssertions {
    /*//////////////////////////////////////////////////////////////
                                 IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Delegatee-enabled coordinator instance resolved from the Router.
    DelegateeCoordinator private immutable delegateeCoordinator;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Construct a MockAgent that will forward calls to the DelegateeCoordinator resolved from `router`.
    /// @param router Router instance used to resolve the Coordinator contract address.
    constructor(Router router) {
        // Lookup the coordinator address by the well-known coordinator id used in the test fixture.
        bytes32 coordinatorId = bytes32("Coordinator_v1.0.0");
        address coordinatorAddress = router.getContractById(coordinatorId);
        require(coordinatorAddress != address(0), "MockAgent: coordinator not found");
        delegateeCoordinator = DelegateeCoordinator(coordinatorAddress);
    }

    /*//////////////////////////////////////////////////////////////
                           COORDINATOR WRAPPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Forward a regular compute delivery call to the Coordinator.
    /// @dev This wrapper keeps the calling EOA as the msg.sender when tests impersonate the node.
    /// @param deliveryInterval Interval number for which the node produced a response.
    /// @param input Arbitrary input bytes used for the compute job.
    /// @param output Arbitrary output bytes produced by the node.
    /// @param proof Off-chain proof bytes (optional / protocol-specific).
    /// @param commitmentData ABI-encoded Commitment struct expected by Coordinator.
    /// @param nodeWallet Wallet address used by the node for payments/escrow operations.
    function reportComputeResult(
        uint32 deliveryInterval,
        bytes calldata input,
        bytes calldata output,
        bytes calldata proof,
        bytes memory commitmentData,
        address nodeWallet
    ) external {
        delegateeCoordinator.reportComputeResult(deliveryInterval, input, output, proof, commitmentData, nodeWallet);
    }

    /// @notice Signal the Coordinator to prepare the next interval for a subscription.
    /// @dev Test helper wrapper for Coordinator.prepareNextInterval.
    /// @param subscriptionId Subscription identifier.
    /// @param nextInterval Next interval number that the node intends to serve.
    /// @param nodeWallet The node's wallet address used for on-chain settlement.
    function prepareNextInterval(uint64 subscriptionId, uint32 nextInterval, address nodeWallet) external {
        delegateeCoordinator.prepareNextInterval(subscriptionId, nextInterval, nodeWallet);
    }

    /// @notice Forward a delegated delivery call which creates/uses a subscription via EIP-712 delegate flow and delivers output.
    /// @dev Matches Coordinator.deliverComputeDelegatee signature. Tests can sign the provided `sub` off-chain and
    ///      pass the signature bytes here so the Coordinator will validate and act on the delegated payload.
    /// @param nonce Subscriber contract nonce used in the delegate envelope.
    /// @param expiry Signature expiry timestamp.
    /// @param sub ComputeSubscription payload (delegated subscription parameters).
    /// @param signature EIP-712 signature authorizing the delegate action.
    /// @param deliveryInterval Interval for which this delivery applies.
    /// @param input Input payload bytes for compute.
    /// @param output Output bytes produced by the node.
    /// @param proof Off-chain proof bytes associated with the output.
    /// @param nodeWallet Node wallet address used for settlement bookkeeping.
    function reportDelegatedComputeResult(
        uint32 nonce,
        uint32 expiry,
        ComputeSubscription calldata sub,
        bytes calldata signature,
        uint32 deliveryInterval,
        bytes calldata input,
        bytes calldata output,
        bytes calldata proof,
        address nodeWallet
    ) external {
        delegateeCoordinator.reportDelegatedComputeResult(
            nonce, expiry, sub, signature, deliveryInterval, input, output, proof, nodeWallet
        );
    }

    /*//////////////////////////////////////////////////////////////
                                FALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice Allow the mock to receive native ETH in tests.
    receive() external payable {}
}
