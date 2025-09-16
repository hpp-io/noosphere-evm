// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Router} from "../../src/v1_0_0/Router.sol";
import {Coordinator} from "../../src/v1_0_0/Coordinator.sol";
import {Wallet} from "../../src/v1_0_0/wallet/Wallet.sol";
import {WalletFactory} from "../../src/v1_0_0/wallet/WalletFactory.sol";
import {Payment} from "../../src/v1_0_0/types/Payment.sol";
import {MockToken} from "../mocks/MockToken.sol";
import {LibDeploy} from "../lib/LibDeploy.sol";

/// @title IWalletEvents
/// @notice Events emitted by Wallet
interface IWalletEvents {
    event Deposit(address indexed token, uint256 amount);
    event Withdraw(address token, uint256 amount);
    event Approval(address indexed spender, address indexed token, uint256 amount);
    event RequestLocked(bytes32 indexed requestId, address indexed spender, address token, uint256 totalAmount, uint16 redundancy);
    event RequestReleased(bytes32 indexed requestId, address indexed spender, address token, uint256 amountRefunded);
    event RequestDisbursed(bytes32 indexed requestId, address indexed to, address token, uint256 amount, uint16 paidCount);
}


abstract contract WalletTest is Test, IWalletEvents {
    Router internal ROUTER;
    Coordinator internal COORDINATOR;
    WalletFactory internal WALLET_FACTORY;
    Wallet internal userWallet;
    MockToken internal TOKEN;

    address internal owner;
    address internal spender; // Represents the consumer contract
    address internal node1;
    address internal node2;
    address internal node3;

    uint256 internal constant INITIAL_ETH_FUNDS = 10 ether;
    uint256 internal constant INITIAL_TOKEN_FUNDS = 10_000e18;
    uint256 internal constant INITIAL_ALLOWANCE = 5 ether;

    function setUp() public virtual {
        // Create users
        owner = makeAddr("owner");
        spender = makeAddr("spender");
        node1 = makeAddr("node1");
        node2 = makeAddr("node2");
        node3 = makeAddr("node3");

        // Deploy core contracts
        uint256 initialNonce = vm.getNonce(address(this));
        (Router router, Coordinator coordinator, , WalletFactory walletFactory) = LibDeploy.deployContracts(
            address(this), initialNonce, owner, 1
        );
        ROUTER = router;
        COORDINATOR = coordinator;
        WALLET_FACTORY = walletFactory;
        router.setWalletFactory(address(walletFactory));

        // Create and fund user wallet
        vm.prank(owner);
        address walletAddress = WALLET_FACTORY.createWallet(owner);
        userWallet = Wallet(payable(walletAddress));

        // Fund with ETH
        vm.deal(address(userWallet), INITIAL_ETH_FUNDS);

        // Fund with ERC20
        TOKEN = new MockToken();
        TOKEN.mint(address(userWallet), INITIAL_TOKEN_FUNDS);

        // Set initial allowance for the spender
        vm.prank(owner);
        userWallet.approve(spender, address(0), INITIAL_ALLOWANCE); // ETH allowance
        vm.prank(owner);
        userWallet.approve(spender, address(TOKEN), INITIAL_ALLOWANCE); // Token allowance
    }
}

/// @title WalletRequestLockTest
/// @notice Tests the request-level locking mechanism of the Wallet.
contract WalletRequestLockTest is WalletTest {
    bytes32 internal requestId = keccak256("test-request-1");

    /// @notice Tests successful locking of ETH for a request.
    function test_lockForRequest_Succeeds_ETH() public {
        uint256 lockAmount = 1 ether;
        uint16 redundancy = 3;

        vm.startPrank(address(ROUTER));

        vm.expectEmit(true, true, false, false, address(userWallet));
        emit RequestLocked(requestId, spender, address(0), lockAmount, redundancy);

        userWallet.lockForRequest(spender, address(0), lockAmount, requestId, redundancy);

        vm.stopPrank();

        assertEq(userWallet.allowance(spender, address(0)), INITIAL_ALLOWANCE - lockAmount, "ETH allowance should be reduced");
        assertEq(userWallet.lockedOf(spender, address(0)), lockAmount, "Spender's locked ETH balance should be updated");
        assertEq(userWallet.totalLockedFor(address(0)), lockAmount, "Total locked ETH should be updated");
        assertEq(userWallet.lockedOfRequest(requestId), lockAmount, "Request lock remaining amount should be correct");
        assertEq(userWallet.paidCountOfRequest(requestId), 0, "Request lock paid count should be 0");
    }

    /// @notice Tests successful locking of ERC20 tokens for a request.
    function test_lockForRequest_Succeeds_ERC20() public {
        uint256 lockAmount = 1 ether;
        uint16 redundancy = 2;

        vm.startPrank(address(ROUTER));

        vm.expectEmit(true, true, false, false, address(userWallet));
        emit RequestLocked(requestId, spender, address(TOKEN), lockAmount, redundancy);

        userWallet.lockForRequest(spender, address(TOKEN), lockAmount, requestId, redundancy);

        vm.stopPrank();

        assertEq(userWallet.allowance(spender, address(TOKEN)), INITIAL_ALLOWANCE - lockAmount, "Token allowance should be reduced");
        assertEq(userWallet.lockedOf(spender, address(TOKEN)), lockAmount, "Spender's locked Token balance should be updated");
        assertEq(userWallet.totalLockedFor(address(TOKEN)), lockAmount, "Total locked Token should be updated");
        assertEq(userWallet.lockedOfRequest(requestId), lockAmount, "Request lock remaining amount should be correct");
    }

    /// @notice Tests that locking fails if the request ID is already in use.
    function test_lockForRequest_Fails_If_AlreadyLocked() public {
        uint256 lockAmount = 1 ether;
        uint16 redundancy = 1;

        vm.startPrank(address(ROUTER));
        userWallet.lockForRequest(spender, address(0), lockAmount, requestId, redundancy);

        vm.expectRevert(Wallet.RequestAlreadyLocked.selector);
        userWallet.lockForRequest(spender, address(0), lockAmount, requestId, redundancy);
        vm.stopPrank();
    }

    /// @notice Tests that locking fails if the wallet has insufficient unlocked funds.
    function test_lockForRequest_Fails_If_InsufficientFunds() public {
        uint256 lockAmount = INITIAL_ETH_FUNDS + 1 ether; // More than the wallet holds

        vm.startPrank(address(ROUTER));
        vm.expectRevert(Wallet.InsufficientFunds.selector);
        userWallet.lockForRequest(spender, address(0), lockAmount, requestId, 1);
        vm.stopPrank();
    }

    /// @notice Tests that locking fails if the spender has insufficient allowance.
    function test_lockForRequest_Fails_If_InsufficientAllowance() public {
        uint256 lockAmount = INITIAL_ALLOWANCE + 1 ether; // More than the allowance

        vm.startPrank(address(ROUTER));
        vm.expectRevert(Wallet.InsufficientAllowance.selector);
        userWallet.lockForRequest(spender, address(0), lockAmount, requestId, 1);
        vm.stopPrank();
    }

    /// @notice Tests that only the router can call lockForRequest.
    function test_lockForRequest_Fails_If_NotRouter() public {
        vm.prank(owner); // Not the router
        vm.expectRevert(bytes("OnlyCallableByRouter()"));
        userWallet.lockForRequest(spender, address(0), 1 ether, requestId, 1);
    }
}

/// @title WalletDisbursementTest
/// @notice Tests the disbursement logic of the Wallet.
contract WalletDisbursementTest is WalletTest {
    bytes32 internal requestId = keccak256("disbursement-test");
    uint256 internal lockAmount = 3 ether;
    uint256 internal payoutAmount = 1 ether;
    uint16 internal redundancy = 3;

    function setUp() public override {
        super.setUp();
        // Pre-lock funds for the tests in this contract
        vm.startPrank(address(ROUTER));
        userWallet.lockForRequest(spender, address(0), lockAmount, requestId, redundancy);
        vm.stopPrank();
    }

    /// @notice Tests a single successful disbursement.
    function test_disburseForRequest_Succeeds_SinglePayout() public {
        vm.startPrank(address(ROUTER));

        vm.expectEmit(true, true, false, false, address(userWallet));
        emit RequestDisbursed(requestId, node1, address(0), payoutAmount, 1);

        userWallet.disburseForRequest(requestId, node1, payoutAmount);

        vm.stopPrank();

        assertEq(userWallet.lockedOfRequest(requestId), lockAmount - payoutAmount, "Remaining amount should be reduced");
        assertEq(userWallet.paidCountOfRequest(requestId), 1, "Paid count should be 1");
        assertEq(node1.balance, payoutAmount, "Node1 should receive the payout");
        assertEq(userWallet.totalLockedFor(address(0)), lockAmount - payoutAmount, "Total locked should be reduced");
    }

    /// @notice Tests multiple disbursements until redundancy is met, with a refund of remaining funds.
    function test_disburseForRequest_Succeeds_MultiplePayouts_WithRefund() public {
        uint256 smallPayout = 0.8 ether;
        uint256 expectedRefund = lockAmount - (smallPayout * redundancy);

        vm.startPrank(address(ROUTER));

        // Payout 1
        userWallet.disburseForRequest(requestId, node1, smallPayout);
        assertEq(userWallet.paidCountOfRequest(requestId), 1);

        // Payout 2
        userWallet.disburseForRequest(requestId, node2, smallPayout);
        assertEq(userWallet.paidCountOfRequest(requestId), 2);

        // Payout 3 (final)
        vm.expectEmit(true, true, false, false, address(userWallet));
        emit RequestDisbursed(requestId, node3, address(0), smallPayout, 3);
        vm.expectEmit(true, true, false, false, address(userWallet));
        emit RequestReleased(requestId, spender, address(0), expectedRefund);

        userWallet.disburseForRequest(requestId, node3, smallPayout);

        vm.stopPrank();

        assertEq(userWallet.lockedOfRequest(requestId), 0, "Request lock should be deleted");
        assertEq(userWallet.allowance(spender, address(0)), INITIAL_ALLOWANCE - lockAmount + expectedRefund, "Spender allowance should be refunded");
        assertEq(node1.balance, smallPayout);
        assertEq(node2.balance, smallPayout);
        assertEq(node3.balance, smallPayout);
    }

    /// @notice Tests multiple disbursements that consume the entire locked amount.
    function test_disburseForRequest_Succeeds_MultiplePayouts_NoRefund() public {
        vm.startPrank(address(ROUTER));

        // Payout 1, 2, 3
        userWallet.disburseForRequest(requestId, node1, payoutAmount);
        userWallet.disburseForRequest(requestId, node2, payoutAmount);

        vm.expectEmit(true, true, false, false, address(userWallet));
        emit RequestReleased(requestId, spender, address(0), 0); // No refund
        userWallet.disburseForRequest(requestId, node3, payoutAmount);

        vm.stopPrank();

        assertEq(userWallet.lockedOfRequest(requestId), 0, "Request lock should be deleted");
        assertEq(userWallet.allowance(spender, address(0)), INITIAL_ALLOWANCE - lockAmount, "Spender allowance should not change");
    }

    /// @notice Tests that disbursement fails if the redundancy limit is exhausted.
    function test_disburseForRequest_Fails_If_RedundancyExhausted() public {
        vm.startPrank(address(ROUTER));
        userWallet.disburseForRequest(requestId, node1, payoutAmount);
        userWallet.disburseForRequest(requestId, node2, payoutAmount);
        userWallet.disburseForRequest(requestId, node3, payoutAmount);

        // Attempt 4th payout
        vm.expectRevert(Wallet.NoSuchRequestLock.selector);
        userWallet.disburseForRequest(requestId, node1, 0.1 ether);
        vm.stopPrank();
    }

    /// @notice Tests that disbursement fails for a non-existent request lock.
    function test_disburseForRequest_Fails_If_NoSuchLock() public {
        bytes32 fakeRequestId = keccak256("fake-request");
        vm.startPrank(address(ROUTER));
        vm.expectRevert(Wallet.NoSuchRequestLock.selector);
        userWallet.disburseForRequest(fakeRequestId, node1, payoutAmount);
        vm.stopPrank();
    }

    /// @notice Tests successful disbursement to multiple recipients in a single fulfillment.
    function test_disburseForFulfillment_Succeeds_MultipleRecipients() public {
        Payment[] memory payments = new Payment[](2);
        payments[0] = Payment({recipient: node1, paymentToken: address(0), paymentAmount: 0.5 ether});
        payments[1] = Payment({recipient: node2, paymentToken: address(0), paymentAmount: 0.7 ether});
        uint256 totalDisbursed = 1.2 ether;

        vm.startPrank(address(ROUTER));

        vm.expectEmit(true, true, false, false, address(userWallet));
        emit RequestDisbursed(requestId, node1, address(0), payments[0].paymentAmount, 1);
        vm.expectEmit(true, true, false, false, address(userWallet));
        emit RequestDisbursed(requestId, node2, address(0), payments[1].paymentAmount, 1);

        userWallet.disburseForFulfillment(requestId, payments);

        vm.stopPrank();

        assertEq(userWallet.paidCountOfRequest(requestId), 1, "Paid count should be incremented only once");
        assertEq(userWallet.lockedOfRequest(requestId), lockAmount - totalDisbursed, "Remaining amount should be reduced by total");
        assertEq(node1.balance, payments[0].paymentAmount);
        assertEq(node2.balance, payments[1].paymentAmount);
    }

    /// @notice Tests that fulfillment disbursement fails if a payment token does not match the lock's token.
    function test_disburseForFulfillment_Fails_If_TokenMismatch() public {
        Payment[] memory payments = new Payment[](1);
        // Lock is for ETH (address(0)), but payment is for TOKEN
        payments[0] = Payment({recipient: node1, paymentToken: address(TOKEN), paymentAmount: 0.5 ether});

        vm.startPrank(address(ROUTER));
        vm.expectRevert(bytes("Mismatched payment token"));
        userWallet.disburseForFulfillment(requestId, payments);
        vm.stopPrank();
    }
}

/// @title WalletReleaseTest
/// @notice Tests the lock release (refund) mechanism of the Wallet.
contract WalletReleaseTest is WalletTest {
    bytes32 internal requestId = keccak256("release-test");
    uint256 internal lockAmount = 2 ether;
    uint16 internal redundancy = 2;

    function setUp() public override {
        super.setUp();
        // Pre-lock funds for the tests
        vm.startPrank(address(ROUTER));
        userWallet.lockForRequest(spender, address(0), lockAmount, requestId, redundancy);
        vm.stopPrank();
    }

    /// @notice Tests releasing a lock that has not been disbursed, resulting in a full refund.
    function test_releaseForRequest_Succeeds_FullRefund() public {
        uint256 initialAllowance = userWallet.allowance(spender, address(0));

        vm.startPrank(address(ROUTER));

        vm.expectEmit(true, true, false, false, address(userWallet));
        emit RequestReleased(requestId, spender, address(0), lockAmount);

        userWallet.releaseForRequest(requestId);

        vm.stopPrank();

        assertEq(userWallet.lockedOfRequest(requestId), 0, "Request lock should be deleted");
        assertEq(userWallet.allowance(spender, address(0)), initialAllowance + lockAmount, "Spender allowance should be fully refunded");
        assertEq(userWallet.lockedOf(spender, address(0)), 0, "Spender's locked balance should be zero");
        assertEq(userWallet.totalLockedFor(address(0)), 0, "Total locked balance should be zero");
    }

    /// @notice Tests releasing a lock that has been partially disbursed, resulting in a partial refund.
    function test_releaseForRequest_Succeeds_PartialRefund() public {
        uint256 payoutAmount = 0.5 ether;
        uint256 expectedRefund = lockAmount - payoutAmount;
        uint256 initialAllowance = userWallet.allowance(spender, address(0));

        // First, disburse once
        vm.startPrank(address(ROUTER));
        userWallet.disburseForRequest(requestId, node1, payoutAmount);
        vm.stopPrank();

        // Now, release the rest
        vm.startPrank(address(ROUTER));
        vm.expectEmit(true, true, false, false, address(userWallet));
        emit RequestReleased(requestId, spender, address(0), expectedRefund);
        userWallet.releaseForRequest(requestId);
        vm.stopPrank();

        assertEq(userWallet.lockedOfRequest(requestId), 0, "Request lock should be deleted");
        assertEq(userWallet.allowance(spender, address(0)), initialAllowance + expectedRefund, "Spender allowance should be partially refunded");
        assertEq(userWallet.lockedOf(spender, address(0)), 0, "Spender's locked balance should be zero after release");
        assertEq(userWallet.totalLockedFor(address(0)), 0, "Total locked balance should be zero after release");
    }

    /// @notice Tests that releasing fails for a non-existent request lock.
    function test_releaseForRequest_Fails_If_NoSuchLock() public {
        bytes32 fakeRequestId = keccak256("fake-request");
        vm.startPrank(address(ROUTER));
        vm.expectRevert(Wallet.NoSuchRequestLock.selector);
        userWallet.releaseForRequest(fakeRequestId);
        vm.stopPrank();
    }
}