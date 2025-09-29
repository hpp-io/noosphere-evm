// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {MockImmediateVerifier} from "./mocks/verifier/MockImmediateVerifier.sol";
import {MockDeferredVerifier} from "./mocks/verifier/MockDeferredVerifier.sol";
import {Commitment} from "src/v1_0_0/types/Commitment.sol";
import {ComputeTest} from "./Compute.t.sol";
import {ICoordinator} from "../src/v1_0_0/interfaces/ICoordinator.sol";
import {Wallet} from "src/v1_0_0/wallet/Wallet.sol";
import {console} from "forge-std/console.sol";
import {PendingDelivery} from "src/v1_0_0/types/PendingDelivery.sol";

contract ComputeVerifierTest is ComputeTest {
    /// @notice Mock atomic verifier
    MockImmediateVerifier internal immediateVerifier;

    /// @notice Mock optimistic verifier
    MockDeferredVerifier internal deferredVerifier;
    //
    //    Commitment commitment;
    //    ComputeSubscription sub;

    function setUp() public override {
        super.setUp();
        immediateVerifier = new MockImmediateVerifier(ROUTER);
        deferredVerifier = new MockDeferredVerifier(ROUTER);
    }

    function test_RevertIf_DeliveringCompute_When_NodeWalletNotApproved() public {
        // Create new wallets
        address aliceWallet = walletFactory.createWallet(address(alice));
        address bobWallet = walletFactory.createWallet(address(bob));

        // Mint 50 tokens to alice wallet
        erc20Token.mint(aliceWallet, 50e6);

        // Setup atomic verifier approved token + fee (5 tokens)
        // This must be done BEFORE createMockRequest, as createMockRequest calls _startBilling which checks verifier.isPaymentTokenSupported
        immediateVerifier.updateSupportedToken(address(erc20Token), true);
        immediateVerifier.updateFee(address(erc20Token), 5e6);

        // Mint 50 tokens to bob wallet (ensuring node has sufficient funds to put up for escrow)
        erc20Token.mint(bobWallet, 50e6);

        // Allow CALLBACK consumer to spend alice wallet balance up to 50e6 tokens.
        // This must be done BEFORE creating the request, as request creation locks the funds.
        vm.prank(address(alice));
        Wallet(payable(aliceWallet)).approve(address(transientClient), address(erc20Token), 50e6);

        // Create new one-time subscription with 50e6 payout
        (, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID,
            MOCK_INPUT,
            1,
            address(erc20Token),
            50e6,
            aliceWallet,
            // Specify atomic verifier
            address(immediateVerifier)
        );
        bytes memory commitmentData = abi.encode(commitment);

        // Verify initial balances and allowances
        assertEq(erc20Token.balanceOf(aliceWallet), 50e6);
        assertEq(erc20Token.balanceOf(bobWallet), 50e6);

        // Ensure that atomic verifier will return true for proof verification
        immediateVerifier.setNextValidityTrue();

        // Execute response fulfillment from Charlie expecting it to fail given no authorization to Bob's wallet
        vm.warp(1 minutes);
        vm.expectRevert(Wallet.InsufficientAllowance.selector);
        vm.prank(address(charlie));
        charlie.reportComputeResult(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWallet);
    }

    function test_RevertIf_DeliveringCompute_When_NodeWalletHasInsufficientFundsForEscrow() public {
        // Create new wallets
        address aliceWallet = walletFactory.createWallet(address(alice));
        address bobWallet = walletFactory.createWallet(address(bob));

        // Mint 50 tokens to alice wallet (but not to Bob's wallet)
        erc20Token.mint(aliceWallet, 50e6);

        // Allow CALLBACK consumer to spend alice wallet balance up to 50e6 tokens
        vm.prank(address(alice));
        Wallet(payable(aliceWallet)).approve(address(transientClient), address(erc20Token), 50e6);

        // Allow BOB to sepnd bob wallet balance up to 50e6 tokens
        vm.prank(address(bob));
        Wallet(payable(bobWallet)).approve(address(bob), address(erc20Token), 50e6);

        // Setup atomic verifier approved token + fee (5 tokens)
        immediateVerifier.updateSupportedToken(address(erc20Token), true);
        immediateVerifier.updateFee(address(erc20Token), 5e6);

        // Create new one-time subscription with 40e6 payout
        (, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID,
            MOCK_INPUT,
            1,
            address(erc20Token),
            50e6,
            aliceWallet,
            // Specify atomic verifier
            address(immediateVerifier)
        );
        bytes memory commitmentData = abi.encode(commitment);

        // Verify initial balances and allowances
        assertEq(erc20Token.balanceOf(aliceWallet), 50e6);
        assertEq(erc20Token.balanceOf(bobWallet), 0e6);

        // Ensure that atomic verifier will return true for proof verification
        immediateVerifier.setNextValidityTrue();

        // Execute response fulfillment expecting it to fail given not enough unlocked funds
        vm.warp(1 minutes);
        vm.expectRevert(Wallet.InsufficientFunds.selector);
        bob.reportComputeResult(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWallet);
    }

    function test_Succeeds_When_FulfillingSubscription_WithValidProof() public {
        // Create new wallets
        address aliceWallet = walletFactory.createWallet(address(alice));
        address bobWallet = walletFactory.createWallet(address(bob));

        // Mint 50 tokens to wallets
        erc20Token.mint(aliceWallet, 50e6);
        erc20Token.mint(bobWallet, 50e6);

        // Allow CALLBACK consumer to spend alice wallet balance up to 50e6 tokens
        vm.prank(address(alice));
        Wallet(payable(aliceWallet)).approve(address(transientClient), address(erc20Token), 50e6);

        // Allow Bob to spend bob wallet balance up to 50e6 tokens
        vm.prank(address(bob));
        Wallet(payable(bobWallet)).approve(address(bob), address(erc20Token), 50e6);

        // Setup atomic verifier approved token + fee (5 tokens)
        immediateVerifier.updateSupportedToken(address(erc20Token), true);
        immediateVerifier.updateFee(address(erc20Token), 5e6);

        // Create new one-time subscription with 40e6 payout
        (uint64 subId, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID,
            MOCK_INPUT,
            1,
            address(erc20Token),
            40e6,
            aliceWallet,
            // Specify atomic verifier
            address(immediateVerifier)
        );
        bytes memory commitmentData = abi.encode(commitment);

        // Verify initial balances and allowances
        assertEq(erc20Token.balanceOf(aliceWallet), 50e6);
        assertEq(erc20Token.balanceOf(bobWallet), 50e6);

        // Ensure that atomic verifier will return true for proof verification
        immediateVerifier.setNextValidityTrue();

        // Execute response fulfillment from Bob
        vm.warp(1 minutes);
        bob.reportComputeResult(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWallet);

        // Assert new balances
        assertEq(erc20Token.balanceOf(aliceWallet), 10e6); // -40
        assertEq(erc20Token.balanceOf(bobWallet), 80_912_000); // 50 (initial) + (40 - (40 * 5.11% * 2) - (5))
        assertEq(erc20Token.balanceOf(address(immediateVerifier)), 4_744_500); // (5 - (5 * 5.11%))
        assertEq(erc20Token.balanceOf(protocolWalletAddress), 4_343_500);

        // Assert consumed allowance
        assertEq(Wallet(payable(aliceWallet)).allowance(address(transientClient), address(erc20Token)), 10e6);
        assertEq(Wallet(payable(bobWallet)).allowance(address(bob), address(erc20Token)), 50e6);
    }

    function test_Succeeds_When_FulfillingLazySubscription_WithValidProof() public {
        // Create new wallets
        address aliceWallet = walletFactory.createWallet(address(alice));
        address bobWallet = walletFactory.createWallet(address(bob));

        // Mint 50 tokens to wallets
        erc20Token.mint(aliceWallet, 50e6);
        erc20Token.mint(bobWallet, 50e6);

        // Allow SUBSCRIPTION consumer to spend alice wallet balance up to 50e6 tokens
        vm.prank(address(alice));
        Wallet(payable(aliceWallet)).approve(address(ScheduledClient), address(erc20Token), 50e6);

        // Allow Bob to spend bob wallet balance up to 50e6 tokens
        vm.prank(address(bob));
        Wallet(payable(bobWallet)).approve(address(bob), address(erc20Token), 50e6);

        // Setup atomic verifier approved token + fee (5 tokens)
        immediateVerifier.updateSupportedToken(address(erc20Token), true);
        immediateVerifier.updateFee(address(erc20Token), 5e6);

        // Create new one-time useDeliveryInbox subscription with 40e6 payout
        (uint64 subId, Commitment memory commitment) = ScheduledClient.createMockSubscription(
            MOCK_CONTAINER_ID,
            1, // maxExecutions
            1 minutes, // intervalSeconds
            1, // redundancy
            true, // useDeliveryInbox
            address(erc20Token),
            40e6,
            aliceWallet,
            // Specify atomic verifier
            address(immediateVerifier)
        );
        bytes memory commitmentData = abi.encode(commitment);

        // Verify initial balances and allowances
        assertEq(erc20Token.balanceOf(aliceWallet), 50e6);
        assertEq(erc20Token.balanceOf(bobWallet), 50e6);

        // Ensure that atomic verifier will return true for proof verification
        immediateVerifier.setNextValidityTrue();

        // Warp to the exact time the subscription becomes active
        vm.warp(1 minutes + 1);

        // Execute response fulfillment from Bob
        bob.reportComputeResult(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWallet);

        // Assert new balances (same as eager subscription)
        assertEq(erc20Token.balanceOf(aliceWallet), 10e6); // -40
        assertEq(erc20Token.balanceOf(bobWallet), 80_912_000); // 50 (initial) + (40 - (40 * 5.11% * 2) - (5))
        assertEq(erc20Token.balanceOf(address(immediateVerifier)), 4_744_500); // (5 - (5 * 5.11%))
        assertEq(erc20Token.balanceOf(protocolWalletAddress), 4_343_500);

        // Assert consumed allowance
        assertEq(Wallet(payable(aliceWallet)).allowance(address(ScheduledClient), address(erc20Token)), 10e6);
        assertEq(Wallet(payable(bobWallet)).allowance(address(bob), address(erc20Token)), 50e6);

        // Assert that the delivery is stored in DeliveryInbox.sol within the SUBSCRIPTION contract
        (bool exists, PendingDelivery memory pd) = ScheduledClient.getDelivery(commitment.requestId, bobWallet);
        assertTrue(exists, "Pending delivery should exist");
        assertEq(pd.subscriptionId, subId, "Pending delivery subscriptionId mismatch");
        assertEq(pd.output, MOCK_OUTPUT, "Pending delivery output mismatch");
        assertEq(pd.proof, MOCK_PROOF, "Pending delivery proof mismatch");
    }

    function test_Succeeds_When_SlashingNode_WithInvalidProof() public {
        // Create new wallets
        address aliceWallet = walletFactory.createWallet(address(alice));
        address bobWallet = walletFactory.createWallet(address(bob));

        // Mint 1 ether to Alice and Bob
        vm.deal(address(aliceWallet), 1 ether);
        vm.deal(address(bobWallet), 1 ether);

        // Allow CALLBACK consumer to spend alice wallet balance up to 1 ether
        vm.prank(address(alice));
        Wallet(payable(aliceWallet)).approve(address(transientClient), ZERO_ADDRESS, 1 ether);

        // Allow Bob to spend bob wallet balance up to 1 ether
        vm.prank(address(bob));
        Wallet(payable(bobWallet)).approve(address(bob), ZERO_ADDRESS, 1 ether);

        // Verify initial balances and allowances
        assertEq(aliceWallet.balance, 1 ether);
        assertEq(bobWallet.balance, 1 ether);

        // Setup atomic verifier approved token + fee (0.111 ether)
        immediateVerifier.updateSupportedToken(ZERO_ADDRESS, true);
        immediateVerifier.updateFee(ZERO_ADDRESS, 111e15);

        // Create new one-time subscription with 40e6 payout
        (, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID,
            MOCK_INPUT,
            1,
            ZERO_ADDRESS,
            1 ether,
            aliceWallet,
            // Specify atomic verifier
            address(immediateVerifier)
        );
        bytes memory commitmentData = abi.encode(commitment);

        // Ensure that atomic verifier will return true for proof verification
        immediateVerifier.setNextValidityFalse();

        // Execute response fulfillment from Bob
        vm.warp(1 minutes);
        bob.reportComputeResult(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWallet);

        // Assert new balances
        // Alice --> 1 ether - protocol fee (0.1022 ether) - verifier fee (0.111 ether) + slashed (1 ether) = 1.7868 ether
        assertEq(aliceWallet.balance, 17_868e14);
        // Bob --> -1 ether
        assertEq(bobWallet.balance, 0 ether);
        // verifier --> +0.111 * (1 - 0.0511) ether = 0.1053279 ether
        assertEq(immediateVerifier.ethBalance(), 1_053_279e11);
        // Protocol --> feeFromConsumer (0.1022 ether) + feeFromVerifier (0.0056721 ether) = 0.1078721 ether
        assertEq(protocolWalletAddress.balance, 1_078_721e11);

        // Assert consumed allowance
        assertEq(Wallet(payable(aliceWallet)).allowance(address(transientClient), ZERO_ADDRESS), 7868e14);
        assertEq(Wallet(payable(bobWallet)).allowance(address(bob), ZERO_ADDRESS), 0 ether);
    }

    function test_Succeeds_When_SlashingNode_InOptimisticFlow_WithInvalidProof() public {
        // Create new wallets
        address aliceWallet = walletFactory.createWallet(address(alice));
        address bobWallet = walletFactory.createWallet(address(bob));

        // Mint 1 ether to Alice and Bob
        vm.deal(address(aliceWallet), 1 ether);
        vm.deal(address(bobWallet), 1 ether);

        // Allow CALLBACK consumer to spend alice wallet balance up to 1 ether
        vm.prank(address(alice));
        Wallet(payable(aliceWallet)).approve(address(transientClient), ZERO_ADDRESS, 1 ether);

        // Allow Bob to spend bob wallet balance up to 1 ether
        vm.prank(address(bob));
        Wallet(payable(bobWallet)).approve(address(bob), ZERO_ADDRESS, 1 ether);

        // Verify initial balances and allowances
        assertEq(aliceWallet.balance, 1 ether);
        assertEq(bobWallet.balance, 1 ether);

        // Setup optimistic verifier approved token + fee (0.1 ether)
        deferredVerifier.updateSupportedToken(ZERO_ADDRESS, true);
        deferredVerifier.updateFee(ZERO_ADDRESS, 1e17);

        // Create new one-time subscription with 1 ether payout
        (uint64 subId, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID,
            MOCK_INPUT,
            1,
            ZERO_ADDRESS,
            1 ether,
            aliceWallet,
            // Specify optimistic verifier
            address(deferredVerifier)
        );

        bytes memory commitmentData = abi.encode(commitment);
        // Execute response fulfillment from Bob
        bob.reportComputeResult(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWallet);

        // Assert immediate balances
        // Alice -> 1 ether - protocol fee (0.1022 ether) - verifier fee (0.1 ether)
        // Alice --> allowance: 0 ether
        assertEq(aliceWallet.balance, 7978e14);
        console.log("aliceWallet.balance : ", aliceWallet.balance);
        console.log(
            "aliceWallet.allowance : ", Wallet(payable(aliceWallet)).allowance(address(transientClient), ZERO_ADDRESS)
        );
        //        assertEq(Wallet(payable(aliceWallet)).allowance(address(CALLBACK), ZERO_ADDRESS), 0);
        // Bob --> 1 ether
        // Bob --> allowance: 0 ether
        assertEq(bobWallet.balance, 1 ether);
        assertEq(Wallet(payable(bobWallet)).allowance(address(bob), ZERO_ADDRESS), 0);
        // verifier --> 0.1 * (1 - 0.0511) ether = 0.09489 ether
        assertEq(deferredVerifier.ethBalance(), 9489e13);
        // Protocol --> feeFromConsumer (0.1022 ether) + feeFromVerifier (0.00511 ether) = 0.10731 ether
        assertEq(protocolWalletAddress.balance, 10_731e13);

        // Fast forward 1 day and trigger optimistic response with valid: false
        vm.warp(1 days);
        vm.expectEmit(address(COORDINATOR));
        emit ICoordinator.ProofVerified(subId, 1, address(bob), false, address(deferredVerifier));
        deferredVerifier.mockFinalizeVerification(subId, 1, address(bob), false);

        // Assert new balances
        // Alice --> 1 ether - protocol fee (0.1022 ether) - verifier fee (0.1 ether) + 1 ether (slashed from node)
        // Alice --> allowance: 1 ether - protocol fee (0.1022 ether) - verifier fee (0.1 ether)
        assertEq(aliceWallet.balance, 17_978e14);
        assertEq(Wallet(payable(aliceWallet)).allowance(address(transientClient), ZERO_ADDRESS), 7978e14);
        // Bob --> 0 ether
        // Bob --> allowance: 0 ether
        assertEq(bobWallet.balance, 0);
        assertEq(Wallet(payable(bobWallet)).allowance(address(bob), ZERO_ADDRESS), 0 ether);
        // verifier, protocol stay same
        assertEq(deferredVerifier.ethBalance(), 9489e13);
        assertEq(protocolWalletAddress.balance, 10_731e13);
    }
}
