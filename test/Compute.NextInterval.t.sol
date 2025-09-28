// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {ComputeTest} from "./Compute.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {Commitment} from "../src/v1_0_0/types/Commitment.sol";
import {Wallet} from "../src/v1_0_0/wallet/Wallet.sol";
import {DeployUtils} from "./lib/DeployUtils.sol";
import {Router} from "../src/v1_0_0/Router.sol";

contract ComputeNextIntervalPrepareTest is ComputeTest {
    function test_Succeeds_When_PreparingNextInterval_OnDelivery() public {
        // 1. Create a recurring, paid subscription
        address aliceWallet = WALLET_FACTORY.createWallet(address(ALICE));
        address bobWallet = WALLET_FACTORY.createWallet(address(BOB));

        uint256 feeAmount = 40e6;
        uint16 redundancy = 2;
        uint256 totalPaymentForTwoIntervals = feeAmount * redundancy * 2;

        // 2. Fund the wallet
        TOKEN.mint(aliceWallet, totalPaymentForTwoIntervals + 10e6); // Mint extra

        // 3. Approve the consumer
        vm.prank(address(ALICE));
        Wallet(payable(aliceWallet)).approve(address(SUBSCRIPTION), address(TOKEN), totalPaymentForTwoIntervals);

        // 4. Create subscription and first request (interval 1)
        vm.warp(0);
        (uint64 subId, Commitment memory commitment1) = SUBSCRIPTION.createMockSubscription( //
            MOCK_CONTAINER_ID,
            2, // maxExecutions
            1 minutes, // intervalSeconds
            redundancy,
            false, // useDeliveryInbox
            address(TOKEN),
            feeAmount,
            aliceWallet,
            NO_VERIFIER
        );

        // 5. Warp to the first interval and deliver the compute
        vm.warp(1 minutes);
        bytes memory commitmentData1 = abi.encode(commitment1);

        // --- Assertions for the next interval preparation ---
        // 6. Deliver compute for interval 1, which triggers preparation for interval 2
        vm.prank(address(BOB));
        BOB.reportComputeResult(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, bobWallet);

        // Expect a new request to be started for interval 2
        bytes32 requestId2 = keccak256(abi.encodePacked(subId, uint32(2)));
        // Expect funds to be locked for the second request
        vm.expectEmit(true, true, false, false, address(Wallet(payable(aliceWallet))));
        emit Wallet.RequestLocked(requestId2, address(SUBSCRIPTION), address(TOKEN), feeAmount * redundancy, redundancy);
        BOB.prepareNextInterval(subId, 2, address(BOB));
        // 7. Final assertions on wallet state
        assertEq(
            Wallet(payable(aliceWallet)).lockedOfRequest(requestId2),
            feeAmount * redundancy,
            "Funds for interval 2 should be locked"
        );
    }

    function test_DoesNotPrepareNextInterval_OnFinalDelivery() public {
        // 1. Create a subscription with a maxExecutions of 1 (a single-shot request).
        address consumerWallet = WALLET_FACTORY.createWallet(address(this));
        address nodeWallet = WALLET_FACTORY.createWallet(address(BOB));
        uint256 feeAmount = 40e6;
        TOKEN.mint(consumerWallet, feeAmount);
        vm.prank(address(this));
        Wallet(payable(consumerWallet)).approve(address(CALLBACK), address(TOKEN), feeAmount);

        (, Commitment memory commitment1) = CALLBACK.createMockRequest( //
        MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, address(TOKEN), feeAmount, consumerWallet, NO_VERIFIER);

        // 2. Deliver the compute for the final (and only) interval.
        bytes memory commitmentData1 = abi.encode(commitment1);

        // 3. Record logs to check for the absence of next-interval events.
        vm.recordLogs();

        // 4. Deliver compute.
        vm.prank(address(BOB));
        BOB.reportComputeResult(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, nodeWallet);
        BOB.prepareNextInterval(commitment1.subscriptionId, 2, address(BOB));
        // 5. Assert that no events related to preparing a next interval were emitted.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 requestStartSelector = Router.RequestStart.selector;
        bytes32 requestLockedSelector = Wallet.RequestLocked.selector;

        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], requestStartSelector, "Should not emit RequestStart");
            assertNotEq(logs[i].topics[0], requestLockedSelector, "Should not emit RequestLocked");
        }
    }

    function test_DoesNotPrepareNextInterval_WithInsufficientFunds() public {
        // 1. Create a recurring subscription.
        address consumerWallet = WALLET_FACTORY.createWallet(address(this));
        address nodeWallet = WALLET_FACTORY.createWallet(address(BOB));
        uint256 feeAmount = 40e6;
        uint16 redundancy = 2;

        // 2. Fund the wallet with enough for ONLY the first interval
        uint256 paymentForOneInterval = feeAmount * redundancy;
        TOKEN.mint(consumerWallet, paymentForOneInterval);

        // 3. Approve for two intervals (even though funds are insufficient)
        vm.prank(address(this));
        Wallet(payable(consumerWallet)).approve(address(SUBSCRIPTION), address(TOKEN), paymentForOneInterval * 2);

        // 4. Create subscription and first request
        (uint64 subId, Commitment memory commitment1) = SUBSCRIPTION.createMockSubscription( //
        MOCK_CONTAINER_ID, 2, 1 minutes, redundancy, false, address(TOKEN), feeAmount, consumerWallet, NO_VERIFIER);
        // 5. Deliver compute for the first interval
        vm.warp(block.timestamp + 1 minutes);
        bytes memory commitmentData1 = abi.encode(commitment1);

        // 6. Deliver compute. This should succeed, but it should NOT trigger the next interval preparation
        // because hasSubscriptionNextInterval will return false due to insufficient funds.
        vm.prank(address(BOB));
        BOB.reportComputeResult(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, nodeWallet);
        BOB.prepareNextInterval(subId, 2, address(BOB));
        // 7. Assert that no funds were locked for the next interval.
        bytes32 requestId2 = keccak256(abi.encodePacked(subId, uint32(2)));
        assertEq(
            Wallet(payable(consumerWallet)).lockedOfRequest(requestId2), 0, "Should not lock funds for next interval"
        );
    }

    function test_DoesNotPrepareNextInterval_When_InsufficientAllowance() public {
        // 1. Create a recurring subscription.
        address consumerWallet = WALLET_FACTORY.createWallet(address(this));
        address nodeWallet = WALLET_FACTORY.createWallet(address(BOB));
        uint256 feeAmount = 40e6;
        uint16 redundancy = 2;

        // 2. Fund the wallet with enough for two intervals
        uint256 paymentForOneInterval = feeAmount * redundancy;
        TOKEN.mint(consumerWallet, paymentForOneInterval * 2);

        // 3. Approve for ONLY one interval
        vm.prank(address(this));
        Wallet(payable(consumerWallet)).approve(address(SUBSCRIPTION), address(TOKEN), paymentForOneInterval);

        // 4. Create subscription and first request
        (uint64 subId, Commitment memory commitment1) = SUBSCRIPTION.createMockSubscription( //
        MOCK_CONTAINER_ID, 2, 1 minutes, redundancy, false, address(TOKEN), feeAmount, consumerWallet, NO_VERIFIER);

        // 5. Deliver compute for the first interval
        vm.warp(block.timestamp + 1 minutes);
        bytes memory commitmentData1 = abi.encode(commitment1);

        // 6. Deliver compute. This should succeed, but it should NOT trigger the next interval preparation
        // because hasSubscriptionNextInterval will return false due to insufficient allowance.
        vm.prank(address(BOB));
        BOB.reportComputeResult(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, nodeWallet);
        BOB.prepareNextInterval(commitment1.subscriptionId, 2, address(BOB));
        // 7. Assert that no funds were locked for the next interval.
        bytes32 requestId2 = keccak256(abi.encodePacked(subId, uint32(2)));
        assertEq(
            Wallet(payable(consumerWallet)).lockedOfRequest(requestId2),
            0,
            "Should not lock funds for next interval due to allowance"
        );
    }

    function test_Succeeds_When_PayingTickFee_OnNextIntervalPreparation() public {
        // 1. Arrange: Set the tickNodeFee specifically for this test.
        uint256 expectedTickFee = 0.01 ether;

        // Create a recurring subscription and a node wallet.
        address consumerWallet = WALLET_FACTORY.createWallet(address(this));
        address nodeWallet = WALLET_FACTORY.createWallet(address(BOB)); // This wallet will receive the tick fee.
        address protocolWallet = WALLET_FACTORY.createWallet(address(this));
        uint16 redundancy = 1;
        uint256 feeAmount = 1 ether;

        // Fund protocol wallet with ETH
        vm.deal(protocolWallet, 10 ether);
        DeployUtils.updateBillingConfig(
            COORDINATOR, 1 weeks, protocolWallet, MOCK_PROTOCOL_FEE, 0, expectedTickFee, address(0)
        );

        // The protocol wallet is its own spender for tick fees.
        vm.startPrank(address(this));
        Wallet(payable(protocolWallet)).approve(protocolWallet, address(0), 10 ether);
        vm.stopPrank();

        // Fund the consumer wallet for the subscription payments
        vm.deal(consumerWallet, feeAmount * 2); // Fund for two intervals

        // Approve the SUBSCRIPTION consumer to spend from the wallet
        vm.prank(address(this));
        Wallet(payable(consumerWallet)).approve(address(SUBSCRIPTION), ZERO_ADDRESS, feeAmount * 2);

        // Create the subscription
        (uint64 subId, Commitment memory commitment) = SUBSCRIPTION.createMockSubscription( //
        MOCK_CONTAINER_ID, 2, 1 minutes, redundancy, false, ZERO_ADDRESS, feeAmount, consumerWallet, NO_VERIFIER);
        assertEq(subId, 1);

        // 2. Act: Deliver compute for the first interval, which triggers preparation for the second.
        vm.warp(block.timestamp + 1 minutes);
        bytes memory commitmentData1 = abi.encode(commitment);
        vm.prank(address(BOB));
        BOB.reportComputeResult(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, nodeWallet);
        BOB.prepareNextInterval(commitment.subscriptionId, 2, nodeWallet);
        // 3. Assert: Check if the node wallet received the tick fee.
        uint256 computeFee = 0.8978 ether;
        uint256 finalNodeWalletBalance = expectedTickFee + computeFee;

        // Get initial balance of the node wallet that will trigger the tick
        uint256 nodeWalletBalance = nodeWallet.balance;
        assertEq(nodeWalletBalance, finalNodeWalletBalance, "Node wallet should receive the tick fee");
    }
}
