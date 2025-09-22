// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {CoordinatorTest} from "./Coordinator.t.sol";
import {Commitment} from "../src/v1_0_0/types/Commitment.sol";
import {BaseConsumer} from "../src/v1_0_0/consumer/BaseConsumer.sol";

/// @title CoordinatorGeneralTest
/// @notice General coordinator tests
contract CoordinatorGeneralTest is CoordinatorTest {
    /// @notice Cannot be reassigned a subscription ID
    function test_SubscriptionId_IsNeverReassigned() public {
        // Create new callback subscription
        (uint64 id1, Commitment memory commitment1) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        assertEq(id1, 1);

        // Create new subscriptions
        (uint64 id2,) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );
        // Assert head
        assertEq(id2, 2);

        // Delete subscriptions
        vm.startPrank(address(CALLBACK));
        ROUTER.timeoutRequest(commitment1.requestId, commitment1.subscriptionId, commitment1.interval);
        ROUTER.cancelSubscription(1);

        // Create new subscription
        (uint64 id3,) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );
        assertEq(id3, 3);
    }

    /// @notice Cannot receive response from non-coordinator contract
    function test_RevertIf_ReceivingResponse_FromNonCoordinator() public {
        // Expect revert sending from address(this)
        vm.expectRevert(BaseConsumer.NotRouter.selector);
        CALLBACK.rawReceiveCompute(1, 1, 1, address(this), MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, bytes32(0), 0);
    }
}