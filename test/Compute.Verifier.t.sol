// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {MockImmediateVerifier} from "./mocks/verifier/MockImmediateVerifier.sol";
import {MockDeferredVerifier} from "./mocks/verifier/MockDeferredVerifier.sol";
import {Commitment} from "src/v1_0_0/types/Commitment.sol";
import {ComputeTest} from "./Compute.t.sol";
import {IRouter} from "src/v1_0_0/interfaces/IRouter.sol";
import {IVerifier} from "src/v1_0_0/interfaces/IVerifier.sol";
import {ICoordinator} from "../src/v1_0_0/interfaces/ICoordinator.sol";
import {Payment} from "src/v1_0_0/types/Payment.sol";
import {ProofVerificationRequest} from "src/v1_0_0/types/ProofVerificationRequest.sol";
import {ComputeSubscription} from "src/v1_0_0/types/ComputeSubscription.sol";
import {Wallet} from "src/v1_0_0/wallet/Wallet.sol";
import {console} from "forge-std/console.sol";
import {PendingDelivery} from "src/v1_0_0/types/PendingDelivery.sol";

contract ComputeVerifierTest is ComputeTest {
    address verifier;
    address consumerWallet;
    address node;
    address nodeWallet;

    uint64 subId = 1;
    uint32 interval = 1;
    uint256 feeAmount = 1000 ether;
    bytes32 containerId = "test-container";

    bytes32 constant COORDINATOR_ID = "coordinator_v1.0.0";
    /// @notice Mock atomic verifier
    MockImmediateVerifier internal IMMEDIATE_VERIFIER;

    /// @notice Mock optimistic verifier
    MockDeferredVerifier internal DEFERRED_VERIFIER;

    Commitment commitment;
    ComputeSubscription sub;

    function setUp() public override {
        super.setUp();
        IMMEDIATE_VERIFIER = new MockImmediateVerifier(ROUTER);
        DEFERRED_VERIFIER = new MockDeferredVerifier(ROUTER);
    }

    function test_RevertIf_DeliveringCompute_When_NodeWalletNotApproved() public {
        // Create new wallets
        address aliceWallet = WALLET_FACTORY.createWallet(address(ALICE));
        address bobWallet = WALLET_FACTORY.createWallet(address(BOB));

        // Mint 50 tokens to alice wallet
        TOKEN.mint(aliceWallet, 50e6);

        // Setup atomic verifier approved token + fee (5 tokens)
        // This must be done BEFORE createMockRequest, as createMockRequest calls _startBilling which checks verifier.isPaymentTokenSupported
        IMMEDIATE_VERIFIER.updateSupportedToken(address(TOKEN), true);
        IMMEDIATE_VERIFIER.updateFee(address(TOKEN), 5e6);

        // Mint 50 tokens to bob wallet (ensuring node has sufficient funds to put up for escrow)
        TOKEN.mint(bobWallet, 50e6);

        // Allow CALLBACK consumer to spend alice wallet balance up to 50e6 tokens.
        // This must be done BEFORE creating the request, as request creation locks the funds.
        vm.prank(address(ALICE));
        Wallet(payable(aliceWallet)).approve(address(CALLBACK), address(TOKEN), 50e6);

        // Create new one-time subscription with 50e6 payout
        (uint64 subId, Commitment memory commitment) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID,
            MOCK_INPUT,
            1,
            address(TOKEN),
            50e6,
            aliceWallet,
            // Specify atomic verifier
            address(IMMEDIATE_VERIFIER)
        );
        bytes memory commitmentData = abi.encode(commitment);

        // Verify initial balances and allowances
        assertEq(TOKEN.balanceOf(aliceWallet), 50e6);
        assertEq(TOKEN.balanceOf(bobWallet), 50e6);

        // Ensure that atomic verifier will return true for proof verification
        IMMEDIATE_VERIFIER.setNextValidityTrue();

        // Execute response fulfillment from Charlie expecting it to fail given no authorization to Bob's wallet
        vm.warp(1 minutes);
        vm.expectRevert(Wallet.InsufficientAllowance.selector);
        vm.prank(address(CHARLIE));
        CHARLIE.reportComputeResult(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWallet);
    }

    function test_RevertIf_DeliveringCompute_When_NodeWalletHasInsufficientFundsForEscrow() public {
        // Create new wallets
        address aliceWallet = WALLET_FACTORY.createWallet(address(ALICE));
        address bobWallet = WALLET_FACTORY.createWallet(address(BOB));

        // Mint 50 tokens to alice wallet (but not to Bob's wallet)
        TOKEN.mint(aliceWallet, 50e6);

        // Allow CALLBACK consumer to spend alice wallet balance up to 50e6 tokens
        vm.prank(address(ALICE));
        Wallet(payable(aliceWallet)).approve(address(CALLBACK), address(TOKEN), 50e6);

        // Allow BOB to sepnd bob wallet balance up to 50e6 tokens
        vm.prank(address(BOB));
        Wallet(payable(bobWallet)).approve(address(BOB), address(TOKEN), 50e6);

        // Setup atomic verifier approved token + fee (5 tokens)
        IMMEDIATE_VERIFIER.updateSupportedToken(address(TOKEN), true);
        IMMEDIATE_VERIFIER.updateFee(address(TOKEN), 5e6);

        // Create new one-time subscription with 40e6 payout
        (uint64 subId, Commitment memory commitment) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID,
            MOCK_INPUT,
            1,
            address(TOKEN),
            50e6,
            aliceWallet,
            // Specify atomic verifier
            address(IMMEDIATE_VERIFIER)
        );
        bytes memory commitmentData = abi.encode(commitment);

        // Verify initial balances and allowances
        assertEq(TOKEN.balanceOf(aliceWallet), 50e6);
        assertEq(TOKEN.balanceOf(bobWallet), 0e6);

        // Ensure that atomic verifier will return true for proof verification
        IMMEDIATE_VERIFIER.setNextValidityTrue();

        // Execute response fulfillment expecting it to fail given not enough unlocked funds
        vm.warp(1 minutes);
        vm.expectRevert(Wallet.InsufficientFunds.selector);
        BOB.reportComputeResult(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWallet);
    }

    function test_Succeeds_When_FulfillingSubscription_WithValidProof() public {
        // Create new wallets
        address aliceWallet = WALLET_FACTORY.createWallet(address(ALICE));
        address bobWallet = WALLET_FACTORY.createWallet(address(BOB));

        // Mint 50 tokens to wallets
        TOKEN.mint(aliceWallet, 50e6);
        TOKEN.mint(bobWallet, 50e6);

        // Allow CALLBACK consumer to spend alice wallet balance up to 50e6 tokens
        vm.prank(address(ALICE));
        Wallet(payable(aliceWallet)).approve(address(CALLBACK), address(TOKEN), 50e6);

        // Allow Bob to spend bob wallet balance up to 50e6 tokens
        vm.prank(address(BOB));
        Wallet(payable(bobWallet)).approve(address(BOB), address(TOKEN), 50e6);

        // Setup atomic verifier approved token + fee (5 tokens)
        IMMEDIATE_VERIFIER.updateSupportedToken(address(TOKEN), true);
        IMMEDIATE_VERIFIER.updateFee(address(TOKEN), 5e6);

        // Create new one-time subscription with 40e6 payout
        (uint64 subId, Commitment memory commitment) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID,
            MOCK_INPUT,
            1,
            address(TOKEN),
            40e6,
            aliceWallet,
            // Specify atomic verifier
            address(IMMEDIATE_VERIFIER)
        );
        bytes memory commitmentData = abi.encode(commitment);

        // Verify initial balances and allowances
        assertEq(TOKEN.balanceOf(aliceWallet), 50e6);
        assertEq(TOKEN.balanceOf(bobWallet), 50e6);

        // Ensure that atomic verifier will return true for proof verification
        IMMEDIATE_VERIFIER.setNextValidityTrue();

        // Execute response fulfillment from Bob
        vm.warp(1 minutes);
        BOB.reportComputeResult(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWallet);

        // Assert new balances
        assertEq(TOKEN.balanceOf(aliceWallet), 10e6); // -40
        assertEq(TOKEN.balanceOf(bobWallet), 80_912_000); // 50 (initial) + (40 - (40 * 5.11% * 2) - (5))
        assertEq(TOKEN.balanceOf(address(IMMEDIATE_VERIFIER)), 4_744_500); // (5 - (5 * 5.11%))
        assertEq(TOKEN.balanceOf(protocolWalletAddress), 4_343_500);

        // Assert consumed allowance
        assertEq(Wallet(payable(aliceWallet)).allowance(address(CALLBACK), address(TOKEN)), 10e6);
        assertEq(Wallet(payable(bobWallet)).allowance(address(BOB), address(TOKEN)), 50e6);
    }

    function test_Succeeds_When_FulfillingLazySubscription_WithValidProof() public {
        // Create new wallets
        address aliceWallet = WALLET_FACTORY.createWallet(address(ALICE));
        address bobWallet = WALLET_FACTORY.createWallet(address(BOB));

        // Mint 50 tokens to wallets
        TOKEN.mint(aliceWallet, 50e6);
        TOKEN.mint(bobWallet, 50e6);

        // Allow SUBSCRIPTION consumer to spend alice wallet balance up to 50e6 tokens
        vm.prank(address(ALICE));
        Wallet(payable(aliceWallet)).approve(address(SUBSCRIPTION), address(TOKEN), 50e6);

        // Allow Bob to spend bob wallet balance up to 50e6 tokens
        vm.prank(address(BOB));
        Wallet(payable(bobWallet)).approve(address(BOB), address(TOKEN), 50e6);

        // Setup atomic verifier approved token + fee (5 tokens)
        IMMEDIATE_VERIFIER.updateSupportedToken(address(TOKEN), true);
        IMMEDIATE_VERIFIER.updateFee(address(TOKEN), 5e6);

        // Create new one-time useDeliveryInbox subscription with 40e6 payout
        (uint64 subId, Commitment memory commitment) = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID,
            1, // maxExecutions
            1 minutes, // intervalSeconds
            1, // redundancy
            true, // useDeliveryInbox
            address(TOKEN),
            40e6,
            aliceWallet,
            // Specify atomic verifier
            address(IMMEDIATE_VERIFIER)
        );
        bytes memory commitmentData = abi.encode(commitment);

        // Verify initial balances and allowances
        assertEq(TOKEN.balanceOf(aliceWallet), 50e6);
        assertEq(TOKEN.balanceOf(bobWallet), 50e6);

        // Ensure that atomic verifier will return true for proof verification
        IMMEDIATE_VERIFIER.setNextValidityTrue();

        // Warp to the exact time the subscription becomes active
        vm.warp(1 minutes + 1);

        // Execute response fulfillment from Bob
        BOB.reportComputeResult(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWallet);

        // Assert new balances (same as eager subscription)
        assertEq(TOKEN.balanceOf(aliceWallet), 10e6); // -40
        assertEq(TOKEN.balanceOf(bobWallet), 80_912_000); // 50 (initial) + (40 - (40 * 5.11% * 2) - (5))
        assertEq(TOKEN.balanceOf(address(IMMEDIATE_VERIFIER)), 4_744_500); // (5 - (5 * 5.11%))
        assertEq(TOKEN.balanceOf(protocolWalletAddress), 4_343_500);

        // Assert consumed allowance
        assertEq(Wallet(payable(aliceWallet)).allowance(address(SUBSCRIPTION), address(TOKEN)), 10e6);
        assertEq(Wallet(payable(bobWallet)).allowance(address(BOB), address(TOKEN)), 50e6);

        // Assert that the delivery is stored in DeliveryInbox.sol within the SUBSCRIPTION contract
        (bool exists, PendingDelivery memory pd) = SUBSCRIPTION.getDelivery(commitment.requestId, bobWallet);
        assertTrue(exists, "Pending delivery should exist");
        assertEq(pd.subscriptionId, subId, "Pending delivery subscriptionId mismatch");
        assertEq(pd.output, MOCK_OUTPUT, "Pending delivery output mismatch");
        assertEq(pd.proof, MOCK_PROOF, "Pending delivery proof mismatch");
    }

    function test_Succeeds_When_SlashingNode_WithInvalidProof() public {
        // Create new wallets
        address aliceWallet = WALLET_FACTORY.createWallet(address(ALICE));
        address bobWallet = WALLET_FACTORY.createWallet(address(BOB));

        // Mint 1 ether to Alice and Bob
        vm.deal(address(aliceWallet), 1 ether);
        vm.deal(address(bobWallet), 1 ether);

        // Allow CALLBACK consumer to spend alice wallet balance up to 1 ether
        vm.prank(address(ALICE));
        Wallet(payable(aliceWallet)).approve(address(CALLBACK), ZERO_ADDRESS, 1 ether);

        // Allow Bob to spend bob wallet balance up to 1 ether
        vm.prank(address(BOB));
        Wallet(payable(bobWallet)).approve(address(BOB), ZERO_ADDRESS, 1 ether);

        // Verify initial balances and allowances
        assertEq(aliceWallet.balance, 1 ether);
        assertEq(bobWallet.balance, 1 ether);

        // Setup atomic verifier approved token + fee (0.111 ether)
        IMMEDIATE_VERIFIER.updateSupportedToken(ZERO_ADDRESS, true);
        IMMEDIATE_VERIFIER.updateFee(ZERO_ADDRESS, 111e15);

        // Create new one-time subscription with 40e6 payout
        (uint64 subId, Commitment memory commitment) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID,
            MOCK_INPUT,
            1,
            ZERO_ADDRESS,
            1 ether,
            aliceWallet,
            // Specify atomic verifier
            address(IMMEDIATE_VERIFIER)
        );
        bytes memory commitmentData = abi.encode(commitment);

        // Ensure that atomic verifier will return true for proof verification
        IMMEDIATE_VERIFIER.setNextValidityFalse();

        // Execute response fulfillment from Bob
        vm.warp(1 minutes);
        BOB.reportComputeResult(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWallet);

        // Assert new balances
        // Alice --> 1 ether - protocol fee (0.1022 ether) - verifier fee (0.111 ether) + slashed (1 ether) = 1.7868 ether
        assertEq(aliceWallet.balance, 17_868e14);
        // Bob --> -1 ether
        assertEq(bobWallet.balance, 0 ether);
        // verifier --> +0.111 * (1 - 0.0511) ether = 0.1053279 ether
        assertEq(IMMEDIATE_VERIFIER.ethBalance(), 1_053_279e11);
        // Protocol --> feeFromConsumer (0.1022 ether) + feeFromVerifier (0.0056721 ether) = 0.1078721 ether
        assertEq(protocolWalletAddress.balance, 1_078_721e11);

        // Assert consumed allowance
        assertEq(Wallet(payable(aliceWallet)).allowance(address(CALLBACK), ZERO_ADDRESS), 7868e14);
        assertEq(Wallet(payable(bobWallet)).allowance(address(BOB), ZERO_ADDRESS), 0 ether);
    }

    function test_Succeeds_When_SlashingNode_InOptimisticFlow_WithInvalidProof() public {
        // Create new wallets
        address aliceWallet = WALLET_FACTORY.createWallet(address(ALICE));
        address bobWallet = WALLET_FACTORY.createWallet(address(BOB));

        // Mint 1 ether to Alice and Bob
        vm.deal(address(aliceWallet), 1 ether);
        vm.deal(address(bobWallet), 1 ether);

        // Allow CALLBACK consumer to spend alice wallet balance up to 1 ether
        vm.prank(address(ALICE));
        Wallet(payable(aliceWallet)).approve(address(CALLBACK), ZERO_ADDRESS, 1 ether);

        // Allow Bob to spend bob wallet balance up to 1 ether
        vm.prank(address(BOB));
        Wallet(payable(bobWallet)).approve(address(BOB), ZERO_ADDRESS, 1 ether);

        // Verify initial balances and allowances
        assertEq(aliceWallet.balance, 1 ether);
        assertEq(bobWallet.balance, 1 ether);

        // Setup optimistic verifier approved token + fee (0.1 ether)
        DEFERRED_VERIFIER.updateSupportedToken(ZERO_ADDRESS, true);
        DEFERRED_VERIFIER.updateFee(ZERO_ADDRESS, 1e17);

        // Create new one-time subscription with 1 ether payout
        (uint64 subId, Commitment memory commitment) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID,
            MOCK_INPUT,
            1,
            ZERO_ADDRESS,
            1 ether,
            aliceWallet,
            // Specify optimistic verifier
            address(DEFERRED_VERIFIER)
        );

        bytes memory commitmentData = abi.encode(commitment);
        // Execute response fulfillment from Bob
        BOB.reportComputeResult(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWallet);

        // Assert immediate balances
        // Alice -> 1 ether - protocol fee (0.1022 ether) - verifier fee (0.1 ether)
        // Alice --> allowance: 0 ether
        assertEq(aliceWallet.balance, 7978e14);
        console.log("aliceWallet.balance : " ,aliceWallet.balance);
        console.log("aliceWallet.allowance : " ,Wallet(payable(aliceWallet)).allowance(address(CALLBACK), ZERO_ADDRESS));
//        assertEq(Wallet(payable(aliceWallet)).allowance(address(CALLBACK), ZERO_ADDRESS), 0);
        // Bob --> 1 ether
        // Bob --> allowance: 0 ether
        assertEq(bobWallet.balance, 1 ether);
        assertEq(Wallet(payable(bobWallet)).allowance(address(BOB), ZERO_ADDRESS), 0);
        // verifier --> 0.1 * (1 - 0.0511) ether = 0.09489 ether
        assertEq(DEFERRED_VERIFIER.ethBalance(), 9489e13);
        // Protocol --> feeFromConsumer (0.1022 ether) + feeFromVerifier (0.00511 ether) = 0.10731 ether
        assertEq(protocolWalletAddress.balance, 10_731e13);

        // Fast forward 1 day and trigger optimistic response with valid: false
        vm.warp(1 days);
        vm.expectEmit(address(COORDINATOR));
        emit ICoordinator.ProofVerified(subId, 1, address(BOB), false, address(DEFERRED_VERIFIER));
        DEFERRED_VERIFIER.mockFinalizeVerification(subId, 1, address(BOB), false);

        // Assert new balances
        // Alice --> 1 ether - protocol fee (0.1022 ether) - verifier fee (0.1 ether) + 1 ether (slashed from node)
        // Alice --> allowance: 1 ether - protocol fee (0.1022 ether) - verifier fee (0.1 ether)
        assertEq(aliceWallet.balance, 17_978e14);
        assertEq(Wallet(payable(aliceWallet)).allowance(address(CALLBACK), ZERO_ADDRESS), 7978e14);
        // Bob --> 0 ether
        // Bob --> allowance: 0 ether
        assertEq(bobWallet.balance, 0);
        assertEq(Wallet(payable(bobWallet)).allowance(address(BOB), ZERO_ADDRESS), 0 ether);
        // verifier, protocol stay same
        assertEq(DEFERRED_VERIFIER.ethBalance(), 9489e13);
        assertEq(protocolWalletAddress.balance, 10_731e13);
    }

}