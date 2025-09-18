// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import "./mocks/consumer/MockCallbackConsumer.sol";
import {BaseConsumer} from "../src/v1_0_0/consumer/BaseConsumer.sol";
import {Coordinator} from "../src/v1_0_0/Coordinator.sol";
import {LibDeploy} from "./lib/LibDeploy.sol";
import {MockNode} from "./mocks/MockNode.sol";
import {MockProtocol} from "./mocks/MockProtocol.sol";
import {MockSubscriptionConsumer} from "./mocks/consumer/MockSubscriptionConsumer.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {WalletFactory} from "../src/v1_0_0/wallet/WalletFactory.sol";
import {Wallet} from "../src/v1_0_0/wallet/Wallet.sol";
import {Router} from "../src/v1_0_0/Router.sol";
import {Reader} from "../src/v1_0_0/utility/Reader.sol";
import {DeliveredOutput} from "./mocks/consumer/MockBaseConsumer.sol";

/// @title ICoordinatorEvents
/// @notice Events emitted by Coordinator
interface ICoordinatorEvents {
    event SubscriptionCreated(uint64 indexed id);
    event SubscriptionCancelled(uint64 indexed id);
    event CommitmentTimedOut(bytes32 indexed requestId, uint64 indexed subscriptionId, uint32 indexed interval);
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

/// @title IWalletEvents
/// @notice Events emitted by Wallet
interface IWalletEvents {
    event Deposit(address indexed token, uint256 amount);
    event Withdraw(address token, uint256 amount);
    event Approval(address indexed spender, address indexed token, uint256 amount);
    event RequestLocked(
        bytes32 indexed requestId, address indexed spender, address token, uint256 totalAmount, uint16 redundancy
    );
    event RequestReleased(bytes32 indexed requestId, address indexed spender, address token, uint256 amountRefunded);
    event RequestDisbursed(
        bytes32 indexed requestId, address indexed to, address token, uint256 amount, uint16 paidCount
    );
}

/// @title ISubscriptionManagerErrors
/// @notice Errors emitted by SubscriptionManager
interface ISubscriptionManagerErrors {
    error NoSuchCommitment();
    error CommitmentNotTimeoutable();
    error SubscriptionNotActive();
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

    address internal aliceWalletAddress;

    address internal bobWalletAddress;

    address internal protocolWalletAddress;

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
        address ownerProtocolWalletAddress = vm.computeCreateAddress(address(this), initialNonce + 4);

        // Initialize contracts
        (Router router, Coordinator coordinator, Reader reader, WalletFactory walletFactory) = LibDeploy.deployContracts(
            address(this), initialNonce, ownerProtocolWalletAddress, MOCK_PROTOCOL_FEE, address(TOKEN)
        );
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
        aliceWalletAddress = WALLET_FACTORY.createWallet(address(this));
        bobWalletAddress = WALLET_FACTORY.createWallet(address(this));
        protocolWalletAddress = WALLET_FACTORY.createWallet(ownerProtocolWalletAddress);

        // Fund protocol wallet with ETH
//        vm.deal(protocolWalletAddress, 10 ether);
//        vm.startPrank(ownerProtocolWalletAddress);
//        Wallet(payable(protocolWalletAddress)).approve(address(COORDINATOR), address(0), 10 ether);
//        vm.stopPrank();

        // Approve the coordinator to spend from the protocol wallet for native token
        LibDeploy.updateBillingConfig(coordinator, 1 weeks,
            protocolWalletAddress, MOCK_PROTOCOL_FEE,
            0, 0 ether, address(0));

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
        (uint64 id2,) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );
        // Assert head
        assertEq(id2, 2);

        // Delete subscriptions
        vm.startPrank(address(CALLBACK));
        ROUTER.timeoutRequest(commitment1.requestId, commitment1.subscriptionId, commitment1.interval);
        ROUTER.cancelSubscription(1);

        // Create new subscription
        (uint64 id3,) = CALLBACK.createMockRequest(
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
        (uint64 actual,) = CALLBACK.createMockRequest(
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
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, aliceWalletAddress, 1);

        // Call the function that emits the event.
        bytes memory commitmentData = abi.encode(commitment);
        vm.prank(address(ALICE));
        ALICE.deliverCompute(
            commitment.interval, // Use the correct interval from the commitment
            MOCK_INPUT,
            MOCK_OUTPUT,
            MOCK_PROOF,
            commitmentData,
            aliceWalletAddress
        );
        // --- 3. Assert: Verify the outcome ---
        DeliveredOutput memory out = CALLBACK.getDeliveredOutput(subId, 1, 1);
        assertEq(out.subscriptionId, subId);
        assertEq(out.interval, 1);
        assertEq(out.redundancy, 1);
        assertEq(out.node, aliceWalletAddress);
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
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, aliceWalletAddress, 1);
        ALICE.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, aliceWalletAddress);

        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, bobWalletAddress, 2);
        BOB.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWalletAddress);

        // Assert delivery
        address[2] memory nodes = [aliceWalletAddress, bobWalletAddress];
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
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, aliceWalletAddress, 1);
        ALICE.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, aliceWalletAddress);
        vm.expectRevert(Coordinator.NodeRespondedAlready.selector);
        ALICE.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, aliceWalletAddress);
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
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, aliceWalletAddress, 1);
        ALICE.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, aliceWalletAddress);

        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, bobWalletAddress, 2);
        BOB.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWalletAddress);

        // Attempt to deliver a third response (exceeds redundancy)
        // The Coordinator should revert with a RequestCompleted error.
        vm.expectRevert(abi.encodeWithSelector(ICoordinatorEvents.RequestCompleted.selector, commitment.requestId));
        CHARLIE.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWalletAddress);
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
        (uint64 subId, Commitment memory commitment) = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 1 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        bytes memory commitmentData = abi.encode(commitment);

        // Fulfill at least once
        vm.warp(block.timestamp + 1 minutes);
        vm.expectEmit(true, true, true, true, address(COORDINATOR));
        emit ICoordinatorEvents.ComputeDelivered(commitment.requestId, aliceWalletAddress, 1);
        ALICE.deliverCompute(commitment.interval, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, aliceWalletAddress);

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
        ALICE.deliverCompute(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, aliceWalletAddress);

        // Warp to the second interval
        vm.warp(2 minutes);

        // Now, the current interval is 2. Attempting to deliver for interval 1 should fail.
        // We use the commitment from the first interval to simulate this.
        vm.expectRevert(abi.encodeWithSelector(ICoordinatorEvents.IntervalMismatch.selector, 1));
        ALICE.deliverCompute(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, aliceWalletAddress);
    }
}
/// @title CoordinatorEagerPaymentNoProofTest
/// @notice Coordinator tests specific to eager subscriptions with payments but no proofs
contract CoordinatorEagerPaymentNoProofTest is CoordinatorTest {
    /// @notice Subscription can be fulfilled with ETH payment
    function testSubscriptionCanBeFulfilledWithETHPayment() public {
        // Create new wallet with Alice as owner
        address aliceWallet = WALLET_FACTORY.createWallet(address(ALICE));

        // Create new wallet with Bob as owner
        address bobWallet = WALLET_FACTORY.createWallet(address(BOB));

        // Fund alice wallet with 1 ether
        vm.deal(aliceWallet, 1 ether);

        // Create new one-time subscription with 1 eth payout
//        uint32 subId = CALLBACK.createMockRequest(
//            MOCK_CONTAINER_ID, MOCK_INPUT, 1, ZERO_ADDRESS, 1 ether, aliceWallet, NO_VERIFIER
//        );

        // Allow CALLBACK consumer to spend alice wallet balance up to 1 ether
        vm.prank(address(ALICE));
        Wallet(payable(aliceWallet)).approve(address(CALLBACK), ZERO_ADDRESS, 1 ether);

        (uint64 subId, Commitment memory commitment) =
                            CALLBACK.createMockRequest(MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, ZERO_ADDRESS, 1 ether, aliceWallet, NO_VERIFIER);
        assertEq(subId, 1);

        // Verify initial balances and allowances
        assertEq(aliceWallet.balance, 1 ether);

        bytes memory commitmentData = abi.encode(commitment);
        vm.prank(address(BOB));
        BOB.deliverCompute(
            commitment.interval, // Use the correct interval from the commitment
            MOCK_INPUT,
            MOCK_OUTPUT,
            MOCK_PROOF,
            commitmentData,
            bobWallet
        );

        // Execute response fulfillment from Bob
//        BOB.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, bobWallet);

        // Assert new balances
        assertEq(aliceWallet.balance, 0 ether);
        assertEq(bobWallet.balance, 0.8978 ether);
        assertEq(protocolWalletAddress.balance, 0.1022 ether);

        // Assert consumed allowance
        assertEq(Wallet(payable(aliceWallet)).allowance(address(CALLBACK), ZERO_ADDRESS), 0 ether);
    }

    /// @notice Subscription can be fulfilled with ERC20 payment
    function testSubscriptionCanBeFulfilledWithERC20() public {
        // Create new wallet with Alice as owner
        address aliceWallet = WALLET_FACTORY.createWallet(address(ALICE));

        // Create new wallet with Bob as owner
        address bobWallet = WALLET_FACTORY.createWallet(address(BOB));

        // Mint 100 tokens to alice wallet
        TOKEN.mint(aliceWallet, 100e6);

        // Create new one-time subscription with 50e6 payout
//        uint32 subId = CALLBACK.createMockRequest(MOCK_CONTAINER_ID, MOCK_INPUT, 1, address(TOKEN), 50e6, aliceWallet, NO_VERIFIER);

        // Allow CALLBACK consumer to spend alice wallet balance up to 90e6 tokens
        vm.prank(address(ALICE));
        Wallet(payable(aliceWallet)).approve(address(CALLBACK), address(TOKEN), 90e6);

        (uint64 subId, Commitment memory commitment) =
                            CALLBACK.createMockRequest(MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, address(TOKEN), 50e6, aliceWallet, NO_VERIFIER);
        assertEq(subId, 1);

        // Verify initial balances and allowances
        assertEq(TOKEN.balanceOf(aliceWallet), 100e6);

        bytes memory commitmentData = abi.encode(commitment);
        vm.prank(address(BOB));
        BOB.deliverCompute(
            commitment.interval, // Use the correct interval from the commitment
            MOCK_INPUT,
            MOCK_OUTPUT,
            MOCK_PROOF,
            commitmentData,
            bobWallet
        );

        // Assert new balances
        assertEq(TOKEN.balanceOf(aliceWallet), 50e6);
        assertEq(TOKEN.balanceOf(bobWallet), 44_890_000);
        assertEq(TOKEN.balanceOf(protocolWalletAddress), 5_110_000);

        // Assert consumed allowance
        assertEq(Wallet(payable(aliceWallet)).allowance(address(CALLBACK), address(TOKEN)), 40e6);
    }

//    /// @notice Subscription can be fulfilled across intervals with ERC20 payment
    function testSubscriptionCanBeFulfilledAcrossIntervalsWithERC20Payment() public {
        // Create new wallet with Alice as owner
        address aliceWallet = WALLET_FACTORY.createWallet(address(ALICE));

        // Create new wallet with Bob as owner
        address bobWallet = WALLET_FACTORY.createWallet(address(BOB));

        // Mint 100 tokens to alice wallet
        TOKEN.mint(aliceWallet, 100e6);

        // Create new two-time subscription with 40e6 payout
        vm.warp(0 minutes);
//        uint32 subId = SUBSCRIPTION.createMockSubscription(
//            MOCK_CONTAINER_ID, 2, 1 minutes, 1, false, address(TOKEN), 40e6, aliceWallet, NO_VERIFIER
//        );

        // Allow CALLBACK consumer to spend alice wallet balance up to 90e6 tokens
        vm.prank(address(ALICE));
        Wallet(payable(aliceWallet)).approve(address(SUBSCRIPTION), address(TOKEN), 90e6);

        // Verify initial balances and allowances
        assertEq(TOKEN.balanceOf(aliceWallet), 100e6);

        (uint64 subId, Commitment memory commitment) = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID, 2, 1 minutes, 2, false, address(TOKEN), 40e6, aliceWallet, NO_VERIFIER
        );

        // Execute response fulfillment from Bob
        vm.warp(1 minutes);
        bytes memory commitmentData = abi.encode(commitment);
        BOB.deliverCompute(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWallet);
//        BOB.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, bobWallet);

        // Execute response fulfillment from Charlie (notice that for no proof submissions there is no collateral so we can use any wallet)
        vm.warp(2 minutes);
        CHARLIE.deliverCompute(2, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWallet);
//        CHARLIE.deliverCompute(subId, 2, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, bobWallet);

        // Assert new balances
        assertEq(TOKEN.balanceOf(aliceWallet), 20e6);
        assertEq(TOKEN.balanceOf(bobWallet), (40e6 * 2) - (4_088_000 * 2));
        assertEq(TOKEN.balanceOf(protocolWalletAddress), 4_088_000 * 2);

        // Assert consumed allowance
        assertEq(Wallet(payable(aliceWallet)).allowance(address(SUBSCRIPTION), address(TOKEN)), 10e6);
    }

    /// @notice Subscription cannot be fulfilled with an invalid `Wallet` not created by `WalletFactory`
    function testSubscriptionCannotBeFulfilledWithInvalidWalletProvenance() public {
        // Create new wallet for Alice directly
        Wallet aliceWallet = new Wallet(address(ROUTER), address(ALICE));

        // Fund the wallet with tokens, as it's created empty.
        TOKEN.mint(address(aliceWallet), 100e6);

        // Create a new wallet with Bob as the owner.
        address bobWallet = WALLET_FACTORY.createWallet(address(BOB));

        // The owner of the wallet (ALICE) must approve the consumer (CALLBACK) to spend funds.
        vm.prank(address(ALICE));
        aliceWallet.approve(address(CALLBACK), address(TOKEN), 50e6);

        vm.expectRevert(bytes("InvalidWallet()"));
        // Create a new one-time subscription with a 50e6 payout.
        (uint64 subId, Commitment memory commitment) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, address(TOKEN), 50e6, address(aliceWallet), NO_VERIFIER
        );

//        vm.expectRevert(bytes("InvalidWallet()"));
////        vm.expectRevert(Router.InvalidWallet.selector);
//        bytes memory commitmentData = abi.encode(commitment);
//        BOB.deliverCompute(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, bobWallet);
////        BOB.deliverCompute(subId, 1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, bobWallet);
    }

    /// @notice Subscription cannot be fulfilled with an invalid `nodeWallet` not created by `WalletFactory`
    function testSubscriptionCannotBeFulfilledWithInvalidNodeWalletProvenance() public {
        // Create new wallet with Alice as owner
        address aliceWallet = WALLET_FACTORY.createWallet(address(ALICE));
        TOKEN.mint(address(aliceWallet), 100e6);

        vm.prank(address(ALICE));
//        aliceWallet.approve(address(CALLBACK), address(TOKEN), 50e6);
        Wallet(payable(aliceWallet)).approve(address(CALLBACK), address(TOKEN), 50e6);

        // Create a new one-time subscription with a 50e6 payout.
        (uint64 subId, Commitment memory commitment) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, address(TOKEN), 50e6, aliceWallet, NO_VERIFIER
        );

        Wallet bobWallet = new Wallet(address(ROUTER), address(BOB));
        // Execute response fulfillment from Bob using address(BOB) as nodeWallet
        vm.expectRevert(bytes("InvalidWallet()"));
        bytes memory commitmentData = abi.encode(commitment);
        BOB.deliverCompute(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData, address(bobWallet));
    }

    /// @notice Subscription cannot be fulfilled if `Wallet` does not approve consumer
    function testSubscriptionCannotBeFulfilledIfSpenderNoAllowance() public {
        // Create new wallets
        address aliceWallet = WALLET_FACTORY.createWallet(address(ALICE));
        address bobWallet = WALLET_FACTORY.createWallet(address(BOB));

        // Fund alice wallet with 1 ether
        vm.deal(aliceWallet, 1 ether);
        // Verify CALLBACK has 0 allowance to spend on aliceWallet
        assertEq(Wallet(payable(aliceWallet)).allowance(address(CALLBACK), ZERO_ADDRESS), 0 ether);

        vm.expectRevert(Wallet.InsufficientAllowance.selector);
        (uint64 subId, Commitment memory commitment) = CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, ZERO_ADDRESS, 1 ether, aliceWallet, NO_VERIFIER
        );
    }

    /// @notice Subscription cannot be fulfilled if `Wallet` only partially approves consumer
    function testSubscriptionCannotBeFulfilledIfSpenderPartialAllowance() public {
        // Create new wallets.
        address aliceWallet = WALLET_FACTORY.createWallet(address(ALICE));
        address bobWallet = WALLET_FACTORY.createWallet(address(BOB));

        // Fund aliceWallet with 1 ether.
        vm.deal(aliceWallet, 1 ether);

        // Increase callback allowance to just under the required 1 ether.
        vm.startPrank(address(ALICE));
        Wallet(payable(aliceWallet)).approve(address(CALLBACK), ZERO_ADDRESS, 1 ether - 1 wei);

        // Expect the request creation to fail because the consumer (CALLBACK) has insufficient allowance.
        vm.expectRevert(Wallet.InsufficientAllowance.selector);

        // Attempt to create a new one-time subscription with a 1 ether payout.
        CALLBACK.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, ZERO_ADDRESS, 1 ether, aliceWallet, NO_VERIFIER
        );
    }
}

contract CoordinatorNextIntervalPrepareTest is CoordinatorTest {
    function testPreparesNextIntervalOnDelivery() public {
        // 1. Create a recurring, paid subscription
        address aliceWallet = WALLET_FACTORY.createWallet(address(ALICE));
        address bobWallet = WALLET_FACTORY.createWallet(address(BOB));

        uint256 paymentAmount = 40e6;
        uint16 redundancy = 2;
        uint256 totalPaymentForTwoIntervals = paymentAmount * redundancy * 2;

        // 2. Fund the wallet
        TOKEN.mint(aliceWallet, totalPaymentForTwoIntervals + 10e6); // Mint extra

        // 3. Approve the consumer
        vm.prank(address(ALICE));
        Wallet(payable(aliceWallet)).approve(address(SUBSCRIPTION), address(TOKEN), totalPaymentForTwoIntervals);

        // 4. Create subscription and first request (interval 1)
        vm.warp(0);
        (uint64 subId, Commitment memory commitment1) = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID,
            2, // frequency
            1 minutes, // period
            redundancy,
            false, // lazy
            address(TOKEN),
            paymentAmount,
            aliceWallet,
            NO_VERIFIER
        );

        // 5. Warp to the first interval and deliver the compute
        vm.warp(1 minutes);
        bytes memory commitmentData1 = abi.encode(commitment1);

        // --- Assertions for the next interval preparation ---
        // Expect a new request to be started for interval 2
        bytes32 requestId2 = keccak256(abi.encodePacked(subId, uint32(2)));
        // Expect funds to be locked for the second request
        vm.expectEmit(true, true, false, false, address(Wallet(payable(aliceWallet))));
        emit Wallet.RequestLocked(
            requestId2, address(SUBSCRIPTION), address(TOKEN), paymentAmount * redundancy, redundancy
        );
        // 6. Deliver compute for interval 1, which triggers preparation for interval 2
        vm.prank(address(BOB));
        BOB.deliverCompute(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, bobWallet);

        // 7. Final assertions on wallet state
        assertEq(Wallet(payable(aliceWallet)).lockedOfRequest(requestId2), paymentAmount * redundancy, "Funds for interval 2 should be locked");
    }

    function testDoesNotPrepareNextIntervalOnFinalDelivery() public {
        // 1. Create a subscription with a frequency of 1 (a single-shot request).
        address consumerWallet = WALLET_FACTORY.createWallet(address(this));
        address nodeWallet = WALLET_FACTORY.createWallet(address(BOB));
        uint256 paymentAmount = 40e6;
        TOKEN.mint(consumerWallet, paymentAmount);
        vm.prank(address(this));
        Wallet(payable(consumerWallet)).approve(address(CALLBACK), address(TOKEN), paymentAmount);

        (, Commitment memory commitment1) =
                            CALLBACK.createMockRequest(MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, address(TOKEN), paymentAmount, consumerWallet, NO_VERIFIER);

        // 2. Deliver the compute for the final (and only) interval.
        bytes memory commitmentData1 = abi.encode(commitment1);

        // 3. Record logs to check for the absence of next-interval events.
        vm.recordLogs();

        // 4. Deliver compute.
        vm.prank(address(BOB));
        BOB.deliverCompute(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, nodeWallet);

        // 5. Assert that no events related to preparing a next interval were emitted.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 requestStartSelector = ICoordinatorEvents.RequestStart.selector;
        bytes32 requestLockedSelector = Wallet.RequestLocked.selector;

        for (uint i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], requestStartSelector, "Should not emit RequestStart");
            assertNotEq(logs[i].topics[0], requestLockedSelector, "Should not emit RequestLocked");
        }
    }

    function test_RevertWhen_PrepareNextIntervalWithInsufficientFunds() public {
        // 1. Create a recurring subscription.
        address consumerWallet = WALLET_FACTORY.createWallet(address(this));
        address nodeWallet = WALLET_FACTORY.createWallet(address(BOB));
        uint256 paymentAmount = 40e6;
        uint16 redundancy = 2;

        // 2. Fund the wallet with enough for ONLY the first interval
        uint256 paymentForOneInterval = paymentAmount * redundancy;
        TOKEN.mint(consumerWallet, paymentForOneInterval);

        // 3. Approve for two intervals (even though funds are insufficient)
        vm.prank(address(this));
        Wallet(payable(consumerWallet)).approve(address(SUBSCRIPTION), address(TOKEN), paymentForOneInterval * 2);

        // 4. Create subscription and first request
        (uint64 subId, Commitment memory commitment1) = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID, 2, 1 minutes, redundancy, false, address(TOKEN), paymentAmount, consumerWallet, NO_VERIFIER
        );
        // 5. Deliver compute for the first interval
        vm.warp(block.timestamp + 1 minutes);
        bytes memory commitmentData1 = abi.encode(commitment1);
//        console.log("Test Interval : ", ROUTER.getSubscriptionInterval(subId));

        // 6. Deliver compute. This should succeed, but it should NOT trigger the next interval preparation
        // because hasSubscriptionNextInterval will return false due to insufficient funds.
        vm.prank(address(BOB));
        BOB.deliverCompute(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, nodeWallet);

        // 7. Assert that no funds were locked for the next interval.
        bytes32 requestId2 = keccak256(abi.encodePacked(subId, uint32(2)));
        assertEq(Wallet(payable(consumerWallet)).lockedOfRequest(requestId2), 0, "Should not lock funds for next interval");
    }

    function test_DoesNotPrepareNextInterval_When_InsufficientAllowance() public {
        // 1. Create a recurring subscription.
        address consumerWallet = WALLET_FACTORY.createWallet(address(this));
        address nodeWallet = WALLET_FACTORY.createWallet(address(BOB));
        uint256 paymentAmount = 40e6;
        uint16 redundancy = 2;

        // 2. Fund the wallet with enough for two intervals
        uint256 paymentForOneInterval = paymentAmount * redundancy;
        TOKEN.mint(consumerWallet, paymentForOneInterval * 2);

        // 3. Approve for ONLY one interval
        vm.prank(address(this));
        Wallet(payable(consumerWallet)).approve(address(SUBSCRIPTION), address(TOKEN), paymentForOneInterval);

        // 4. Create subscription and first request
        (uint64 subId, Commitment memory commitment1) = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID, 2, 1 minutes, redundancy, false, address(TOKEN), paymentAmount, consumerWallet, NO_VERIFIER
        );

        // 5. Deliver compute for the first interval
        vm.warp(block.timestamp + 1 minutes);
        bytes memory commitmentData1 = abi.encode(commitment1);

        // 6. Deliver compute. This should succeed, but it should NOT trigger the next interval preparation
        // because hasSubscriptionNextInterval will return false due to insufficient allowance.
        vm.prank(address(BOB));
        BOB.deliverCompute(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, nodeWallet);

        // 7. Assert that no funds were locked for the next interval.
        bytes32 requestId2 = keccak256(abi.encodePacked(subId, uint32(2)));
        assertEq(Wallet(payable(consumerWallet)).lockedOfRequest(requestId2), 0, "Should not lock funds for next interval due to allowance");
    }

    function testPaysTickFeeOnNextIntervalPreparation() public {
        // 1. Arrange: Set the tickNodeFee specifically for this test.
        uint256 expectedTickFee = 0.01 ether;

        // Create a recurring subscription and a node wallet.
        address consumerWallet = WALLET_FACTORY.createWallet(address(this));
        address nodeWallet = WALLET_FACTORY.createWallet(address(BOB)); // This wallet will receive the tick fee.
        address protocolWallet = WALLET_FACTORY.createWallet(address(this));
        uint16 redundancy = 1;
        uint256 paymentAmount = 1 ether;

        // Fund protocol wallet with ETH
        vm.deal(protocolWallet, 10 ether);
        vm.startPrank(address(this));
        Wallet(payable(protocolWallet)).approve(address(COORDINATOR), address(0), 10 ether);
        vm.stopPrank();
        LibDeploy.updateBillingConfig(
            COORDINATOR, 1 weeks, protocolWallet, MOCK_PROTOCOL_FEE, 0, expectedTickFee, address(0)
        );

        // Fund the consumer wallet for the subscription payments
        vm.deal(consumerWallet, paymentAmount * 2); // Fund for two intervals

        // Approve the SUBSCRIPTION consumer to spend from the wallet
        vm.prank(address(this));
        Wallet(payable(consumerWallet)).approve(address(SUBSCRIPTION), ZERO_ADDRESS, paymentAmount * 2);

        // Create the subscription
        (uint64 subId, Commitment memory commitment) = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID, 2, 1 minutes, redundancy, false, ZERO_ADDRESS, paymentAmount, consumerWallet, NO_VERIFIER
        );
        assertEq(subId, 1);

        // 2. Act: Deliver compute for the first interval, which triggers preparation for the second.
        vm.warp(block.timestamp + 1 minutes);
        bytes memory commitmentData1 = abi.encode(commitment);
        vm.prank(address(BOB));
        BOB.deliverCompute(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, nodeWallet);

        // 3. Assert: Check if the node wallet received the tick fee.
        uint256 computeFee = 0.8978 ether;
        uint256 finalNodeWalletBalance = expectedTickFee + computeFee;

        // Get initial balance of the node wallet that will trigger the tick
        uint256 nodeWalletBalance = nodeWallet.balance;
        assertEq(nodeWalletBalance, finalNodeWalletBalance, "Node wallet should receive the tick fee");
    }
}

contract CoordinatorTimeoutRequestTest is CoordinatorTest, ISubscriptionManagerErrors {
    function testCanTimeoutRequest() public {
        // 1. Create a recurring, paid subscription
        address consumerWallet = WALLET_FACTORY.createWallet(address(this));
        uint256 paymentAmount = 40e6;
        uint16 redundancy = 2;
        uint256 paymentForOneInterval = paymentAmount * redundancy;
        TOKEN.mint(consumerWallet, paymentForOneInterval * 2); // Fund for two intervals

        vm.prank(address(this));
        Wallet(payable(consumerWallet)).approve(address(SUBSCRIPTION), address(TOKEN), paymentForOneInterval * 2);

        // Create subscription and first request
        (uint64 subId, Commitment memory commitment1) = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID,
            3, // frequency
            1 minutes, // period
            redundancy,
            false, // lazy
            address(TOKEN),
            paymentAmount,
            consumerWallet,
            NO_VERIFIER
        );

        // 2. Warp time to the *second* interval, making the first one timeoutable
        vm.warp(block.timestamp + 2 minutes); // currentInterval will be 2

        // 3. Assert that funds are initially locked for the first request
        assertEq(Wallet(payable(consumerWallet)).lockedOfRequest(commitment1.requestId), paymentForOneInterval);

        // 4. Expect the CommitmentTimedOut event from the Router
        vm.expectEmit(true, true, true, true, address(ROUTER));
        emit ICoordinatorEvents.CommitmentTimedOut(commitment1.requestId, subId, 1);

        // 5. Call timeoutRequest for the first interval. Anyone can call this.
        ROUTER.timeoutRequest(commitment1.requestId, subId, 1);

        // 6. Assert that funds have been released
        assertEq(Wallet(payable(consumerWallet)).lockedOfRequest(commitment1.requestId), 0, "Funds should be released after timeout");
    }

    function test_RevertWhen_TimeoutRequestForCurrentInterval() public {
        // 1. Create a recurring subscription
        (uint64 subId, Commitment memory commitment1) = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 1 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // 2. Warp time to the *first* interval. The request is not yet in the past.
        vm.warp(block.timestamp + 1 minutes);

        // 3. Expect a revert because the interval is not in the past
        vm.expectRevert(CommitmentNotTimeoutable.selector);
        ROUTER.timeoutRequest(commitment1.requestId, subId, 1);
    }

    function test_RevertWhen_TimeoutRequestForNotYetActiveSubscription() public {
        // 1. Create a recurring subscription. The first request is created immediately.
        (uint64 subId, Commitment memory commitment1) = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID, 3, 1 minutes, 1, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        // 2. Do NOT warp time. The subscription's activeAt is `block.timestamp + 1 minutes`.
        // The current block.timestamp is before activeAt.

        // 3. Expect a revert because the subscription is not active
        vm.expectRevert(bytes("SubscriptionNotActive()"));
        ROUTER.timeoutRequest(commitment1.requestId, subId, 1);
    }

    function test_RevertWhen_TimeoutNonExistentRequest() public {
        // 1. Create a subscription but don't create a request for interval 2
        uint64 subId = SUBSCRIPTION.createMockSubscriptionWithoutRequest(
            MOCK_CONTAINER_ID, 3, 1 minutes, 1, false, NO_PAYMENT_TOKEN, 0, NO_WALLET, NO_VERIFIER
        );

        // 2. Warp time to make the subscription active
        vm.warp(block.timestamp + 2 minutes);

        // 3. Attempt to timeout a request for an interval that was never requested
        bytes32 nonExistentRequestId = keccak256(abi.encodePacked(subId, uint32(2)));
        vm.expectRevert(NoSuchCommitment.selector);
        ROUTER.timeoutRequest(nonExistentRequestId, subId, 2);
    }

    function test_RevertWhen_DeliverComputeForTimedOutRequest() public {
        // 1. Create a recurring, paid subscription and its first request
        address consumerWallet = WALLET_FACTORY.createWallet(address(this));
        address nodeWallet = WALLET_FACTORY.createWallet(address(BOB));
        uint256 paymentAmount = 40e6;
        uint16 redundancy = 1;
        uint256 paymentForOneInterval = paymentAmount * redundancy;
        TOKEN.mint(consumerWallet, paymentForOneInterval);

        vm.prank(address(this));
        Wallet(payable(consumerWallet)).approve(address(SUBSCRIPTION), address(TOKEN), paymentForOneInterval);

        (uint64 subId, Commitment memory commitment1) = SUBSCRIPTION.createMockSubscription(
            MOCK_CONTAINER_ID,
            2, // frequency
            1 minutes, // period
            redundancy,
            false, // lazy
            address(TOKEN),
            paymentAmount,
            consumerWallet,
            NO_VERIFIER
        );

        // 2. Warp time to make the request timeoutable and then time it out.
        vm.warp(block.timestamp + 2 minutes);
        ROUTER.timeoutRequest(commitment1.requestId, subId, 1);

        // 3. Attempt to deliver compute for the now-timed-out request.
        // It should revert because the coordinator detects a mismatch between the
        // delivery interval (1) and the current system interval (2).
        bytes memory commitmentData1 = abi.encode(commitment1);
        vm.expectRevert(abi.encodeWithSelector(ICoordinatorEvents.IntervalMismatch.selector, 1));
        vm.prank(address(BOB));
        BOB.deliverCompute(1, MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, commitmentData1, nodeWallet);
    }
}
