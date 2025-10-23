// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {DelegateeCoordinator} from "../src/v1_0_0/DelegateeCoordinator.sol";
import {MockTransientComputeClient} from "./mocks/client/MockTransientComputeClient.sol";
import {DeployUtils} from "./lib/DeployUtils.sol";
import {MockAgent} from "./mocks/MockAgent.sol";
import {MockProtocol} from "./mocks/MockProtocol.sol";
import {MockScheduledComputeClient} from "./mocks/client/MockScheduledComputeClient.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {Router} from "../src/v1_0_0/Router.sol";
import {Test} from "forge-std/Test.sol";
import {WalletFactory} from "../src/v1_0_0/wallet/WalletFactory.sol";
import {Wallet} from "../src/v1_0_0/wallet/Wallet.sol";

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
abstract contract ComputeTest is Test, CoordinatorConstants {
    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Mock protocol wallet
    MockProtocol internal PROTOCOL;

    Router internal ROUTER;

    DelegateeCoordinator internal COORDINATOR;

    /// @notice Inbox
    //    Inbox internal INBOX;

    /// @notice Wallet factory
    WalletFactory internal walletFactory;

    /// @notice Mock ERC20 token
    MockToken internal erc20Token;

    /// @notice Mock node (Alice)
    MockAgent internal alice;

    /// @notice Mock node (Bob)
    MockAgent internal bob;

    /// @notice Mock node (Charlie)
    MockAgent internal charlie;

    /// @notice Mock callback consumer
    MockTransientComputeClient internal transientClient;

    /// @notice Mock subscription consumer
    MockScheduledComputeClient internal ScheduledClient;

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

    function setUp() public virtual {
        // Create mock protocol wallet
        uint256 initialNonce = vm.getNonce(address(this));
        address ownerProtocolWalletAddress = vm.computeCreateAddress(address(this), initialNonce + 4);

        // Initialize contracts
        DeployUtils.DeployedContracts memory contracts = DeployUtils.deployContracts(
            address(this), ownerProtocolWalletAddress, MOCK_PROTOCOL_FEE, address(erc20Token)
        );
        ROUTER = contracts.router;
        COORDINATOR = contracts.coordinator;
        walletFactory = contracts.walletFactory;

        ROUTER.setWalletFactory(address(contracts.walletFactory));
        PROTOCOL = new MockProtocol(COORDINATOR);
        erc20Token = new MockToken();

        // Initalize mock nodes
        alice = new MockAgent(ROUTER);
        bob = new MockAgent(ROUTER);
        charlie = new MockAgent(ROUTER);
        // Initialize mock callback consumer
        transientClient = new MockTransientComputeClient(address(ROUTER));

        // Initialize mock subscription consumer
        ScheduledClient = new MockScheduledComputeClient(address(ROUTER));

        // Initialize mock subscription consumer w/ Allowlist
        // Add only Alice as initially allowed node
        address[] memory initialAllowed = new address[](1);
        initialAllowed[0] = address(alice);

        // --- Wallet Setup Example ---
        // 1. Create a wallet. The test contract will be the client.
        userWalletAddress = walletFactory.createWallet(address(this));
        Wallet userWallet = Wallet(payable(userWalletAddress));
        aliceWalletAddress = walletFactory.createWallet(address(this));
        bobWalletAddress = walletFactory.createWallet(address(this));
        protocolWalletAddress = walletFactory.createWallet(ownerProtocolWalletAddress);

        // Approve the coordinator to spend from the protocol wallet for native token
        DeployUtils.updateBillingConfig(
            COORDINATOR, 1 weeks, protocolWalletAddress, MOCK_PROTOCOL_FEE, 0 ether, address(0)
        );

        // 2. Define payment details for a paid request.
        uint256 feeAmount = 0.1 ether;

        // 3. Fund the wallet with ETH to cover the payment.
        (bool success,) = userWalletAddress.call{value: 1 ether}("");
        require(success, "Failed to fund wallet");

        // 4. Approve the consumer contract (CALLBACK) to spend from the wallet.
        // The approval is for the native token (address(0)).
        userWallet.approve(address(transientClient), address(0), feeAmount);
        // --- End Wallet Setup ---
    }
}
