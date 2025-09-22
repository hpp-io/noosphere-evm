// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.4;

import {ICoordinatorEvents} from "./Coordinator.t.sol";
import {CoordinatorConstants} from "./Coordinator.t.sol";
import {EIP712Coordinator} from "../src/v1_0_0/EIP712Coordinator.sol";
import {Coordinator} from "../src/v1_0_0/Coordinator.sol";
import {LibDeploy} from "./lib/LibDeploy.sol";
import {MockDelegatorCallbackConsumer} from "../src/v1_0_0/consumer/DelegatorCallbackConsumer.sol";
import {MockDelegatorSubscriptionConsumer} from "../src/v1_0_0/consumer/DelegatorSubscriptionConsumer.sol";
import {MockNode} from "./mocks/MockNode.sol";
import {MockProtocol} from "./mocks/MockProtocol.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Router} from "../src/v1_0_0/Router.sol";
import {WalletFactory} from "../src/v1_0_0/wallet/WalletFactory.sol";
import {Wallet} from "../src/v1_0_0/wallet/Wallet.sol";
import {console} from "forge-std/console.sol";
import {Commitment} from "../src/v1_0_0/types/Commitment.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {Reader} from "../src/v1_0_0/utility/Reader.sol";
import {LibSign} from "./lib/LibSign.sol";
import {Subscription} from "../src/v1_0_0/types/Subscription.sol";
import {Delegator} from "../src/v1_0_0/utility/Delegator.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {DeliveredOutput} from "./mocks/consumer/MockBaseConsumer.sol";

contract EIP712CoordinatorTest is Test, CoordinatorConstants, ICoordinatorEvents {
    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Mock protocol wallet
    MockProtocol internal PROTOCOL;

    Router internal ROUTER;

    EIP712Coordinator internal COORDINATOR;

    /*/// @notice Inbox
    Inbox private INBOX;*/

    /// @notice Wallet factory
    WalletFactory internal WALLET_FACTORY;

    /// @notice Mock ERC20 token
    MockToken internal TOKEN;

    /// @notice Mock node (Alice)
    MockNode internal ALICE;

    /// @notice Mock node (Bob)
    MockNode internal BOB;

    /// @notice Mock node (Charlie)
    MockNode internal CHARLIE;


    /// @notice Mock callback consumer (w/ assigned delegatee)
    MockDelegatorCallbackConsumer private CALLBACK;

    /// @notice Mock subscription consumer (w/ assigned delegatee)
    MockDelegatorSubscriptionConsumer private SUBSCRIPTION;

//    /// @notice Mock subscription consumer (w/ Allowlist & assigned delegatee)
//    MockAllowlistDelegatorSubscriptionConsumer private ALLOWLIST_SUBSCRIPTION;

    /// @notice Delegatee address
    address private DELEGATEE_ADDRESS;

    /// @notice Delegatee private key
    uint256 private DELEGATEE_PRIVATE_KEY;

    /// @notice Backup delegatee address
    address private BACKUP_DELEGATEE_ADDRESS;

    /// @notice Backup delegatee private key
    uint256 private BACKUP_DELEGATEE_PRIVATE_KEY;

    address internal userWalletAddress;

    address internal aliceWalletAddress;

    address internal bobWalletAddress;

    address internal protocolWalletAddress;


    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // Create mock protocol wallet
        uint256 initialNonce = vm.getNonce(address(this));
        address ownerProtocolWalletAddress = vm.computeCreateAddress(address(this), initialNonce + 4);

        // Initialize contracts
        (Router router, EIP712Coordinator coordinator, Reader reader, WalletFactory walletFactory) = LibDeploy.deployContracts(
            address(this), initialNonce, ownerProtocolWalletAddress, MOCK_PROTOCOL_FEE, address(TOKEN)
        );
        ROUTER = router;
        COORDINATOR = coordinator;
        WALLET_FACTORY = walletFactory;

        router.setWalletFactory(address(walletFactory));
        PROTOCOL = new MockProtocol(coordinator);
        TOKEN = new MockToken();

        // Initalize mock nodes
        ALICE = new MockNode(router);
        BOB = new MockNode(router);
        CHARLIE = new MockNode(router);
        // Initialize mock callback consumer

        userWalletAddress = WALLET_FACTORY.createWallet(address(this));
        Wallet userWallet = Wallet(payable(userWalletAddress));
        aliceWalletAddress = WALLET_FACTORY.createWallet(address(this));
        bobWalletAddress = WALLET_FACTORY.createWallet(address(this));
        protocolWalletAddress = WALLET_FACTORY.createWallet(ownerProtocolWalletAddress);

        // Approve the coordinator to spend from the protocol wallet for native token
        LibDeploy.updateBillingConfig(coordinator, 1 weeks,
            protocolWalletAddress, MOCK_PROTOCOL_FEE,
            0, 0 ether, address(0));

        // Create new delegatee
        DELEGATEE_PRIVATE_KEY = 0xA11CE;
        DELEGATEE_ADDRESS = vm.addr(DELEGATEE_PRIVATE_KEY);

        // Create new backup delegatee
        BACKUP_DELEGATEE_PRIVATE_KEY = 0xB0B;
        BACKUP_DELEGATEE_ADDRESS = vm.addr(BACKUP_DELEGATEE_PRIVATE_KEY);

        // Initialize mock callback consumer w/ assigned delegatee
        CALLBACK = new MockDelegatorCallbackConsumer(address(router), DELEGATEE_ADDRESS);

        // Initialize mock subscription consumer w/ assigned delegatee
        SUBSCRIPTION = new MockDelegatorSubscriptionConsumer(address(router), DELEGATEE_ADDRESS);

        // Initialize mock subscription consumer w/ Allowlist & assigned delegatee
        // Add only Alice as initially allowed node
        address[] memory initialAllowed = new address[](1);
        initialAllowed[0] = address(ALICE);
//        ALLOWLIST_SUBSCRIPTION =
//                    new MockAllowlistDelegatorSubscriptionConsumer(address(registry), DELEGATEE_ADDRESS, initialAllowed);
    }
    /*//////////////////////////////////////////////////////////////
                              UTILITY FUNCTIONS
       //////////////////////////////////////////////////////////////*/

    /// @notice Creates new mock subscription with sane defaults
    function getMockSubscription() public view returns (Subscription memory) {
        return Subscription({
            activeAt: uint32(block.timestamp),
            owner: address(CALLBACK),
            redundancy: 1,
            frequency: 1,
            period: 0,
            containerId: HASHED_MOCK_CONTAINER_ID,
            lazy: false,
            verifier: payable(NO_VERIFIER),
            paymentAmount: 0,
            paymentToken: NO_PAYMENT_TOKEN,
            wallet: payable(userWalletAddress),
            routeId: "Coordinator_v1.0.0"
        });
    }

    /// @notice Generates the hash of the fully encoded EIP-712 message, based on environment domain config
    /// @param nonce subscriber contract nonce
    /// @param expiry signature expiry
    /// @param sub subscription
    /// @return typed EIP-712 message hash
    function getMessage(uint32 nonce, uint32 expiry, Subscription memory sub) public view returns (bytes32) {
        return LibSign.getTypedMessageHash(
            ROUTER.EIP712_NAME(), ROUTER.EIP712_VERSION(), address(ROUTER), nonce, expiry, sub
        );
    }

    /// @notice Mocks subscription creation via EIP712 delegate process
    /// @param nonce subscriber contract nonce
    /// @return subscriptionId
    function createMockSubscriptionEIP712(uint32 nonce) public returns (uint64) {
        // Check initial subscriptionId
        uint64 id = ROUTER.getLastSubscriptionId() + 1;

        // Create new dummy subscription
        Subscription memory sub = getMockSubscription();

        // Check max subscriber nonce
        uint32 maxSubscriberNonce = ROUTER.maxSubscriberNonce(sub.owner);

        // Generate signature expiry
        uint32 expiry = uint32(block.timestamp) + 30 minutes;

        // Get EIP-712 typed message
        bytes32 message = getMessage(nonce, expiry, sub);

        // Sign message from delegatee private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(DELEGATEE_PRIVATE_KEY, message);
        // Create subscription
        uint64 subscriptionId = ROUTER.createSubscriptionDelegatee(0, expiry, sub, v, r, s);
        assertEq(subscriptionId, id);

        // Assert subscription data is correctly stored
        Subscription memory actual = ROUTER.getSubscription(id);
        assertEq(sub.activeAt, actual.activeAt);
        assertEq(sub.owner, actual.owner);
        assertEq(sub.redundancy, actual.redundancy);
        assertEq(sub.frequency, actual.frequency);
        assertEq(sub.period, actual.period);
        assertEq(sub.containerId, actual.containerId);
        assertEq(sub.lazy, actual.lazy);
        assertEq(sub.verifier, actual.verifier);
        assertEq(sub.paymentToken, actual.paymentToken);
        assertEq(sub.paymentAmount, actual.paymentAmount);
        assertEq(sub.wallet, actual.wallet);

        // Assert state is correctly updated
        if (nonce > maxSubscriberNonce) {
            assertEq(ROUTER.maxSubscriberNonce(address(CALLBACK)), nonce);
        } else {
            assertEq(ROUTER.maxSubscriberNonce(address(CALLBACK)), maxSubscriberNonce);
        }
        assertEq(ROUTER.delegateCreatedIds(keccak256(abi.encodePacked(address(CALLBACK), nonce))), subscriptionId);

        // Explicitly return new subscriptionId
        return subscriptionId;
    }

    /*//////////////////////////////////////////////////////////////
                                 TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertsIf_CreateDelegatedSubscription_WithExpiredSignature() public {
        // Create new dummy subscription
        Subscription memory sub = getMockSubscription();

        // Generate signature expiry
        uint32 expiry = uint32(block.timestamp) + 30 minutes;

        // Get EIP-712 typed message
        bytes32 message = getMessage(0, expiry, sub);

        // Sign message from delegatee private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(DELEGATEE_PRIVATE_KEY, message);

        // Warp time forward past signature expiry
        vm.warp(expiry + 1 seconds);

        // Create subscription via delegate and expect error
        vm.expectRevert(bytes("SignatureExpired()"));
        ROUTER.createSubscriptionDelegatee(0, expiry, sub, v, r, s);
    }

    /// @notice Cannot create delegated subscription where signature does not match
    function testFuzz_RevertsIf_CreateDelegatedSubscription_WithMismatchedSignature(uint256 privateKey) public {
        // Ensure signer private key is not actual delegatee private key
        vm.assume(privateKey != DELEGATEE_PRIVATE_KEY);
        // Ensure signer private key < secp256k1 curve order
        vm.assume(privateKey < SECP256K1_ORDER);
        // Ensure signer private key != 0
        vm.assume(privateKey != 0);

        // Create new dummy subscription
        Subscription memory sub = getMockSubscription();

        // Generate signature expiry
        uint32 expiry = uint32(block.timestamp) + 30 minutes;

        // Get EIP-712 typed message
        bytes32 message = getMessage(0, expiry, sub);

        // Sign message from new private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, message);

        // Create subscription via delegate and expect error
        vm.expectRevert(bytes("SignerMismatch()"));
        ROUTER.createSubscriptionDelegatee(0, expiry, sub, v, r, s);
    }

    /// @notice Can create new subscription via EIP712 signature
    function test_Succeeds_When_CreatingNewSubscription_ViaEIP712() public {
        // Create new dummy subscription
        Subscription memory sub = getMockSubscription();

        // Generate signature expiry
        uint32 expiry = uint32(block.timestamp) + 30 minutes;

        // Get EIP-712 typed message
        bytes32 message = getMessage(0, expiry, sub);

        // Sign message from delegatee private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(DELEGATEE_PRIVATE_KEY, message);

        // Create subscription
        uint64 subscriptionId = ROUTER.createSubscriptionDelegatee(0, expiry, sub, v, r, s);
        assertEq(subscriptionId, 1);

        // Assert subscription data is correctly stored
        Subscription memory actual = ROUTER.getSubscription(1);
        assertEq(sub.activeAt, actual.activeAt);
        assertEq(sub.owner, actual.owner);
        assertEq(sub.redundancy, actual.redundancy);
        assertEq(sub.frequency, actual.frequency);
        assertEq(sub.period, actual.period);
        assertEq(sub.containerId, actual.containerId);
        assertEq(sub.lazy, actual.lazy);
        assertEq(sub.verifier, actual.verifier);
        assertEq(sub.paymentToken, actual.paymentToken);
        assertEq(sub.paymentAmount, actual.paymentAmount);
        assertEq(sub.wallet, actual.wallet);

        // Assert state is correctly updated
        assertEq(ROUTER.maxSubscriberNonce(address(CALLBACK)), 0);
        assertEq(ROUTER.delegateCreatedIds(keccak256(abi.encodePacked(address(CALLBACK), uint32(0)))), 1);
    }

    /// @notice Cannot use valid delegated subscription from old signer
    function test_RevertsIf_CreateDelegatedSubscription_FromOldSigner() public {
        // Create new dummy subscription
        Subscription memory sub = getMockSubscription();

        // Generate signature expiry
        uint32 expiry = uint32(block.timestamp) + 30 minutes;

        // Get EIP-712 typed message
        bytes32 message = getMessage(0, expiry, sub);

        // Sign message from delegatee private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(DELEGATEE_PRIVATE_KEY, message);

        // Update signer to backup delegatee
        CALLBACK.updateMockSigner(BACKUP_DELEGATEE_ADDRESS);
        assertEq(CALLBACK.getSigner(), BACKUP_DELEGATEE_ADDRESS);

        // Create subscription with valid message and expect error
        vm.expectRevert(bytes("SignerMismatch()"));
        ROUTER.createSubscriptionDelegatee(0, expiry, sub, v, r, s);
    }

    /// @notice Can use existing subscription created by old signer
    function test_ReplaysExistingDelegatedSubscription_FromOldSigner() public {
        // Create new dummy subscription
        Subscription memory sub = getMockSubscription();

        // Generate signature expiry
        uint32 expiry = uint32(block.timestamp) + 30 minutes;

        // Get EIP-712 typed message
        bytes32 message = getMessage(0, expiry, sub);

        // Sign message from delegatee private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(DELEGATEE_PRIVATE_KEY, message);
        address recoveredSigner = ECDSA.recover(message, v, r, s);
        console.log("recoveredSigner: ", recoveredSigner);
        console.log("signer address ", Delegator(sub.owner).getSigner());

        // Create subscription
        uint64 subscriptionId = ROUTER.createSubscriptionDelegatee(0, expiry, sub, v, r, s);
        assertEq(subscriptionId, 1);

        // Update signer to backup delegatee
        CALLBACK.updateMockSigner(BACKUP_DELEGATEE_ADDRESS);
        assertEq(CALLBACK.getSigner(), BACKUP_DELEGATEE_ADDRESS);

        // Creating subscription should return existing subscription (ID: 1)
        subscriptionId = ROUTER.createSubscriptionDelegatee(0, expiry, sub, v, r, s);
        assertEq(subscriptionId, 1);
    }

    /// @notice Cannot create delegated subscription where nonce is reused
    function test_CreateDelegatedSubscription_IsIdempotent_ForReusedNonce() public {
        // Setup nonce
        uint32 nonce = 0;

        // Create new dummy subscription
        Subscription memory sub = getMockSubscription();

        // Generate signature expiry
        uint32 expiry = uint32(block.timestamp) + 30 minutes;

        // Get EIP-712 typed message
        bytes32 message = getMessage(nonce, expiry, sub);

        // Sign message
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(DELEGATEE_PRIVATE_KEY, message);

        // Create subscription
        uint64 subscriptionId = ROUTER.createSubscriptionDelegatee(nonce, expiry, sub, v, r, s);
        assertEq(subscriptionId, 1);

        // Create second dummy subscription and set redundancy to 5 (identifier param)
        sub = getMockSubscription();
        uint16 oldRedundancy = sub.redundancy;
        sub.redundancy = 5;

        // Get EIP-712 typed message
        message = getMessage(nonce, expiry, sub);

        // Sign message
        (v, r, s) = vm.sign(DELEGATEE_PRIVATE_KEY, message);

        // Create subscription (notice, with the same nonce)
        subscriptionId = ROUTER.createSubscriptionDelegatee(nonce, expiry, sub, v, r, s);

        // Assert that we are instead simply returned the existing subscription
        assertEq(subscriptionId, 1);
        // Also, assert that the redundancy has not changed
        Subscription memory actual = ROUTER.getSubscription(subscriptionId);
        assertEq(actual.redundancy, oldRedundancy);

        // Now, ensure that we can't resign with a new delegatee and force nonce replay
        // Change the signing delegatee to the backup delegatee
        CALLBACK.updateMockSigner(BACKUP_DELEGATEE_ADDRESS);
        assertEq(CALLBACK.getSigner(), BACKUP_DELEGATEE_ADDRESS);

        // Use same summy subscription with redundancy == 5, but sign with backup delegatee
        (v, r, s) = vm.sign(BACKUP_DELEGATEE_PRIVATE_KEY, message);

        // Create subscription (notice, with the same nonce)
        subscriptionId = ROUTER.createSubscriptionDelegatee(nonce, expiry, sub, v, r, s);

        // Assert that we are instead simply returned the existing subscription
        assertEq(subscriptionId, 1);
        // Also, assert that the redundancy has not changed
        actual = ROUTER.getSubscription(subscriptionId);
        assertEq(actual.redundancy, oldRedundancy);
    }
    /// @notice Can create delegated subscription with out of order nonces
    function test_Succeeds_When_CreatingDelegatedSubscription_WithUnorderedNonces() public {
        // Create subscription with nonce 10
        uint32 nonce = 10;
        Subscription memory sub = getMockSubscription();
        uint32 expiry = uint32(block.timestamp) + 30 minutes;
        bytes32 message = getMessage(nonce, expiry, sub);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(DELEGATEE_PRIVATE_KEY, message);
        uint64 subscriptionId = ROUTER.createSubscriptionDelegatee(nonce, expiry, sub, v, r, s);
        assertEq(subscriptionId, 1);

        // Ensure maximum subscriber nonce is 10
        assertEq(ROUTER.maxSubscriberNonce(sub.owner), 10);

        // Create subscription with nonce 1
        nonce = 1;
        sub = getMockSubscription();
        expiry = uint32(block.timestamp) + 30 minutes;
        message = getMessage(nonce, expiry, sub);
        (v, r, s) = vm.sign(DELEGATEE_PRIVATE_KEY, message);
        subscriptionId = ROUTER.createSubscriptionDelegatee(nonce, expiry, sub, v, r, s);
        assertEq(subscriptionId, 2);

        // Ensure maximum subscriber nonce is still 10
        assertEq(ROUTER.maxSubscriberNonce(sub.owner), 10);

        // Attempt to replay tx with nonce 10
        nonce = 10;
        sub = getMockSubscription();
        expiry = uint32(block.timestamp) + 30 minutes;
        message = getMessage(nonce, expiry, sub);
        (v, r, s) = vm.sign(DELEGATEE_PRIVATE_KEY, message);
        subscriptionId = ROUTER.createSubscriptionDelegatee(nonce, expiry, sub, v, r, s);

        // Ensure that instead of a new subscription, existing subscription (ID: 1) is returned
        assertEq(subscriptionId, 1);
    }

    /// @notice Can cancel subscription created via delegate
    function test_Succeeds_When_CancellingSubscription_CreatedViaDelegate() public {
        // Create mock subscription via delegate, nonce 0
        uint64 subscriptionId = createMockSubscriptionEIP712(0);

        // Attempt to cancel from Callback contract
        vm.startPrank(address(CALLBACK));
        ROUTER.cancelSubscription(subscriptionId);

        // Assert cancelled status
        Subscription memory actual = ROUTER.getSubscription(1);
        assertEq(actual.activeAt, type(uint32).max);
    }

    /// @notice Can delegated deliver compute response, while creating new subscription
    function test_Succeeds_When_AtomicallyCreatingSubscriptionAndDeliveringOutput() public {
        // Starting nonce
        uint32 nonce = ROUTER.maxSubscriberNonce(address(CALLBACK));

        // Create new dummy subscription
        Subscription memory sub = getMockSubscription();

        // Generate signature expiry
        uint32 expiry = uint32(block.timestamp) + 30 minutes;

        // Get EIP-712 typed message
        bytes32 message = getMessage(nonce, expiry, sub);

        // Sign message from delegatee private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(DELEGATEE_PRIVATE_KEY, message);

        // Create subscription and deliver response, via deliverComputeDelegatee
        uint32 subscriptionId = 1;
        uint32 deliveryInterval = 1;
        ALICE.deliverComputeDelegatee( //
            nonce,
            expiry,
            sub,
            v,
            r,
            s,
            deliveryInterval,
            MOCK_INPUT,
            MOCK_OUTPUT,
            MOCK_PROOF,
            aliceWalletAddress
        );

        // Get response
        DeliveredOutput memory out = CALLBACK.getDeliveredOutput(subscriptionId, deliveryInterval, 1);
        assertEq(out.subscriptionId, subscriptionId);
        assertEq(out.interval, deliveryInterval);
        assertEq(out.redundancy, 1);
        assertEq(out.input, MOCK_INPUT);
        assertEq(out.output, MOCK_OUTPUT);
        assertEq(out.proof, MOCK_PROOF);

        // Ensure subscription completion is tracked
        bytes32 key = keccak256(abi.encode(subscriptionId, deliveryInterval, address(ALICE)));
        assertEq(COORDINATOR.nodeResponded(key), true);
    }

    /// @notice Cannot delegated deliver compute response for completed subscription
    function test_RevertsIf_AtomicallyDeliveringOutput_ForCompletedSubscription() public {
        // Starting nonce
        uint32 nonce = ROUTER.maxSubscriberNonce(address(CALLBACK));

        // Create new dummy subscription
        Subscription memory sub = getMockSubscription();

        // Generate signature expiry
        uint32 expiry = uint32(block.timestamp) + 30 minutes;

        // Get EIP-712 typed message
        bytes32 message = getMessage(nonce, expiry, sub);

        // Sign message from delegatee private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(DELEGATEE_PRIVATE_KEY, message);

        // Create subscription and deliver response, via deliverComputeDelegatee
        uint64 subscriptionId = 1;
        uint32 deliveryInterval = 1;

        // To capture the event, we need to record logs before the transaction
        vm.recordLogs();

        ALICE.deliverComputeDelegatee(
            nonce,
            expiry,
            sub,
            v,
            r,
            s,
            deliveryInterval,
            MOCK_INPUT,
            MOCK_OUTPUT,
            MOCK_PROOF,
            aliceWalletAddress
        );

        // Retrieve the Commitment value from the RequestStarted event
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestStartedTopic = keccak256(
            "RequestStarted(uint64,bytes32,bytes32,(bytes32,uint64,bytes32,uint32,bool,uint16,address,uint256,address,address,address))"
        );
        Commitment memory commitment;
        bool eventFound;

        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == requestStartedTopic) {
                commitment = abi.decode(entries[i].data, (Commitment));
                eventFound = true;
                break;
            }
        }
        assertTrue(eventFound, "RequestStarted event not found");
        // You can now use the `commitment` variable, for example:
        assertEq(commitment.subscriptionId, subscriptionId);

        // Attempt to deliver from Bob via delegatee
        vm.expectRevert(Coordinator.IntervalCompleted.selector);
        BOB.deliverComputeDelegatee(
            nonce,
            expiry,
            sub,
            v,
            r,
            s,
            deliveryInterval,
            MOCK_INPUT,
            MOCK_OUTPUT,
            MOCK_PROOF,
            bobWalletAddress
        );
        bytes memory commitmentData1 = abi.encode(commitment);
        // Attempt to delivery from Bob direct
        vm.expectRevert(Coordinator.IntervalCompleted.selector);
        BOB.deliverCompute(
            deliveryInterval,
            MOCK_INPUT,
            MOCK_OUTPUT,
            MOCK_PROOF,
            commitmentData1,
            bobWalletAddress
        );
    }

    /// @notice Can delegated deliver compute response for existing subscription
    function test_Succeeds_When_DeliveringDelegatedComputeResponse_ForExistingSubscription() public {
        // Starting nonce
        uint32 nonce = ROUTER.maxSubscriberNonce(address(CALLBACK));

        // Create new dummy subscription
        Subscription memory sub = getMockSubscription();
        // Modify dummy subscription to allow > 1 redundancy
        sub.redundancy = 2;

        // Generate signature expiry
        uint32 expiry = uint32(block.timestamp) + 30 minutes;

        // Get EIP-712 typed message
        bytes32 message = getMessage(nonce, expiry, sub);

        // Sign message from delegatee private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(DELEGATEE_PRIVATE_KEY, message);

        // Delivery from Alice
        uint32 subscriptionId = 1;
        uint32 deliveryInterval = 1;
        ALICE.deliverComputeDelegatee( //
            nonce,
            expiry,
            sub,
            v,
            r,
            s,
            deliveryInterval,
            MOCK_INPUT,
            MOCK_OUTPUT,
            MOCK_PROOF,
            aliceWalletAddress
        );

        // Ensure subscription completion is tracked
        bytes32 key = keccak256(abi.encode(subscriptionId, deliveryInterval, address(ALICE)));
        assertEq(COORDINATOR.nodeResponded(key), true);

        // Deliver from Bob
        BOB.deliverComputeDelegatee( //
            nonce,
            expiry,
            sub,
            v,
            r,
            s,
            deliveryInterval,
            MOCK_INPUT,
            MOCK_OUTPUT,
            MOCK_PROOF,
            bobWalletAddress
        );

        // Ensure subscription completion is tracked
        key = keccak256(abi.encode(subscriptionId, deliveryInterval, address(BOB)));
        assertEq(COORDINATOR.nodeResponded(key), true);

        // Expect revert if trying to deliver again
        vm.expectRevert(Coordinator.IntervalCompleted.selector);
        BOB.deliverComputeDelegatee( //
            nonce,
            expiry,
            sub,
            v,
            r,
            s,
            deliveryInterval,
            MOCK_INPUT,
            MOCK_OUTPUT,
            MOCK_PROOF,
            bobWalletAddress
        );
    }
}