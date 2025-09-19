// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.4;

import {ICoordinatorEvents} from "./Coordinator.t.sol";
import {CoordinatorConstants} from "./Coordinator.t.sol";
import {EIP712Coordinator} from "../src/v1_0_0/EIP712Coordinator.sol";
import {LibDeploy} from "./lib/LibDeploy.sol";
import {MockDelegatorCallbackConsumer} from "../src/v1_0_0/consumer/DelegatorCallbackConsumer.sol";
import {MockDelegatorSubscriptionConsumer} from "../src/v1_0_0/consumer/DelegatorSubscriptionConsumer.sol";
import {MockNode} from "./mocks/MockNode.sol";
import {MockProtocol} from "./mocks/MockProtocol.sol";
import {Test} from "forge-std/Test.sol";
import {Router} from "../src/v1_0_0/Router.sol";
import {WalletFactory} from "../src/v1_0_0/wallet/WalletFactory.sol";
import {Wallet} from "../src/v1_0_0/wallet/Wallet.sol";
import {console} from "forge-std/console.sol";
import {Commitment} from "../src/v1_0_0/types/Commitment.sol";
import {Subscription} from "../src/v1_0_0/types/Subscription.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {Reader} from "../src/v1_0_0/utility/Reader.sol";
import {LibSign} from "./lib/LibSign.sol";
import {Subscription} from "../src/v1_0_0/types/Subscription.sol";
import {Delegator} from "../src/v1_0_0/utility/Delegator.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";

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
        console.log("DELEGATEE_ADDRESS: ", DELEGATEE_ADDRESS);

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

    function testCannotCreateDelegatedSubscriptionWhereSignatureExpired() public {
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
    function testFuzzCannotCreateDelegatedSubscriptionWhereSignatureMismatch(uint256 privateKey) public {
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
    function testCanCreateNewSubscriptionViaEIP712() public {
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
    function testCannotUseValidDelegatedSubscriptionFromOldSigner() public {
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
    function testCanUseExistingDelegatedSubscriptionFromOldSigner() public {
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

}