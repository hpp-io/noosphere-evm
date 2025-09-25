// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {CoordinatorTest, ICoordinatorEvents} from "./Coordinator.t.sol";
import {Commitment} from "../src/v1_0_0/types/Commitment.sol";
import {Subscription} from "../src/v1_0_0/types/Subscription.sol";
import {DeliveredOutput} from "./mocks/consumer/MockBaseConsumer.sol";
import {Coordinator} from "../src/v1_0_0/EIP712Coordinator.sol";
import {PendingDelivery} from "../src/v1_0_0/types/PendingDelivery.sol";

// @title CoordinatorCallbackTest
// @notice Coordinator tests specific to usage by CallbackConsumer
contract CoordinatorCallbackTest is CoordinatorTest {
    /// @notice Can create callback (one-time subscription)
    function test_Succeeds_When_CreatingCallback() public {
        vm.warp(0);

        // Get expected subscription ID
        uint64 expected = 1;

        // Create new callback
        vm.expectEmit(address(ROUTER));
        emit SubscriptionCreated(expected);
        (uint64 actual,) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Assert subscription ID is correctly stored
        assertEq(expected, actual);

        // Assert subscription data is correctly stored
        Subscription memory sub = ROUTER.getSubscription(actual);
        assertEq(sub.activeAt, 0);
        assertEq(sub.owner, address(CALLBACK));
        assertEq(sub.redundancy, 1);
        assertEq(sub.frequency, 1);
        assertEq(sub.period, 0);
        assertEq(sub.containerId, HASHED_MOCK_CONTAINER_ID);
        assertEq(sub.lazy, false);

        // Assert subscription inputs are correctly stord
        assertEq(CALLBACK.getContainerInputs(actual, 0, 0, address(0)), MOCK_CONTAINER_INPUTS);
    }

    /// @notice Can create lazy callback (one-time subscription)
    function test_Succeeds_When_CreatingLazyCallback() public {
        vm.warp(0);

        // Get expected subscription ID
        uint64 expected = 1;

        // Create new lazy callback
        vm.expectEmit(address(ROUTER));
        emit SubscriptionCreated(expected);
        (uint64 actual,) = CALLBACK.createLazyMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Assert subscription ID is correctly stored
        assertEq(expected, actual);

        // Assert subscription data is correctly stored
        Subscription memory sub = ROUTER.getSubscription(actual);
        assertEq(sub.owner, address(CALLBACK));
        assertEq(sub.lazy, true);

        // Assert subscription inputs are correctly stord
        assertEq(CALLBACK.getContainerInputs(actual, 0, 0, address(0)), MOCK_CONTAINER_INPUTS);
    }

    function testFuzz_RevertIf_DeliveringCallback_WithIncorrectInterval(uint32 interval) public {
        // Check non-correct intervals
        vm.assume(interval != 1);

        // Create new callback request
        (uint64 subId, Commitment memory commitment) =
                            CALLBACK.createMockRequest(MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER);
        assertEq(subId, 1);

        // Attempt to deliver callback request w/ incorrect interval
        vm.expectRevert(abi.encodeWithSelector(Coordinator.IntervalMismatch.selector, interval));
        bytes memory commitmentData = abi.encode(commitment);
        vm.prank(address(ALICE));
        // Use the fuzzed interval to test the logic correctly
        ALICE.deliverCompute(interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, address(ALICE));
    }

    /// @notice Can deliver callback response successfully
    function test_Succeeds_When_DeliveringCallbackResponse() public {
        // --- 1. Arrange: Create a request ---
        (uint64 subId, Commitment memory commitment) =
                            CALLBACK.createMockRequest(MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER);
        assertEq(subId, 1);

        // --- 2. Act: Deliver the response and check for the event ---
        // Expect the `ComputeDelivered` event from the COORDINATOR contract.
        // We check both indexed topics (requestId, nodeWallet) and the emitter address.
        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, aliceWalletAddress, 1);

        // Call the function that emits the event.
        bytes memory commitmentData = abi.encode(commitment);
        vm.prank(address(ALICE));
        ALICE.deliverCompute(
            commitment.interval, // Use the correct interval from the commitment
            MOCK_INPUT,
            MOCK_OUTPUT,
            MOCK_PROOF,
            commitmentData,
            aliceWalletAddress
        );
        // --- 3. Assert: Verify the outcome ---
        DeliveredOutput memory out = CALLBACK.getDeliveredOutput(subId, 1, 1);
        assertEq(out.subscriptionId, subId);
        assertEq(out.interval, 1);
        assertEq(out.redundancy, 1);
        assertEq(out.node, aliceWalletAddress);
        assertEq(out.input, MOCK_INPUT);
        assertEq(out.output, MOCK_OUTPUT);
        assertEq(out.proof, MOCK_PROOF);
        // For non-lazy (eager) subscriptions, the containerId is expected to be bytes32(0)
        // in the callback, as the consumer already knows the container from the subscription.
        assertEq(out.containerId, bytes32(0));
    }

    /// @notice Can deliver lazy callback response successfully
    function test_Succeeds_When_DeliveringLazyCallbackResponse() public {
        // --- 1. Arrange: Create a lazy request ---
        (uint64 subId, Commitment memory commitment) =
            CALLBACK.createLazyMockRequest(MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER);
        assertEq(subId, 1);

        // --- 2. Act: Deliver the response and check for the event ---
        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, aliceWalletAddress, 1);

        bytes memory commitmentData = abi.encode(commitment);
        vm.prank(address(ALICE));
        ALICE.deliverCompute(
            commitment.interval,
            MOCK_INPUT,
            MOCK_OUTPUT,
            MOCK_PROOF,
            commitmentData,
            aliceWalletAddress
        );

        // --- 3. Assert: Verify the outcome ---
        // For lazy delivery, _receiveCompute is NOT called, so getDeliveredOutput should be empty.
//        DeliveredOutput memory out = CALLBACK.getDeliveredOutput(subId, 1, 1);
//        assertEq(out.subscriptionId, 1);

        // Instead, the delivery should be enqueued in PendingDeliveries.
        (bool exists, PendingDelivery memory pd) = CALLBACK.getDelivery(commitment.requestId, aliceWalletAddress);
        assertTrue(exists);
        assertEq(pd.subscriptionId, subId);
        assertEq(pd.interval, 1);
        assertEq(pd.input, MOCK_INPUT);
        assertEq(pd.output, MOCK_OUTPUT);
        assertEq(pd.proof, MOCK_PROOF);
    }

    /// @notice Can deliver callback response once, across two unique nodes
    function test_Succeeds_When_DeliveringCallbackResponse_OncePerNode_WithRedundancy() public {
        // Create new callback request w/ redundancy = 2
        uint16 redundancy = 2;
        (uint64 subId, Commitment memory commitment) =
                            CALLBACK.createMockRequest(MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, redundancy, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER);

        // Call the function that emits the event.
        bytes memory commitmentData = abi.encode(commitment);

        // Deliver callback request from two nodes
        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, aliceWalletAddress, 1);
        ALICE.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, aliceWalletAddress);

        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, bobWalletAddress, 2);
        BOB.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWalletAddress);

        // Assert delivery
        address[2] memory nodes = [aliceWalletAddress, bobWalletAddress];
        for (uint16 r = 1; r <= 2; r++) {
            DeliveredOutput memory out = CALLBACK.getDeliveredOutput(subId, 1, r);
            assertEq(out.subscriptionId, subId);
            assertEq(out.interval, 1);
            assertEq(out.redundancy, r);
            assertEq(out.node, nodes[r - 1]);
            assertEq(out.input, MOCK_INPUT);
            assertEq(out.output, MOCK_OUTPUT);
            assertEq(out.proof, MOCK_PROOF);
            assertEq(out.containerId, bytes32(0));
        }
    }

    /// @notice Can deliver lazy callback response once, across two unique nodes
    function test_Succeeds_When_DeliveringLazyCallbackResponse_WithRedundancy() public {
        // Create new lazy callback request w/ redundancy = 2
        uint16 redundancy = 2;
        (uint64 subId, Commitment memory commitment) =
            CALLBACK.createLazyMockRequest(MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, redundancy, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER);

        bytes memory commitmentData = abi.encode(commitment);

        // Deliver callback request from two nodes
        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, aliceWalletAddress, 1);
        ALICE.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, aliceWalletAddress);

        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, bobWalletAddress, 2);
        BOB.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWalletAddress);

        // Assert that getNodesForRequest returns the correct nodes
        address[] memory nodes = CALLBACK.getNodesForRequest(commitment.requestId);
        assertEq(nodes.length, 2);
        assertEq(nodes[0], aliceWalletAddress);
        assertEq(nodes[1], bobWalletAddress);

        // Assert both deliveries are stored in PendingDeliveries
        (bool existsAlice, PendingDelivery memory pdAlice) = CALLBACK.getDelivery(commitment.requestId, aliceWalletAddress);
        assertTrue(existsAlice);
        assertEq(pdAlice.subscriptionId, subId);
        assertEq(pdAlice.output, MOCK_OUTPUT);

        (bool existsBob, PendingDelivery memory pdBob) = CALLBACK.getDelivery(commitment.requestId, bobWalletAddress);
        assertTrue(existsBob);
        assertEq(pdBob.subscriptionId, subId);
        assertEq(pdBob.output, MOCK_OUTPUT);
    }


    function test_RevertIf_DeliveringCallbackResponse_FromSameNodeTwice() public {
        // Create new callback request w/ redundancy = 2
        uint16 redundancy = 2;
        (uint64 subId, Commitment memory commitment) =
                            CALLBACK.createMockRequest(MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, redundancy, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER);

        bytes memory commitmentData = abi.encode(commitment);

        // Deliver callback request from two nodes (within redundancy)
        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, aliceWalletAddress, 1);
        ALICE.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, aliceWalletAddress);
        vm.expectRevert(Coordinator.NodeRespondedAlready.selector);
        ALICE.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, aliceWalletAddress);
    }

    /// @notice Cannot deliver callback response more than redundancy
    function test_RevertIf_DeliveringCallbackResponse_ExceedingRedundancy() public {
        // Create new callback request w/ redundancy = 2
        uint16 redundancy = 2;
        (uint64 subId, Commitment memory commitment) =
                            CALLBACK.createMockRequest(MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, redundancy, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER);

        // Call the function that emits the event.
        bytes memory commitmentData = abi.encode(commitment);

        // Deliver callback request from two nodes (within redundancy)
        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, aliceWalletAddress, 1);
        ALICE.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, aliceWalletAddress);

        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, bobWalletAddress, 2);
        BOB.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWalletAddress);

        // Attempt to deliver a third response (exceeds redundancy)
        // The Coordinator should revert with a RequestCompleted error.
        vm.expectRevert(abi.encodeWithSelector(ICoordinatorEvents.IntervalCompleted.selector));
        CHARLIE.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWalletAddress);
    }


}