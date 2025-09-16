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
import {DeliveredOutput} from "./mocks/consumer/MockBaseConsumer.sol";



/// @title ICoordinatorEvents
/// @notice Events emitted by Coordinator
interface ICoordinatorEvents {
    event SubscriptionCreated(uint64 indexed id);
    event SubscriptionCancelled(uint64 indexed id);
    event ComputeDelivered(bytes32 indexed requestId, address nodeWallet, uint16 numRedundantDeliveries);
    event ProofVerified(
        uint64 indexed id, uint32 indexed interval, address indexed node, bool active, address verified, bool valid
    );

    event RequestStart(
        bytes32 indexed requestId,
        uint64 indexed subscriptionId,
        bytes32 indexed containerId,
        uint32 interval,
        uint16 redundancy,
        bool lazy,
        uint256 paymentAmount,
        address paymentToken,
        address verifier,
        address coordinator
    );
    error RequestCompleted(bytes32 requestId);
    error IntervalMismatch(uint32 deliveryInterval);
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

        ROUTER = router;
        COORDINATOR = coordinator;
        WALLET_FACTORY = walletFactory;

        // Complete deployment by setting the WalletFactory address in the Router.
        // This breaks the circular dependency during deployment.
        router.setWalletFactory(address(walletFactory));

        // Initialize mock protocol wallet
        PROTOCOL = new MockProtocol(coordinator);

        // Create mock token
        TOKEN = new MockToken();

        // Initalize mock nodes
        ALICE = new MockNode(router);
        BOB = new MockNode(router);
        CHARLIE = new MockNode(router);
        // Initialize mock callback consumer
        CALLBACK = new MockCallbackConsumer(address(router));

        // Initialize mock subscription consumer
        SUBSCRIPTION = new MockSubscriptionConsumer(address(router));

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

    function testFuzzCannotDeliverCallbackIfIncorrectInterval(uint32 interval) public {
        // Check non-correct intervals
        vm.assume(interval != 1);

        // Create new callback request
        (uint64 subId, Commitment memory commitment) =
            CALLBACK.createMockRequest(MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER);
        assertEq(subId, 1);

        // Attempt to deliver callback request w/ incorrect interval
        vm.expectRevert(abi.encodeWithSelector(Coordinator.IntervalMismatch.selector, interval));
        bytes memory commitmentData = abi.encode(commitment);
        vm.prank(address(ALICE));
        // Use the fuzzed interval to test the logic correctly
        ALICE.deliverCompute(interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, address(ALICE));
    }

    /// @notice Can deliver callback response successfully
    function testCanDeliverCallbackResponse() public {
        // --- 1. Arrange: Create a request ---
        (uint64 subId, Commitment memory commitment) =
            CALLBACK.createMockRequest(MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER);
        assertEq(subId, 1);

        // --- 2. Act: Deliver the response and check for the event ---
        // Expect the `ComputeDelivered` event from the COORDINATOR contract.
        // We check both indexed topics (requestId, nodeWallet) and the emitter address.
        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, address(ALICE), 1);

        // Call the function that emits the event.
        bytes memory commitmentData = abi.encode(commitment);
        vm.prank(address(ALICE));
        ALICE.deliverCompute(
            commitment.interval, // Use the correct interval from the commitment
            MOCK_INPUT,
            MOCK_OUTPUT,
            MOCK_PROOF,
            commitmentData,
            address(ALICE)
        );
        // --- 3. Assert: Verify the outcome ---
        DeliveredOutput memory out = CALLBACK.getDeliveredOutput(subId, 1, 1);
        assertEq(out.subscriptionId, subId);
        assertEq(out.interval, 1);
        assertEq(out.redundancy, 1);
        assertEq(out.node, address(ALICE));
        assertEq(out.input, MOCK_INPUT);
        assertEq(out.output, MOCK_OUTPUT);
        assertEq(out.proof, MOCK_PROOF);
        // For non-lazy (eager) subscriptions, the containerId is expected to be bytes32(0)
        // in the callback, as the consumer already knows the container from the subscription.
        assertEq(out.containerId, bytes32(0));
        assertEq(out.index, 0);
    }

    /// @notice Can deliver callback response once, across two unique nodes
    function testCanDeliverCallbackResponseOnceAcrossTwoNodes() public {
        // Create new callback request w/ redundancy = 2
        uint16 redundancy = 2;
        (uint64 subId, Commitment memory commitment) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, redundancy, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Call the function that emits the event.
        bytes memory commitmentData = abi.encode(commitment);

        // Deliver callback request from two nodes
        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, address(ALICE), 1);
        ALICE.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, address(ALICE));

        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, address(BOB), 2);
        BOB.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, address(BOB));

        // Assert delivery
        address[2] memory nodes = [address(ALICE), address(BOB)];
        for (uint16 r = 1; r <= 2; r++) {
            DeliveredOutput memory out = CALLBACK.getDeliveredOutput(subId, 1, r);
            assertEq(out.subscriptionId, subId);
            assertEq(out.interval, 1);
            assertEq(out.redundancy, r);
            assertEq(out.node, nodes[r - 1]);
            assertEq(out.input, MOCK_INPUT);
            assertEq(out.output, MOCK_OUTPUT);
            assertEq(out.proof, MOCK_PROOF);
            assertEq(out.containerId, bytes32(0));
            assertEq(out.index, 0);
        }
    }

    function testCannotDeliverCallbackResponseFromSameNodeTwice() public {
        // Create new callback request w/ redundancy = 2
        uint16 redundancy = 2;
        (uint64 subId, Commitment memory commitment) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, redundancy, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        bytes memory commitmentData = abi.encode(commitment);

        // Deliver callback request from two nodes (within redundancy)
        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, address(ALICE), 1);
        ALICE.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, address(ALICE));
        vm.expectRevert(Coordinator.NodeRespondedAlready.selector);
        ALICE.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, address(ALICE));
    }


    /// @notice Cannot deliver callback response more than redundancy
    function testCannotDeliverCallbackResponseMoreThanRedundancy() public {
        // Create new callback request w/ redundancy = 2
        uint16 redundancy = 2;
        (uint64 subId, Commitment memory commitment) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, redundancy, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // Call the function that emits the event.
        bytes memory commitmentData = abi.encode(commitment);

        // Deliver callback request from two nodes (within redundancy)
        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, address(ALICE), 1);
        ALICE.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, address(ALICE));

        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, address(BOB), 2);
        BOB.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, address(BOB));

        // Attempt to deliver a third response (exceeds redundancy)
        // The Coordinator should revert with a RequestCompleted error.
        vm.expectRevert(abi.encodeWithSelector(ICoordinatorEvents.RequestCompleted.selector, commitment.requestId));
        CHARLIE.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, address(CHARLIE));
    }

}

contract CoordinatorSubscriptionTest is CoordinatorTest {
    function testCanCancelSubscription() public {
        // Create subscription
        uint64 subId = SUBSCRIPTION.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, 3, 1 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );
        vm.warp(block.timestamp + 1 minutes);
        // Cancel subscription and expect event emission
        vm.expectEmit(address(ROUTER));
        emit SubscriptionCancelled(subId);
        SUBSCRIPTION.cancelMockSubscription(subId);
    }

    function testCanCancelFulfilledSubscription() public {
        // Create subscription
//        vm.warp(0);
        (uint64 subId, Commitment memory commitment)  = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 1 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        bytes memory commitmentData = abi.encode(commitment);

        // Fulfill at least once
        vm.warp(block.timestamp + 1 minutes);
        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, address(ALICE), 1);
        ALICE.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, address(ALICE));


        // Cancel subscription
        vm.expectEmit(address(ROUTER));
        emit SubscriptionCancelled(subId);
        SUBSCRIPTION.cancelMockSubscription(subId);
    }

    /// @notice Cannot cancel a subscription that does not exist
    function testCannotCancelNonExistentSubscription() public {
        // Try to delete subscription without creating
        vm.expectRevert(bytes("NotSubscriptionOwner()"));
        SUBSCRIPTION.cancelMockSubscription(1);
    }


    /// @notice Can cancel a subscription that has already been cancelled
    function testCanCancelCancelledSubscription() public {
        // Create and cancel subscription
        uint64 subId = SUBSCRIPTION.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, 3, 1 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );
        vm.warp(block.timestamp + 1 minutes);

        // Cancel subscription and expect event emission
        vm.expectEmit(address(ROUTER));
        emit SubscriptionCancelled(subId);
        SUBSCRIPTION.cancelMockSubscription(subId);
        // Attempt to cancel again, expect a revert as it's already cancelled
        vm.expectRevert(bytes("SubscriptionNotFound()"));
        SUBSCRIPTION.cancelMockSubscription(subId);
    }

    /// @notice Subscription intervals are properly calculated
    function testFuzzSubscriptionIntervalsAreCorrect(uint32 blockTime, uint32 frequency, uint32 period) public {
        // In the interest of testing time, upper bounding frequency loops + having at minimum 1 frequency
        vm.assume(frequency > 1 && frequency < 32);
        // Prevent upperbound overflow
        vm.assume(uint256(blockTime) + (uint256(frequency) * uint256(period)) < 2 ** 32 - 1);

        // Set the block time before creating the subscription
        vm.warp(blockTime);

        uint64 subId = SUBSCRIPTION.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, frequency, period, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );


        // Subscription activeAt timestamp
        uint32 activeAt = blockTime + period;

        // If period == 0, interval is always 1
        if (period == 0) {
            uint32 actual = ROUTER.getSubscriptionInterval(subId);
            assertEq(1, actual);
            return;
        }

        // Else, verify each manual interval
        // blockTime -> blockTime + period = underflow (this should never be called since we verify block.timestamp >= activeAt)
        // blockTime + N * period = N
        uint32 expected = 1;
        for (uint32 start = blockTime + period; start < (blockTime) + (frequency * period); start += period) {
            // Set current time
            vm.warp(start);

            // Check subscription interval
            uint32 actual = ROUTER.getSubscriptionInterval(subId);
            assertEq(expected, actual);

            // Check subscription interval 1s before if not first iteration
            if (expected != 1) {
                vm.warp(start - 1);
                actual = ROUTER.getSubscriptionInterval(subId);
                assertEq(expected - 1, actual);
            }

            // Increment expected for next cycle
            expected++;
        }
    }

    function testCannotDeliverResponseForNonExistentSubscription() public {
        // Attempt to deliver output for subscription without creating
        uint64 nonExistentSubId = 999;
        Commitment memory fakeCommitment = Commitment({
            requestId: keccak256(abi.encodePacked(nonExistentSubId, uint32(1))),
            subscriptionId: nonExistentSubId,
            containerId: HASHED_MOCK_CONTAINER_ID,
            interval: 1,
            lazy: false,
            redundancy: 1,
            walletAddress: userWalletAddress,
            paymentAmount: 0,
            paymentToken: NO_PAYMENT_TOKEN,
            verifier: NO_VERIFIER,
            coordinator: address(COORDINATOR)
        });
        bytes memory commitmentData = abi.encode(fakeCommitment);

        // The call chain is deliverCompute -> getSubscriptionInterval -> _isExistingSubscription.
        // This will revert with "InvalidSubscription".
        vm.expectRevert(bytes("SubscriptionNotFound()"));

        // Call deliverCompute with the crafted commitment.
        ALICE.deliverCompute(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, address(ALICE));
    }

    /// @notice Cannot deliver a response for an interval that is not the current one.
    function testCannotDeliverResponseIncorrectInterval() public {
        // Create new subscription at time = 0, which will be active at t = 60s
        vm.warp(0);
        uint64 subId = SUBSCRIPTION.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID,
            2, // frequency = 2
            1 minutes,
            1,
            false,
            NO_PAYMENT_TOKEN,
            0,
            userWalletAddress,
            NO_VERIFIER
        );

        // Warp to the first active interval and send the request
        vm.warp(1 minutes);
        (, Commitment memory commitment1) = ROUTER.sendRequest(subId, 1);
        bytes memory commitmentData1 = abi.encode(commitment1);

        // Successfully deliver for interval 1
        ALICE.deliverCompute(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, address(ALICE));

        // Warp to the second interval
        vm.warp(2 minutes);

        // Now, the current interval is 2. Attempting to deliver for interval 1 should fail.
        // We use the commitment from the first interval to simulate this.
        vm.expectRevert(abi.encodeWithSelector(ICoordinatorEvents.IntervalMismatch.selector, 1));
        ALICE.deliverCompute(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, address(ALICE));
    }

}