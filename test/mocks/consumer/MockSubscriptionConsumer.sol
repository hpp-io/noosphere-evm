// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Commitment} from "../../../src/v1_0_0/types/Commitment.sol";
import {Subscription} from "../../../src/v1_0_0/types/Subscription.sol";
import {SubscriptionConsumer} from "../../../src/v1_0_0/consumer/SubscriptionConsumer.sol";
import "./MockBaseConsumer.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";

/// @title MockSubscriptionConsumer
/// @notice Mocks SubscriptionConsumer
contract MockSubscriptionConsumer is MockBaseConsumer, SubscriptionConsumer, StdAssertions {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Hard-coded container inputs
    bytes public constant CONTAINER_INPUTS = bytes("CONTAINER_INPUTS");

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Create new MockSubscriptionConsumer
    /// @param router The address of the Router contract.
    constructor(address router) SubscriptionConsumer(router) {}

    /*//////////////////////////////////////////////////////////////
                           UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mock interface read an `InboxItem` from `Inbox`
    /// @param containerId compute container ID
    /// @param node delivering node address
    /// @param index item index
    /// @return inbox item
    //    function readMockInbox(bytes32 containerId, address node, uint256 index) external view returns (InboxItem memory) {
    //        return INBOX.read(containerId, node, index);
    //    }

    /// @notice Create new mock subscription
    /// @dev Parameter interface conforms to same as `SubscriptionConsumer._createComputeSubscription`
    /// @dev Augmented with checks
    /// @dev Checks returned subscription ID is serially conforming.
    /// @dev Checks subscription stored in coordinator storage conforms to expected, given inputs
    function createMockSubscription(
        string calldata containerId,
        uint32 frequency,
        uint32 period,
        uint16 redundancy,
        bool lazy,
        address paymentToken,
        uint256 paymentAmount,
        address wallet,
        address verifier
    ) external returns (uint64, Commitment memory) {
        uint256 creationTimestamp = block.timestamp;
        uint64 actualSubscriptionID =
            _createComputeSubscription(
            containerId,
            frequency,
            period,
            redundancy,
            lazy,
            paymentToken,
            paymentAmount,
            wallet,
            verifier,
            bytes32("Coordinator_v1.0.0")
        );

        _assertSubscription(
            actualSubscriptionID,
            containerId,
            frequency,
            period,
            redundancy,
            lazy,
            paymentToken,
            paymentAmount,
            wallet,
            verifier,
            creationTimestamp
        );

        return _requestCompute(actualSubscriptionID, 1);
    }

    /// @notice Create new mock subscription without sending an initial request
    function createMockSubscriptionWithoutRequest(
        string calldata containerId,
        uint32 frequency,
        uint32 period,
        uint16 redundancy,
        bool lazy,
        address paymentToken,
        uint256 paymentAmount,
        address wallet,
        address verifier
    ) external returns (uint64) {
        uint64 actualSubscriptionID =
            _createComputeSubscription(
            containerId,
            frequency,
            period,
            redundancy,
            lazy,
            paymentToken,
            paymentAmount,
            wallet,
            verifier,
            bytes32("Coordinator_v1.0.0")
        );

        _assertSubscription(
            actualSubscriptionID,
            containerId,
            frequency,
            period,
            redundancy,
            lazy,
            paymentToken,
            paymentAmount,
            wallet,
            verifier,
            block.timestamp
        );

        return actualSubscriptionID;
    }

    /// @dev Asserts that the subscription was created with the correct parameters.
    function _assertSubscription(
        uint64 subId,
        string calldata containerId,
        uint32 frequency,
        uint32 period,
        uint16 redundancy,
        bool lazy,
        address paymentToken,
        uint256 paymentAmount,
        address wallet,
        address verifier,
        uint256 creationTimestamp
    ) private {
        Subscription memory sub = _getRouter().getSubscription(subId);

        assertEq(sub.activeAt, creationTimestamp + period);
        assertEq(sub.owner, address(this));
        assertEq(sub.redundancy, redundancy);
        assertEq(sub.frequency, frequency);
        assertEq(sub.period, period);
        assertEq(sub.containerId, keccak256(abi.encode(containerId)));
        assertEq(sub.lazy, lazy);
        assertEq(sub.paymentToken, paymentToken);
        assertEq(sub.paymentAmount, paymentAmount);
        assertEq(sub.wallet, wallet);
        assertEq(sub.verifier, verifier);
    }

    /// @notice Allows cancelling subscription
    /// @param subscriptionId to cancel
    /// @dev Augmented with checks
    /// @dev Asserts subscription owner is nullified after cancellation
    function cancelMockSubscription(uint64 subscriptionId) external {
        _cancelComputeSubscription(subscriptionId);
        // Assert maxxed out subscription `activeAt`
        uint32 expected = type(uint32).max;
        Subscription memory actual = _getRouter().getSubscription(subscriptionId);
        assertEq(actual.activeAt, expected);
    }

    /*//////////////////////////////////////////////////////////////
                           INHERITED FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Override function to return container inputs
    /// @return container inputs
    function getContainerInputs(uint64 subscriptionId, uint32 interval, uint32 timestamp, address caller)
        external
        pure
        override
        returns (bytes memory)
    {
        return CONTAINER_INPUTS;
    }

    /// @notice Overrides internal function, pushing received response to delivered outputs map
    /// @dev Allows further overriding downstream (useful for `Allowlist` testing)
    function _receiveCompute(
        uint64 subscriptionId,
        uint32 interval,
        uint16 redundancy,
        bool lazy,
        address node,
        bytes calldata input,
        bytes calldata output,
        bytes calldata proof,
        bytes32 containerId
    ) internal virtual override {
        // Log delivered output
        outputs[subscriptionId][interval][redundancy] = DeliveredOutput({
            subscriptionId: subscriptionId,
            interval: interval,
            redundancy: redundancy,
            lazy: lazy,
            node: node,
            input: input,
            output: output,
            proof: proof,
            containerId: containerId
        });
    }

    function typeAndVersion() external pure override returns (string memory) {
        return "MockSubscriptionConsumer_v1.0.0";
    }
}
