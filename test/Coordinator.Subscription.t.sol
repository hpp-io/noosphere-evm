// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {CoordinatorTest, ICoordinatorEvents} from "./Coordinator.t.sol";
import {Commitment} from "../src/v1_0_0/types/Commitment.sol";

contract CoordinatorSubscriptionTest is CoordinatorTest {
    function test_Succeeds_When_CancellingSubscription() public {
        // Create subscription
        uint64 subId = SUBSCRIPTION.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, 3, 1 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );
        vm.warp(block.timestamp + 1 minutes);
        // Cancel subscription and expect event emission
        vm.expectEmit(address(ROUTER));
        emit SubscriptionCancelled(subId);
        SUBSCRIPTION.cancelMockSubscription(subId);
    }

    function test_Succeeds_When_CancellingFulfilledSubscription() public {
        // Create subscription
        // vm.warp(0);
        (uint64 subId, Commitment memory commitment) = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 1 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        bytes memory commitmentData = abi.encode(commitment);

        // Fulfill at least once
        vm.warp(block.timestamp + 1 minutes);
        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, aliceWalletAddress, 1);
        ALICE.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, aliceWalletAddress);

        // Cancel subscription
        vm.expectEmit(address(ROUTER));
        emit SubscriptionCancelled(subId);
        SUBSCRIPTION.cancelMockSubscription(subId);
    }

    /// @notice Cannot cancel a subscription that does not exist
    function test_RevertIf_CancellingNonExistentSubscription() public {
        // Try to delete subscription without creating
        vm.expectRevert(bytes("NotSubscriptionOwner()"));
        SUBSCRIPTION.cancelMockSubscription(1);
    }

    /// @notice Can cancel a subscription that has already been cancelled
    function test_RevertIf_Cancelling_AlreadyCancelledSubscription() public {
        // Create and cancel subscription
        uint64 subId = SUBSCRIPTION.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, 3, 1 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );
        vm.warp(block.timestamp + 1 minutes);

        // Cancel subscription and expect event emission
        vm.expectEmit(address(ROUTER));
        emit SubscriptionCancelled(subId);
        SUBSCRIPTION.cancelMockSubscription(subId);
        // Attempt to cancel again, expect a revert as it's already cancelled
        vm.expectRevert(bytes("SubscriptionNotFound()"));
        SUBSCRIPTION.cancelMockSubscription(subId);
    }

    /// @notice Subscription intervals are properly calculated
    function testFuzz_SubscriptionIntervals_AreCalculatedCorrectly(
        uint32 blockTime,
        uint32 frequency,
        uint32 period
    ) public {
        // In the interest of testing time, upper bounding frequency loops + having at minimum 1 frequency
        vm.assume(frequency > 1 && frequency < 32);
        // Prevent upperbound overflow
        vm.assume(uint256(blockTime) + (uint256(frequency) * uint256(period)) < 2 ** 32 - 1);

        // Set the block time before creating the subscription
        vm.warp(blockTime);

        uint64 subId = SUBSCRIPTION.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, frequency, period, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Subscription activeAt timestamp
        uint32 activeAt = blockTime + period;

        // If period == 0, interval is always 1
        if (period == 0) {
            uint32 actual = ROUTER.getSubscriptionInterval(subId);
            assertEq(1, actual);
            return;
        }

        // Else, verify each manual interval
        // blockTime -> blockTime + period = underflow (this should never be called since we verify block.timestamp >= activeAt)
        // blockTime + N * period = N
        uint32 expected = 1;
        for (uint32 start = blockTime + period; start < (blockTime) + (frequency * period); start += period) {
            // Set current time
            vm.warp(start);

            // Check subscription interval
            uint32 actual = ROUTER.getSubscriptionInterval(subId);
            assertEq(expected, actual);

            // Check subscription interval 1s before if not first iteration
            if (expected != 1) {
                vm.warp(start - 1);
                actual = ROUTER.getSubscriptionInterval(subId);
                assertEq(expected - 1, actual);
            }

            // Increment expected for next cycle
            expected++;
        }
    }

    function test_RevertIf_DeliveringResponse_ForNonExistentSubscription() public {
        // Attempt to deliver output for subscription without creating
        uint64 nonExistentSubId = 999;
        Commitment memory fakeCommitment = Commitment({
            requestId: keccak256(abi.encodePacked(nonExistentSubId, uint32(1))),
            subscriptionId: nonExistentSubId,
            containerId: HASHED_MOCK_CONTAINER_ID,
            interval: 1,
            lazy: false,
            redundancy: 1,
            walletAddress: userWalletAddress,
            paymentAmount: 0,
            paymentToken: NO_PAYMENT_TOKEN,
            verifier: NO_VERIFIER,
            coordinator: address(COORDINATOR)
        });
        bytes memory commitmentData = abi.encode(fakeCommitment);

        // The call chain is deliverCompute -> getSubscriptionInterval -> _isExistingSubscription.
        // This will revert with "InvalidSubscription".
        vm.expectRevert(bytes("SubscriptionNotFound()"));

        // Call deliverCompute with the crafted commitment.
        ALICE.deliverCompute(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, address(ALICE));
    }

    /// @notice Cannot deliver a response for an interval that is not the current one.
    function test_RevertIf_DeliveringResponse_ForIncorrectInterval() public {
        // Create new subscription at time = 0, which will be active at t = 60s
        vm.warp(0);
        uint64 subId = SUBSCRIPTION.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID,
            2, // frequency = 2
            1 minutes,
            1,
            false,
            NO_PAYMENT_TOKEN,
            0,
            userWalletAddress,
            NO_VERIFIER
        );

        // Warp to the first active interval and send the request
        vm.warp(1 minutes);
        (, Commitment memory commitment1) = ROUTER.sendRequest(subId, 1);
        bytes memory commitmentData1 = abi.encode(commitment1);

        // Successfully deliver for interval 1
        ALICE.deliverCompute(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, aliceWalletAddress);

        // Warp to the second interval
        vm.warp(2 minutes);

        // Now, the current interval is 2. Attempting to deliver for interval 1 should fail.
        // We use the commitment from the first interval to simulate this.
        vm.expectRevert(abi.encodeWithSelector(ICoordinatorEvents.IntervalMismatch.selector, 1));
        ALICE.deliverCompute(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, aliceWalletAddress);
    }
}