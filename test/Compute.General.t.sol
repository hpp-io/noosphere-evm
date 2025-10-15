// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {Commitment} from "../src/v1_0_0/types/Commitment.sol";
import {ComputeClient} from "../src/v1_0_0/client/ComputeClient.sol";
import {ComputeTest} from "./Compute.t.sol";
import {MockCoordinatorV2} from "./mocks/MockCoordinatorV2.sol";
import {IOwnableRouter} from "../src/v1_0_0/interfaces/IOwnableRouter.sol";
import {RequestIdUtils} from "../src/v1_0_0/utility/RequestIdUtils.sol";
import {MockMultiSigWallet} from "./mocks/MockMultiSigWallet.sol";

/// @title CoordinatorGeneralTest
/// @notice General coordinator tests
contract GeneralComputeTest is ComputeTest {
    /// @notice Cannot be reassigned a subscription ID
    function test_SubscriptionId_IsNeverReassigned() public {
        // Create new callback subscription
        (uint64 id1, Commitment memory commitment1) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );

        assertEq(id1, 1);

        // Create new subscriptions
        (uint64 id2,) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );
        // Assert head
        assertEq(id2, 2);

        // Delete subscriptions
        vm.startPrank(address(transientClient));
        ROUTER.timeoutRequest(commitment1.requestId, commitment1.subscriptionId, commitment1.interval);
        ROUTER.cancelComputeSubscription(1);

        // Create new subscription
        (uint64 id3,) = transientClient.createMockRequest(
            MOCK_CONTAINER_ID, MOCK_CONTAINER_INPUTS, 1, NO_PAYMENT_TOKEN, 0, userWalletAddress, NO_VERIFIER
        );
        assertEq(id3, 3);
    }

    /// @notice Cannot receive response from non-coordinator contract
    function test_RevertIf_ReceivingResponse_FromNonCoordinator() public {
        // Expect revert sending from address(this)
        vm.expectRevert(ComputeClient.NotRouter.selector);
        transientClient.receiveRequestCompute(
            1, 1, 1, false, address(this), MOCK_INPUT, MOCK_OUTPUT, MOCK_PROOF, bytes32(0)
        );
    }

    /// @notice Router should route to the correct coordinator version
    function test_Router_RoutesToCorrectCoordinatorVersion() public {
        // 1. Deploy and register a V2 Coordinator
        MockCoordinatorV2 coordinatorV2 = new MockCoordinatorV2();
        bytes32 v2TypeAndVersion = keccak256(bytes(coordinatorV2.typeAndVersion()));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = v2TypeAndVersion;
        address[] memory addrs = new address[](1);
        addrs[0] = address(coordinatorV2);

        vm.startPrank(ROUTER.client());
        ROUTER.proposeContractsUpdate(ids, addrs);
        ROUTER.updateContracts();
        vm.stopPrank();

        // 2. Get the next subscription ID to predict the requestId
        uint64 nextSubscriptionId = ROUTER.getLastSubscriptionId() + 1;
        uint32 interval = 1;
        bytes32 expectedRequestId = RequestIdUtils.requestIdPacked(nextSubscriptionId, interval);

        // Assert that the predicted values are correct before setting up the expectation
        assertEq(nextSubscriptionId, 1, "Next subscription ID should be 1");
        assertEq(
            expectedRequestId, keccak256(abi.encodePacked(uint64(1), uint32(1))), "Request ID should match prediction"
        );

        // 3. Expect a call to the V2 coordinator when creating a request
        vm.expectCall(
            address(coordinatorV2),
            abi.encodeWithSelector(
                coordinatorV2.startRequest.selector,
                expectedRequestId,
                nextSubscriptionId,
                keccak256(abi.encode(MOCK_CONTAINER_ID)),
                interval,
                1, // redundancy
                false,
                NO_PAYMENT_TOKEN,
                0, // feeAmount
                userWalletAddress,
                NO_VERIFIER
            ),
            1 // times
        );

        // 4. Create a request, which should be routed to V2
        transientClient.createMockRequestWithRouteId(
            MOCK_CONTAINER_ID,
            MOCK_CONTAINER_INPUTS,
            1,
            NO_PAYMENT_TOKEN,
            0,
            userWalletAddress,
            NO_VERIFIER,
            v2TypeAndVersion
        );
    }

    /// @notice Router should revert if an invalid routeId is used
    function test_Router_RevertIf_InvalidRouteId() public {
        // 1. Define an invalid routeId that is not registered in the router
        bytes32 invalidRouteId = bytes32("invalid_route_id");

        // 2. Expect a revert with the "Coordinator not found" error message
        vm.expectRevert(bytes("Coordinator not found"));

        // 3. Attempt to create a request using the invalid routeId
        transientClient.createMockRequestWithRouteId(
            MOCK_CONTAINER_ID,
            MOCK_CONTAINER_INPUTS,
            1,
            NO_PAYMENT_TOKEN,
            0,
            userWalletAddress,
            NO_VERIFIER,
            invalidRouteId
        );
    }

    /// @notice Tests that ownership of the Router and Coordinator can be transferred to and managed by a multi-sig wallet.
    function test_ManagesOwnership_WithMultiSig() public {
        // 1. Deploy a mock multi-sig wallet with two owners.
        address owner1 = makeAddr("MultiSigOwner1");
        address owner2 = makeAddr("MultiSigOwner2");
        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner2;
        MockMultiSigWallet multiSigWallet = new MockMultiSigWallet(owners);

        // --- Test Router Ownership Transfer ---

        // 2. The current Router owner proposes transferring ownership to the multi-sig wallet.
        address routerOwner = ROUTER.client();
        vm.startPrank(routerOwner);
        ROUTER.transferOwnership(address(multiSigWallet));
        vm.stopPrank();

        // 3. The multi-sig wallet accepts the ownership transfer (executed by owner1).
        bytes memory acceptOwnershipCall = abi.encodeWithSelector(ROUTER.acceptOwnership.selector);
        vm.startPrank(owner1);
        (bool success,) = multiSigWallet.execute(address(ROUTER), acceptOwnershipCall);
        assertTrue(success, "Execution of acceptOwnership should succeed");
        vm.stopPrank();

        // 4. Verify that the Router's owner is now the multi-sig wallet.
        assertEq(ROUTER.client(), address(multiSigWallet), "Router owner should be the multi-sig wallet");

        // --- Test Coordinator Ownership Transfer ---

        // 5. The current Coordinator owner proposes transferring ownership to the multi-sig wallet.
        address coordinatorOwner = COORDINATOR.client();
        vm.startPrank(coordinatorOwner);
        COORDINATOR.transferOwnership(address(multiSigWallet));
        vm.stopPrank();

        // 6. The multi-sig wallet accepts the ownership transfer (executed by owner2).
        acceptOwnershipCall = abi.encodeWithSelector(COORDINATOR.acceptOwnership.selector);
        vm.startPrank(owner2);
        (success,) = multiSigWallet.execute(address(COORDINATOR), acceptOwnershipCall);
        assertTrue(success, "Execution of acceptOwnership should succeed");
        vm.stopPrank();

        // 7. Verify that the Coordinator's owner is now the multi-sig wallet.
        assertEq(COORDINATOR.client(), address(multiSigWallet), "Coordinator owner should be the multi-sig wallet");

        // --- Test Owner-Only Function Execution via Multi-Sig ---

        // 8. The multi-sig wallet calls the pause function on the Router.
        bytes memory pauseCall = abi.encodeWithSelector(ROUTER.pause.selector);
        vm.startPrank(owner1);
        (success,) = multiSigWallet.execute(address(ROUTER), pauseCall);
        assertTrue(success, "Execution of pause should succeed");
        vm.stopPrank();

        // 9. Verify that the Router is now paused.
        assertTrue(ROUTER.paused(), "Router should be paused");
    }
}
