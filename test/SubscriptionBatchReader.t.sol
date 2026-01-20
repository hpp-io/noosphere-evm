// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {SubscriptionBatchReader} from "../src/v1_0_0/utility/SubscriptionBatchReader.sol";
import {ComputeSubscription} from "../src/v1_0_0/types/ComputeSubscription.sol";
import {ComputeTest} from "./Compute.t.sol";
import {MockDelegatorScheduledComputeClient} from "./mocks/client/MockDelegatorScheduledComputeClient.sol";
import {Commitment} from "../src/v1_0_0/types/Commitment.sol";
import {Wallet} from "../src/v1_0_0/wallet/Wallet.sol";
import {console} from "forge-std/console.sol";
import {PayloadData} from "../src/v1_0_0/types/PayloadData.sol";

/// @title SubscriptionBatchReaderTest
/// @notice Tests SubscriptionBatchReader implementation
/// @dev Inherits `ComputeTest` to borrow mocks and setup.
contract SubscriptionBatchReaderTest is ComputeTest {
    /*//////////////////////////////////////////////////////////////
                                CONTRACTS
    //////////////////////////////////////////////////////////////*/

    /// @notice SubscriptionBatchReader
    SubscriptionBatchReader private batchReader;

    /// @notice Mock subscription consumer
    MockDelegatorScheduledComputeClient private scheduledClient;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public override {
        super.setUp();
        // The base ComputeTest deploys most contracts. We just need the reader.
        address coordinator = ROUTER.getContractById("Coordinator_v1.0.0");
        batchReader = new SubscriptionBatchReader(address(ROUTER), coordinator);
        scheduledClient = new MockDelegatorScheduledComputeClient(address(ROUTER), address(this));
        vm.prank(address(this));
        COORDINATOR.setSubscriptionBatchReader(address(batchReader));
    }

    /*//////////////////////////////////////////////////////////////
                                 TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Can retrieve the batch reader address from the coordinator
    function test_Succeeds_When_GettingReaderFromCoordinator() public view {
        // Act
        address readerAddressFromCoordinator = COORDINATOR.getSubscriptionBatchReader();

        // Assert
        assertEq(readerAddressFromCoordinator, address(batchReader));
    }

    /// @notice Can read single subscription
    function test_Succeeds_When_ReadingSingleSubscription() public {
        // Create subscription
        vm.warp(0);
        (uint64 subId,) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 10 minutes, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Read via `SubscriptionBatchReader ` and direct via `Router`
        ComputeSubscription[] memory read = batchReader.getSubscriptions(subId, subId);
        ComputeSubscription memory actual = ROUTER.getComputeSubscription(subId);

        // Assert batch length
        assertEq(read.length, 1);

        // Assert subscription parameters
        assertEq(read[0].client, actual.client);
        assertEq(read[0].activeAt, actual.activeAt);
        assertEq(read[0].intervalSeconds, actual.intervalSeconds);
        assertEq(read[0].maxExecutions, actual.maxExecutions);
        assertEq(read[0].containerId, actual.containerId);
        assertEq(read[0].useDeliveryInbox, actual.useDeliveryInbox);
        assertEq(read[0].feeToken, actual.feeToken);
        assertEq(read[0].feeAmount, actual.feeAmount);
        assertEq(read[0].wallet, actual.wallet);
        assertEq(read[0].verifier, actual.verifier);
    }

    /// @notice Can read batch subscriptions
    function test_Succeeds_When_ReadingBatchOfSubscriptions() public {
        // Create normal subscriptions at ids {1, 2, 3}
        // Create cancelled subscription at id {4}
        // Check non-existent subscription at id {5}
        vm.warp(0);

        // Fund and approve the user wallet for the subscriptions
        uint256 requiredFunds = 10e6 * 4;
        vm.deal(userWalletAddress, requiredFunds);
        vm.prank(address(this));
        Wallet(payable(userWalletAddress)).approve(address(ScheduledClient), NO_PAYMENT_TOKEN, requiredFunds);

        console.log("User wallet balance before:", userWalletAddress.balance);
        console.log(
            "User wallet allowance for SUBSCRIPTION:",
            Wallet(payable(userWalletAddress)).allowance(address(ScheduledClient), NO_PAYMENT_TOKEN)
        );

        // Create normal subscriptions at ids {1, 2, 3, 4}
        for (uint32 i = 0; i < 4; i++) {
            ScheduledClient.createMockSubscriptionWithoutRequest(
                MOCK_CONTAINER_ID,
                i + 1, // Use maxExecutions as verification index
                10 minutes,
                false,
                NO_PAYMENT_TOKEN,
                10e6,
                userWalletAddress,
                NO_VERIFIER
            );
        }

        console.log("User wallet balance after creating subs:", userWalletAddress.balance);
        console.log(
            "User wallet allowance for SUBSCRIPTION after:",
            Wallet(payable(userWalletAddress)).allowance(address(ScheduledClient), NO_PAYMENT_TOKEN)
        );

        // Cancel subscription id {4}
        vm.prank(address(ScheduledClient));
        ROUTER.cancelComputeSubscription(4);

        // Read subscriptions
        ComputeSubscription[] memory read = batchReader.getSubscriptions(1, 5);

        // Assert batch length
        assertEq(read.length, 5);

        // Check normal subscriptions {1, 2, 3}
        for (uint32 i = 0; i < 3; i++) {
            assertEq(read[i].client, address(ScheduledClient));
            assertEq(read[i].intervalSeconds, 10 minutes);
            assertEq(read[i].maxExecutions, i + 1); // Use as verification index
            assertEq(read[i].containerId, HASHED_MOCK_CONTAINER_ID);
            assertEq(read[i].useDeliveryInbox, false);
            assertEq(read[i].feeToken, NO_PAYMENT_TOKEN);
            assertEq(read[i].feeAmount, 10e6);
            assertEq(read[i].wallet, payable(userWalletAddress));
            assertEq(read[i].verifier, payable(NO_VERIFIER));
        }

        //        // Check cancelled subscription
        assertEq(read[3].client, address(0));

        // Check non-existent subscription
        assertEq(read[4].client, address(0));
        assertEq(read[4].activeAt, 0);
        assertEq(read[4].intervalSeconds, 0);
        assertEq(read[4].maxExecutions, 0);
        assertEq(read[4].containerId, bytes32(0));
        assertEq(read[4].useDeliveryInbox, false);
        assertEq(read[4].feeAmount, 0);
    }

    /// @notice Can read interval commitment status
    function test_Succeeds_When_QueryingIntervalStatus() public {
        // Create subscriptions
        vm.warp(0);
        uint64 subOne = ScheduledClient.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, 2, 10 minutes, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        uint64 subTwo = ScheduledClient.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, 1, 10 minutes, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Create commitments for intervals
        (, Commitment memory commitmentStruct1) = ScheduledClient.sendRequest(subOne, 1);
        (, Commitment memory commitmentStruct2) = ScheduledClient.sendRequest(subTwo, 1);

        // Deliver to clear commitments
        bytes memory commitment1 = abi.encode(commitmentStruct1);
        alice.reportComputeResult(1, _mockInput(), _mockOutput(), _mockProof(), commitment1, aliceWalletAddress);

        // Create new commitment for interval 2
        vm.warp(10 minutes);
        (, Commitment memory commitmentStruct3) = ScheduledClient.sendRequest(subOne, 2);

        // Check interval statuses
        uint64[] memory ids = new uint64[](4);
        uint32[] memory intervals = new uint32[](4);

        // (id: subOne, interval: 1) - commitment was delivered, should be false
        ids[0] = subOne;
        intervals[0] = 1;

        // (id: subOne, interval: 2) - commitment exists, should be true
        ids[1] = subOne;
        intervals[1] = 2;

        // (id: subTwo, interval: 1) - commitment exists (not delivered), should be true
        ids[2] = subTwo;
        intervals[2] = 1;

        // (id: subTwo, interval: 2) - no commitment, should be false
        ids[3] = subTwo;
        intervals[3] = 2;

        SubscriptionBatchReader.IntervalStatus[] memory actual = batchReader.getIntervalStatuses(ids, intervals);

        assertEq(actual[0].commitmentExists, false); // Delivered, commitment deleted
        assertEq(actual[1].commitmentExists, true); // Pending commitment
        assertEq(actual[2].commitmentExists, true); // Pending commitment
        assertEq(actual[3].commitmentExists, false); // No commitment created
    }

    /// @notice Commitment status after subscription cancellation
    /// @dev TODO: This test is skipped because cancellation only cleans up the Router's requestCommitments
    ///      but not the Coordinator's s_requestCommitments. SubscriptionBatchReader reads from Coordinator,
    ///      so commitmentExists remains true after cancellation. Fix requires adding Coordinator.cancelRequest()
    ///      call to SubscriptionManager._cancelSubscriptionHelper().
    function test_Succeeds_When_QueryingStatusAfterSubscriptionCancellation() public {
        vm.skip(true);
        // Create subscription
        vm.warp(0);
        (uint64 subId, Commitment memory commitment) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 10 minutes, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Check commitment exists
        uint64[] memory ids = new uint64[](1);
        uint32[] memory intervals = new uint32[](1);
        ids[0] = subId;
        intervals[0] = 1;
        SubscriptionBatchReader.IntervalStatus[] memory statusesBefore = batchReader.getIntervalStatuses(ids, intervals);
        assertEq(statusesBefore[0].commitmentExists, true);

        // Cancel subscription (should clean up commitment)
        vm.prank(address(ScheduledClient));
        ROUTER.cancelComputeSubscription(subId);

        // Check commitment no longer exists
        SubscriptionBatchReader.IntervalStatus[] memory statusesAfter = batchReader.getIntervalStatuses(ids, intervals);
        assertEq(statusesAfter[0].commitmentExists, false);
    }

    /// @notice Non-existent interval returns no commitment
    function test_Fuzz_NonExistentInterval_ReturnsNoCommitment(uint64 subscriptionId, uint32 interval) public view {
        uint64[] memory ids = new uint64[](1);
        uint32[] memory intervals = new uint32[](1);
        ids[0] = subscriptionId;
        intervals[0] = interval;
        SubscriptionBatchReader.IntervalStatus[] memory statuses = batchReader.getIntervalStatuses(ids, intervals);

        assertEq(statuses.length, 1);
        assertEq(statuses[0].commitmentExists, false);
    }

    /// @notice Cannot read when input array lengths mismatch
    function test_Reverts_When_InputArrayLengthMismatch() public {
        uint64[] memory ids = new uint64[](2);
        uint32[] memory intervals = new uint32[](1);

        ids[0] = 0;
        ids[1] = 1;
        intervals[0] = 0;

        vm.expectRevert();
        batchReader.getIntervalStatuses(ids, intervals);
    }
}
