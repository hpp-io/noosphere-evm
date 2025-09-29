// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {ComputeTest} from "./Compute.t.sol";
import {Commitment} from "../src/v1_0_0/types/Commitment.sol";
import {Wallet} from "../src/v1_0_0/wallet/Wallet.sol";
import {PendingDelivery} from "../src/v1_0_0/types/PendingDelivery.sol";

/// @title CoordinatorEagerPaymentNoProofTest
/// @notice Coordinator tests specific to eager subscriptions with payments but no proofs
contract ComputePaymentNoProofTest is ComputeTest {
    /// @notice Subscription can be fulfilled with ETH payment
    function test_Succeeds_When_FulfillingSubscription_WithEthPayment() public {
        // Create new wallet with Alice as client
        address aliceWallet = walletFactory.createWallet(address(alice));

        // Create new wallet with Bob as client
        address bobWallet = walletFactory.createWallet(address(bob));

        // Fund alice wallet with 1 ether
        vm.deal(aliceWallet, 1 ether);

        // Allow CALLBACK consumer to spend alice wallet balance up to 1 ether
        vm.prank(address(alice));
        Wallet(payable(aliceWallet)).approve(address(transientClient), ZERO_ADDRESS, 1 ether);

        (uint64 subId, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, ZERO_ADDRESS, 1 ether, aliceWallet, NO_VERIFIER
        );
        assertEq(subId, 1);

        // Verify initial balances and allowances
        assertEq(aliceWallet.balance, 1 ether);

        bytes memory commitmentData = abi.encode(commitment);
        vm.prank(address(bob));
        bob.reportComputeResult(
            commitment.interval, // Use the correct interval from the commitment
            MOCK_INPUT,
            MOCK_OUTPUT,
            MOCK_PROOF,
            commitmentData,
            bobWallet
        );

        // Assert new balances
        assertEq(aliceWallet.balance, 0 ether);
        assertEq(bobWallet.balance, 0.8978 ether);
        assertEq(protocolWalletAddress.balance, 0.1022 ether);

        // Assert consumed allowance
        assertEq(Wallet(payable(aliceWallet)).allowance(address(transientClient), ZERO_ADDRESS), 0 ether);
    }

    /// @notice Lazy subscription can be fulfilled with ETH payment
    function test_Succeeds_When_FulfillingLazySubscription_WithEthPayment() public {
        // Create new wallet with Alice as client
        address aliceWallet = walletFactory.createWallet(address(alice));

        // Create new wallet with Bob as client
        address bobWallet = walletFactory.createWallet(address(bob));

        // Fund alice wallet with 1 ether
        vm.deal(aliceWallet, 1 ether);

        // Allow SUBSCRIPTION consumer to spend alice wallet balance up to 1 ether
        vm.prank(address(alice));
        Wallet(payable(aliceWallet)).approve(address(ScheduledClient), ZERO_ADDRESS, 1 ether);

        (uint64 subId, Commitment memory commitment) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 1, 1 minutes, 1, true, ZERO_ADDRESS, 1 ether, aliceWallet, NO_VERIFIER
        );
        assertEq(subId, 1);

        // Verify initial balances and allowances
        assertEq(aliceWallet.balance, 1 ether);

        // Warp to the exact time the subscription becomes active.
        // activeAt is calculated as block.timestamp (which is 1 at creation) + intervalSeconds (1 minute/60 seconds).
        vm.warp(1 minutes + 1);

        bytes memory commitmentData = abi.encode(commitment);
        vm.prank(address(bob));
        bob.reportComputeResult(
            1, // interval
            MOCK_INPUT,
            MOCK_OUTPUT,
            MOCK_PROOF,
            commitmentData,
            bobWallet
        );

        // Assert new balances
        assertEq(aliceWallet.balance, 0 ether);
        assertEq(bobWallet.balance, 0.8978 ether);
        assertEq(protocolWalletAddress.balance, 0.1022 ether);

        // Assert that the delivery is stored in DeliveryInbox.sol within the SUBSCRIPTION contract
        (bool exists, PendingDelivery memory pd) = ScheduledClient.getDelivery(commitment.requestId, bobWallet);
        assertTrue(exists, "Pending delivery should exist");
        assertEq(pd.subscriptionId, subId, "Pending delivery subscriptionId mismatch");
        assertEq(pd.interval, 1, "Pending delivery interval mismatch");
        assertEq(pd.input, MOCK_INPUT, "Pending delivery input mismatch");
        assertEq(pd.output, MOCK_OUTPUT, "Pending delivery output mismatch");
    }

    /// @notice Subscription can be fulfilled with ERC20 payment
    function test_Succeeds_When_FulfillingSubscription_WithErc20Payment() public {
        // Create new wallet with Alice as client
        address aliceWallet = walletFactory.createWallet(address(alice));

        // Create new wallet with Bob as client
        address bobWallet = walletFactory.createWallet(address(bob));

        // Mint 100 tokens to alice wallet
        erc20Token.mint(aliceWallet, 100e6);

        // Allow CALLBACK consumer to spend alice wallet balance up to 90e6 tokens
        vm.prank(address(alice));
        Wallet(payable(aliceWallet)).approve(address(transientClient), address(erc20Token), 90e6);

        (uint64 subId, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, address(erc20Token), 50e6, aliceWallet, NO_VERIFIER
        );
        assertEq(subId, 1);

        // Verify initial balances and allowances
        assertEq(erc20Token.balanceOf(aliceWallet), 100e6);

        bytes memory commitmentData = abi.encode(commitment);
        vm.prank(address(bob));
        bob.reportComputeResult(
            commitment.interval, // Use the correct interval from the commitment
            MOCK_INPUT,
            MOCK_OUTPUT,
            MOCK_PROOF,
            commitmentData,
            bobWallet
        );

        // Assert new balances
        assertEq(erc20Token.balanceOf(aliceWallet), 50e6);
        assertEq(erc20Token.balanceOf(bobWallet), 44_890_000);
        assertEq(erc20Token.balanceOf(protocolWalletAddress), 5_110_000);

        // Assert consumed allowance
        assertEq(Wallet(payable(aliceWallet)).allowance(address(transientClient), address(erc20Token)), 40e6);
    }

    // /// @notice Subscription can be fulfilled across intervals with ERC20 payment
    function test_Succeeds_When_FulfillingSubscription_AcrossIntervals_WithErc20Payment() public {
        // Create new wallet with Alice as client
        address aliceWallet = walletFactory.createWallet(address(alice));

        // Create new wallet with Bob as client
        address bobWallet = walletFactory.createWallet(address(bob));

        // Mint 100 tokens to alice wallet
        erc20Token.mint(aliceWallet, 100e6);

        // Create new two-time subscription with 40e6 payout
        vm.warp(0 minutes);

        // Allow CALLBACK consumer to spend alice wallet balance up to 90e6 tokens
        vm.prank(address(alice));
        Wallet(payable(aliceWallet)).approve(address(ScheduledClient), address(erc20Token), 90e6);

        // Verify initial balances and allowances
        assertEq(erc20Token.balanceOf(aliceWallet), 100e6);

        (, Commitment memory commitment) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID, 2, 1 minutes, 2, false, address(erc20Token), 40e6, aliceWallet, NO_VERIFIER
        );

        // Execute response fulfillment from Bob
        vm.warp(1 minutes);
        bytes memory commitmentData = abi.encode(commitment);
        bob.reportComputeResult(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWallet);

        // Execute response fulfillment from Charlie (notice that for no proof submissions there is no collateral so we can use any wallet)
        vm.warp(2 minutes);
        charlie.reportComputeResult(2, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWallet);

        // Assert new balances
        assertEq(erc20Token.balanceOf(aliceWallet), 20e6);
        assertEq(erc20Token.balanceOf(bobWallet), (40e6 * 2) - (4_088_000 * 2));
        assertEq(erc20Token.balanceOf(protocolWalletAddress), 4_088_000 * 2);

        // Assert consumed allowance
        assertEq(Wallet(payable(aliceWallet)).allowance(address(ScheduledClient), address(erc20Token)), 10e6);
    }

    /// @notice Subscription cannot be fulfilled with an invalid `Wallet` not created by `WalletFactory`
    function test_RevertIf_CreatingRequest_WithInvalidConsumerWallet() public {
        // Create new wallet for Alice directly
        Wallet aliceWallet = new Wallet(address(ROUTER), address(alice));

        // Fund the wallet with tokens, as it's created empty.
        erc20Token.mint(address(aliceWallet), 100e6);

        // The client of the wallet (ALICE) must approve the consumer (CALLBACK) to spend funds.
        vm.prank(address(alice));
        aliceWallet.approve(address(transientClient), address(erc20Token), 50e6);

        vm.expectRevert(bytes("InvalidWallet()"));
        // Create a new one-time subscription with a 50e6 payout.
        transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, address(erc20Token), 50e6, address(aliceWallet), NO_VERIFIER
        );
    }

    /// @notice Subscription cannot be fulfilled with an invalid `nodeWallet` not created by `WalletFactory`
    function test_RevertIf_FulfillingSubscription_WithInvalidNodeWallet() public {
        // Create new wallet with Alice as client
        address aliceWallet = walletFactory.createWallet(address(alice));
        erc20Token.mint(address(aliceWallet), 100e6);

        vm.prank(address(alice));
        Wallet(payable(aliceWallet)).approve(address(transientClient), address(erc20Token), 50e6);

        // Create a new one-time subscription with a 50e6 payout.
        (, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, address(erc20Token), 50e6, aliceWallet, NO_VERIFIER
        );

        Wallet bobWallet = new Wallet(address(ROUTER), address(bob));
        // Execute response fulfillment from Bob using address(BOB) as nodeWallet
        vm.expectRevert(bytes("InvalidWallet()"));
        bytes memory commitmentData = abi.encode(commitment);
        bob.reportComputeResult(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, address(bobWallet));
    }

    /// @notice Subscription cannot be fulfilled if `Wallet` does not approve consumer
    function test_RevertIf_CreatingRequest_WithNoSpenderAllowance() public {
        // Create new wallets
        address aliceWallet = walletFactory.createWallet(address(alice));

        // Fund alice wallet with 1 ether
        vm.deal(aliceWallet, 1 ether);
        // Verify CALLBACK has 0 allowance to spend on aliceWallet
        assertEq(Wallet(payable(aliceWallet)).allowance(address(transientClient), ZERO_ADDRESS), 0 ether);

        vm.expectRevert(Wallet.InsufficientAllowance.selector);
        transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, ZERO_ADDRESS, 1 ether, aliceWallet, NO_VERIFIER
        );
    }

    /// @notice Subscription cannot be fulfilled if `Wallet` only partially approves consumer
    function test_RevertIf_CreatingRequest_WithPartialSpenderAllowance() public {
        // Create new wallets.
        address aliceWallet = walletFactory.createWallet(address(alice));

        // Fund aliceWallet with 1 ether.
        vm.deal(aliceWallet, 1 ether);

        // Increase callback allowance to just under the required 1 ether.
        vm.startPrank(address(alice));
        Wallet(payable(aliceWallet)).approve(address(transientClient), ZERO_ADDRESS, 1 ether - 1 wei);

        // Expect the request creation to fail because the consumer (CALLBACK) has insufficient allowance.
        vm.expectRevert(Wallet.InsufficientAllowance.selector);

        // Attempt to create a new one-time subscription with a 1 ether payout.
        transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, ZERO_ADDRESS, 1 ether, aliceWallet, NO_VERIFIER
        );
    }
}
