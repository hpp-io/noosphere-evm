// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {ComputeTest} from "./Compute.t.sol";
import {NoosphereX402Client} from "../src/v1_0_0/client/NoosphereX402Client.sol";
import {Commitment} from "../src/v1_0_0/types/Commitment.sol";
import {Wallet} from "../src/v1_0_0/wallet/Wallet.sol";
import {ISubscriptionsManager} from "../src/v1_0_0/interfaces/ISubscriptionManager.sol";

/// @title NoosphereX402ClientTest
/// @notice Tests for the x402 payment gateway client: access control, event
///         emission, and the disabling of generic parent entry points.
contract NoosphereX402ClientTest is ComputeTest {
    NoosphereX402Client internal x402Client;

    address internal OPERATOR;
    uint256 internal OPERATOR_KEY = 0xA11CE;
    address internal ATTACKER = address(0xBAD);

    bytes internal constant INPUTS = "hello-payload";
    bytes32 internal constant JOB_ID = bytes32("job-abc-123");
    uint96 internal constant PAID_AMOUNT = 10_000; // 0.01 USDC.e (6 decimals)

    // Re-declared for vm.expectEmit matching
    event OperatorUpdated(address indexed previous, address indexed current);
    event X402Dispatched(
        uint64 indexed subscriptionId,
        uint32 indexed interval,
        address indexed payer,
        bytes32 jobId,
        uint96 paidAmount,
        uint64 timestamp
    );

    function setUp() public override {
        super.setUp();
        OPERATOR = vm.addr(OPERATOR_KEY);

        // Deploy the x402 client owned by OPERATOR.
        x402Client = new NoosphereX402Client(address(ROUTER), OPERATOR);

        // Fund a fresh wallet owned by this test contract, and grant the x402
        // client spending permission so dispatchPaidCompute can debit it.
        address clientWallet = walletFactory.createWallet(address(this));
        (bool ok,) = clientWallet.call{value: 1 ether}("");
        require(ok, "fund client wallet failed");
        Wallet(payable(clientWallet)).approve(address(x402Client), address(0), 1 ether);

        // Operator-owned state: a subscription for paid dispatches.
        vm.prank(OPERATOR);
        x402Client.createSubscription(
            MOCK_CONTAINER_ID,
            false, // useDeliveryInbox
            NO_PAYMENT_TOKEN,
            0,
            clientWallet,
            NO_VERIFIER,
            bytes32("Coordinator_v1.0.0")
        );
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsOperator() public view {
        assertEq(x402Client.operator(), OPERATOR);
    }

    function test_Constructor_RevertsOnZeroOperator() public {
        vm.expectRevert(NoosphereX402Client.ZeroOperator.selector);
        new NoosphereX402Client(address(ROUTER), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                          createSubscription
    //////////////////////////////////////////////////////////////*/

    function test_CreateSubscription_RevertsForNonOperator() public {
        vm.prank(ATTACKER);
        vm.expectRevert(NoosphereX402Client.NotOperator.selector);
        x402Client.createSubscription(
            MOCK_CONTAINER_ID, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER, bytes32("r")
        );
    }

    function test_CreateSubscription_SucceedsForOperator() public {
        // Second subscription — setUp already created one with ID=1.
        vm.expectEmit(address(ROUTER));
        emit ISubscriptionsManager.SubscriptionCreated(2);

        vm.prank(OPERATOR);
        uint64 subId = x402Client.createSubscription(
            MOCK_CONTAINER_ID, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER, bytes32("Coordinator_v1.0.0")
        );
        assertEq(subId, 2);
    }

    /*//////////////////////////////////////////////////////////////
                          dispatchPaidCompute
    //////////////////////////////////////////////////////////////*/

    function test_DispatchPaidCompute_RevertsForNonOperator() public {
        vm.prank(ATTACKER);
        vm.expectRevert(NoosphereX402Client.NotOperator.selector);
        x402Client.dispatchPaidCompute(1, INPUTS, address(this), JOB_ID, PAID_AMOUNT);
    }

    function test_DispatchPaidCompute_EmitsX402DispatchedWithCorrectData() public {
        address payer = makeAddr("payer");

        // Match indexed topics; don't check data fields exactly to stay tolerant
        // of timestamp. `checkData = true` with explicit timestamp via vm.warp.
        vm.warp(1_700_000_000);

        vm.expectEmit(true, true, true, true, address(x402Client));
        emit X402Dispatched(1, 1, payer, JOB_ID, PAID_AMOUNT, uint64(block.timestamp));

        vm.prank(OPERATOR);
        x402Client.dispatchPaidCompute(1, INPUTS, payer, JOB_ID, PAID_AMOUNT);
    }

    function test_DispatchPaidCompute_IncrementsInterval() public {
        address payer = makeAddr("payer");

        vm.prank(OPERATOR);
        (, Commitment memory c1) = x402Client.dispatchPaidCompute(1, INPUTS, payer, JOB_ID, PAID_AMOUNT);

        vm.prank(OPERATOR);
        (, Commitment memory c2) = x402Client.dispatchPaidCompute(1, INPUTS, payer, JOB_ID, PAID_AMOUNT);

        assertEq(c1.interval, 1);
        assertEq(c2.interval, 2);
    }

    /*//////////////////////////////////////////////////////////////
                            updateOperator
    //////////////////////////////////////////////////////////////*/

    function test_UpdateOperator_RevertsForNonOperator() public {
        vm.prank(ATTACKER);
        vm.expectRevert(NoosphereX402Client.NotOperator.selector);
        x402Client.updateOperator(ATTACKER);
    }

    function test_UpdateOperator_RevertsOnZeroAddress() public {
        vm.prank(OPERATOR);
        vm.expectRevert(NoosphereX402Client.ZeroOperator.selector);
        x402Client.updateOperator(address(0));
    }

    function test_UpdateOperator_RotatesAndEmits() public {
        address newOperator = makeAddr("newOperator");

        vm.expectEmit(true, true, false, false, address(x402Client));
        emit OperatorUpdated(OPERATOR, newOperator);

        vm.prank(OPERATOR);
        x402Client.updateOperator(newOperator);

        assertEq(x402Client.operator(), newOperator);

        // Previous operator can no longer dispatch.
        vm.prank(OPERATOR);
        vm.expectRevert(NoosphereX402Client.NotOperator.selector);
        x402Client.dispatchPaidCompute(1, INPUTS, address(this), JOB_ID, PAID_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                    DISABLED PARENT ENTRY POINTS
    //////////////////////////////////////////////////////////////*/

    function test_ParentCreateComputeSubscription_IsDisabled() public {
        vm.expectRevert(NoosphereX402Client.DisabledUseCreateSubscription.selector);
        x402Client.createComputeSubscription(
            MOCK_CONTAINER_ID, 1, 0, false, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER, bytes32("r")
        );
    }

    function test_ParentSendRequest_IsDisabled() public {
        vm.expectRevert(NoosphereX402Client.DisabledUseDispatchPaidCompute.selector);
        x402Client.sendRequest(1, 1);
    }

    /*//////////////////////////////////////////////////////////////
                          typeAndVersion
    //////////////////////////////////////////////////////////////*/

    function test_TypeAndVersion() public view {
        assertEq(x402Client.typeAndVersion(), "NoosphereX402Client_v0.1.0");
    }
}
