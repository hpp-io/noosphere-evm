// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {ComputeSubscription} from "../src/v1_0_0/types/ComputeSubscription.sol";
import {Coordinator} from "../src/v1_0_0/Coordinator.sol";
import {Commitment} from "../src/v1_0_0/types/Commitment.sol";
import {CoordinatorConstants} from "./Compute.t.sol";
import {ICoordinator} from "../src/v1_0_0/interfaces/ICoordinator.sol";
import {DelegateeCoordinator} from "../src/v1_0_0/DelegateeCoordinator.sol";
import {DeliveredOutput} from "./mocks/client/MockComputeClient.sol";
import {DeployUtils} from "./lib/DeployUtils.sol";
import {EIP712Utils} from "./lib/EIP712Utils.sol";
import {MockDelegatorScheduledComputeClient} from "./mocks/client/MockDelegatorScheduledComputeClient.sol";
import {MockDelegatorTransientComputeClient} from "./mocks/client/MockDelegatorTransientComputeClient.sol";
import {MockAgent} from "./mocks/MockAgent.sol";
import {MockProtocol} from "./mocks/MockProtocol.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {PendingDelivery} from "src/v1_0_0/types/PendingDelivery.sol";
import {SubscriptionBatchReader} from "../src/v1_0_0/utility/SubscriptionBatchReader.sol";
import {RequestIdUtils} from "../src/v1_0_0/utility/RequestIdUtils.sol";
import {Router} from "../src/v1_0_0/Router.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {WalletFactory} from "../src/v1_0_0/wallet/WalletFactory.sol";

/// @title Delegatee compute integration tests (refactored)
/// @notice Tests the delegated subscription flow and delegated delivery paths.
/// @dev Variable names and comments are refactored for clarity; behavior preserved.
contract DelegateeComputeTestRefactored is Test, CoordinatorConstants {
    /*//////////////////////////////////////////////////////////////
                                CONTRACT REFERENCES
    //////////////////////////////////////////////////////////////*/

    /// @notice Mock protocol helper contract
    MockProtocol internal protocolMock;

    /// @notice Router reference
    Router internal router;

    /// @notice Coordinator (delegatee-capable)
    DelegateeCoordinator internal coordinator;

    /// @notice Wallet factory for user / node wallets
    WalletFactory internal walletFactory;

    /// @notice ERC20 token used for protocol fees in tests
    MockToken internal token;

    /*//////////////////////////////////////////////////////////////
                               MOCK NODES / CLIENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Node actors
    MockAgent internal nodeAlice;
    MockAgent internal nodeBob;
    MockAgent internal nodeCharlie;

    /// @notice Transient compute client that uses a delegator pattern
    MockDelegatorTransientComputeClient private transientClient;

    /// @notice Subscription-style client that accepts pending deliveries (inbox)
    MockDelegatorScheduledComputeClient private subscriptionClient;

    /*//////////////////////////////////////////////////////////////
                                  ADDRESSES / KEYS
    //////////////////////////////////////////////////////////////*/

    /// @notice Delegatee EOA and key used for signing delegated enrollment messages
    address private delegateeAddr;
    uint256 private delegateeKey;

    /// @notice Backup delegatee EOA and key (used to simulate signer rotation)
    address private backupDelegateeAddr;
    uint256 private backupDelegateeKey;

    /// @notice Wallet addresses used in tests
    address internal userWalletAddr;
    address internal aliceWalletAddr;
    address internal bobWalletAddr;
    address internal protocolWalletAddr;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy and initialize fixture contracts and mocks
    function setUp() public {
        // Pre-compute wallet factory owner address via CREATE address derivation
        uint256 initialNonce = vm.getNonce(address(this));
        address ownerProtocolWalletAddress = vm.computeCreateAddress(address(this), initialNonce + 4);

        // Deploy core contracts and supporting utilities via helper
        DeployUtils.DeployedContracts memory contracts =
            DeployUtils.deployContracts(address(this), ownerProtocolWalletAddress, MOCK_PROTOCOL_FEE, address(token));
        router = contracts.router;
        coordinator = contracts.coordinator;
        walletFactory = contracts.walletFactory;

        router.setWalletFactory(address(contracts.walletFactory));

        // instantiate mocks used by tests
        protocolMock = new MockProtocol(Coordinator(address(contracts.coordinator)));
        token = new MockToken();

        // create and register mock nodes
        nodeAlice = new MockAgent(router);
        nodeBob = new MockAgent(router);
        nodeCharlie = new MockAgent(router);

        // create wallets for test actors
        userWalletAddr = walletFactory.createWallet(address(this));
        aliceWalletAddr = walletFactory.createWallet(address(this));
        bobWalletAddr = walletFactory.createWallet(address(this));
        protocolWalletAddr = walletFactory.createWallet(ownerProtocolWalletAddress);

        // configure billing settings for coordinator (protocol fee recipient / wallet)
        DeployUtils.updateBillingConfig(
            coordinator, 1 weeks, protocolWalletAddr, MOCK_PROTOCOL_FEE, 0 ether, address(0)
        );

        // setup delegatee and backup keys/addresses
        delegateeKey = 0xA11CE;
        delegateeAddr = vm.addr(delegateeKey);

        backupDelegateeKey = 0xB0B;
        backupDelegateeAddr = vm.addr(backupDelegateeKey);

        // initialize clients with assigned delegator signer
        transientClient = new MockDelegatorTransientComputeClient(address(router), delegateeAddr);
        subscriptionClient = new MockDelegatorScheduledComputeClient(address(router), delegateeAddr);

        // Optionally initialize allowlist consumer variants etc.
        // (commented out in this test fixture)
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Build a default, valid ComputeSubscription payload used by tests.
    /// @dev This returns a memory instance matching the on-chain ComputeSubscription layout.
    function mockSubscription() public view returns (ComputeSubscription memory) {
        return ComputeSubscription({
            activeAt: uint32(block.timestamp),
            client: address(transientClient),
            redundancy: 1,
            maxExecutions: 1,
            intervalSeconds: 0,
            containerId: HASHED_MOCK_CONTAINER_ID,
            useDeliveryInbox: false,
            verifier: payable(NO_VERIFIER),
            feeAmount: 0,
            feeToken: NO_PAYMENT_TOKEN,
            wallet: payable(userWalletAddr),
            routeId: "Coordinator_v1.0.0"
        });
    }

    /// @notice Compute the EIP-712 typed data digest for a delegated subscription payload.
    /// @param nonce delegated payload nonce used by the subscriber contract
    /// @param expiry expiry timestamp of the signature
    /// @param sub subscription payload being signed
    /// @return typed EIP-712 digest that should be signed/off-chain recovered
    function buildTypedMessage(uint32 nonce, uint32 expiry, ComputeSubscription memory sub)
        public
        view
        returns (bytes32)
    {
        return EIP712Utils.buildTypedDataHash(
            router.EIP712_NAME(), router.EIP712_VERSION(), address(router), nonce, expiry, sub
        );
    }

    /// @notice Convenience flow: create a delegated subscription via EIP-712 signature
    /// @param nonce delegated nonce
    /// @return subscriptionId the created or existing subscription id
    function createDelegatedSubscriptionEIP712(uint32 nonce) public returns (uint64) {
        uint64 expectedId = router.getLastSubscriptionId() + 1;

        ComputeSubscription memory sub = mockSubscription();

        uint32 maxSubscriberNonce = router.maxSubscriberNonce(sub.client);
        uint32 expiry = uint32(block.timestamp) + 30 minutes;

        bytes32 typed = buildTypedMessage(nonce, expiry, sub);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegateeKey, typed);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint64 subscriptionId = router.createSubscriptionDelegatee(0, expiry, sub, signature);
        assertEq(subscriptionId, expectedId);

        // verify stored subscription fields mirror input
        ComputeSubscription memory stored = router.getComputeSubscription(expectedId);
        assertEq(sub.activeAt, stored.activeAt);
        assertEq(sub.client, stored.client);
        assertEq(sub.redundancy, stored.redundancy);
        assertEq(sub.maxExecutions, stored.maxExecutions);
        assertEq(sub.intervalSeconds, stored.intervalSeconds);
        assertEq(sub.containerId, stored.containerId);
        assertEq(sub.useDeliveryInbox, stored.useDeliveryInbox);
        assertEq(sub.verifier, stored.verifier);
        assertEq(sub.feeToken, stored.feeToken);
        assertEq(sub.feeAmount, stored.feeAmount);
        assertEq(sub.wallet, stored.wallet);

        // nonce tracking: ensure router recorded maxSubscriberNonce appropriately
        if (nonce > maxSubscriberNonce) {
            assertEq(router.maxSubscriberNonce(address(transientClient)), nonce);
        } else {
            assertEq(router.maxSubscriberNonce(address(transientClient)), maxSubscriberNonce);
        }

        // ensure delegate-created id mapping set
        assertEq(
            router.delegateCreatedIds(keccak256(abi.encodePacked(address(transientClient), nonce))), subscriptionId
        );
        return subscriptionId;
    }

    /*//////////////////////////////////////////////////////////////
                                 TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Creating a delegated subscription must revert if the signature has expired
    function test_RevertsIf_CreateDelegatedSubscription_WithExpiredSignature() public {
        ComputeSubscription memory sub = mockSubscription();
        uint32 expiry = uint32(block.timestamp) + 30 minutes;

        bytes32 typed = buildTypedMessage(0, expiry, sub);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegateeKey, typed);
        bytes memory signature = abi.encodePacked(r, s, v);

        // advance time past expiry and expect revert
        vm.warp(expiry + 1 seconds);
        vm.expectRevert(bytes("SignatureExpired()"));
        router.createSubscriptionDelegatee(0, expiry, sub, signature);
    }

    /// @notice Creating delegated subscription with a mismatched signer should revert
    function testFuzz_RevertsIf_CreateDelegatedSubscription_WithMismatchedSignature(uint256 privateKey) public {
        // Ensure supplied key is different and valid
        vm.assume(privateKey != delegateeKey);
        vm.assume(privateKey < SECP256K1_ORDER);
        vm.assume(privateKey != 0);

        ComputeSubscription memory sub = mockSubscription();
        uint32 expiry = uint32(block.timestamp) + 30 minutes;
        bytes32 typed = buildTypedMessage(0, expiry, sub);

        // sign with an unrelated key and expect signer mismatch
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, typed);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(bytes("SignerMismatch()"));
        router.createSubscriptionDelegatee(0, expiry, sub, signature);
    }

    /// @notice Successfully create a delegated subscription via EIP-712 valid signature
    function test_Succeeds_When_CreatingNewSubscription_ViaEIP712() public {
        ComputeSubscription memory sub = mockSubscription();
        uint32 expiry = uint32(block.timestamp) + 30 minutes;
        bytes32 typed = buildTypedMessage(0, expiry, sub);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegateeKey, typed);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint64 subscriptionId = router.createSubscriptionDelegatee(0, expiry, sub, signature);
        assertEq(subscriptionId, 1);

        ComputeSubscription memory stored = router.getComputeSubscription(1);
        assertEq(sub.activeAt, stored.activeAt);
        assertEq(sub.client, stored.client);
        assertEq(sub.redundancy, stored.redundancy);
        assertEq(sub.maxExecutions, stored.maxExecutions);
        assertEq(sub.intervalSeconds, stored.intervalSeconds);
        assertEq(sub.containerId, stored.containerId);
        assertEq(sub.useDeliveryInbox, stored.useDeliveryInbox);
        assertEq(sub.verifier, stored.verifier);
        assertEq(sub.feeToken, stored.feeToken);
        assertEq(sub.feeAmount, stored.feeAmount);
        assertEq(sub.wallet, stored.wallet);

        // verify nonce/bookkeeping
        assertEq(router.maxSubscriberNonce(address(transientClient)), 0);
        assertEq(router.delegateCreatedIds(keccak256(abi.encodePacked(address(transientClient), uint32(0)))), 1);
    }

    /// @notice When the client rotates its signer, previously signed delegated requests should be rejected
    function test_RevertsIf_CreateDelegatedSubscription_FromOldSigner() public {
        ComputeSubscription memory sub = mockSubscription();
        uint32 expiry = uint32(block.timestamp) + 30 minutes;
        bytes32 typed = buildTypedMessage(0, expiry, sub);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegateeKey, typed);
        bytes memory signature = abi.encodePacked(r, s, v);

        // client updates its signer to a new (backup) address
        transientClient.updateMockSigner(backupDelegateeAddr);
        assertEq(transientClient.getSigner(), backupDelegateeAddr);
        // even a previously valid signature must now revert (signer mismatch)
        vm.expectRevert(bytes("SignerMismatch()"));
        router.createSubscriptionDelegatee(0, expiry, sub, signature);
    }

    /// @notice An already-created delegated subscription should be replayable (idempotent) even after signer rotation
    function test_ReplaysExistingDelegatedSubscription_FromOldSigner() public {
        ComputeSubscription memory sub = mockSubscription();
        uint32 expiry = uint32(block.timestamp) + 30 minutes;
        bytes32 typed = buildTypedMessage(0, expiry, sub);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegateeKey, typed);
        bytes memory signature = abi.encodePacked(r, s, v);

        // first creation succeeds
        uint64 subscriptionId = router.createSubscriptionDelegatee(0, expiry, sub, signature);
        assertEq(subscriptionId, 1);

        // client rotates signer
        transientClient.updateMockSigner(backupDelegateeAddr);
        assertEq(transientClient.getSigner(), backupDelegateeAddr);

        // replaying the same signed payload should return the existing subscription id
        subscriptionId = router.createSubscriptionDelegatee(0, expiry, sub, signature);
        assertEq(subscriptionId, 1);
    }

    /// @notice Reusing the same nonce should be idempotent — second attempt returns existing subscription and does not mutate it.
    function test_CreateDelegatedSubscription_IsIdempotent_ForReusedNonce() public {
        uint32 nonce = 0;
        ComputeSubscription memory sub = mockSubscription();
        uint32 expiry = uint32(block.timestamp) + 30 minutes;
        bytes32 typed = buildTypedMessage(nonce, expiry, sub);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegateeKey, typed);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint64 subscriptionId = router.createSubscriptionDelegatee(nonce, expiry, sub, signature);
        assertEq(subscriptionId, 1);

        // create another payload with different redundancy but same nonce
        sub = mockSubscription();
        uint16 originalRedundancy = sub.redundancy;
        sub.redundancy = 5;

        // sign and attempt to create with same nonce
        typed = buildTypedMessage(nonce, expiry, sub);
        (v, r, s) = vm.sign(delegateeKey, typed);
        signature = abi.encodePacked(r, s, v);

        subscriptionId = router.createSubscriptionDelegatee(nonce, expiry, sub, signature);
        // should return the existing id and not update redundancy
        assertEq(subscriptionId, 1);
        ComputeSubscription memory stored = router.getComputeSubscription(subscriptionId);
        assertEq(stored.redundancy, originalRedundancy);

        // rotating signer and attempting to use same nonce with a different signer must also not overwrite
        transientClient.updateMockSigner(backupDelegateeAddr);
        (v, r, s) = vm.sign(backupDelegateeKey, typed);
        signature = abi.encodePacked(r, s, v);
        subscriptionId = router.createSubscriptionDelegatee(nonce, expiry, sub, signature);

        assertEq(subscriptionId, 1);
        stored = router.getComputeSubscription(subscriptionId);
        assertEq(stored.redundancy, originalRedundancy);
    }

    /// @notice Delegated subscription creation should accept out-of-order nonces (non-monotonic), but maxSubscriberNonce should track the maximum seen nonce.
    function test_Succeeds_When_CreatingDelegatedSubscription_WithUnorderedNonces() public {
        // create with nonce 10
        uint32 nonce = 10;
        ComputeSubscription memory sub = mockSubscription();
        uint32 expiry = uint32(block.timestamp) + 30 minutes;
        bytes32 typed = buildTypedMessage(nonce, expiry, sub);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegateeKey, typed);
        bytes memory signature = abi.encodePacked(r, s, v);
        uint64 subscriptionId = router.createSubscriptionDelegatee(nonce, expiry, sub, signature);
        assertEq(subscriptionId, 1);
        assertEq(router.maxSubscriberNonce(sub.client), 10);

        // create with nonce 1 (older)
        nonce = 1;
        sub = mockSubscription();
        expiry = uint32(block.timestamp) + 30 minutes;
        typed = buildTypedMessage(nonce, expiry, sub);
        (v, r, s) = vm.sign(delegateeKey, typed);
        signature = abi.encodePacked(r, s, v);
        subscriptionId = router.createSubscriptionDelegatee(nonce, expiry, sub, signature);
        assertEq(subscriptionId, 2);
        // maxSubscriberNonce should remain 10
        assertEq(router.maxSubscriberNonce(sub.client), 10);

        // replay nonce 10 should return existing subscription id (1)
        nonce = 10;
        sub = mockSubscription();
        expiry = uint32(block.timestamp) + 30 minutes;
        typed = buildTypedMessage(nonce, expiry, sub);
        (v, r, s) = vm.sign(delegateeKey, typed);
        signature = abi.encodePacked(r, s, v);
        subscriptionId = router.createSubscriptionDelegatee(nonce, expiry, sub, signature);
        assertEq(subscriptionId, 1);
    }

    /// @notice Cancel a subscription created via delegate by calling cancel from the client.
    function test_Succeeds_When_CancellingSubscription_CreatedViaDelegate() public {
        uint64 subscriptionId = createDelegatedSubscriptionEIP712(0);

        // impersonate client and cancel
        vm.startPrank(address(transientClient));
        router.cancelComputeSubscription(subscriptionId);

        ComputeSubscription memory stored = router.getComputeSubscription(1);
        // After cancellation, the subscription should be deleted, and its client address reset to the default (zero).
        assertEq(stored.client, address(0));
    }

    /// @notice Deliver a compute response atomically while creating a subscription (delegatee path)
    function test_Succeeds_When_AtomicallyCreatingSubscriptionAndDeliveringOutput() public {
        uint32 nonce = router.maxSubscriberNonce(address(transientClient));
        ComputeSubscription memory sub = mockSubscription();
        uint32 expiry = uint32(block.timestamp) + 30 minutes;
        bytes32 typed = buildTypedMessage(nonce, expiry, sub);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegateeKey, typed);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint32 deliveryInterval = 1;
        // Alice delivers using the delegatee flow; this will create subscription and deliver output
        nodeAlice.reportDelegatedComputeResult(
            nonce, expiry, sub, signature, deliveryInterval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, aliceWalletAddr
        );

        DeliveredOutput memory out = transientClient.getDeliveredOutput(1, deliveryInterval, 1);
        assertEq(out.subscriptionId, 1);
        assertEq(out.interval, deliveryInterval);
        assertEq(out.redundancy, 1);
        assertEq(out.input, MOCK_INPUT);
        assertEq(out.output, MOCK_OUTPUT);
        assertEq(out.proof, MOCK_PROOF);

        bytes32 key = keccak256(abi.encode(uint64(1), deliveryInterval, address(nodeAlice)));
        assertEq(coordinator.nodeResponded(key), true);
    }

    /// @notice When a subscription requests inbox delivery, the delegated delivery should store the pending delivery in the client's inbox.
    function test_Succeeds_When_AtomicallyCreatingLazySubscriptionAndDeliveringOutput() public {
        uint32 nonce = router.maxSubscriberNonce(address(subscriptionClient));
        ComputeSubscription memory sub = mockSubscription();
        sub.client = address(subscriptionClient);
        sub.useDeliveryInbox = true;

        uint32 expiry = uint32(block.timestamp) + 30 minutes;
        bytes32 typed = buildTypedMessage(nonce, expiry, sub);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegateeKey, typed);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint32 deliveryInterval = 1;
        // make subscription active by advancing time
        vm.warp(block.timestamp + 1 minutes);

        nodeAlice.reportDelegatedComputeResult(
            nonce, expiry, sub, signature, deliveryInterval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, aliceWalletAddr
        );

        // pending delivery should be stored in the subscription client's inbox
        bytes32 requestId = RequestIdUtils.requestIdPacked(uint64(1), deliveryInterval);
        (bool exists, PendingDelivery memory pd) = subscriptionClient.getDelivery(requestId, aliceWalletAddr);
        assertTrue(exists, "Expected pending delivery to exist");
        assertEq(pd.subscriptionId, 1);
        assertEq(pd.interval, deliveryInterval);
        assertEq(pd.input, MOCK_INPUT);
        assertEq(pd.output, MOCK_OUTPUT);
        assertEq(pd.proof, MOCK_PROOF);

        bytes32 key = keccak256(abi.encode(uint64(1), deliveryInterval, address(nodeAlice)));
        assertEq(coordinator.nodeResponded(key), true);
    }

    /// @notice Attempting to deliver for a completed interval must revert.
    function test_RevertsIf_AtomicallyDeliveringOutput_ForCompletedSubscription() public {
        uint32 nonce = router.maxSubscriberNonce(address(transientClient));
        ComputeSubscription memory sub = mockSubscription();
        uint32 expiry = uint32(block.timestamp) + 30 minutes;
        bytes32 typed = buildTypedMessage(nonce, expiry, sub);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegateeKey, typed);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint32 deliveryInterval = 1;

        // record logs to extract events emitted by coordinator during atomic delivery
        vm.recordLogs();
        nodeAlice.reportDelegatedComputeResult(
            nonce, expiry, sub, signature, deliveryInterval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, aliceWalletAddr
        );

        // find RequestStarted Commitment in recorded logs
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 requestStartedTopic = ICoordinator.RequestStarted.selector;
        Commitment memory commitment;
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == requestStartedTopic) {
                commitment = abi.decode(logs[i].data, (Commitment));
                found = true;
                break;
            }
        }
        assertTrue(found, "RequestStarted event not emitted");
        assertEq(commitment.subscriptionId, uint64(1));

        // subsequent deliveries for the same interval should revert with IntervalCompleted
        vm.expectRevert(ICoordinator.IntervalCompleted.selector);
        nodeBob.reportDelegatedComputeResult(
            nonce, expiry, sub, signature, deliveryInterval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, bobWalletAddr
        );

        bytes memory commitmentData = abi.encode(commitment);
        vm.expectRevert(ICoordinator.IntervalCompleted.selector);
        nodeBob.reportComputeResult(
            deliveryInterval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWalletAddr
        );
    }

    /// @notice Delegated delivery to an existing subscription should accept multiple distinct node responses up to redundancy.
    function test_Succeeds_When_DeliveringDelegatedComputeResponse_ForExistingSubscription() public {
        uint32 nonce = router.maxSubscriberNonce(address(transientClient));
        ComputeSubscription memory sub = mockSubscription();
        sub.redundancy = 2;

        uint32 expiry = uint32(block.timestamp) + 30 minutes;
        bytes32 typed = buildTypedMessage(nonce, expiry, sub);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegateeKey, typed);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint32 deliveryInterval = 1;
        // first node responds
        nodeAlice.reportDelegatedComputeResult(
            nonce, expiry, sub, signature, deliveryInterval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, aliceWalletAddr
        );
        bytes32 key = keccak256(abi.encode(uint64(1), deliveryInterval, address(nodeAlice)));
        assertEq(coordinator.nodeResponded(key), true);

        // second node responds
        nodeBob.reportDelegatedComputeResult(
            nonce, expiry, sub, signature, deliveryInterval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, bobWalletAddr
        );
        key = keccak256(abi.encode(uint64(1), deliveryInterval, address(nodeBob)));
        assertEq(coordinator.nodeResponded(key), true);

        // a duplicate attempt from the same node should revert
        vm.expectRevert(ICoordinator.IntervalCompleted.selector);
        nodeBob.reportDelegatedComputeResult(
            nonce, expiry, sub, signature, deliveryInterval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, bobWalletAddr
        );
    }
}
