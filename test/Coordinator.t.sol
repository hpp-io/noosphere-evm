// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import "./mocks/consumer/MockCallbackConsumer.sol";
import {BaseConsumer} from "../src/v1_0_0/consumer/BaseConsumer.sol";
import {Coordinator} from "../src/v1_0_0/Coordinator.sol";
import {LibDeploy} from "./lib/LibDeploy.sol";
import {MockNode} from "./mocks/MockNode.sol";
import {MockProtocol} from "./mocks/MockProtocol.sol";
import {MockSubscriptionConsumer} from "./mocks/consumer/MockSubscriptionConsumer.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {Test} from "forge-std/Test.sol";
import {WalletFactory} from "../src/v1_0_0/wallet/WalletFactory.sol";
import {Wallet} from "../src/v1_0_0/wallet/Wallet.sol";
import {Router} from "../src/v1_0_0/Router.sol";
import {Reader} from "../src/v1_0_0/utility/Reader.sol";
import {console} from "forge-std/console.sol";



/// @title ICoordinatorEvents
/// @notice Events emitted by Coordinator
interface ICoordinatorEvents {
    event SubscriptionCreated(uint64 indexed id);
    event SubscriptionCancelled(uint64 indexed id);
    event SubscriptionFulfilled(uint64 indexed id, address indexed node);
    event ProofVerified(
        uint64 indexed id, uint32 indexed interval, address indexed node, bool active, address verified, bool valid
    );
}

/// @title CoordinatorConstants
/// @notice Base constants setup to inherit for Coordinator subtests
abstract contract CoordinatorConstants {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mock compute container ID
    string internal constant MOCK_CONTAINER_ID = "container";

    /// @notice Mock compute container ID hashed
    bytes32 internal constant HASHED_MOCK_CONTAINER_ID = keccak256(abi.encode(MOCK_CONTAINER_ID));

    /// @notice Mock container inputs
    bytes internal constant MOCK_CONTAINER_INPUTS = "inputs";

    /// @notice Mock delivered container input
    /// @dev Example of a hashed input (encoding hash(MOCK_CONTAINER_INPUTS) into input) field
    bytes internal constant MOCK_INPUT = abi.encode(keccak256(abi.encode(MOCK_CONTAINER_INPUTS)));

    /// @notice Mock delivered container compute output
    bytes internal constant MOCK_OUTPUT = "output";

    /// @notice Mock delivered proof
    bytes internal constant MOCK_PROOF = "proof";

    /// @notice Mock protocol fee (5.11%)
    uint16 internal constant MOCK_PROTOCOL_FEE = 511;

    /// @notice Zero address
    address internal constant ZERO_ADDRESS = address(0);

    /// @notice Mock empty payment token
    address internal constant NO_PAYMENT_TOKEN = ZERO_ADDRESS;

    /// @notice Mock empty wallet
    address internal constant NO_WALLET = ZERO_ADDRESS;

    /// @notice Mock empty verifier contract
    address internal constant NO_VERIFIER = ZERO_ADDRESS;
}

/// @title CoordinatorTest
/// @notice Base setup to inherit for Coordinator subtests
abstract contract CoordinatorTest is Test, CoordinatorConstants, ICoordinatorEvents {
    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Mock protocol wallet
    MockProtocol internal PROTOCOL;

    Router internal ROUTER;


    /// @notice Coordinator
    Coordinator internal COORDINATOR;

    /// @notice Inbox
//    Inbox internal INBOX;

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

    /// @notice Mock callback consumer
    MockCallbackConsumer internal CALLBACK;

    /// @notice Mock subscription consumer
    MockSubscriptionConsumer internal SUBSCRIPTION;

    address internal userWalletAddress;

    /// @notice Mock subscription consumer w/ Allowlist
//    MockAllowlistSubscriptionConsumer internal ALLOWLIST_SUBSCRIPTION;

    /// @notice Mock atomic verifier
//    MockAtomicVerifier internal ATOMIC_VERIFIER;

    /// @notice Mock optimistic verifier
//    MockOptimisticVerifier internal OPTIMISTIC_VERIFIER;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // Create mock protocol wallet
        uint256 initialNonce = vm.getNonce(address(this));
        address mockProtocolWalletAddress = vm.computeCreateAddress(address(this), initialNonce + 6);

        // Initialize contracts
        (Router router, Coordinator coordinator, Reader reader, WalletFactory walletFactory) =
                            LibDeploy.deployContracts(address(this), initialNonce, address(0), 1);

        ROUTER = Router(router);

        // Initialize mock protocol wallet
        PROTOCOL = new MockProtocol(coordinator);

        // Create mock token
        TOKEN = new MockToken();

        // Assign to internal (overriding EIP712Coordinator -> isolated Coordinator for tests)
        COORDINATOR = Coordinator(coordinator);
        WALLET_FACTORY = walletFactory;

        // Initalize mock nodes
        ALICE = new MockNode(router);
        BOB = new MockNode(router);
        CHARLIE = new MockNode(router);
        // Initialize mock callback consumer
        CALLBACK = new MockCallbackConsumer(address(router));

        // Initialize mock subscription consumer
//        SUBSCRIPTION = new MockSubscriptionConsumer(address(registry));

        // Initialize mock subscription consumer w/ Allowlist
        // Add only Alice as initially allowed node
        address[] memory initialAllowed = new address[](1);
        initialAllowed[0] = address(ALICE);
//        ALLOWLIST_SUBSCRIPTION = new MockAllowlistSubscriptionConsumer(address(registry), initialAllowed);

        // Initialize mock verifiers
//        ATOMIC_VERIFIER = new MockAtomicVerifier(registry);
//        OPTIMISTIC_VERIFIER = new MockOptimisticVerifier(registry);


        // --- Wallet Setup Example ---
        // 1. Create a wallet. The test contract will be the owner.
        userWalletAddress = WALLET_FACTORY.createWallet(address(this));
        Wallet userWallet = Wallet(payable(userWalletAddress));

        // 2. Define payment details for a paid request.
        uint256 paymentAmount = 0.1 ether;

        // 3. Fund the wallet with ETH to cover the payment.
        (bool success,) = userWalletAddress.call{value: 1 ether}("");
        require(success, "Failed to fund wallet");

        // 4. Approve the consumer contract (CALLBACK) to spend from the wallet.
        // The approval is for the native token (address(0)).
        userWallet.approve(address(CALLBACK), address(0), paymentAmount);
        // --- End Wallet Setup ---
    }
}

/// @title CoordinatorGeneralTest
/// @notice General coordinator tests
contract CoordinatorGeneralTest is CoordinatorTest {
    /// @notice Cannot be reassigned a subscription ID
    function testCannotBeReassignedSubscriptionID() public {
        // Create new callback subscription
        (uint64 id1, Commitment memory commitment1) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        assertEq(id1, 1);

        // Create new subscriptions
        (uint64 id2, ) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );
        // Assert head
        assertEq(id2, 2);

        // Delete subscriptions
        vm.startPrank(address(CALLBACK));
        ROUTER.timeoutRequest(commitment1.requestId, commitment1.subscriptionId, commitment1.interval);
        ROUTER.cancelSubscription(1);

        // Create new subscription
        (uint64 id3, ) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );
        assertEq(id3, 3);
    }

    /// @notice Cannot receive response from non-coordinator contract
    function testCannotReceiveResponseFromNonCoordinator() public {
        // Expect revert sending from address(this)
        vm.expectRevert(BaseConsumer.NotRouter.selector);
        CALLBACK.rawReceiveCompute(1, 1, 1, address(this), MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, bytes32(0), 0);
    }
}

// @title CoordinatorCallbackTest
// @notice Coordinator tests specific to usage by CallbackConsumer
contract CoordinatorCallbackTest is CoordinatorTest {
    /// @notice Can create callback (one-time subscription)
    function testCanCreateCallback() public {
        vm.warp(0);

        // Get expected subscription ID
        uint64 expected = 1;

        // Create new callback
        vm.expectEmit(address(ROUTER));
        emit SubscriptionCreated(expected);
        (uint64 actual, ) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Assert subscription ID is correctly stored
        assertEq(expected, actual);

        // Assert subscription data is correctly stored
        Subscription memory sub = ROUTER.getSubscription(actual);
        assertEq(sub.activeAt, 0);
        assertEq(sub.owner, address(CALLBACK));
        assertEq(sub.redundancy, 1);
        assertEq(sub.frequency, 1);
        assertEq(sub.period, 0);
        assertEq(sub.containerId, HASHED_MOCK_CONTAINER_ID);
        assertEq(sub.lazy, false);

        // Assert subscription inputs are correctly stord
        assertEq(CALLBACK.getContainerInputs(actual, 0, 0, address(0)), MOCK_CONTAINER_INPUTS);
    }

    /// @notice Cannot deliver callback response if incorrect interval
//    function testFuzzCannotDeliverCallbackIfIncorrectInterval(uint32 interval) public {
//        // Check non-correct intervals
//        vm.assume(interval != 1);
//
//        // Create new callback request
//        (uint64 subId,Commitment memory commitment) = CALLBACK.createMockRequest(
//            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
//        );
//
//        // Attempt to deliver callback request w/ incorrect interval
//        vm.expectRevert(Coordinator.IntervalMismatch.selector);
//        bytes memory commitmentData = abi.encode(commitment);
//        vm.prank(address(ALICE));
//        vm.expectRevert(
//            abi.encodeWithSelector(
//                Coordinator.IntervalMismatch.selector,
//                commitment.subscriptionId,
//                commitment.interval,
//                interval
//            )
//        );
//        ALICE.deliverCompute(interval, "", "", "", commitmentData, NO_WALLET);
//    }

    /// @notice Can deliver callback response successfully
    function testCanDeliverCallbackResponse() public {
        // Create new callback request
        (uint64 subId,Commitment memory commitment) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );
        assertEq(subId, 1);

        // Deliver callback request
//        vm.expectEmit(address(COORDINATOR));
        bytes memory commitmentData = abi.encode(commitment);
        vm.prank(address(ALICE));
        ALICE.deliverCompute(1, "", "", "", commitmentData, address(ALICE));
        // Assert delivery
        DeliveredOutput memory out = CALLBACK.getDeliveredOutput(subId, 1, 1);
//        assertEq(out.subscriptionId, subId);
//        assertEq(out.interval, 1);
//        assertEq(out.redundancy, 1);
//        assertEq(out.node, address(ALICE));
//        assertEq(out.input, MOCK_INPUT);
//        assertEq(out.output, MOCK_OUTPUT);
//        assertEq(out.proof, MOCK_PROOF);
//        assertEq(out.containerId, bytes32(0));
//        assertEq(out.index, 0);
    }

    /// @notice Can deliver callback response once, across two unique nodes
//    function testCanDeliverCallbackResponseOnceAcrossTwoNodes() public {
//        // Create new callback request w/ redundancy = 2
//        uint16 redundancy = 2;
//        uint32 subId = CALLBACK.createMockRequest(
//            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, redundancy, NO_PAYMENT_TOKEN, 0, NO_WALLET, NO_VERIFIER
//        );
//
//        // Deliver callback request from two nodes
//        ALICE.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//        BOB.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//
//        // Assert delivery
//        address[2] memory nodes = [address(ALICE), address(BOB)];
//        for (uint16 r = 1; r <= 2; r++) {
//            DeliveredOutput memory out = CALLBACK.getDeliveredOutput(subId, 1, r);
//            assertEq(out.subscriptionId, subId);
//            assertEq(out.interval, 1);
//            assertEq(out.redundancy, r);
//            assertEq(out.node, nodes[r - 1]);
//            assertEq(out.input, MOCK_INPUT);
//            assertEq(out.output, MOCK_OUTPUT);
//            assertEq(out.proof, MOCK_PROOF);
//            assertEq(out.containerId, bytes32(0));
//            assertEq(out.index, 0);
//        }
//    }

    /// @notice Cannot deliver callback response twice from same node
//    function testCannotDeliverCallbackResponseFromSameNodeTwice() public {
//        // Create new callback request w/ redundancy = 2
//        uint16 redundancy = 2;
//        uint32 subId = CALLBACK.createMockRequest(
//            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, redundancy, NO_PAYMENT_TOKEN, 0, NO_WALLET, NO_VERIFIER
//        );
//
//        // Deliver callback request from Alice twice
//        ALICE.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//        vm.expectRevert(Coordinator.NodeRespondedAlready.selector);
//        ALICE.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//    }

    /// @notice Delivered callbacks are not stored in Inbox
//    function testCallbackDeliveryDoesNotStoreDataInInbox() public {
//        // Create new callback request
//        uint32 subId = CALLBACK.createMockRequest(
//            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, NO_WALLET, NO_VERIFIER
//        );
//
//        // Deliver callback request from Alice
//        ALICE.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//
//        // Expect revert (indexOOBError but in external contract)
//        vm.expectRevert();
////        INBOX.read(HASHED_MOCK_CONTAINER_ID, address(ALICE), 0);
//    }
}

/// @title CoordinatorSubscriptionTest
/// @notice Coordinator tests specific to usage by SubscriptionConsumer
//contract CoordinatorSubscriptionTest is CoordinatorTest {
//    /// @notice Can read container inputs
//    function testCanReadContainerInputs() public {
//        bytes memory expected = SUBSCRIPTION.CONTAINER_INPUTS();
//        bytes memory actual = SUBSCRIPTION.getContainerInputs(0, 0, 0, address(this));
//        assertEq(expected, actual);
//    }
//
//    /// @notice Can cancel a subscription
//    function testCanCancelSubscription() public {
//        // Create subscription
//        uint32 subId = SUBSCRIPTION.createMockSubscription(
//            MOCK_CONTAINER_ID, 3, 1 minutes, 1, false, NO_PAYMENT_TOKEN, 0, NO_WALLET, NO_VERIFIER
//        );
//
//        // Cancel subscription and expect event emission
//        vm.expectEmit(address(COORDINATOR));
//        emit SubscriptionCancelled(subId);
//        SUBSCRIPTION.cancelMockSubscription(subId);
//    }
//
//    /// @notice Can cancel a subscription that has been fulfilled at least once
//    function testCanCancelFulfilledSubscription() public {
//        // Create subscription
//        vm.warp(0);
//        uint32 subId = SUBSCRIPTION.createMockSubscription(
//            MOCK_CONTAINER_ID, 3, 1 minutes, 1, false, NO_PAYMENT_TOKEN, 0, NO_WALLET, NO_VERIFIER
//        );
//
//        // Fulfill at least once
//        vm.warp(60);
//        ALICE.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//
//        // Cancel subscription
//        SUBSCRIPTION.cancelMockSubscription(subId);
//    }
//
//    /// @notice Cannot cancel a subscription that does not exist
//    function testCannotCancelNonExistentSubscription() public {
//        // Try to delete subscription without creating
//        vm.expectRevert(Coordinator.NotSubscriptionOwner.selector);
//        SUBSCRIPTION.cancelMockSubscription(1);
//    }
//
//    /// @notice Can cancel a subscription that has already been cancelled
//    function testCanCancelCancelledSubscription() public {
//        // Create and cancel subscription
//        uint32 subId = SUBSCRIPTION.createMockSubscription(
//            MOCK_CONTAINER_ID, 3, 1 minutes, 1, false, NO_PAYMENT_TOKEN, 0, NO_WALLET, NO_VERIFIER
//        );
//        SUBSCRIPTION.cancelMockSubscription(subId);
//
//        // Attempt to cancel subscription again
//        SUBSCRIPTION.cancelMockSubscription(subId);
//    }
//
//    /// @notice Cannot cancel a subscription you do not own
//    function testCannotCancelUnownedSubscription() public {
//        // Create callback subscription
//        uint32 subId = CALLBACK.createMockRequest(
//            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, NO_WALLET, NO_VERIFIER
//        );
//
//        // Attempt to cancel subscription from SUBSCRIPTION consumer
//        vm.expectRevert(Coordinator.NotSubscriptionOwner.selector);
//        SUBSCRIPTION.cancelMockSubscription(subId);
//    }
//
//    /// @notice Subscription intervals are properly calculated
//    function testFuzzSubscriptionIntervalsAreCorrect(uint32 blockTime, uint32 frequency, uint32 period) public {
//        // In the interest of testing time, upper bounding frequency loops + having at minimum 1 frequency
//        vm.assume(frequency > 1 && frequency < 32);
//        // Prevent upperbound overflow
//        vm.assume(uint256(blockTime) + (uint256(frequency) * uint256(period)) < 2 ** 32 - 1);
//
//        // Subscription activeAt timestamp
//        uint32 activeAt = blockTime + period;
//
//        // If period == 0, interval is always 1
//        if (period == 0) {
//            uint32 actual = COORDINATOR.getSubscriptionInterval(activeAt, period);
//            assertEq(1, actual);
//            return;
//        }
//
//        // Else, verify each manual interval
//        // blockTime -> blockTime + period = underflow (this should never be called since we verify block.timestamp >= activeAt)
//        // blockTime + N * period = N
//        uint32 expected = 1;
//        for (uint32 start = blockTime + period; start < (blockTime) + (frequency * period); start += period) {
//            // Set current time
//            vm.warp(start);
//
//            // Check subscription interval
//            uint32 actual = COORDINATOR.getSubscriptionInterval(activeAt, period);
//            assertEq(expected, actual);
//
//            // Check subscription interval 1s before if not first iteration
//            if (expected != 1) {
//                vm.warp(start - 1);
//                actual = COORDINATOR.getSubscriptionInterval(activeAt, period);
//                assertEq(expected - 1, actual);
//            }
//
//            // Increment expected for next cycle
//            expected++;
//        }
//    }
//
//    /// @notice Cannot deliver response for subscription that does not exist
//    function testCannotDeliverResponseForNonExistentSubscription() public {
//        // Attempt to deliver output for subscription without creating
//        vm.expectRevert(Coordinator.SubscriptionNotFound.selector);
//        ALICE.deliverCompute(1, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//    }
//
//    /// @notice Cannot deliver response for non-active subscription
//    function testCannotDeliverResponseNonActiveSubscription() public {
//        // Create new subscription at time = 0
//        vm.warp(0);
//        uint32 subId = SUBSCRIPTION.createMockSubscription(
//            MOCK_CONTAINER_ID, 3, 1 minutes, 1, false, NO_PAYMENT_TOKEN, 0, NO_WALLET, NO_VERIFIER
//        );
//
//        // Expect subscription to be inactive till time = 60
//        vm.expectRevert(Coordinator.SubscriptionNotActive.selector);
//        ALICE.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//
//        // Ensure subscription can be fulfilled when active
//        // Force failure at next conditional (gas price)
//        vm.warp(1 minutes);
//        ALICE.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//    }
//
//    /// @notice Cannot deliver response for completed subscription
//    function testCannotDeliverResponseForCompletedSubscription() public {
//        // Create new subscription at time = 0
//        vm.warp(0);
//        uint32 subId = SUBSCRIPTION.createMockSubscription(
//            MOCK_CONTAINER_ID,
//            2, // frequency = 2
//            1 minutes,
//            1,
//            false,
//            NO_PAYMENT_TOKEN,
//            0,
//            NO_WALLET,
//            NO_VERIFIER
//        );
//
//        // Expect failure at any time prior to t = 60s
//        vm.warp(1 minutes - 1);
//        vm.expectRevert(Coordinator.SubscriptionNotActive.selector);
//        ALICE.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//
//        // Deliver first response at time t = 60s
//        vm.warp(1 minutes);
//        ALICE.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//
//        // Deliver second response at time t = 120s
//        vm.warp(2 minutes);
//        ALICE.deliverCompute(subId, 2, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//
//        // Expect revert because interval > frequency
//        vm.warp(3 minutes);
//        vm.expectRevert(Coordinator.SubscriptionCompleted.selector);
//        ALICE.deliverCompute(subId, 3, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//    }
//
//    /// @notice Cannot deliver response if incorrect interval
//    function testCannotDeliverResponseIncorrectInterval() public {
//        // Create new subscription at time = 0
//        vm.warp(0);
//        uint32 subId = SUBSCRIPTION.createMockSubscription(
//            MOCK_CONTAINER_ID,
//            2, // frequency = 2
//            1 minutes,
//            1,
//            false,
//            NO_PAYMENT_TOKEN,
//            0,
//            NO_WALLET,
//            NO_VERIFIER
//        );
//
//        // Successfully deliver at t = 60s, interval = 1
//        vm.warp(1 minutes);
//        ALICE.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//
//        // Unsuccesfully deliver at t = 120s, interval = 1 (expected = 2)
//        vm.warp(2 minutes);
//        vm.expectRevert(Coordinator.IntervalMismatch.selector);
//        ALICE.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//    }
//
//    /// @notice Cannot deliver response delayed (after interval passed)
//    function testCannotDeliverResponseDelayed() public {
//        // Create new subscription at time = 0
//        vm.warp(0);
//        uint32 subId = SUBSCRIPTION.createMockSubscription(
//            MOCK_CONTAINER_ID,
//            2, // frequency = 2
//            1 minutes,
//            1,
//            false,
//            NO_PAYMENT_TOKEN,
//            0,
//            NO_WALLET,
//            NO_VERIFIER
//        );
//
//        // Attempt to deliver interval = 1 at time = 120s
//        vm.warp(2 minutes);
//        vm.expectRevert(Coordinator.IntervalMismatch.selector);
//        ALICE.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//    }
//
//    /// @notice Cannot deliver response early (before interval arrived)
//    function testCannotDeliverResponseEarly() public {
//        // Create new subscription at time = 0
//        vm.warp(0);
//        uint32 subId = SUBSCRIPTION.createMockSubscription(
//            MOCK_CONTAINER_ID,
//            2, // frequency = 2
//            1 minutes,
//            1,
//            false,
//            NO_PAYMENT_TOKEN,
//            0,
//            NO_WALLET,
//            NO_VERIFIER
//        );
//
//        // Attempt to deliver interval = 2 at time < 120s
//        vm.warp(2 minutes - 1);
//        vm.expectRevert(Coordinator.IntervalMismatch.selector);
//        ALICE.deliverCompute(subId, 2, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//    }
//
//    /// @notice Cannot deliver response if redundancy maxxed out
//    function testCannotDeliverMaxRedundancyResponse() public {
//        // Create new subscription at time = 0
//        vm.warp(0);
//        uint32 subId = SUBSCRIPTION.createMockSubscription(
//            MOCK_CONTAINER_ID,
//            2, // frequency = 2
//            1 minutes,
//            2, // redundancy = 2
//            false,
//            NO_PAYMENT_TOKEN,
//            0,
//            NO_WALLET,
//            NO_VERIFIER
//        );
//
//        // Deliver from Alice
//        vm.warp(1 minutes);
//        ALICE.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//
//        // Deliver from Bob
//        BOB.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//
//        // Attempt to deliver from Charlie, expect failure
//        vm.expectRevert(Coordinator.IntervalCompleted.selector);
//        CHARLIE.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//    }
//
//    /// @notice Cannot deliver response if already delivered in current interval
//    function testCannotDeliverResponseIfAlreadyDeliveredInCurrentInterval() public {
//        // Create new subscription at time = 0
//        vm.warp(0);
//        uint32 subId = SUBSCRIPTION.createMockSubscription(
//            MOCK_CONTAINER_ID,
//            2, // frequency = 2
//            1 minutes,
//            2, // redundancy = 2
//            false,
//            NO_PAYMENT_TOKEN,
//            0,
//            NO_WALLET,
//            NO_VERIFIER
//        );
//
//        // Deliver from Alice
//        vm.warp(1 minutes);
//        ALICE.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//
//        // Attempt to deliver from Alice again
//        vm.expectRevert(Coordinator.NodeRespondedAlready.selector);
//        ALICE.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, NO_WALLET);
//    }
//}
