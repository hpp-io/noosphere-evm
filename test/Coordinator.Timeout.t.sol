// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {CoordinatorTest, ICoordinatorEvents, ISubscriptionManagerErrors} from "./Coordinator.t.sol";
import {Commitment} from "../src/v1_0_0/types/Commitment.sol";
import {Wallet} from "../src/v1_0_0/wallet/Wallet.sol";

contract CoordinatorTimeoutRequestTest is CoordinatorTest, ISubscriptionManagerErrors {
    function test_Succeeds_When_TimingOutRequest() public {
        // 1. Create a recurring, paid subscription
        address consumerWallet = WALLET_FACTORY.createWallet(address(this));
        uint256 paymentAmount = 40e6;
        uint16 redundancy = 2;
        uint256 paymentForOneInterval = paymentAmount * redundancy;
        TOKEN.mint(consumerWallet, paymentForOneInterval * 2); // Fund for two intervals

        vm.prank(address(this));
        Wallet(payable(consumerWallet)).approve(address(SUBSCRIPTION), address(TOKEN), paymentForOneInterval * 2);

        // Create subscription and first request
        (uint64 subId, Commitment memory commitment1) = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID,
            3, // frequency
            1 minutes, // period
            redundancy,
            false, // lazy
            address(TOKEN),
            paymentAmount,
            consumerWallet,
            NO_VERIFIER
        );

        // 2. Warp time to the *second* interval, making the first one timeoutable
        vm.warp(block.timestamp + 2 minutes); // currentInterval will be 2

        // 3. Assert that funds are initially locked for the first request
        assertEq(Wallet(payable(consumerWallet)).lockedOfRequest(commitment1.requestId), paymentForOneInterval);

        // 4. Expect the CommitmentTimedOut event from the Router
        vm.expectEmit(true, true, true, true, address(ROUTER));
        emit ICoordinatorEvents.CommitmentTimedOut(commitment1.requestId, subId, 1);

        // 5. Call timeoutRequest for the first interval. Anyone can call this.
        ROUTER.timeoutRequest(commitment1.requestId, subId, 1);

        // 6. Assert that funds have been released
        assertEq(
            Wallet(payable(consumerWallet)).lockedOfRequest(commitment1.requestId),
            0,
            "Funds should be released after timeout"
        );
    }

    function test_RevertIf_TimingOutRequest_ForCurrentInterval() public {
        // 1. Create a recurring subscription
        (uint64 subId, Commitment memory commitment1) = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 1 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // 2. Warp time to the *first* interval. The request is not yet in the past.
        vm.warp(block.timestamp + 1 minutes);

        // 3. Expect a revert because the interval is not in the past
        vm.expectRevert(CommitmentNotTimeoutable.selector);
        ROUTER.timeoutRequest(commitment1.requestId, subId, 1);
    }

    function test_RevertIf_TimingOutRequest_ForInactiveSubscription() public {
        // 1. Create a recurring subscription. The first request is created immediately.
        (uint64 subId, Commitment memory commitment1) = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 1 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // 2. Do NOT warp time. The subscription's activeAt is `block.timestamp + 1 minutes`.
        // The current block.timestamp is before activeAt.

        // 3. Expect a revert because the subscription is not active
        vm.expectRevert(bytes("SubscriptionNotActive()"));
        ROUTER.timeoutRequest(commitment1.requestId, subId, 1);
    }

    function test_RevertIf_TimingOut_NonExistentRequest() public {
        // 1. Create a subscription but don't create a request for interval 2
        uint64 subId = SUBSCRIPTION.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, 3, 1 minutes, 1, false, NO_PAYMENT_TOKEN, 0, NO_WALLET, NO_VERIFIER
        );

        // 2. Warp time to make the subscription active
        vm.warp(block.timestamp + 2 minutes);

        // 3. Attempt to timeout a request for an interval that was never requested
        bytes32 nonExistentRequestId = keccak256(abi.encodePacked(subId, uint32(2)));
        vm.expectRevert(NoSuchCommitment.selector);
        ROUTER.timeoutRequest(nonExistentRequestId, subId, 2);
    }

    function test_RevertIf_DeliveringCompute_ForTimedOutRequest() public {
        // 1. Create a recurring, paid subscription and its first request
        address consumerWallet = WALLET_FACTORY.createWallet(address(this));
        address nodeWallet = WALLET_FACTORY.createWallet(address(BOB));
        uint256 paymentAmount = 40e6;
        uint16 redundancy = 1;
        uint256 paymentForOneInterval = paymentAmount * redundancy;
        TOKEN.mint(consumerWallet, paymentForOneInterval);

        vm.prank(address(this));
        Wallet(payable(consumerWallet)).approve(address(SUBSCRIPTION), address(TOKEN), paymentForOneInterval);

        (uint64 subId, Commitment memory commitment1) = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID,
            2, // frequency
            1 minutes, // period
            redundancy,
            false, // lazy
            address(TOKEN),
            paymentAmount,
            consumerWallet,
            NO_VERIFIER
        );

        // 2. Warp time to make the request timeoutable and then time it out.
        vm.warp(block.timestamp + 2 minutes);
        ROUTER.timeoutRequest(commitment1.requestId, subId, 1);

        // 3. Attempt to deliver compute for the now-timed-out request.
        // It should revert because the coordinator detects a mismatch between the
        // delivery interval (1) and the current system interval (2).
        bytes memory commitmentData1 = abi.encode(commitment1);
        vm.expectRevert(abi.encodeWithSelector(ICoordinatorEvents.IntervalMismatch.selector, 1));
        vm.prank(address(BOB));
        BOB.deliverCompute(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, nodeWallet);
    }
}