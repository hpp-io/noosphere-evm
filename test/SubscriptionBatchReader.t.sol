// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {Router} from "../src/v1_0_0/Router.sol";
import {MockAgent} from "./mocks/MockAgent.sol";
import {DeployUtils} from "./lib/DeployUtils.sol";
import {stdError} from "forge-std/StdError.sol";
import {SubscriptionBatchReader} from "../src/v1_0_0/utility/SubscriptionBatchReader.sol";
import {ComputeSubscription} from "../src/v1_0_0/types/ComputeSubscription.sol";
import {ComputeTest} from "./Compute.t.sol";
import {Coordinator} from "../src/v1_0_0/Coordinator.sol";
import {MockDelegatorSubscriptionConsumer} from "./mocks/client/MockDelegatorSubscriptionConsumer.sol";
import {Commitment} from "../src/v1_0_0/types/Commitment.sol";
import {Wallet} from "../src/v1_0_0/wallet/Wallet.sol";
import {console} from "forge-std/console.sol";

/// @title SubscriptionBatchReaderTest
/// @notice Tests SubscriptionBatchReader implementation
/// @dev Inherits `ComputeTest` to borrow mocks and setup.
contract SubscriptionBatchReaderTest is ComputeTest {
    /*//////////////////////////////////////////////////////////////
                                CONTRACTS
    //////////////////////////////////////////////////////////////*/

    /// @notice SubscriptionBatchReader
    SubscriptionBatchReader private READER;

    /// @notice Mock subscription consumer
    MockDelegatorSubscriptionConsumer private SUBSCRIPTION_CONSUMER;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public override {
        super.setUp();
        // The base ComputeTest deploys most contracts. We just need the reader.
        address coordinator = ROUTER.getContractById("Coordinator_v1.0.0");
        READER = new SubscriptionBatchReader(address(ROUTER), coordinator);
        SUBSCRIPTION_CONSUMER = new MockDelegatorSubscriptionConsumer(address(ROUTER), address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                 TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Can read single subscription
    function test_Succeeds_When_ReadingSingleSubscription() public {
        // Create subscription
        vm.warp(0);
        (uint64 subId,) = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 1 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Read via `SubscriptionBatchReader ` and direct via `Router`
        ComputeSubscription[] memory read = READER.getSubscriptions(subId, subId + 1);
        ComputeSubscription memory actual = ROUTER.getComputeSubscription(subId);

        // Assert batch length
        assertEq(read.length, 1);

        // Assert subscription parameters
        assertEq(read[0].client, actual.client);
        assertEq(read[0].activeAt, actual.activeAt);
        assertEq(read[0].intervalSeconds, actual.intervalSeconds);
        assertEq(read[0].maxExecutions, actual.maxExecutions);
        assertEq(read[0].redundancy, actual.redundancy);
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
        Wallet(payable(userWalletAddress)).approve(address(SUBSCRIPTION), NO_PAYMENT_TOKEN, requiredFunds);

        console.log("User wallet balance before:", userWalletAddress.balance);
        console.log(
            "User wallet allowance for SUBSCRIPTION:",
            Wallet(payable(userWalletAddress)).allowance(address(SUBSCRIPTION), NO_PAYMENT_TOKEN)
        );

        // Create normal subscriptions at ids {1, 2, 3, 4}
        for (uint32 i = 0; i < 4; i++) {
            SUBSCRIPTION.createMockSubscription(
                MOCK_CONTAINER_ID,
                i + 1, // Use maxExecutions as verification index
                1 minutes,
                1,
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
            Wallet(payable(userWalletAddress)).allowance(address(SUBSCRIPTION), NO_PAYMENT_TOKEN)
        );

        // Cancel subscription id {4}
        vm.prank(address(SUBSCRIPTION));
        ROUTER.cancelComputeSubscription(4);

        // Read subscriptions
        ComputeSubscription[] memory read = READER.getSubscriptions(1, 6);

        // Assert batch length
        assertEq(read.length, 5);

        // Check normal subscriptions {1, 2, 3}
        for (uint32 i = 0; i < 3; i++) {
            assertEq(read[i].client, address(SUBSCRIPTION));
            assertEq(read[i].activeAt, 60);
            assertEq(read[i].intervalSeconds, 1 minutes);
            assertEq(read[i].maxExecutions, i + 1); // Use as verification index
            assertEq(read[i].redundancy, 1);
            assertEq(read[i].containerId, HASHED_MOCK_CONTAINER_ID);
            assertEq(read[i].useDeliveryInbox, false);
            assertEq(read[i].feeToken, NO_PAYMENT_TOKEN);
            assertEq(read[i].feeAmount, 10e6);
            assertEq(read[i].wallet, payable(userWalletAddress));
            assertEq(read[i].verifier, payable(NO_VERIFIER));
        }

        // Check cancelled subscription
        assertEq(read[3].client, address(SUBSCRIPTION));
        assertEq(read[3].activeAt, type(uint32).max); // Cancelled
        assertEq(read[3].intervalSeconds, 1 minutes);
        assertEq(read[3].maxExecutions, 4);
        assertEq(read[3].redundancy, 1);
        assertEq(read[3].containerId, HASHED_MOCK_CONTAINER_ID);
        assertEq(read[3].useDeliveryInbox, false);
        assertEq(read[3].feeAmount, 10e6);

        // Check non-existent subscription
        assertEq(read[4].client, address(0));
        assertEq(read[4].activeAt, 0);
        assertEq(read[4].intervalSeconds, 0);
        assertEq(read[4].maxExecutions, 0);
        assertEq(read[4].redundancy, 0);
        assertEq(read[4].containerId, bytes32(0));
        assertEq(read[4].useDeliveryInbox, false);
        assertEq(read[4].feeAmount, 0);
    }

    /// @notice Can read redundancy counts
    function test_Succeeds_When_QueryingRedundancyCounts() public {
        // Create first subscription (maxExecutions = 2, redundancy = 2)
        vm.warp(0);
        (uint64 subOne,) = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID, 2, 1 minutes, 2, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Create second subscription (maxExecutions = 1, redundancy = 1)
        (uint64 subTwo,) = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID, 1, 1 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Deliver (id: subOne, interval: 1) from Alice + Bob
        // Deliver (id: subTwo, interval: 1) from Alice
        vm.warp(1 minutes);
        (, Commitment memory commitmentStruct1) = SUBSCRIPTION.sendRequest(subOne, 1);
        bytes memory commitment1 = abi.encode(commitmentStruct1);
        (, Commitment memory commitmentStruct2) = SUBSCRIPTION.sendRequest(subTwo, 1);
        bytes memory commitment2 = abi.encode(commitmentStruct2);

        ALICE.reportComputeResult(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitment1, aliceWalletAddress);
        BOB.reportComputeResult(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitment1, bobWalletAddress);
        ALICE.reportComputeResult(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitment2, aliceWalletAddress);

        // Deliver (id: subOne, interval: 2) from Alice
        vm.warp(2 minutes);
        (, Commitment memory commitmentStruct3) = SUBSCRIPTION.sendRequest(subOne, 2);
        bytes memory commitment3 = abi.encode(commitmentStruct3);
        ALICE.reportComputeResult(2, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitment3, aliceWalletAddress);

        // Assert correct batch reads
        uint64[] memory ids = new uint64[](4);
        uint32[] memory intervals = new uint32[](4);
        uint16[] memory expectedRedundancyCounts = new uint16[](4);

        // (id: subOne, interval: 1) == 2
        // Tests completed interval read
        ids[0] = subOne;
        intervals[0] = 1;
        expectedRedundancyCounts[0] = 2;

        // (id: subOne, interval: 2) == 1
        // Tests partial interval read
        ids[1] = subOne;
        intervals[1] = 2;
        expectedRedundancyCounts[1] = 1;

        // (id: subTwo, interval: 1) == 1
        // Tests completed interval read for second subscription
        ids[2] = subTwo;
        intervals[2] = 1;
        expectedRedundancyCounts[2] = 1;

        // (id: subTwo, interval: 2) == 0
        // Tests non-existent interval read via second subscription
        ids[3] = subTwo;
        intervals[3] = 2;
        expectedRedundancyCounts[3] = 0;

        SubscriptionBatchReader.IntervalStatus[] memory actual = READER.getIntervalStatuses(ids, intervals);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(actual[i].redundancyCount, expectedRedundancyCounts[i]);
        }
    }

    /// @notice Can read redundancy counts for a deleted subscription post-delivery
    function test_Succeeds_When_QueryingRedundancyAfterSubscriptionCancellation() public {
        // Create subscription
        vm.warp(0);
        (uint64 subId,) = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 1 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Deliver subscription
        vm.warp(1 minutes);
        uint32 interval = 1;
        (, Commitment memory commitmentStruct) = SUBSCRIPTION.sendRequest(subId, interval);
        bytes memory commitment = abi.encode(commitmentStruct);
        ALICE.reportComputeResult(interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitment, aliceWalletAddress);

        // Cancel partially fulfilled subscription
        vm.prank(address(SUBSCRIPTION));
        ROUTER.cancelComputeSubscription(subId);

        // Assert redundancy count still returns 1 for (id: subId, interval: 1)
        uint64[] memory ids = new uint64[](1);
        uint32[] memory intervals = new uint32[](1);
        ids[0] = subId;
        intervals[0] = interval;
        SubscriptionBatchReader.IntervalStatus[] memory statuses = READER.getIntervalStatuses(ids, intervals);

        // Assert batch length
        assertEq(statuses.length, 1);

        // Assert count is 1
        assertEq(statuses[0].redundancyCount, 1);
    }

    /// @notice Non-existent redundancy count returns `0`
    function test_Fuzz_NonExistentInterval_ReturnsZeroRedundancy(uint64 subscriptionId, uint32 interval) public {
        // Collect redundancy count
        uint64[] memory ids = new uint64[](1);
        uint32[] memory intervals = new uint32[](1);
        ids[0] = subscriptionId;
        intervals[0] = interval;
        SubscriptionBatchReader.IntervalStatus[] memory statuses = READER.getIntervalStatuses(ids, intervals);

        // Assert batch length
        assertEq(statuses.length, 1);

        // Assert count is 0
        assertEq(statuses[0].redundancyCount, 0);
    }

    /// @notice Cannot read redundancy counts when input array lengths mismatch
    function test_Reverts_When_InputArrayLengthMismatch() public {
        // Create dummy arrays with length mismatch
        uint64[] memory ids = new uint64[](2);
        uint32[] memory intervals = new uint32[](1);

        // Populate with dummy (id, interval)-pairs
        ids[0] = 0;
        ids[1] = 1;
        intervals[0] = 0;

        // Attempt to batch read (catching OOBError in external contract)
        vm.expectRevert();
        READER.getIntervalStatuses(ids, intervals);
    }
}
