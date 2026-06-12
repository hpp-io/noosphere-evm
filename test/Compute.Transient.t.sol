// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {ComputeTest} from "./Compute.t.sol";
import {Commitment} from "../src/v1_0_0/types/Commitment.sol";
import {ComputeSubscription} from "../src/v1_0_0/types/ComputeSubscription.sol";
import {DeliveredOutput} from "./mocks/client/MockComputeClient.sol";
import {PendingDelivery} from "../src/v1_0_0/types/PendingDelivery.sol";
import {ICoordinator} from "../src/v1_0_0/interfaces/ICoordinator.sol";
import {PayloadData} from "../src/v1_0_0/types/PayloadData.sol";
import {ISubscriptionsManager} from "../src/v1_0_0/interfaces/ISubscriptionManager.sol";

// @title CoordinatorCallbackTest
// @notice Coordinator tests specific to usage by TransientComputeClient.sol
contract ComputeTransientTest is ComputeTest {
    /// @notice Can create callback (one-time subscription)
    function test_Succeeds_When_CreatingCallback() public {
        vm.warp(0);

        // Get expected subscription ID
        uint64 expected = 1;

        // Create new callback
        vm.expectEmit(address(ROUTER));
        emit ISubscriptionsManager.SubscriptionCreated(expected);
        (uint64 actual,) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Assert subscription ID is correctly stored
        assertEq(expected, actual);

        // Assert subscription data is correctly stored
        ComputeSubscription memory sub = ROUTER.getComputeSubscription(actual);
        assertEq(sub.activeAt, 0);
        assertEq(sub.client, address(transientClient));
        assertEq(sub.maxExecutions, 1);
        assertEq(sub.intervalSeconds, 0);
        assertEq(sub.containerId, HASHED_MOCK_CONTAINER_ID);
        assertEq(sub.useDeliveryInbox, false);

        // Assert subscription inputs are correctly stored
        (bytes memory data,) = transientClient.getComputeInputs(actual, 1, 0, address(0));
        assertEq(data, MOCK_CONTAINER_INPUTS);
    }

    /// @notice Can create useDeliveryInbox callback (one-time subscription)
    function test_Succeeds_When_CreatingLazyCallback() public {
        vm.warp(0);

        // Get expected subscription ID
        uint64 expected = 1;

        // Create new useDeliveryInbox callback
        vm.expectEmit(address(ROUTER));
        emit ISubscriptionsManager.SubscriptionCreated(expected);
        (uint64 actual,) = transientClient.createLazyMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Assert subscription ID is correctly stored
        assertEq(expected, actual);

        // Assert subscription data is correctly stored
        ComputeSubscription memory sub = ROUTER.getComputeSubscription(actual);
        assertEq(sub.client, address(transientClient));
        assertEq(sub.useDeliveryInbox, true);

        // Assert subscription inputs are correctly stored
        (bytes memory data,) = transientClient.getComputeInputs(actual, 1, 0, address(0));
        assertEq(data, MOCK_CONTAINER_INPUTS);
    }

    function testFuzz_RevertIf_DeliveringCallback_WithIncorrectInterval(uint32 interval) public {
        // Check non-correct intervals
        vm.assume(interval != 1);

        // Create new callback request
        (uint64 subId, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );
        assertEq(subId, 1);

        // Attempt to deliver callback request w/ incorrect interval
        vm.expectRevert(abi.encodeWithSelector(ICoordinator.IntervalMismatch.selector, interval));
        bytes memory commitmentData = abi.encode(commitment);
        vm.prank(address(alice));
        // Use the fuzzed interval to test the logic correctly
        alice.reportComputeResult(interval, _mockInput(), _mockOutput(), _mockProof(), commitmentData, address(alice));
    }

    /// @notice Can deliver callback response successfully
    function test_Succeeds_When_DeliveringCallbackResponse() public {
        // --- 1. Arrange: Create a request ---
        (uint64 subId, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );
        assertEq(subId, 1);

        // --- 2. Act: Deliver the response and check for the event ---
        // Expect the `ComputeDelivered` event from the COORDINATOR contract.
        // We check both indexed topics (requestId, nodeWallet) and the emitter address.
        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinator.ComputeDelivered(
            commitment.requestId,
            aliceWalletAddress,
            _mockInput().contentHash,
            _mockOutput().contentHash,
            _mockProof().contentHash
        );

        // Call the function that emits the event.
        bytes memory commitmentData = abi.encode(commitment);
        vm.prank(address(alice));
        alice.reportComputeResult(
            commitment.interval, // Use the correct interval from the commitment
            _mockInput(),
            _mockOutput(),
            _mockProof(),
            commitmentData,
            aliceWalletAddress
        );
        // --- 3. Assert: Verify the outcome ---
        DeliveredOutput memory out = transientClient.getDeliveredOutput(subId, 1);
        assertEq(out.subscriptionId, subId);
        assertEq(out.interval, 1);
        assertEq(out.node, aliceWalletAddress);
        assertEq(out.input.contentHash, _mockInput().contentHash);
        assertEq(out.output.contentHash, _mockOutput().contentHash);
        assertEq(out.proof.contentHash, _mockProof().contentHash);
        // For non-useDeliveryInbox (eager) subscriptions, the containerId is expected to be bytes32(0)
        // in the callback, as the consumer already knows the container from the subscription.
        assertEq(out.containerId, bytes32(0));
    }

    /// @notice Can deliver useDeliveryInbox callback response successfully
    function test_Succeeds_When_DeliveringLazyCallbackResponse() public {
        // --- 1. Arrange: Create a useDeliveryInbox request ---
        (uint64 subId, Commitment memory commitment) = transientClient.createLazyMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );
        assertEq(subId, 1);

        // --- 2. Act: Deliver the response and check for the event ---
        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinator.ComputeDelivered(
            commitment.requestId,
            aliceWalletAddress,
            _mockInput().contentHash,
            _mockOutput().contentHash,
            _mockProof().contentHash
        );

        bytes memory commitmentData = abi.encode(commitment);
        vm.prank(address(alice));
        alice.reportComputeResult(
            commitment.interval, _mockInput(), _mockOutput(), _mockProof(), commitmentData, aliceWalletAddress
        );

        // --- 3. Assert: Verify the outcome ---
        // For useDeliveryInbox delivery, _receiveCompute is NOT called, so getDeliveredOutput should be empty.
        //        DeliveredOutput memory out = CALLBACK.getDeliveredOutput(subId, 1, 1);
        //        assertEq(out.subscriptionId, 1);

        // Instead, the delivery should be enqueued in DeliveryInbox.sol.
        (bool exists, PendingDelivery memory pd) = transientClient.getDelivery(commitment.requestId, aliceWalletAddress);
        assertTrue(exists);
        assertEq(pd.subscriptionId, subId);
        assertEq(pd.interval, 1);
        assertEq(pd.input.contentHash, _mockInput().contentHash);
        assertEq(pd.output.contentHash, _mockOutput().contentHash);
        assertEq(pd.proof.contentHash, _mockProof().contentHash);
    }

    /// @notice Cannot deliver callback response twice - commitment is deleted after first response
    function test_RevertIf_DeliveringCallbackResponse_Twice() public {
        // Create new callback request
        (, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        bytes memory commitmentData = abi.encode(commitment);

        // Deliver callback request from first node
        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinator.ComputeDelivered(
            commitment.requestId,
            aliceWalletAddress,
            _mockInput().contentHash,
            _mockOutput().contentHash,
            _mockProof().contentHash
        );
        alice.reportComputeResult(
            commitment.interval, _mockInput(), _mockOutput(), _mockProof(), commitmentData, aliceWalletAddress
        );

        // Second delivery should fail with InvalidCommitment since commitment is deleted after first response
        vm.expectRevert(ICoordinator.InvalidCommitment.selector);
        bob.reportComputeResult(
            commitment.interval, _mockInput(), _mockOutput(), _mockProof(), commitmentData, bobWalletAddress
        );
    }
}
