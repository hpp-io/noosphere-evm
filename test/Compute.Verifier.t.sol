// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.23;

import {OptimisticVerifier} from "src/v1_0_0/verifier/OptimisticVerifier.sol";
import {MockImmediateVerifier} from "./mocks/verifier/MockImmediateVerifier.sol";
import {MockDeferredVerifier} from "./mocks/verifier/MockDeferredVerifier.sol";
import {Commitment} from "src/v1_0_0/types/Commitment.sol";
import {ComputeTest} from "./Compute.t.sol";
import {MockAgent} from "./mocks/MockAgent.sol";
import {IVerifier} from "src/v1_0_0/interfaces/IVerifier.sol";
import {ICoordinator} from "../src/v1_0_0/interfaces/ICoordinator.sol";
import {IOptimisticVerifier} from "../src/v1_0_0/interfaces/IOptimisticVerifier.sol";
import {Wallet} from "src/v1_0_0/wallet/Wallet.sol";
import {ImmediateFinalizeVerifier} from "src/v1_0_0/verifier/ImmediateFinalizeVerifier.sol";
import {Merkle} from "./utils/Merkle.sol";
import {console} from "forge-std/console.sol";
import {PendingDelivery} from "src/v1_0_0/types/PendingDelivery.sol";

contract ComputeVerifierTest is ComputeTest {
    using Merkle for bytes32[];

    /// @notice Mock atomic verifier
    MockImmediateVerifier internal immediateVerifier;

    /// @notice Mock optimistic verifier
    MockDeferredVerifier internal deferredVerifier;

    /// @notice Real optimistic verifier
    OptimisticVerifier internal optimisticVerifier;

    /// @notice Real immediate finalize verifier
    ImmediateFinalizeVerifier internal immediateFinalizeVerifier;

    function setUp() public override {
        super.setUp();
        immediateVerifier = new MockImmediateVerifier(ROUTER);
        deferredVerifier = new MockDeferredVerifier(ROUTER);

        optimisticVerifier = new OptimisticVerifier(address(COORDINATOR), address(this), address(this));
        immediateFinalizeVerifier = new ImmediateFinalizeVerifier(address(COORDINATOR), address(this));

        optimisticVerifier.setTokenSupported(address(erc20Token), true);
        optimisticVerifier.setTokenSupported(ZERO_ADDRESS, true);

        immediateFinalizeVerifier.setTokenSupported(address(erc20Token), true);
        immediateFinalizeVerifier.setTokenSupported(ZERO_ADDRESS, true);
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
        vm.warp(10 minutes);
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
        vm.warp(10 minutes);
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
        vm.warp(10 minutes);
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
            10 minutes, // intervalSeconds
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
        vm.warp(10 minutes);
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

    /*//////////////////////////////////////////////////////////////
                        OPTIMISTIC VERIFIER TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test 1: Verifier emits ProvisionalSubmitted on compute report.
    function test_Optimistic_ProvisionalSubmission() public {
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
            // Specify optimistic verifier
            address(optimisticVerifier)
        );
        bytes memory commitmentData = abi.encode(commitment);

        // Prepare compute report data
        bytes32 execCommitment = keccak256("optimistic_exec");
        bytes32 resultDigest = keccak256("result");
        bytes memory daBatchId = bytes("test_da_batch_id");
        bytes32 dataHash = keccak256(daBatchId);

        // Encode the proof according to the new format expected by OptimisticVerifier
        bytes memory proof = abi.encode(
            uint8(1), // version
            execCommitment,
            resultDigest,
            daBatchId,
            uint32(0), // leafIndex (not used in this test)
            bytes(""), // proofNodes (not used in this test)
            address(0), // adapter (not used in this test)
            bytes("") // adapterSig (not used in this test)
        );

        // Execute response fulfillment from Bob
        vm.warp(10 minutes);

        // Expect ProvisionalSubmitted event from the verifier
        bytes32 expectedKey = optimisticVerifier.submissionKey(subId, 1, address(bob));
        vm.expectEmit(address(optimisticVerifier));
        emit IOptimisticVerifier.ProvisionalSubmitted(
            subId, 1, address(bob), expectedKey, execCommitment, resultDigest, dataHash
        );

        bob.reportComputeResult(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, proof, commitmentData, bobWallet);
    }

    /// @notice Test 2: A submission can be challenged and slashed.
    function test_Optimistic_ChallengeAndSlash() public {
        // 1. Setup subscription, wallets, and funds
        address aliceWallet = walletFactory.createWallet(address(alice));
        address bobWallet = walletFactory.createWallet(address(bob));
        erc20Token.mint(aliceWallet, 50e6);
        erc20Token.mint(bobWallet, 50e6);
        vm.prank(address(alice));
        Wallet(payable(aliceWallet)).approve(address(transientClient), address(erc20Token), 50e6);
        vm.prank(address(bob));
        Wallet(payable(bobWallet)).approve(address(bob), address(erc20Token), 50e6);

        (uint64 subId, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_INPUT, 1, address(erc20Token), 40e6, aliceWallet, address(optimisticVerifier)
        );
        bytes memory commitmentData = abi.encode(commitment);

        // 2. Prepare invalid proof data for the node's report
        // The node will commit to a Merkle root, but the challenger will prove
        // that another leaf in that same Merkle tree does not match the reported resultDigest.
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("correct_result"); // This is the expected result
        leaves[1] = keccak256("incorrect_leaf"); // This is another leaf in the tree

        bytes32 execCommitment = leaves.getMerkleRoot(); // The Merkle root of all leaves
        bytes32 resultDigest = leaves[0]; // The node claims the result is the first leaf
        bytes memory daBatchId = bytes("challenge_da_batch_id");

        // Encode the proof for the initial report
        bytes memory reportProof = abi.encode(
            uint8(1), // version
            execCommitment,
            resultDigest,
            daBatchId,
            uint32(0), // leafIndex
            bytes(""), // proofNodes (not used for submission, only for challenge)
            address(0), // adapter
            bytes("") // adapterSig
        );

        // 3. Node reports the compute result
        vm.warp(10 minutes);
        bob.reportComputeResult(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, reportProof, commitmentData, bobWallet);

        // 4. Challenger prepares a proof for the *other* leaf to prove the inconsistency
        bytes32[] memory challengeProof = leaves.getMerkleProof(leaves[1]);

        // 5. Expect Slashed event and perform the challenge
        bytes32 expectedKey = optimisticVerifier.submissionKey(subId, 1, address(bob));
        vm.expectEmit(address(optimisticVerifier));
        emit IOptimisticVerifier.Slashed(expectedKey, address(this));

        vm.prank(address(this));
        optimisticVerifier.challengeAndSlash(subId, 1, address(bob), leaves[1], challengeProof);

        // 6. Verify state: the submission should now be marked as slashed
        IOptimisticVerifier.Submission memory s = optimisticVerifier.getSubmission(expectedKey);
        assertTrue(s.slashed, "Submission should be slashed");
    }

    /// @notice Test 3: A submission can be finalized after the challenge window.
    function test_Optimistic_FinalizeSubmission() public {
        // 1. Setup subscription, wallets, and funds
        address aliceWallet = walletFactory.createWallet(address(alice));
        address bobWallet = walletFactory.createWallet(address(bob));
        erc20Token.mint(aliceWallet, 50e6);
        erc20Token.mint(bobWallet, 50e6);
        vm.prank(address(alice));
        Wallet(payable(aliceWallet)).approve(address(transientClient), address(erc20Token), 50e6);
        vm.prank(address(bob));
        Wallet(payable(bobWallet)).approve(address(bob), address(erc20Token), 50e6);

        (uint64 subId, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_INPUT, 1, address(erc20Token), 40e6, aliceWallet, address(optimisticVerifier)
        );
        bytes memory commitmentData = abi.encode(commitment);

        // 2. Prepare and report a valid compute result
        bytes32 execCommitment = keccak256("finalizable_exec");
        bytes32 resultDigest = keccak256("finalizable_result");
        bytes memory daBatchId = bytes("finalize_da_batch_id");

        // Encode the proof according to the new format
        bytes memory proof = abi.encode(
            uint8(1), // version
            execCommitment,
            resultDigest,
            daBatchId,
            uint32(0), // leafIndex
            bytes(""), // proofNodes
            address(0), // adapter
            bytes("") // adapterSig
        );

        vm.warp(10 minutes);
        bob.reportComputeResult(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, proof, commitmentData, bobWallet);

        // 3. Warp time to after the challenge window has passed
        uint256 challengeWindow = optimisticVerifier.defaultChallengeWindow();
        vm.warp(block.timestamp + challengeWindow + 1);

        // 4. Expect Finalized event and finalize the submission (anyone can call this)
        bytes32 expectedKey = optimisticVerifier.submissionKey(subId, 1, address(bob));
        vm.expectEmit(address(optimisticVerifier));
        emit IOptimisticVerifier.SubmissionFinalized(expectedKey, subId, 1, address(bob));

        vm.prank(address(this));
        optimisticVerifier.finalizeSubmission(subId, 1, address(bob));

        // 5. Verify state: the submission should now be marked as finalized
        IOptimisticVerifier.Submission memory s = optimisticVerifier.getSubmission(expectedKey);
        assertTrue(s.finalized, "Submission should be finalized");
    }

    /// @notice Test: A submission can be immediately finalized using ImmediateFinalizeVerifier.
    ///         This test is similar to test_Optimistic_ProvisionalSubmission but uses ImmediateFinalizeVerifier.
    function test_ImmediateFinalize_SuccessfulSubmission() public {
        // solhint-disable-line function-max-lines
        // The node is represented by an EOA (bob) that owns a smart contract wallet (nodeWallet).
        uint256 bobPrivateKey = 0x2;
        address bob = vm.addr(bobPrivateKey);
        vm.label(bob, "Bob (EOA)");

        // 1. Setup wallets, mint tokens, and set approvals
        address aliceWallet = walletFactory.createWallet(address(alice));
        address nodeWallet = walletFactory.createWallet(bob); // The CA wallet is owned by Bob (EOA)
        vm.label(nodeWallet, "NodeWallet (CA)");

        erc20Token.mint(aliceWallet, 50e6);
        erc20Token.mint(nodeWallet, 50e6);

        vm.prank(address(alice));
        Wallet(payable(aliceWallet)).approve(address(transientClient), address(erc20Token), 50e6);

        // Bob (EOA owner) approves himself to spend from his wallet for the escrow lock.
        vm.prank(bob);
        Wallet(payable(nodeWallet)).approve(bob, address(erc20Token), 50e6);

        // 2. Create a one-time subscription with a 40e6 payout, specifying ImmediateFinalizeVerifier
        (uint64 subId, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID,
            MOCK_INPUT,
            1,
            address(erc20Token),
            40e6,
            aliceWallet,
            address(immediateFinalizeVerifier) // Use the real ImmediateFinalizeVerifier
        );
        bytes memory commitmentData = abi.encode(commitment);

        // 3. Prepare proof data for EIP-712 signature
        bytes32 requestId = commitment.requestId; // This is an arbitrary off-chain identifier
        bytes32 commitmentHash = keccak256(commitmentData);
        bytes32 inputHash = keccak256(MOCK_INPUT);
        bytes32 resultHash = keccak256(MOCK_OUTPUT);
        uint256 timestamp = block.timestamp + 10 minutes;

        // 4. Create the EIP-712 digest for the node (Bob) to sign
        bytes32 digest = immediateFinalizeVerifier.getTypedDataHash(
            // The `nodeAddress` in the struct MUST be the EOA that is actually signing the message.
            immediateFinalizeVerifier.getStructHash(requestId, commitmentHash, inputHash, resultHash, bob, timestamp)
        );

        // 5. Sign the digest with Bob's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPrivateKey, digest); // solhint-disable-line var-name-mixedcase
        bytes memory signature = abi.encodePacked(r, s, v);

        // 6. Encode the proof as expected by ImmediateFinalizeVerifier
        // The proof now includes the EOA's address, which is the intended signer.
        bytes memory proof = abi.encode(requestId, commitmentHash, inputHash, resultHash, bob, timestamp, signature);
        // 7. Execute response fulfillment from Bob
        vm.warp(timestamp);
        // Check for the VerificationRequested event from the verifier
        //        vm.expectEmit(true, true, true, true, address(immediateFinalizeVerifier));
        //        emit IVerifier.VerificationRequested(subId, 1, nodeWallet);
        // Check for the final ComputeDelivered event from the coordinator
        vm.expectEmit(true, false, false, true, address(COORDINATOR));
        emit ICoordinator.ComputeDelivered(commitment.requestId, nodeWallet, 1);

        // 9. Bob reports the compute result
        // The EOA `bob` initiates the transaction by calling the Coordinator directly.
        // This ensures msg.sender is the EOA, which is required for the escrow lock approval check.
        vm.startPrank(bob);
        COORDINATOR.reportComputeResult(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, proof, commitmentData, nodeWallet);
        vm.stopPrank();

        // 10. Assert final balances
        // Alice's wallet: 50e6 (initial) - 40e6 (payment) = 10e6
        assertEq(erc20Token.balanceOf(aliceWallet), 10e6);

        // Bob's wallet: 50e6 (initial) + 35,920,000 (payment after fees) = 85,920,000
        // Payment: 40e6
        // Protocol fee: 40e6 * 0.0511 * 2 = 4,088,000
        // Verifier fee: 0 (ImmediateFinalizeVerifier has no fee)
        // Net to Bob: 40e6 - 4,088,000 = 35,912,000
        // Total: 50,000,000 + 35,912,000 = 85,912,000
        assertEq(erc20Token.balanceOf(nodeWallet), 85_912_000);

        // Verifier's balance should be 0 as it has no fee and doesn't receive funds
        assertEq(erc20Token.balanceOf(address(immediateFinalizeVerifier)), 0);

        // Protocol wallet: 4,088,000 (fees from payment)
        assertEq(erc20Token.balanceOf(protocolWalletAddress), 4_088_000);

        // 11. Assert consumed allowances
        // Alice's allowance for the client should be reduced by 40e6
        assertEq(Wallet(payable(aliceWallet)).allowance(address(transientClient), address(erc20Token)), 10e6);

        // Bob's allowance for himself should remain as the lock/unlock for verification is atomic
        // and doesn't consume allowance in the same way.
        assertEq(Wallet(payable(nodeWallet)).allowance(bob, address(erc20Token)), 50e6);
    }

    /// @notice Test: Reverts if the proof signature is from the wrong EOA.
    function test_RevertIf_ImmediateFinalize_WithInvalidSignature() public {
        // solhint-disable-line function-max-lines
        // The node is represented by an EOA (bob) that owns a smart contract wallet (nodeWallet).
        uint256 bobPrivateKey = 0x2;
        address bob = vm.addr(bobPrivateKey);
        vm.label(bob, "Bob (EOA)");

        // The attacker is Charlie
        uint256 charliePrivateKey = 0x3;
        address charlie = vm.addr(charliePrivateKey);
        vm.label(charlie, "Charlie (Attacker EOA)");

        // 1. Setup wallets and funds
        address aliceWallet = walletFactory.createWallet(address(alice));
        address nodeWallet = walletFactory.createWallet(bob);
        erc20Token.mint(aliceWallet, 50e6);
        erc20Token.mint(nodeWallet, 50e6);
        vm.prank(address(alice));
        Wallet(payable(aliceWallet)).approve(address(transientClient), address(erc20Token), 50e6);
        vm.prank(bob);
        Wallet(payable(nodeWallet)).approve(bob, address(erc20Token), 50e6);

        // 2. Create a subscription
        (, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_INPUT, 1, address(erc20Token), 40e6, aliceWallet, address(immediateFinalizeVerifier)
        );
        bytes memory commitmentData = abi.encode(commitment);

        // 3. Prepare proof data, but sign it with the WRONG key (Charlie's)
        bytes32 requestId = commitment.requestId;
        bytes32 commitmentHash = keccak256(commitmentData);
        bytes32 inputHash = keccak256(MOCK_INPUT);
        bytes32 resultHash = keccak256(MOCK_OUTPUT);
        uint256 timestamp = block.timestamp + 10 minutes;

        bytes32 digest = immediateFinalizeVerifier.getTypedDataHash(
            immediateFinalizeVerifier.getStructHash(requestId, commitmentHash, inputHash, resultHash, bob, timestamp)
        );

        // Charlie signs the digest, not Bob.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(charliePrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes memory proof = abi.encode(requestId, commitmentHash, inputHash, resultHash, bob, timestamp, signature);

        // 4. Expect the transaction to revert with InvalidEOASignature
        vm.warp(timestamp);
        vm.startPrank(bob);
        vm.expectEmit(true, true, true, true, address(immediateFinalizeVerifier));
        emit ImmediateFinalizeVerifier.VerificationFailed(
            commitment.subscriptionId, commitment.interval, bob, "signer_mismatch"
        );
        COORDINATOR.reportComputeResult(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, proof, commitmentData, nodeWallet);
        vm.stopPrank();

        // 5. Assert final balances after slashing
        // Alice's wallet: 50e6 (initial) - 4,088,000 (protocol fee) + 40e6 (slashed funds) = 85,912,000
        // The original 40e6 payment is refunded, and an additional 40e6 is received from the slashed node.
        assertEq(erc20Token.balanceOf(aliceWallet), 85_912_000, "Alice's balance is incorrect");

        // Bob's wallet (node): 50e6 (initial) - 40e6 (slashed) = 10e6
        assertEq(erc20Token.balanceOf(nodeWallet), 10_000_000, "Bob's balance is incorrect");

        // Verifier's balance should be 0
        assertEq(erc20Token.balanceOf(address(immediateFinalizeVerifier)), 0, "Verifier's balance should be 0");

        // Protocol wallet: 4,088,000 (fees from the original payment attempt)
        assertEq(erc20Token.balanceOf(protocolWalletAddress), 4_088_000, "Protocol wallet balance is incorrect");

        // 6. Assert consumed allowances
        // Alice's allowance is partially consumed by the protocol fee.
        // Initial: 50e6, Consumed: 4,088,000, Remaining: 45,912,000
        assertEq(
            Wallet(payable(aliceWallet)).allowance(address(transientClient), address(erc20Token)),
            45_912_000,
            "Alice's allowance is incorrect"
        );

        // Bob's allowance is consumed by the escrow lock.
        // Initial: 50e6, Consumed by lockEscrow: 40e6, Remaining: 10e6
        assertEq(
            Wallet(payable(nodeWallet)).allowance(bob, address(erc20Token)), 10_000_000, "Bob's allowance is incorrect"
        );
    }

    /// @notice Test: Reverts if the nodeAddress in the proof data does not match the signer.
    function test_RevertIf_ImmediateFinalize_WithMismatchedNodeAddress() public {
        // solhint-disable-line function-max-lines
        uint256 bobPrivateKey = 0x2;
        address bob = vm.addr(bobPrivateKey);
        vm.label(bob, "Bob (EOA)");

        address randomAddress = vm.addr(0x99);
        vm.label(randomAddress, "Random Address");

        // 1. Setup wallets and funds
        address aliceWallet = walletFactory.createWallet(address(alice));
        address nodeWallet = walletFactory.createWallet(bob);
        erc20Token.mint(aliceWallet, 50e6);
        erc20Token.mint(nodeWallet, 50e6);
        vm.prank(address(alice));
        Wallet(payable(aliceWallet)).approve(address(transientClient), address(erc20Token), 50e6);
        vm.prank(bob);
        Wallet(payable(nodeWallet)).approve(bob, address(erc20Token), 50e6);
        immediateFinalizeVerifier.setFee(address(erc20Token), 5e6);

        // 2. Create a subscription
        (, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_INPUT, 1, address(erc20Token), 40e6, aliceWallet, address(immediateFinalizeVerifier)
        );
        bytes memory commitmentData = abi.encode(commitment);

        // 3. Prepare proof data where `nodeAddress` is a random address, not Bob's.
        bytes32 requestId = commitment.requestId;
        bytes32 commitmentHash = keccak256(commitmentData);
        bytes32 inputHash = keccak256(MOCK_INPUT);
        bytes32 resultHash = keccak256(MOCK_OUTPUT);
        uint256 timestamp = block.timestamp + 10 minutes;

        // The digest is created with the wrong address.
        bytes32 digest = immediateFinalizeVerifier.getTypedDataHash(
            immediateFinalizeVerifier.getStructHash(
                requestId, commitmentHash, inputHash, resultHash, randomAddress, timestamp
            )
        );

        // Bob signs this digest.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // The proof is encoded with the wrong address.
        bytes memory proof =
            abi.encode(requestId, commitmentHash, inputHash, resultHash, randomAddress, timestamp, signature);

        // 4. Expect a `VerificationFailed` event because the recovered signer (Bob) will not match `proofData.nodeAddress` (randomAddress).
        // The transaction itself should not revert, but the verifier will report the failure to the coordinator.
        vm.warp(timestamp);
        vm.startPrank(bob);
        vm.expectEmit(true, true, true, true, address(immediateFinalizeVerifier));
        emit ImmediateFinalizeVerifier.VerificationFailed(
            commitment.subscriptionId, commitment.interval, bob, "signer_mismatch"
        );
        COORDINATOR.reportComputeResult(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, proof, commitmentData, nodeWallet);
        vm.stopPrank();

        // 5. Assert final balances after slashing
        // Alice's wallet: 50e6 (initial) - 4,088,000 (protocol fee) - 5e6 (verifier fee) + 40e6 (slashed funds) = 80,912,000
        // The original 40e6 payment is refunded, and an additional 40e6 is received from the slashed node.
        assertEq(erc20Token.balanceOf(aliceWallet), 80_912_000, "Alice's balance is incorrect");

        // Bob's wallet (node): 50e6 (initial) - 40e6 (slashed) = 10e6
        assertEq(erc20Token.balanceOf(nodeWallet), 10_000_000, "Bob's balance is incorrect");

        // Verifier fee: 5e6 - (5e6 * 5.11%) = 4,744,500
        assertEq(
            erc20Token.balanceOf(address(immediateFinalizeVerifier)),
            4_744_500,
            "Verifier's balance should be incorrect"
        );

        // Protocol wallet: 4,088,000 (fees from the original payment attempt)
        // Protocol fee: 4,088,000 (from payment) + 255,500 (from verifier fee) = 4,343,500
        assertEq(erc20Token.balanceOf(protocolWalletAddress), 4_343_500, "Protocol wallet balance is incorrect");

        // 6. Assert consumed allowances
        // Alice's allowance is partially consumed by the protocol fee.
        // Initial: 50e6, Consumed: 4,088,000 (protocol) + 5,000,000 (verifier) = 9,088,000. Remaining: 40,912,000
        uint256 expectedAliceAllowance = 50e6 - 4_088_000 - 5e6;
        assertEq(
            Wallet(payable(aliceWallet)).allowance(address(transientClient), address(erc20Token)),
            expectedAliceAllowance,
            "Alice's allowance is incorrect"
        );

        // Bob's allowance is consumed by the escrow lock.
        // Initial: 50e6, Consumed by lockEscrow: 40e6, Remaining: 10e6
        assertEq(
            Wallet(payable(nodeWallet)).allowance(bob, address(erc20Token)), 10_000_000, "Bob's allowance is incorrect"
        );
    }

    /// @notice Test: Reverts if the commitment hash in the proof does not match the one from the Coordinator.
    function test_RevertIf_ImmediateFinalize_WithMismatchedCommitmentHash() public {
        uint256 bobPrivateKey = 0x2;
        address bob = vm.addr(bobPrivateKey);

        // 1. Setup wallets and funds
        address aliceWallet = walletFactory.createWallet(address(alice));
        address nodeWallet = walletFactory.createWallet(bob);
        erc20Token.mint(aliceWallet, 50e6);
        erc20Token.mint(nodeWallet, 50e6); // Fund the node's wallet
        vm.prank(address(alice));
        Wallet(payable(aliceWallet)).approve(address(transientClient), address(erc20Token), 50e6);
        vm.prank(bob);
        Wallet(payable(nodeWallet)).approve(bob, address(erc20Token), 50e6); // Approve the node to spend from its own wallet

        // 2. Create a subscription
        (, Commitment memory commitment) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_INPUT, 1, address(erc20Token), 40e6, aliceWallet, address(immediateFinalizeVerifier)
        );
        bytes memory commitmentData = abi.encode(commitment);

        // 3. Create a proof with a FAKE commitment hash.
        bytes32 fakeCommitmentHash = keccak256("fake");
        bytes32 digest = immediateFinalizeVerifier.getTypedDataHash(
            immediateFinalizeVerifier.getStructHash(
                commitment.requestId,
                fakeCommitmentHash,
                keccak256(MOCK_INPUT),
                keccak256(MOCK_OUTPUT),
                bob,
                block.timestamp
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPrivateKey, digest);
        bytes memory proof = abi.encode(
            commitment.requestId,
            fakeCommitmentHash,
            keccak256(MOCK_INPUT),
            keccak256(MOCK_OUTPUT),
            bob,
            block.timestamp,
            abi.encodePacked(r, s, v)
        );

        // 4. Expect revert because the hash from the proof will not match the hash from the coordinator's parameters.
        vm.startPrank(bob);
        vm.expectEmit(true, true, true, true, address(immediateFinalizeVerifier));
        emit ImmediateFinalizeVerifier.VerificationFailed(
            commitment.subscriptionId, commitment.interval, bob, "commitmentHash_mismatch"
        );
        COORDINATOR.reportComputeResult(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, proof, commitmentData, nodeWallet);
        vm.stopPrank();
    }
}
