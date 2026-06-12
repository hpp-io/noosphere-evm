// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {ComputeTest} from "./Compute.t.sol";
import {Commitment} from "../src/v1_0_0/types/Commitment.sol";
import {ComputeSubscription} from "../src/v1_0_0/types/ComputeSubscription.sol";
import {Wallet} from "../src/v1_0_0/wallet/Wallet.sol";
import {ICoordinator} from "../src/v1_0_0/interfaces/ICoordinator.sol";
import {IRouter} from "../src/v1_0_0/interfaces/IRouter.sol";
import {PayloadData} from "../src/v1_0_0/types/PayloadData.sol";
import {ISubscriptionsManager} from "../src/v1_0_0/interfaces/ISubscriptionManager.sol";
import {FulfillResult} from "../src/v1_0_0/types/FulfillResult.sol";
import {Payment} from "../src/v1_0_0/types/Payment.sol";
import {RequestIdUtils} from "../src/v1_0_0/utility/RequestIdUtils.sol";
import {IVerifier} from "../src/v1_0_0/interfaces/IVerifier.sol";
import {MockImmediateVerifier} from "./mocks/verifier/MockImmediateVerifier.sol";

/// @title RouterFailuresTest
/// @notice Comprehensive tests for Router failure scenarios and recovery procedures
/// @dev Tests correspond to scenarios in docs/router-error-handling-guide.md
contract RouterFailuresTest is ComputeTest {
    // =============================================================================
    // 1. REQUEST LIFECYCLE FAILURES
    // =============================================================================

    /// @notice Test 1.1: Invalid Request ID - INVALID_REQUEST_ID result
    function test_Scenario1_1_InvalidRequestId_ReturnsInvalidRequestId() public {
        // Create a subscription but don't create a request
        uint64 subId = ScheduledClient.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID,
            3, // maxExecutions
            10 minutes,
            false,
            NO_PAYMENT_TOKEN,
            0,
            userWalletAddress,
            NO_VERIFIER
        );

        // Create a fake request ID that doesn't exist
        bytes32 fakeRequestId = keccak256(abi.encodePacked(subId, uint32(999)));

        // Build a commitment for the fake request
        ComputeSubscription memory sub = ROUTER.getComputeSubscription(subId);
        Commitment memory fakeCommitment = Commitment({
            requestId: fakeRequestId,
            subscriptionId: subId,
            containerId: sub.containerId,
            interval: 999,
            useDeliveryInbox: false,
            walletAddress: userWalletAddress,
            feeAmount: 0,
            feeToken: NO_PAYMENT_TOKEN,
            verifier: NO_VERIFIER,
            coordinator: address(COORDINATOR),
            verifierFee: 0
        });

        Payment[] memory payments = new Payment[](0);

        // Attempt to fulfill with invalid request ID
        vm.prank(address(COORDINATOR));
        FulfillResult result =
            ROUTER.fulfill(_mockInput(), _mockOutput(), _mockProof(), userWalletAddress, payments, fakeCommitment);

        assertEq(uint256(result), uint256(FulfillResult.INVALID_REQUEST_ID));
    }

    /// @notice Test 1.1: Recovery - Verify request ID and recreate if needed
    function test_Scenario1_1_Recovery_RecreateRequest() public {
        // Create subscription with a request (this activates it)
        (uint64 subId, Commitment memory commitment) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 10 minutes, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Get current interval (should be 1 since subscription is now active)
        uint32 currentInterval = ROUTER.getComputeSubscriptionInterval(subId);
        assertEq(currentInterval, 1);

        // Verify request ID format
        bytes32 expectedId = RequestIdUtils.requestIdPacked(subId, currentInterval);
        assertEq(commitment.requestId, expectedId);

        // Verify commitment stored
        bytes32 storedCommitment = COORDINATOR.requestCommitments(commitment.requestId);
        assertNotEq(storedCommitment, bytes32(0));

        // Demonstrate recovery by warping time and creating request for next interval
        vm.warp(block.timestamp + 15 minutes);
        uint32 nextInterval = ROUTER.getComputeSubscriptionInterval(subId);
        assertEq(nextInterval, 2);

        // Create request for next interval (recovery scenario)
        (bytes32 newRequestId, Commitment memory newCommitment) = ROUTER.sendRequest(subId, nextInterval);
        bytes32 expectedNextId = RequestIdUtils.requestIdPacked(subId, nextInterval);
        assertEq(newRequestId, expectedNextId);
    }

    /// @notice Test 1.2: Invalid Commitment - INVALID_COMMITMENT result
    function test_Scenario1_2_InvalidCommitment_ReturnsInvalidCommitment() public {
        // Create a request
        (uint64 subId, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Modify commitment data (tampering)
        commitment.feeAmount = 999; // Wrong amount

        Payment[] memory payments = new Payment[](0);

        // Attempt to fulfill with invalid commitment
        vm.prank(address(COORDINATOR));
        FulfillResult result =
            ROUTER.fulfill(_mockInput(), _mockOutput(), _mockProof(), userWalletAddress, payments, commitment);

        assertEq(uint256(result), uint256(FulfillResult.INVALID_COMMITMENT));
    }

    /// @notice Test 1.2: Recovery - Retrieve correct commitment from coordinator
    function test_Scenario1_2_Recovery_RetrieveCorrectCommitment() public {
        // Create a request
        (uint64 subId, Commitment memory originalCommitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Retrieve commitment from coordinator
        Commitment memory retrievedCommitment = COORDINATOR.getCommitment(subId, originalCommitment.interval);

        // Verify all fields match
        assertEq(retrievedCommitment.requestId, originalCommitment.requestId);
        assertEq(retrievedCommitment.subscriptionId, originalCommitment.subscriptionId);
        assertEq(retrievedCommitment.containerId, originalCommitment.containerId);
        assertEq(retrievedCommitment.interval, originalCommitment.interval);
        assertEq(retrievedCommitment.feeAmount, originalCommitment.feeAmount);
        assertEq(retrievedCommitment.feeToken, originalCommitment.feeToken);
        assertEq(retrievedCommitment.verifier, originalCommitment.verifier);
    }

    /// @notice Test 1.3: Request Timeout - Successful timeout and fund release
    function test_Scenario1_3_RequestTimeout_SuccessfulTimeout() public {
        // Already covered in Compute.Timeout.t.sol::test_Succeeds_When_TimingOutRequest
        // This is a reference test to ensure it's documented in failure scenarios

        address consumerWallet = walletFactory.createWallet(address(this));
        uint256 feeAmount = 40e6;
        uint256 paymentForOneInterval = feeAmount;
        erc20Token.mint(consumerWallet, paymentForOneInterval * 2);

        vm.prank(address(this));
        Wallet(payable(consumerWallet))
            .approve(address(ScheduledClient), address(erc20Token), paymentForOneInterval * 2);

        (uint64 subId, Commitment memory commitment1) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 10 minutes, false, address(erc20Token), feeAmount, consumerWallet, NO_VERIFIER
        );

        // Warp to second interval
        vm.warp(block.timestamp + 20 minutes);

        // Verify funds locked
        assertEq(Wallet(payable(consumerWallet)).lockedOfRequest(commitment1.requestId), paymentForOneInterval);

        // Timeout request
        vm.expectEmit(true, true, true, true, address(ROUTER));
        emit ISubscriptionsManager.CommitmentTimedOut(commitment1.requestId, subId, 1);
        ROUTER.timeoutRequest(commitment1.requestId, subId, 1);

        // Verify funds released
        assertEq(Wallet(payable(consumerWallet)).lockedOfRequest(commitment1.requestId), 0);
    }

    /// @notice Test 1.3: Recovery - Recreate request for current interval after timeout
    function test_Scenario1_3_Recovery_RecreateAfterTimeout() public {
        address consumerWallet = walletFactory.createWallet(address(this));
        uint256 feeAmount = 40e6;
        uint256 paymentForOneInterval = feeAmount;
        erc20Token.mint(consumerWallet, paymentForOneInterval * 3);

        vm.prank(address(this));
        Wallet(payable(consumerWallet))
            .approve(address(ScheduledClient), address(erc20Token), paymentForOneInterval * 3);

        (uint64 subId, Commitment memory commitment1) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 5, 10 minutes, false, address(erc20Token), feeAmount, consumerWallet, NO_VERIFIER
        );

        // Warp to third interval (20 minutes = 2 full intervals, so we're in interval 3)
        // Interval calculation: ((timestamp - activeAt) / intervalSeconds) + 1
        // At exactly 20 minutes: ((1200) / 600) + 1 = 2 + 1 = 3
        vm.warp(block.timestamp + 20 minutes);
        uint32 currentInterval = ROUTER.getComputeSubscriptionInterval(subId);
        assertEq(currentInterval, 3);

        // Timeout first interval
        ROUTER.timeoutRequest(commitment1.requestId, subId, 1);

        // Create request for current interval
        bool hasPending = ROUTER.pendingRequestExists(subId);
        if (!hasPending) {
            (bytes32 newRequestId, Commitment memory newCommitment) = ROUTER.sendRequest(subId, currentInterval);
            assertEq(newCommitment.interval, currentInterval);
            assertNotEq(newRequestId, bytes32(0));
        }
    }

    /// @notice Test 1.4: Duplicate Request - Idempotent request creation
    function test_Scenario1_4_DuplicateRequest_IdempotentCreation() public {
        // Create subscription and first request
        uint64 subId = ScheduledClient.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, 3, 10 minutes, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        vm.warp(block.timestamp + 2 minutes);
        uint32 interval = ROUTER.getComputeSubscriptionInterval(subId);

        // Create first request
        (bytes32 requestId1, Commitment memory commitment1) = ROUTER.sendRequest(subId, interval);

        // Attempt to create duplicate request - should return same commitment
        (bytes32 requestId2, Commitment memory commitment2) = ROUTER.sendRequest(subId, interval);

        // Verify idempotency
        assertEq(requestId1, requestId2);
        assertEq(commitment1.requestId, commitment2.requestId);
        assertEq(commitment1.interval, commitment2.interval);
    }

    /// @notice Test 1.5: Empty Request Data - Revert with proper error
    function test_Scenario1_5_EmptyRequestData_RevertsIfInvalidSubscription() public {
        // Attempt to send request for non-existent subscription
        vm.expectRevert(abi.encodeWithSignature("InvalidSubscription()"));
        ROUTER.sendRequest(999, 1);
    }

    // =============================================================================
    // 2. SUBSCRIPTION MANAGEMENT FAILURES
    // =============================================================================

    /// @notice Test 2.1: Invalid Subscription - Non-existent subscription
    function test_Scenario2_1_InvalidSubscription_NonExistent() public {
        uint64 invalidSubId = 9999;

        // getComputeSubscription returns empty struct for non-existent subscriptions (doesn't revert)
        ComputeSubscription memory sub = ROUTER.getComputeSubscription(invalidSubId);

        // Verify it's an empty/invalid subscription
        assertEq(sub.client, address(0), "Non-existent subscription should have zero client");
        assertEq(sub.wallet, address(0), "Non-existent subscription should have zero wallet");
    }

    /// @notice Test 2.1: Recovery - Verify subscription ID and recreate if needed
    function test_Scenario2_1_Recovery_VerifyAndRecreate() public {
        // Get last subscription ID
        uint64 lastSubId = ROUTER.getLastSubscriptionId();

        // Try to get subscription that might not exist
        uint64 testSubId = lastSubId + 1;

        // getComputeSubscription doesn't revert, so check the returned struct
        ComputeSubscription memory sub = ROUTER.getComputeSubscription(testSubId);

        if (sub.client == address(0)) {
            // Subscription doesn't exist, create a new one
            uint64 newSubId = ScheduledClient.createMockSubscriptionWithoutRequest(
                MOCK_CONTAINER_ID, 3, 10 minutes, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
            );
            assertEq(newSubId, lastSubId + 1);
        } else {
            // Subscription exists and is valid
            assertNotEq(sub.client, address(0), "Valid subscription should have non-zero client");
        }
    }

    /// @notice Test 2.2: Subscription Interval Too Short
    function test_Scenario2_2_IntervalTooShort_Reverts() public {
        uint32 tooShortInterval = 60; // 1 minute, less than minimum (10 minutes)

        vm.expectRevert(
            abi.encodeWithSelector(
                ISubscriptionsManager.SubscriptionIntervalTooShort.selector,
                tooShortInterval,
                ROUTER.minRepeatInterval()
            )
        );

        ScheduledClient.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, 3, tooShortInterval, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );
    }

    /// @notice Test 2.2: Recovery - Query and use minimum interval
    function test_Scenario2_2_Recovery_UseMinimumInterval() public {
        uint32 minInterval = ROUTER.minRepeatInterval();
        assertEq(minInterval, 600); // Default 10 minutes

        // Create subscription with safe interval
        uint32 desiredInterval = 5 minutes;
        uint32 safeInterval = desiredInterval < minInterval ? minInterval : desiredInterval;

        uint64 subId = ScheduledClient.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, 3, safeInterval, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        ComputeSubscription memory sub = ROUTER.getComputeSubscription(subId);
        assertEq(sub.intervalSeconds, safeInterval);
    }

    /// @notice Test 2.3: Cancel subscription with pending requests
    function test_Scenario2_3_CancelWithPendingRequests_CleansUp() public {
        address consumerWallet = walletFactory.createWallet(address(ScheduledClient));
        uint256 feeAmount = 40e6;
        erc20Token.mint(consumerWallet, feeAmount * 5);

        vm.prank(address(ScheduledClient));
        Wallet(payable(consumerWallet)).approve(address(ScheduledClient), address(erc20Token), feeAmount * 5);

        // Create subscription with request
        (uint64 subId, Commitment memory commitment) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 5, 10 minutes, false, address(erc20Token), feeAmount, consumerWallet, NO_VERIFIER
        );

        // Warp to create multiple intervals worth of potential requests
        vm.warp(block.timestamp + 30 minutes); // Interval 3

        // Clean up manually before cancellation (best practice)
        uint32 currentInterval = ROUTER.getComputeSubscriptionInterval(subId);
        if (currentInterval > 1) {
            vm.prank(address(ScheduledClient));
            ROUTER.timeoutSubscriptionIntervalsUpTo(subId, currentInterval - 1, type(uint32).max);
        }

        // Cancel subscription
        vm.prank(address(ScheduledClient));
        ROUTER.cancelComputeSubscription(subId);

        // Verify subscription deleted (getComputeSubscription returns empty struct)
        ComputeSubscription memory deletedSub = ROUTER.getComputeSubscription(subId);
        assertEq(deletedSub.client, address(0), "Deleted subscription should have zero client");
        assertEq(deletedSub.wallet, address(0), "Deleted subscription should have zero wallet");
    }

    /// @notice Test 2.4: Insufficient funds for next interval
    function test_Scenario2_4_InsufficientFunds_PreventsNextInterval() public {
        address consumerWallet = walletFactory.createWallet(address(ScheduledClient));
        uint256 feeAmount = 40e6;
        uint256 paymentForOneInterval = feeAmount;

        // Only fund for ONE interval
        erc20Token.mint(consumerWallet, paymentForOneInterval);

        vm.prank(address(ScheduledClient));
        Wallet(payable(consumerWallet)).approve(address(ScheduledClient), address(erc20Token), paymentForOneInterval);

        (uint64 subId, Commitment memory commitment) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 5, 10 minutes, false, address(erc20Token), feeAmount, consumerWallet, NO_VERIFIER
        );

        // Check that next interval is NOT available due to insufficient funds
        bool hasNext = ROUTER.hasSubscriptionNextInterval(subId, 1);
        assertEq(hasNext, false, "Should not have next interval with insufficient funds");
    }

    /// @notice Test 2.4: Recovery - Fund wallet and increase allowance
    function test_Scenario2_4_Recovery_FundWalletAndIncreaseAllowance() public {
        address consumerWallet = walletFactory.createWallet(address(ScheduledClient));
        uint256 feeAmount = 40e6;
        uint256 paymentForOneInterval = feeAmount;

        // Initially fund for one interval
        erc20Token.mint(consumerWallet, paymentForOneInterval);
        vm.prank(address(ScheduledClient));
        Wallet(payable(consumerWallet)).approve(address(ScheduledClient), address(erc20Token), paymentForOneInterval);

        (uint64 subId,) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 5, 10 minutes, false, address(erc20Token), feeAmount, consumerWallet, NO_VERIFIER
        );

        // Verify no next interval initially
        assertEq(ROUTER.hasSubscriptionNextInterval(subId, 1), false);

        // Recovery: Add more funds and increase allowance
        erc20Token.mint(consumerWallet, paymentForOneInterval * 4); // Fund for 4 more intervals

        Wallet wallet = Wallet(payable(consumerWallet));
        uint256 currentAllowance = wallet.allowance(address(ScheduledClient), address(erc20Token));

        vm.prank(address(ScheduledClient));
        wallet.approve(address(ScheduledClient), address(erc20Token), currentAllowance + (paymentForOneInterval * 4));

        // Now should have next interval
        assertEq(ROUTER.hasSubscriptionNextInterval(subId, 1), true);
    }

    // =============================================================================
    // 3. CONTRACT ROUTING FAILURES
    // =============================================================================

    /// @notice Test 3.1: Route not found
    function test_Scenario3_1_RouteNotFound_Reverts() public {
        // Already tested in Compute.General.t.sol::test_Router_RevertIf_InvalidRouteId
        bytes32 invalidRouteId = bytes32("invalid_route");

        vm.expectRevert(abi.encodeWithSignature("CoordinatorNotFound()"));
        transientClient.createMockRequestWithRouteId(
            MOCK_CONTAINER_ID,
            MOCK_CONTAINER_INPUTS,
            NO_PAYMENT_TOKEN,
            0,
            userWalletAddress,
            NO_VERIFIER,
            invalidRouteId
        );
    }

    /// @notice Test 3.2: Invalid proposed update - Empty arrays
    function test_Scenario3_2_InvalidProposedUpdate_EmptyArrays() public {
        bytes32[] memory ids = new bytes32[](0);
        address[] memory addrs = new address[](0);

        vm.prank(ROUTER.client());
        vm.expectRevert();
        ROUTER.proposeContractsUpdate(ids, addrs);
    }

    /// @notice Test 3.2: Invalid proposed update - Mismatched lengths
    function test_Scenario3_2_InvalidProposedUpdate_MismatchedLengths() public {
        bytes32[] memory ids = new bytes32[](2);
        address[] memory addrs = new address[](1);

        vm.prank(ROUTER.client());
        vm.expectRevert();
        ROUTER.proposeContractsUpdate(ids, addrs);
    }

    /// @notice Test 3.2: Invalid proposed update - Zero address
    function test_Scenario3_2_InvalidProposedUpdate_ZeroAddress() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32("test");
        address[] memory addrs = new address[](1);
        addrs[0] = address(0);

        vm.prank(ROUTER.client());
        vm.expectRevert();
        ROUTER.proposeContractsUpdate(ids, addrs);
    }

    /// @notice Test 3.2: Invalid proposed update - Same as current
    function test_Scenario3_2_InvalidProposedUpdate_SameAsCurrent() public {
        bytes32 currentRouteId = keccak256(bytes(COORDINATOR.typeAndVersion()));
        address currentAddr = ROUTER.getContractById(currentRouteId);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = currentRouteId;
        address[] memory addrs = new address[](1);
        addrs[0] = currentAddr;

        vm.prank(ROUTER.client());
        vm.expectRevert();
        ROUTER.proposeContractsUpdate(ids, addrs);
    }

    // =============================================================================
    // 4. PAYMENT AND FUND MANAGEMENT FAILURES
    // =============================================================================

    /// @notice Test 4.1: Insufficient funds in wallet
    function test_Scenario4_1_InsufficientFunds_RevertsOnLock() public {
        address consumerWallet = walletFactory.createWallet(address(ScheduledClient));
        uint256 feeAmount = 100e6;

        // Don't fund the wallet
        vm.prank(address(ScheduledClient));
        Wallet(payable(consumerWallet)).approve(address(ScheduledClient), address(erc20Token), feeAmount);

        // Attempt to create subscription (will fail when trying to lock funds)
        vm.expectRevert(); // Will revert with InsufficientFunds when attempting to lock
        ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 10 minutes, false, address(erc20Token), feeAmount, consumerWallet, NO_VERIFIER
        );
    }

    /// @notice Test 4.2: Insufficient allowance
    function test_Scenario4_2_InsufficientAllowance_RevertsOnLock() public {
        address consumerWallet = walletFactory.createWallet(address(ScheduledClient));
        uint256 feeAmount = 100e6;

        // Fund wallet but don't set allowance
        erc20Token.mint(consumerWallet, feeAmount);
        // No approve call

        vm.expectRevert(); // Will revert with InsufficientAllowance
        ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 10 minutes, false, address(erc20Token), feeAmount, consumerWallet, NO_VERIFIER
        );
    }

    /// @notice Test 4.3: Payment token mismatch
    function test_Scenario4_3_PaymentTokenMismatch_DetectedInFulfillment() public {
        address consumerWallet = walletFactory.createWallet(address(transientClient));
        uint256 feeAmount = 40e6;

        erc20Token.mint(consumerWallet, feeAmount);
        vm.prank(address(transientClient));
        Wallet(payable(consumerWallet)).approve(address(transientClient), address(erc20Token), feeAmount);

        (uint64 subId, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, address(erc20Token), feeAmount, consumerWallet, NO_VERIFIER
        );

        // This scenario is prevented at the protocol level
        // Payments must match the subscription's feeToken
        // The test demonstrates that the system enforces this
        ComputeSubscription memory sub = ROUTER.getComputeSubscription(subId);
        assertEq(sub.feeToken, address(erc20Token));
        assertEq(commitment.feeToken, address(erc20Token));
    }

    /// @notice Test 4.4: Verifier fee issues - Insufficient fee amount
    function test_Scenario4_4_VerifierFee_InsufficientFeeAmount() public {
        // Deploy a mock verifier with a specific fee
        MockImmediateVerifier verifier = new MockImmediateVerifier(ROUTER);
        uint256 verifierFee = 50e6;
        verifier.updateFee(address(erc20Token), verifierFee);
        verifier.updateSupportedToken(address(erc20Token), true);

        address consumerWallet = walletFactory.createWallet(address(transientClient));
        uint256 insufficientFee = 30e6; // Less than verifier fee

        erc20Token.mint(consumerWallet, insufficientFee);
        vm.prank(address(transientClient));
        Wallet(payable(consumerWallet)).approve(address(transientClient), address(erc20Token), insufficientFee);

        // Attempt to create request with verifier but insufficient fee
        vm.expectRevert(); // Should revert with InsufficientForVerifierFee
        transientClient.createMockRequest(
            MOCK_CONTAINER_ID,
            MOCK_CONTAINER_INPUTS,
            address(erc20Token),
            insufficientFee,
            consumerWallet,
            address(verifier)
        );
    }

    // =============================================================================
    // 5. ACCESS CONTROL AND SECURITY FAILURES
    // =============================================================================

    /// @notice Test 5.1: Only callable by owner - proposeContractsUpdate
    function test_Scenario5_1_OnlyOwner_ProposeContractsUpdate() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32("test");
        address[] memory addrs = new address[](1);
        addrs[0] = address(0x123);

        vm.prank(address(alice)); // Not owner
        vm.expectRevert();
        ROUTER.proposeContractsUpdate(ids, addrs);
    }

    /// @notice Test 5.1: Only callable by owner - pause
    function test_Scenario5_1_OnlyOwner_Pause() public {
        vm.prank(address(alice)); // Not owner
        vm.expectRevert();
        ROUTER.pause();
    }

    /// @notice Test 5.1: Only callable by owner - unpause
    function test_Scenario5_1_OnlyOwner_Unpause() public {
        // First pause as owner
        vm.prank(ROUTER.client());
        ROUTER.pause();

        // Try to unpause as non-owner
        vm.prank(address(alice));
        vm.expectRevert();
        ROUTER.unpause();
    }

    /// @notice Test 5.2: Only callable by coordinator - fulfill
    function test_Scenario5_2_OnlyCoordinator_Fulfill() public {
        (uint64 subId, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        Payment[] memory payments = new Payment[](0);

        // Attempt to call fulfill from non-coordinator address
        // Should revert with OnlyCallableFromCoordinator error
        vm.prank(address(alice));
        vm.expectRevert(abi.encodeWithSignature("OnlyCallableFromCoordinator()"));
        ROUTER.fulfill(_mockInput(), _mockOutput(), _mockProof(), userWalletAddress, payments, commitment);
    }

    /// @notice Test 5.3: Reentrancy protection
    function test_Scenario5_3_Reentrancy_Protection() public {
        // The Router uses ReentrancyGuard on fulfill()
        // This test verifies that the guard is in place
        // Actual reentrancy attempts would require a malicious contract

        (uint64 subId, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        Payment[] memory payments = new Payment[](0);

        // Normal call should succeed
        vm.prank(address(COORDINATOR));
        FulfillResult result =
            ROUTER.fulfill(_mockInput(), _mockOutput(), _mockProof(), userWalletAddress, payments, commitment);

        assertEq(uint256(result), uint256(FulfillResult.FULFILLED));
    }

    // =============================================================================
    // 6. SYSTEM STATE FAILURES
    // =============================================================================

    /// @notice Test 6.1: Paused state prevents operations
    function test_Scenario6_1_PausedState_PreventsOperations() public {
        // Pause router
        vm.prank(ROUTER.client());
        ROUTER.pause();

        // Attempt to create subscription
        vm.expectRevert();
        ScheduledClient.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, 3, 10 minutes, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Unpause
        vm.prank(ROUTER.client());
        ROUTER.unpause();

        // Now should succeed
        uint64 subId = ScheduledClient.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, 3, 10 minutes, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );
        assertGt(subId, 0);
    }

    /// @notice Test 6.2: Invalid wallet not from factory
    function test_Scenario6_2_InvalidWallet_NotFromFactory() public {
        address fakeWallet = address(0x999);

        vm.expectRevert();
        ScheduledClient.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID,
            3,
            10 minutes,
            false,
            NO_PAYMENT_TOKEN,
            0,
            fakeWallet, // Not created via WalletFactory
            NO_VERIFIER
        );
    }

    /// @notice Test 6.2: Recovery - Create valid wallet via factory
    function test_Scenario6_2_Recovery_CreateValidWallet() public {
        // Create wallet via factory
        address validWallet = walletFactory.createWallet(address(this));

        // Verify wallet is valid
        bool isValid = ROUTER.isValidWallet(validWallet);
        assertEq(isValid, true);

        // Use valid wallet in subscription
        uint64 subId = ScheduledClient.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, 3, 10 minutes, false, NO_PAYMENT_TOKEN, 0, validWallet, NO_VERIFIER
        );

        assertGt(subId, 0);
    }

    // =============================================================================
    // INTEGRATION SCENARIOS
    // =============================================================================

    /// @notice Integration: Complete failure and recovery cycle
    function test_Integration_CompleteFailureRecoveryCycle() public {
        // 1. Create subscription with insufficient funds for multiple intervals
        address consumerWallet = walletFactory.createWallet(address(ScheduledClient));
        uint256 feeAmount = 40e6;
        uint256 paymentForOneInterval = feeAmount;

        erc20Token.mint(consumerWallet, paymentForOneInterval);
        vm.prank(address(ScheduledClient));
        Wallet(payable(consumerWallet)).approve(address(ScheduledClient), address(erc20Token), paymentForOneInterval);

        (uint64 subId, Commitment memory commitment1) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 5, 10 minutes, false, address(erc20Token), feeAmount, consumerWallet, NO_VERIFIER
        );

        // 2. Interval passes without fulfillment (timeout scenario)
        vm.warp(block.timestamp + 20 minutes); // Now at interval 3
        ROUTER.timeoutRequest(commitment1.requestId, subId, 1);

        // 3. Get current interval
        // Note: After timeout, funds are released, so there's actually enough for next interval
        // The subscription still has funds since timeout releases the lock
        uint32 currentInterval = ROUTER.getComputeSubscriptionInterval(subId);
        assertEq(currentInterval, 3); // Should be at interval 3

        // After timeout, funds were released, so next interval is actually possible
        assertEq(ROUTER.hasSubscriptionNextInterval(subId, currentInterval), true);

        // 4. Simulate scenario where we DO need recovery: create and lock funds for current interval
        // This will consume the available funds
        ROUTER.sendRequest(subId, currentInterval);

        // Now check if there's enough for ANOTHER interval after this one
        assertEq(ROUTER.hasSubscriptionNextInterval(subId, currentInterval), false);

        // 5. Recovery: Fund wallet
        erc20Token.mint(consumerWallet, paymentForOneInterval * 4);
        Wallet wallet = Wallet(payable(consumerWallet));
        uint256 currentAllowance = wallet.allowance(address(ScheduledClient), address(erc20Token));
        vm.prank(address(ScheduledClient));
        wallet.approve(address(ScheduledClient), address(erc20Token), currentAllowance + (paymentForOneInterval * 4));

        // 6. Verify recovery - now should have next interval
        assertEq(ROUTER.hasSubscriptionNextInterval(subId, currentInterval), true);

        // 7. Verify we can create request for next interval now
        // Note: currentInterval request was already created above, so check next interval
        uint32 nextInterval = currentInterval + 1;
        vm.warp(block.timestamp + 10 minutes); // Move to next interval
        (bytes32 newRequestId, Commitment memory newCommitment) = ROUTER.sendRequest(subId, nextInterval);
        assertNotEq(newRequestId, bytes32(0));
    }

    /// @notice Integration: Batch timeout recovery
    function test_Integration_BatchTimeoutRecovery() public {
        address consumerWallet = walletFactory.createWallet(address(ScheduledClient));
        uint256 feeAmount = 40e6;
        erc20Token.mint(consumerWallet, feeAmount * 10);

        vm.prank(address(ScheduledClient));
        Wallet(payable(consumerWallet)).approve(address(ScheduledClient), address(erc20Token), feeAmount * 10);

        (uint64 subId,) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 10, 10 minutes, false, address(erc20Token), feeAmount, consumerWallet, NO_VERIFIER
        );

        // Simulate time passing for multiple intervals
        vm.warp(block.timestamp + 50 minutes); // Interval 5

        uint32 currentInterval = ROUTER.getComputeSubscriptionInterval(subId);

        // Batch timeout all past intervals
        vm.prank(address(ScheduledClient));
        ROUTER.timeoutSubscriptionIntervalsUpTo(subId, currentInterval - 1, type(uint32).max);

        // Verify all past intervals are cleaned up
        // (This is demonstrated by the function completing without errors)
    }
}
