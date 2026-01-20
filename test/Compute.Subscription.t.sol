// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {ComputeTest} from "./Compute.t.sol";
import {Commitment} from "../src/v1_0_0/types/Commitment.sol";
import {ICoordinator} from "../src/v1_0_0/interfaces/ICoordinator.sol";
import {PayloadData} from "../src/v1_0_0/types/PayloadData.sol";
import {ISubscriptionsManager} from "../src/v1_0_0/interfaces/ISubscriptionManager.sol";
import {Wallet} from "../src/v1_0_0/wallet/Wallet.sol";

contract ComputeSubscriptionTest is ComputeTest {
    event SubscriptionCreated(uint64 indexed subscriptionId);

    event SubscriptionCancelled(uint64 indexed subscriptionId);

    function test_Succeeds_When_CancellingSubscription() public {
        // Create subscription
        uint64 subId = ScheduledClient.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, 3, 10 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );
        vm.warp(block.timestamp + 10 minutes);
        // Cancel subscription and expect event emission
        vm.expectEmit(address(ROUTER));
        emit ISubscriptionsManager.SubscriptionCancelled(subId);
        ScheduledClient.cancelMockSubscription(subId);
    }

    function test_Succeeds_When_CancellingFulfilledSubscription() public {
        (uint64 subId, Commitment memory commitment) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 10 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        bytes memory commitmentData = abi.encode(commitment);
        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinator.ComputeDelivered(
            commitment.requestId,
            aliceWalletAddress,
            1,
            _mockInput().contentHash,
            _mockOutput().contentHash,
            _mockProof().contentHash
        );
        alice.reportComputeResult(
            commitment.interval, _mockInput(), _mockOutput(), _mockProof(), commitmentData, aliceWalletAddress
        );

        // Cancel subscription
        vm.expectEmit(address(ROUTER));
        emit ISubscriptionsManager.SubscriptionCancelled(subId);
        ScheduledClient.cancelMockSubscription(subId);
    }

    /// @notice Cannot cancel a subscription that does not exist
    function test_RevertIf_CancellingNonExistentSubscription() public {
        // Try to delete subscription without creating
        vm.expectRevert(bytes("SubscriptionNotFound()"));
        ScheduledClient.cancelMockSubscription(1);
    }

    /// @notice Can cancel a subscription that has already been cancelled
    function test_RevertIf_Cancelling_AlreadyCancelledSubscription() public {
        // Create and cancel subscription
        uint64 subId = ScheduledClient.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, 3, 10 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );
        vm.warp(block.timestamp + 10 minutes);

        // Cancel subscription and expect event emission
        vm.expectEmit(address(ROUTER));
        emit ISubscriptionsManager.SubscriptionCancelled(subId);
        ScheduledClient.cancelMockSubscription(subId);
        // Attempt to cancel again, expect a revert as it's already cancelled
        vm.expectRevert(bytes("SubscriptionNotFound()"));
        ScheduledClient.cancelMockSubscription(subId);
    }

    /// @notice Subscription intervals are properly calculated
    function testFuzz_SubscriptionIntervals_AreCalculatedCorrectly(
        uint32 blockTime,
        uint32 maxExecutions,
        uint32 intervalSeconds
    ) public {
        // In the interest of testing time, upper bounding maxExecutions loops + having at minimum 1 maxExecutions
        vm.assume(maxExecutions > 1 && maxExecutions < 32);
        // Prevent upperbound overflow
        vm.assume(uint256(blockTime) + (uint256(maxExecutions) * uint256(intervalSeconds)) < type(uint32).max);
        vm.assume(intervalSeconds >= 600);

        // Set the block time before creating the subscription
        vm.warp(blockTime);

        (uint64 subId,) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID,
            maxExecutions,
            intervalSeconds,
            1,
            false,
            NO_PAYMENT_TOKEN,
            0,
            userWalletAddress,
            NO_VERIFIER
        );

        // If intervalSeconds == 0, interval is always 1
        if (intervalSeconds == 0) {
            uint32 actual = ROUTER.getComputeSubscriptionInterval(subId);
            assertEq(1, actual);
            return;
        }

        // Else, verify each manual interval
        // blockTime -> blockTime + intervalSeconds = underflow (this should never be called since we verify block.timestamp >= activeAt)
        // blockTime + N * intervalSeconds = N
        uint32 expected = 1;
        for (
            uint32 start = blockTime;
            start < (blockTime) + (maxExecutions * intervalSeconds);
            start += intervalSeconds
        ) {
            // Set current time
            vm.warp(start);

            // Check subscription interval
            uint32 actual = ROUTER.getComputeSubscriptionInterval(subId);
            assertEq(expected, actual);

            // Check subscription interval 1s before if not first iteration
            if (expected != 1) {
                vm.warp(start - 1);
                actual = ROUTER.getComputeSubscriptionInterval(subId);
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
            useDeliveryInbox: false,
            redundancy: 1,
            walletAddress: userWalletAddress,
            feeAmount: 0,
            feeToken: NO_PAYMENT_TOKEN,
            verifier: NO_VERIFIER,
            coordinator: address(COORDINATOR),
            verifierFee: 0
        });
        bytes memory commitmentData = abi.encode(fakeCommitment);

        // The call chain is reportComputeResult -> getSubscriptionInterval -> _isExistingSubscription.
        // This will revert with "InvalidSubscription".
        vm.expectRevert(bytes("InvalidCommitment()"));

        // Call reportComputeResult with the crafted commitment.
        alice.reportComputeResult(1, _mockInput(), _mockOutput(), _mockProof(), commitmentData, address(alice));
    }

    /// @notice Cannot deliver a response for an interval that is not the current one.
    function test_RevertIf_DeliveringResponse_ForIncorrectInterval() public {
        // Create new subscription at time = 0, which will be active at t = 60s
        vm.warp(0);
        uint64 subId = ScheduledClient.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID,
            2, // maxExecutions = 2
            10 minutes,
            2,
            false,
            NO_PAYMENT_TOKEN,
            0,
            userWalletAddress,
            NO_VERIFIER
        );

        // Warp to the first active interval and send the request
        (, Commitment memory commitment1) = ScheduledClient.sendRequest(subId, 1);
        bytes memory commitmentData1 = abi.encode(commitment1);

        // Successfully deliver for interval 1
        alice.reportComputeResult(1, _mockInput(), _mockOutput(), _mockProof(), commitmentData1, aliceWalletAddress);

        // Warp to the second interval
        vm.warp(20 minutes);

        // Now, the current interval is 2. Attempting to deliver for interval 1 should fail.
        // We use the commitment from the first interval to simulate this.
        vm.expectRevert(abi.encodeWithSelector(ICoordinator.IntervalMismatch.selector, 1));
        alice.reportComputeResult(1, _mockInput(), _mockOutput(), _mockProof(), commitmentData1, aliceWalletAddress);
    }

    /// @notice Reverts if the subscription interval is shorter than the minimum allowed.
    function test_RevertIf_SubscriptionIntervalIsTooShort() public {
        uint32 shortInterval = 599;
        uint32 expectedMinInterval = ROUTER.minRepeatInterval();

        vm.expectRevert(
            abi.encodeWithSelector(
                ISubscriptionsManager.SubscriptionIntervalTooShort.selector, shortInterval, expectedMinInterval
            )
        );

        ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID,
            1, // maxExecutions
            shortInterval,
            1, // redundancy
            false, // useDeliveryInbox
            NO_PAYMENT_TOKEN,
            0,
            userWalletAddress,
            NO_VERIFIER
        );
    }

    /// @notice The owner should be able to set the minimum repeat interval.
    function test_Succeeds_When_SettingMinRepeatInterval() public {
        uint32 newMinInterval = 1200; // 20 minutes

        vm.expectEmit(true, false, false, true, address(ROUTER));
        emit ISubscriptionsManager.MinRepeatIntervalSet(newMinInterval);

        ROUTER.setMinRepeatInterval(newMinInterval);

        assertEq(ROUTER.minRepeatInterval(), newMinInterval, "Minimum repeat interval should be updated");
    }

    /// @notice Non-owners should not be able to set the minimum repeat interval.
    function test_RevertIf_NonOwnerSetsMinRepeatInterval() public {
        uint32 newMinInterval = 1200;

        vm.prank(address(alice));
        vm.expectRevert(bytes("Only callable by client"));
        ROUTER.setMinRepeatInterval(newMinInterval);
    }

    /// @notice Owner can cancel subscription with no pending commitments
    function test_Succeeds_When_OwnerCancelsSubscriptionWithoutCommitments() public {
        // Create subscription
        vm.warp(0);
        uint64 subId = ScheduledClient.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, 3, 10 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Move to interval 2 without creating any commitments
        vm.warp(20 minutes);

        // Owner should be able to cancel
        vm.expectEmit(address(ROUTER));
        emit ISubscriptionsManager.SubscriptionCancelled(subId);
        vm.prank(address(this)); // Owner is address(this)
        ROUTER.ownerCancelSubscription(subId);
    }

    /// @notice Owner can cancel subscription and clean up past interval commitments
    function test_Succeeds_When_OwnerCancelsSubscriptionWithPastCommitments() public {
        // Create subscription with payment
        vm.warp(0);
        uint256 feeAmount = 10e6;

        // Fund and approve wallet
        vm.deal(userWalletAddress, 1 ether);
        vm.prank(address(this));
        Wallet(payable(userWalletAddress)).approve(address(ScheduledClient), NO_PAYMENT_TOKEN, feeAmount * 3);

        (uint64 subId,) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 10 minutes, 1, false, NO_PAYMENT_TOKEN, feeAmount, userWalletAddress, NO_VERIFIER
        );

        // Create commitment for interval 1
        (, Commitment memory commitment1) = ScheduledClient.sendRequest(subId, 1);
        bytes32 requestId1 = commitment1.requestId;

        // Move to interval 2 and create commitment
        vm.warp(10 minutes);
        (, Commitment memory commitment2) = ScheduledClient.sendRequest(subId, 2);
        bytes32 requestId2 = commitment2.requestId;

        // Move to interval 3 without creating commitment
        vm.warp(20 minutes);

        // Verify that interval 1 and 2 have locked funds
        uint256 lockedInterval1Before = Wallet(payable(userWalletAddress)).lockedOfRequest(requestId1);
        uint256 lockedInterval2Before = Wallet(payable(userWalletAddress)).lockedOfRequest(requestId2);
        assertEq(lockedInterval1Before, feeAmount, "Interval 1 should have locked funds");
        assertEq(lockedInterval2Before, feeAmount, "Interval 2 should have locked funds");

        // Owner cancels subscription - should clean up interval 1 and 2
        vm.expectEmit(address(ROUTER));
        emit ISubscriptionsManager.SubscriptionCancelled(subId);
        vm.prank(address(this));
        ROUTER.ownerCancelSubscription(subId);

        // Verify that all past commitments are cleaned up
        uint256 lockedInterval1After = Wallet(payable(userWalletAddress)).lockedOfRequest(requestId1);
        uint256 lockedInterval2After = Wallet(payable(userWalletAddress)).lockedOfRequest(requestId2);
        assertEq(lockedInterval1After, 0, "Interval 1 funds should be released");
        assertEq(lockedInterval2After, 0, "Interval 2 funds should be released");
    }

    /// @notice Owner can cancel subscription even with current interval commitment
    function test_Succeeds_When_OwnerCancelsSubscriptionWithCurrentCommitment() public {
        // Create subscription with payment
        vm.warp(0);
        uint256 feeAmount = 10e6;

        // Fund and approve wallet
        vm.deal(userWalletAddress, 1 ether);
        vm.prank(address(this));
        Wallet(payable(userWalletAddress)).approve(address(ScheduledClient), NO_PAYMENT_TOKEN, feeAmount * 3);

        (uint64 subId, Commitment memory commitment1) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 10 minutes, 1, false, NO_PAYMENT_TOKEN, feeAmount, userWalletAddress, NO_VERIFIER
        );
        bytes32 requestId1 = commitment1.requestId;

        // Verify current interval has locked funds
        uint256 lockedBefore = Wallet(payable(userWalletAddress)).lockedOfRequest(requestId1);
        assertEq(lockedBefore, feeAmount, "Current interval should have locked funds");

        // Owner cancels - should clean up current interval commitment
        vm.expectEmit(address(ROUTER));
        emit ISubscriptionsManager.SubscriptionCancelled(subId);
        vm.prank(address(this));
        ROUTER.ownerCancelSubscription(subId);

        // Verify commitment is cleaned up
        uint256 lockedAfter = Wallet(payable(userWalletAddress)).lockedOfRequest(requestId1);
        assertEq(lockedAfter, 0, "Current interval funds should be released");
    }

    /// @notice Owner cancel cleans up multiple past intervals efficiently
    function test_Succeeds_When_OwnerCancelsSubscriptionWithManyPastCommitments() public {
        // Create subscription with 5 intervals
        vm.warp(0);
        uint256 feeAmount = 10e6;

        // Fund and approve wallet for 5 intervals
        vm.deal(userWalletAddress, 1 ether);
        vm.prank(address(this));
        Wallet(payable(userWalletAddress)).approve(address(ScheduledClient), NO_PAYMENT_TOKEN, feeAmount * 5);

        (uint64 subId,) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 5, 10 minutes, 1, false, NO_PAYMENT_TOKEN, feeAmount, userWalletAddress, NO_VERIFIER
        );

        // Create commitments for intervals 1-4
        bytes32[] memory requestIds = new bytes32[](4);
        for (uint32 i = 1; i <= 4; i++) {
            vm.warp((i - 1) * 10 minutes);
            (, Commitment memory commitment) = ScheduledClient.sendRequest(subId, i);
            requestIds[i - 1] = commitment.requestId;
        }

        // Move to interval 5
        vm.warp(40 minutes);

        // Verify all 4 intervals have locked funds
        for (uint32 i = 0; i < 4; i++) {
            uint256 locked = Wallet(payable(userWalletAddress)).lockedOfRequest(requestIds[i]);
            assertEq(locked, feeAmount, string(abi.encodePacked("Interval ", i + 1, " should have locked funds")));
        }

        // Owner cancels - should clean up all 4 past intervals
        vm.prank(address(this));
        ROUTER.ownerCancelSubscription(subId);

        // Verify all commitments are cleaned up
        for (uint32 i = 0; i < 4; i++) {
            uint256 locked = Wallet(payable(userWalletAddress)).lockedOfRequest(requestIds[i]);
            assertEq(locked, 0, string(abi.encodePacked("Interval ", i + 1, " funds should be released")));
        }
    }

    /// @notice Non-owner cannot call ownerCancelSubscription
    function test_RevertIf_NonOwnerCallsOwnerCancelSubscription() public {
        // Create subscription
        vm.warp(0);
        uint64 subId = ScheduledClient.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, 3, 10 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Non-owner tries to cancel
        vm.prank(address(alice));
        vm.expectRevert(bytes("Only callable by client"));
        ROUTER.ownerCancelSubscription(subId);
    }

    /// @notice Verifies that wallet total locked balance is properly updated when owner cancels with commitments
    function test_Succeeds_When_OwnerCancelsSubscription_VerifyWalletTotalLocked() public {
        // Create subscription with payment
        vm.warp(0);
        uint256 feeAmount = 10e6;

        // Fund and approve wallet
        vm.deal(userWalletAddress, 1 ether);
        vm.prank(address(this));
        Wallet(payable(userWalletAddress)).approve(address(ScheduledClient), NO_PAYMENT_TOKEN, feeAmount * 4);

        (uint64 subId,) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 4, 10 minutes, 1, false, NO_PAYMENT_TOKEN, feeAmount, userWalletAddress, NO_VERIFIER
        );

        // Create commitments for intervals 1-3
        bytes32[] memory requestIds = new bytes32[](3);
        for (uint32 i = 1; i <= 3; i++) {
            vm.warp((i - 1) * 10 minutes);
            (, Commitment memory commitment) = ScheduledClient.sendRequest(subId, i);
            requestIds[i - 1] = commitment.requestId;
        }

        // Move to interval 4
        vm.warp(30 minutes);

        // Verify total locked balance before cancellation
        uint256 totalLockedBefore = Wallet(payable(userWalletAddress)).totalLockedFor(NO_PAYMENT_TOKEN);
        assertEq(totalLockedBefore, feeAmount * 3, "Total locked should equal 3 intervals worth of fees");

        // Verify individual request locks before cancellation
        for (uint32 i = 0; i < 3; i++) {
            uint256 lockedForRequest = Wallet(payable(userWalletAddress)).lockedOfRequest(requestIds[i]);
            assertEq(
                lockedForRequest,
                feeAmount,
                string(abi.encodePacked("Request ", i + 1, " should have locked funds before owner cancel"))
            );
        }

        // Owner cancels subscription
        vm.prank(address(this));
        ROUTER.ownerCancelSubscription(subId);

        // Verify total locked balance after cancellation
        uint256 totalLockedAfter = Wallet(payable(userWalletAddress)).totalLockedFor(NO_PAYMENT_TOKEN);
        assertEq(totalLockedAfter, 0, "Total locked should be 0 after owner cancellation");

        // Verify individual request locks are released
        for (uint32 i = 0; i < 3; i++) {
            uint256 lockedForRequest = Wallet(payable(userWalletAddress)).lockedOfRequest(requestIds[i]);
            assertEq(
                lockedForRequest,
                0,
                string(abi.encodePacked("Request ", i + 1, " should have no locked funds after owner cancel"))
            );
        }

        // Verify wallet allowance is properly restored
        uint256 allowanceAfter =
            Wallet(payable(userWalletAddress)).allowance(address(ScheduledClient), NO_PAYMENT_TOKEN);
        assertEq(
            allowanceAfter,
            feeAmount * 4,
            "Allowance should be fully restored to original amount after owner cancellation"
        );
    }

    /// @notice Client can cancel subscription and clean up past interval commitments
    function test_Succeeds_When_CancellingSubscriptionWithPastCommitments() public {
        // Create subscription with payment
        vm.warp(0);
        uint256 feeAmount = 10e6;

        // Fund and approve wallet
        vm.deal(userWalletAddress, 1 ether);
        vm.prank(address(this));
        Wallet(payable(userWalletAddress)).approve(address(ScheduledClient), NO_PAYMENT_TOKEN, feeAmount * 3);

        (uint64 subId,) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 10 minutes, 1, false, NO_PAYMENT_TOKEN, feeAmount, userWalletAddress, NO_VERIFIER
        );

        // Create commitment for interval 1
        (, Commitment memory commitment1) = ScheduledClient.sendRequest(subId, 1);
        bytes32 requestId1 = commitment1.requestId;

        // Move to interval 2 and create commitment
        vm.warp(10 minutes);
        (, Commitment memory commitment2) = ScheduledClient.sendRequest(subId, 2);
        bytes32 requestId2 = commitment2.requestId;

        // Move to interval 3 without creating commitment
        vm.warp(20 minutes);

        // Verify that interval 1 and 2 have locked funds
        uint256 lockedInterval1Before = Wallet(payable(userWalletAddress)).lockedOfRequest(requestId1);
        uint256 lockedInterval2Before = Wallet(payable(userWalletAddress)).lockedOfRequest(requestId2);
        assertEq(lockedInterval1Before, feeAmount, "Interval 1 should have locked funds");
        assertEq(lockedInterval2Before, feeAmount, "Interval 2 should have locked funds");

        // Client cancels subscription - should clean up interval 1 and 2
        vm.expectEmit(address(ROUTER));
        emit ISubscriptionsManager.SubscriptionCancelled(subId);
        ScheduledClient.cancelMockSubscription(subId);

        // Verify that all past commitments are cleaned up
        uint256 lockedInterval1After = Wallet(payable(userWalletAddress)).lockedOfRequest(requestId1);
        uint256 lockedInterval2After = Wallet(payable(userWalletAddress)).lockedOfRequest(requestId2);
        assertEq(lockedInterval1After, 0, "Interval 1 funds should be released");
        assertEq(lockedInterval2After, 0, "Interval 2 funds should be released");
    }

    /// @notice Client can cancel subscription with current interval commitment
    function test_Succeeds_When_CancellingSubscriptionWithCurrentCommitment() public {
        // Create subscription with payment
        vm.warp(0);
        uint256 feeAmount = 10e6;

        // Fund and approve wallet
        vm.deal(userWalletAddress, 1 ether);
        vm.prank(address(this));
        Wallet(payable(userWalletAddress)).approve(address(ScheduledClient), NO_PAYMENT_TOKEN, feeAmount * 3);

        (uint64 subId, Commitment memory commitment1) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 10 minutes, 1, false, NO_PAYMENT_TOKEN, feeAmount, userWalletAddress, NO_VERIFIER
        );
        bytes32 requestId1 = commitment1.requestId;

        // Verify current interval has locked funds
        uint256 lockedBefore = Wallet(payable(userWalletAddress)).lockedOfRequest(requestId1);
        assertEq(lockedBefore, feeAmount, "Current interval should have locked funds");

        // Client cancels - should clean up current interval commitment
        vm.expectEmit(address(ROUTER));
        emit ISubscriptionsManager.SubscriptionCancelled(subId);
        ScheduledClient.cancelMockSubscription(subId);

        // Verify commitment is cleaned up
        uint256 lockedAfter = Wallet(payable(userWalletAddress)).lockedOfRequest(requestId1);
        assertEq(lockedAfter, 0, "Current interval funds should be released");
    }

    /// @notice Client cancel cleans up multiple past intervals efficiently
    function test_Succeeds_When_CancellingSubscriptionWithManyPastCommitments() public {
        // Create subscription with 5 intervals
        vm.warp(0);
        uint256 feeAmount = 10e6;

        // Fund and approve wallet for 5 intervals
        vm.deal(userWalletAddress, 1 ether);
        vm.prank(address(this));
        Wallet(payable(userWalletAddress)).approve(address(ScheduledClient), NO_PAYMENT_TOKEN, feeAmount * 5);

        (uint64 subId,) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 5, 10 minutes, 1, false, NO_PAYMENT_TOKEN, feeAmount, userWalletAddress, NO_VERIFIER
        );

        // Create commitments for intervals 1-4
        bytes32[] memory requestIds = new bytes32[](4);
        for (uint32 i = 1; i <= 4; i++) {
            vm.warp((i - 1) * 10 minutes);
            (, Commitment memory commitment) = ScheduledClient.sendRequest(subId, i);
            requestIds[i - 1] = commitment.requestId;
        }

        // Move to interval 5
        vm.warp(40 minutes);

        // Verify all 4 intervals have locked funds
        for (uint32 i = 0; i < 4; i++) {
            uint256 locked = Wallet(payable(userWalletAddress)).lockedOfRequest(requestIds[i]);
            assertEq(locked, feeAmount, string(abi.encodePacked("Interval ", i + 1, " should have locked funds")));
        }

        // Client cancels - should clean up all 4 past intervals
        ScheduledClient.cancelMockSubscription(subId);

        // Verify all commitments are cleaned up
        for (uint32 i = 0; i < 4; i++) {
            uint256 locked = Wallet(payable(userWalletAddress)).lockedOfRequest(requestIds[i]);
            assertEq(locked, 0, string(abi.encodePacked("Interval ", i + 1, " funds should be released")));
        }
    }

    /// @notice Verifies that wallet total locked balance is properly updated when cancelling with commitments
    function test_Succeeds_When_CancellingSubscription_VerifyWalletTotalLocked() public {
        // Create subscription with payment
        vm.warp(0);
        uint256 feeAmount = 10e6;

        // Fund and approve wallet
        vm.deal(userWalletAddress, 1 ether);
        vm.prank(address(this));
        Wallet(payable(userWalletAddress)).approve(address(ScheduledClient), NO_PAYMENT_TOKEN, feeAmount * 4);

        (uint64 subId,) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 4, 10 minutes, 1, false, NO_PAYMENT_TOKEN, feeAmount, userWalletAddress, NO_VERIFIER
        );

        // Create commitments for intervals 1-3
        bytes32[] memory requestIds = new bytes32[](3);
        for (uint32 i = 1; i <= 3; i++) {
            vm.warp((i - 1) * 10 minutes);
            (, Commitment memory commitment) = ScheduledClient.sendRequest(subId, i);
            requestIds[i - 1] = commitment.requestId;
        }

        // Move to interval 4
        vm.warp(30 minutes);

        // Verify total locked balance before cancellation
        uint256 totalLockedBefore = Wallet(payable(userWalletAddress)).totalLockedFor(NO_PAYMENT_TOKEN);
        assertEq(totalLockedBefore, feeAmount * 3, "Total locked should equal 3 intervals worth of fees");

        // Verify individual request locks before cancellation
        for (uint32 i = 0; i < 3; i++) {
            uint256 lockedForRequest = Wallet(payable(userWalletAddress)).lockedOfRequest(requestIds[i]);
            assertEq(
                lockedForRequest,
                feeAmount,
                string(abi.encodePacked("Request ", i + 1, " should have locked funds before cancel"))
            );
        }

        // Client cancels subscription
        ScheduledClient.cancelMockSubscription(subId);

        // Verify total locked balance after cancellation
        uint256 totalLockedAfter = Wallet(payable(userWalletAddress)).totalLockedFor(NO_PAYMENT_TOKEN);
        assertEq(totalLockedAfter, 0, "Total locked should be 0 after cancellation");

        // Verify individual request locks are released
        for (uint32 i = 0; i < 3; i++) {
            uint256 lockedForRequest = Wallet(payable(userWalletAddress)).lockedOfRequest(requestIds[i]);
            assertEq(
                lockedForRequest,
                0,
                string(abi.encodePacked("Request ", i + 1, " should have no locked funds after cancel"))
            );
        }

        // Verify wallet allowance is properly restored
        uint256 allowanceAfter =
            Wallet(payable(userWalletAddress)).allowance(address(ScheduledClient), NO_PAYMENT_TOKEN);
        assertEq(
            allowanceAfter, feeAmount * 4, "Allowance should be fully restored to original amount after cancellation"
        );
    }
}
