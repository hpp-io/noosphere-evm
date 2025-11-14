// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {ComputeTest, ISubscriptionManagerErrors} from "./Compute.t.sol";
import {Commitment} from "../src/v1_0_0/types/Commitment.sol";
import {Wallet} from "../src/v1_0_0/wallet/Wallet.sol";
import {ICoordinator} from "../src/v1_0_0/interfaces/ICoordinator.sol";
import {ISubscriptionsManager} from "../src/v1_0_0/interfaces/ISubscriptionManager.sol";

contract ComputeTimeoutRequestTest is ComputeTest, ISubscriptionManagerErrors {
    function test_Succeeds_When_TimingOutRequest() public {
        // 1. Create a recurring, paid subscription
        address consumerWallet = walletFactory.createWallet(address(this));
        uint256 feeAmount = 40e6;
        uint16 redundancy = 2;
        uint256 paymentForOneInterval = feeAmount * redundancy;
        erc20Token.mint(consumerWallet, paymentForOneInterval * 2); // Fund for two intervals

        vm.prank(address(this));
        Wallet(payable(consumerWallet))
            .approve(address(ScheduledClient), address(erc20Token), paymentForOneInterval * 2);

        // Create subscription and first request
        (uint64 subId, Commitment memory commitment1) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID,
            3, // maxExecutions
            10 minutes, // intervalSeconds
            redundancy,
            false, // useDeliveryInbox
            address(erc20Token),
            feeAmount,
            consumerWallet,
            NO_VERIFIER
        );

        // 2. Warp time to the *second* interval, making the first one timeoutable
        vm.warp(block.timestamp + 20 minutes); // currentInterval will be 2

        // 3. Assert that funds are initially locked for the first request
        assertEq(Wallet(payable(consumerWallet)).lockedOfRequest(commitment1.requestId), paymentForOneInterval);

        // 4. Expect the CommitmentTimedOut event from the Router
        vm.expectEmit(true, true, true, true, address(ROUTER));
        emit ISubscriptionsManager.CommitmentTimedOut(commitment1.requestId, subId, 1);

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
        (uint64 subId, Commitment memory commitment1) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 10 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // 2. Expect a revert because the interval is not in the past
        vm.expectRevert(CommitmentNotTimeoutable.selector);
        ROUTER.timeoutRequest(commitment1.requestId, subId, 1);
    }

    function test_RevertIf_TimingOutRequest_ForInactiveSubscription() public {
        // 1. Create a recurring subscription. The first request is created immediately.
        (uint64 subId, Commitment memory commitment1) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 10 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // 3. Expect a revert because the subscription is not active
        vm.expectRevert(bytes("CommitmentNotTimeoutable()"));
        ROUTER.timeoutRequest(commitment1.requestId, subId, 1);
    }

    function test_RevertIf_TimingOut_NonExistentRequest() public {
        // 1. Create a subscription but don't create a request for interval 2
        uint64 subId = ScheduledClient.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, 3, 10 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
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
        address consumerWallet = walletFactory.createWallet(address(this));
        address nodeWallet = walletFactory.createWallet(address(bob));
        uint256 feeAmount = 40e6;
        uint16 redundancy = 1;
        uint256 paymentForOneInterval = feeAmount * redundancy;
        erc20Token.mint(consumerWallet, paymentForOneInterval);

        vm.prank(address(this));
        Wallet(payable(consumerWallet)).approve(address(ScheduledClient), address(erc20Token), paymentForOneInterval);

        (uint64 subId, Commitment memory commitment1) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID,
            2, // maxExecutions
            10 minutes, // intervalSeconds
            redundancy,
            false, // useDeliveryInbox
            address(erc20Token),
            feeAmount,
            consumerWallet,
            NO_VERIFIER
        );

        // 2. Warp time to make the request timeoutable and then time it out.
        vm.warp(block.timestamp + 20 minutes);
        ROUTER.timeoutRequest(commitment1.requestId, subId, 1);

        // 3. Attempt to deliver compute for the now-timed-out request.
        // It should revert because the coordinator detects a mismatch between the
        // delivery interval (1) and the current system interval (2).
        bytes memory commitmentData1 = abi.encode(commitment1);
        vm.expectRevert(abi.encodeWithSelector(ICoordinator.IntervalMismatch.selector, 1));
        vm.prank(address(bob));
        bob.reportComputeResult(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, nodeWallet);
    }
}
