// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {ComputeSubscription} from "../../../src/v1_0_0/types/ComputeSubscription.sol";
import {TransientComputeClient} from "../../../src/v1_0_0/client/TransientComputeClient.sol";
import {MockComputeClient, DeliveredOutput} from "./MockComputeClient.sol";
import {Commitment} from "../../../src/v1_0_0/types/Commitment.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";

/// @title MockTransientComputeClient.sol
/// @notice Mocks TransientComputeClient.sol
contract MockTransientComputeClient is MockComputeClient, TransientComputeClient, StdAssertions {
    event DeliverOutput(uint64 subscriptionId, uint32 interval, uint16 redundancy, bytes32 containerId, address node);
    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Create new MockTransientComputeClient.sol
    /// @param router router address
    constructor(address router) TransientComputeClient(router) {}

    /*//////////////////////////////////////////////////////////////
                           UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Create new mock callback request
    /// @dev Parameter interface conforms to same as `TransientComputeClient.sol._requestCompute`
    /// @dev Augmented with checks
    /// @dev Checks returned subscription ID is serially conforming
    /// @dev Checks subscription stored in coordinator storage conforms to expected, given inputs
    function createMockRequest(
        string memory containerId,
        bytes memory inputs,
        uint16 redundancy,
        address feeToken,
        uint256 feeAmount,
        address wallet,
        address verifier
    ) external returns (uint64, Commitment memory) {
        // Get current block timestamp
        uint256 currentTimestamp = block.timestamp;
        uint64 subId = _createComputeSubscription(
            containerId, redundancy, false, feeToken, feeAmount, wallet, verifier, bytes32("Coordinator_v1.0.0")
        );

        (uint64 actualSubscriptionID, Commitment memory commitment) = _requestCompute(subId, inputs);

        _assertSubscription(
            actualSubscriptionID,
            containerId,
            inputs,
            redundancy,
            false,
            feeToken,
            feeAmount,
            wallet,
            verifier,
            currentTimestamp
        );

        return (actualSubscriptionID, commitment);
    }

    /// @notice Create new useDeliveryInbox mock callback request
    function createLazyMockRequest(
        string memory containerId,
        bytes memory inputs,
        uint16 redundancy,
        address feeToken,
        uint256 feeAmount,
        address wallet,
        address verifier
    ) external returns (uint64, Commitment memory) {
        // Get current block timestamp
        uint256 currentTimestamp = block.timestamp;
        // Request off-chain container compute
        uint64 subId = _createComputeSubscription(
            containerId,
            redundancy,
            true, // useDeliveryInbox = true
            feeToken,
            feeAmount,
            wallet,
            verifier,
            bytes32("Coordinator_v1.0.0")
        );

        (uint64 actualSubscriptionID, Commitment memory commitment) = _requestCompute(subId, inputs);

        _assertSubscription(
            actualSubscriptionID,
            containerId,
            inputs,
            redundancy,
            true,
            feeToken,
            feeAmount,
            wallet,
            verifier,
            currentTimestamp
        );

        return (actualSubscriptionID, commitment);
    }

    /*//////////////////////////////////////////////////////////////
                           INHERITED FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Asserts that the subscription was created with the correct parameters.
    function _assertSubscription(
        uint64 subId,
        string memory containerId,
        bytes memory inputs,
        uint16 redundancy,
        bool expectedLazy, // Add this parameter
        address feeToken,
        uint256 feeAmount,
        address wallet,
        address verifier,
        uint256 creationTimestamp
    ) private view {
        ComputeSubscription memory sub = _getRouter().getComputeSubscription(subId);

        assertEq(sub.activeAt, creationTimestamp);
        assertEq(sub.client, address(this));
        assertEq(sub.redundancy, redundancy);
        assertEq(sub.maxExecutions, 1);
        assertEq(sub.intervalSeconds, 0);
        assertEq(sub.containerId, keccak256(abi.encode(containerId)));
        assertEq(sub.useDeliveryInbox, expectedLazy); // Use the passed useDeliveryInbox parameter
        assertEq(sub.feeToken, feeToken);
        assertEq(sub.feeAmount, feeAmount);
        assertEq(sub.wallet, wallet);
        assertEq(sub.verifier, verifier);
        assertEq(subscriptionInputs[subId], inputs);
    }

    /// @notice Overrides internal function, pushing received response to delivered outputs map
    function _receiveCompute(
        uint64 subscriptionId,
        uint32 interval,
        uint16 redundancy,
        bool useDeliveryInbox,
        address node,
        bytes calldata input,
        bytes calldata output,
        bytes calldata proof,
        bytes32 containerId
    ) internal override {
        outputs[subscriptionId][interval][redundancy] = DeliveredOutput({
            subscriptionId: subscriptionId,
            interval: interval,
            redundancy: redundancy,
            useDeliveryInbox: useDeliveryInbox,
            node: node,
            input: input,
            output: output,
            proof: proof,
            containerId: containerId
        });
        emit DeliverOutput(subscriptionId, interval, redundancy, containerId, node);
    }

    function typeAndVersion() external pure override returns (string memory) {
        return "MockCallbackConsumer_v1.0.0";
    }
}
