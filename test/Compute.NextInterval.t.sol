// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {BillingConfig} from "../src/v1_0_0/types/BillingConfig.sol";
import {ComputeTest} from "./Compute.t.sol";
import {Commitment} from "../src/v1_0_0/types/Commitment.sol";
import {ICoordinator} from "../src/v1_0_0/interfaces/ICoordinator.sol";
import {RequestIdUtils} from "../src/v1_0_0/utility/RequestIdUtils.sol";
import {Wallet} from "../src/v1_0_0/wallet/Wallet.sol";

contract ComputeNextIntervalPrepareTest is ComputeTest {
    function test_Succeeds_When_PreparingNextInterval_OnDelivery() public {
        // 1. Create a recurring, paid subscription
        address aliceWallet = walletFactory.createWallet(address(alice));
        address bobWallet = walletFactory.createWallet(address(bob));

        uint256 feeAmount = 40e6;
        uint16 redundancy = 2;
        uint256 totalPaymentForTwoIntervals = feeAmount * redundancy * 2;

        // 2. Fund the wallet
        erc20Token.mint(aliceWallet, totalPaymentForTwoIntervals + 10e6); // Mint extra

        // 3. Approve the consumer
        vm.prank(address(alice));
        Wallet(payable(aliceWallet)).approve(address(ScheduledClient), address(erc20Token), totalPaymentForTwoIntervals);

        // 4. Create subscription and first request (interval 1)
        vm.warp(0);
        (uint64 subId, Commitment memory commitment1) = ScheduledClient.createMockSubscription( //
            MOCK_CONTAINER_ID,
            2, // maxExecutions
            10 minutes, // intervalSeconds
            redundancy,
            false, // useDeliveryInbox
            address(erc20Token),
            feeAmount,
            aliceWallet,
            NO_VERIFIER
        );

        // 5. Warp to the first interval and deliver the compute
        bytes memory commitmentData1 = abi.encode(commitment1);

        // --- Assertions for the next interval preparation ---
        // 6. Deliver compute for interval 1, which triggers preparation for interval 2
        vm.prank(address(bob));
        bob.reportComputeResult(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, bobWallet);

        // Expect a new request to be started for interval 2
        bytes32 requestId2 = RequestIdUtils.requestIdPacked(subId, uint32(2));

        // Expect funds to be locked for the second request
        vm.expectEmit(true, true, false, false, address(Wallet(payable(aliceWallet))));
        emit Wallet.RequestLocked(
            requestId2, address(ScheduledClient), address(erc20Token), feeAmount * redundancy, redundancy
        );
        bob.prepareNextInterval(subId, 2, bobWallet);
        // 7. Final assertions on wallet state
        assertEq(
            Wallet(payable(aliceWallet)).lockedOfRequest(requestId2),
            feeAmount * redundancy,
            "Funds for interval 2 should be locked"
        );
    }

    function test_DoesNotPrepareNextInterval_OnFinalDelivery() public {
        // 1. Create a subscription with a maxExecutions of 1 (a single-shot request).
        (uint64 subId,) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID,
            1, // maxExecutions
            10 minutes, // intervalSeconds
            1, // redundancy
            false, // useDeliveryInbox
            NO_PAYMENT_TOKEN,
            0,
            userWalletAddress,
            NO_VERIFIER
        );

        // 2. The subscription has no next interval after the first one.
        // Attempting to prepare for interval 2 should revert.
        vm.expectRevert(ICoordinator.NoNextInterval.selector);
        bob.prepareNextInterval(subId, 2, address(bob));
    }

    function test_DoesNotPrepareNextInterval_WithInsufficientFunds() public {
        // 1. Create a recurring subscription.
        address consumerWallet = walletFactory.createWallet(address(this));
        address nodeWallet = walletFactory.createWallet(address(bob));
        uint256 feeAmount = 40e6;
        uint16 redundancy = 2;

        // 2. Fund the wallet with enough for ONLY the first interval
        uint256 paymentForOneInterval = feeAmount * redundancy;
        erc20Token.mint(consumerWallet, paymentForOneInterval);

        // 3. Approve for two intervals (even though funds are insufficient)
        vm.prank(address(this));
        Wallet(payable(consumerWallet))
            .approve(address(ScheduledClient), address(erc20Token), paymentForOneInterval * 2);

        // 4. Create subscription and first request
        (uint64 subId, Commitment memory commitment1) = ScheduledClient.createMockSubscription( //
            MOCK_CONTAINER_ID,
            2,
            10 minutes,
            redundancy,
            false,
            address(erc20Token),
            feeAmount,
            consumerWallet,
            NO_VERIFIER
        );
        // 5. Deliver compute for the first interval
        bytes memory commitmentData1 = abi.encode(commitment1);

        // 6. Deliver compute. This should succeed, but it should NOT trigger the next interval preparation
        // because hasSubscriptionNextInterval will return false due to insufficient funds.
        vm.prank(address(bob));
        // The call to prepareNextInterval should revert because hasSubscriptionNextInterval returns false.
        vm.expectRevert(ICoordinator.NoNextInterval.selector);
        bob.prepareNextInterval(subId, 2, address(bob));
    }

    function test_DoesNotPrepareNextInterval_When_InsufficientAllowance() public {
        // 1. Create a recurring subscription.
        address consumerWallet = walletFactory.createWallet(address(this));
        address nodeWallet = walletFactory.createWallet(address(bob));
        uint256 feeAmount = 40e6;
        uint16 redundancy = 2;

        // 2. Fund the wallet with enough for two intervals
        uint256 paymentForOneInterval = feeAmount * redundancy;
        erc20Token.mint(consumerWallet, paymentForOneInterval * 2);

        // 3. Approve for ONLY one interval
        vm.prank(address(this));
        Wallet(payable(consumerWallet)).approve(address(ScheduledClient), address(erc20Token), paymentForOneInterval);

        // 4. Create subscription and first request
        (uint64 subId, Commitment memory commitment1) = ScheduledClient.createMockSubscription( //
            MOCK_CONTAINER_ID,
            2,
            10 minutes,
            redundancy,
            false,
            address(erc20Token),
            feeAmount,
            consumerWallet,
            NO_VERIFIER
        );

        // 6. Deliver compute. This should succeed, but it should NOT trigger the next interval preparation
        // because hasSubscriptionNextInterval will return false due to insufficient allowance.
        vm.expectRevert(ICoordinator.NoNextInterval.selector);
        bob.prepareNextInterval(subId, 2, address(bob));
    }

    function test_Succeeds_When_PayingTickFee_OnNextIntervalPreparation() public {
        // 1. Arrange: Set the tickNodeFee specifically for this test.
        uint256 expectedTickFee = 0.01 ether;

        // Create a recurring subscription and a node wallet.
        address consumerWallet = walletFactory.createWallet(address(this));
        address nodeWallet = walletFactory.createWallet(address(bob)); // This wallet will receive the tick fee.
        address protocolWallet = walletFactory.createWallet(address(this)); // This wallet will pay the tick fee.
        uint16 redundancy = 1;
        uint256 feeAmount = 1 ether;

        // Fund protocol wallet with ETH
        vm.deal(protocolWallet, 10 ether);
        BillingConfig memory newConfig = BillingConfig({
            verificationTimeout: 1 weeks,
            protocolFeeRecipient: protocolWallet,
            protocolFee: MOCK_PROTOCOL_FEE,
            tickNodeFee: expectedTickFee,
            tickNodeFeeToken: address(0) // ETH
        });
        COORDINATOR.updateConfig(newConfig);

        // The protocol wallet is its own spender for tick fees.
        vm.startPrank(address(this));
        Wallet(payable(protocolWallet)).approve(protocolWallet, address(0), 10 ether);
        vm.stopPrank();

        // Fund the consumer wallet for the subscription payments
        vm.deal(consumerWallet, feeAmount * 2); // Fund for two intervals

        // Approve the SUBSCRIPTION consumer to spend from the wallet
        vm.prank(address(this));
        Wallet(payable(consumerWallet)).approve(address(ScheduledClient), ZERO_ADDRESS, feeAmount * 2);

        // Create the subscription
        (uint64 subId, Commitment memory commitment) = ScheduledClient.createMockSubscription( //
            MOCK_CONTAINER_ID,
            2,
            10 minutes,
            redundancy,
            false,
            ZERO_ADDRESS,
            feeAmount,
            consumerWallet,
            NO_VERIFIER
        );
        assertEq(subId, 1);

        // 2. Act: Deliver compute for the first interval, which triggers preparation for the second.
        bytes memory commitmentData1 = abi.encode(commitment);
        vm.prank(address(bob));
        bob.reportComputeResult(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, nodeWallet);
        bob.prepareNextInterval(commitment.subscriptionId, 2, nodeWallet);
        // 3. Assert: Check if the node wallet received the tick fee.
        uint256 computeFee = 0.8978 ether;
        uint256 finalNodeWalletBalance = expectedTickFee + computeFee;

        // Get initial balance of the node wallet that will trigger the tick
        uint256 nodeWalletBalance = nodeWallet.balance;
        assertEq(nodeWalletBalance, finalNodeWalletBalance, "Node wallet should receive the tick fee");
    }

    function test_RevertIf_PreparingNextInterval_WhenNotReady() public {
        // 1. Create a subscription with maxExecutions = 3
        (uint64 subId,) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID,
            3, // maxExecutions
            10 minutes, // intervalSeconds
            1, // redundancy
            false, // useDeliveryInbox
            NO_PAYMENT_TOKEN,
            0,
            userWalletAddress,
            NO_VERIFIER
        );

        // 2. The current interval is 1. Attempt to prepare for interval 3, skipping 2.
        vm.expectRevert(ICoordinator.NotReadyForNextInterval.selector);
        bob.prepareNextInterval(subId, 3, address(bob));
    }

    function test_RevertIf_PreparingNextInterval_WhenNoNextInterval() public {
        // 1. Create a subscription with maxExecutions = 1
        (uint64 subId, Commitment memory commitment) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID,
            1, // maxExecutions
            10 minutes, // intervalSeconds
            1, // redundancy
            false, // useDeliveryInbox
            NO_PAYMENT_TOKEN,
            0,
            userWalletAddress,
            NO_VERIFIER
        );

        // 2. The subscription has no next interval after the first one.
        vm.expectRevert(ICoordinator.NoNextInterval.selector);
        bob.prepareNextInterval(subId, 2, address(bob));
    }
}
