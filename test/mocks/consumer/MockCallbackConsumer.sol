// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Subscription} from "../../../src/v1_0_0/types/Subscription.sol";
import {CallbackConsumer} from "../../../src/v1_0_0/consumer/CallbackConsumer.sol";
import {MockBaseConsumer, DeliveredOutput} from "./MockBaseConsumer.sol";
import {Commitment} from "../../../src/v1_0_0/types/Commitment.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";

/// @title MockCallbackConsumer
/// @notice Mocks CallbackConsumer
contract MockCallbackConsumer is MockBaseConsumer, CallbackConsumer, StdAssertions {
    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Create new MockCallbackConsumer
    /// @param router router address
    constructor(address router) CallbackConsumer(router) { }

    /*//////////////////////////////////////////////////////////////
                           UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Create new mock callback request
    /// @dev Parameter interface conforms to same as `CallbackConsumer._requestCompute`
    /// @dev Augmented with checks
    /// @dev Checks returned subscription ID is serially conforming
    /// @dev Checks subscription stored in coordinator storage conforms to expected, given inputs
    function createMockRequest(
        string memory containerId,
        bytes memory inputs,
        uint16 redundancy,
        address paymentToken,
        uint256 paymentAmount,
        address wallet,
        address verifier
    ) external returns (uint64, Commitment memory) {
        // Get current block timestamp
        uint256 currentTimestamp = block.timestamp;
        // Request off-chain container compute
        bytes32 coordinatorId = bytes32("Coordinator_v1.0.0");
        (uint64 actualSubscriptionID, Commitment memory commitment)  = _requestCompute(
            containerId,
            inputs,
            redundancy,
            paymentToken,
            paymentAmount,
            wallet,
            verifier,
            coordinatorId
        );
        // Collect subscription from storage
        Subscription memory sub = _getRouter().getSubscription(actualSubscriptionID);

        // Assert subscription storage
        assertEq(sub.activeAt, currentTimestamp);
        assertEq(sub.owner, address(this));
        assertEq(sub.redundancy, redundancy);
        assertEq(sub.frequency, 1);
        assertEq(sub.period, 0);
        assertEq(sub.containerId, keccak256(abi.encode(containerId)));
        assertEq(sub.lazy, false);
        assertEq(sub.paymentToken, paymentToken);
        assertEq(sub.paymentAmount, paymentAmount);
        assertEq(sub.wallet, wallet);
        assertEq(sub.verifier, verifier);
        assertEq(subscriptionInputs[actualSubscriptionID], inputs);

        // Explicitly return subscription ID
        return (actualSubscriptionID, commitment);
    }

    /*//////////////////////////////////////////////////////////////
                           INHERITED FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Overrides internal function, pushing received response to delivered outputs map
    function _receiveCompute(
        uint64 subscriptionId,
        uint32 interval,
        uint16 redundancy,
        address node,
        bytes calldata input,
        bytes calldata output,
        bytes calldata proof,
        bytes32 containerId,
        uint256 index
    ) internal override {
        // Log delivered output
        outputs[subscriptionId][interval][redundancy] = DeliveredOutput({
            subscriptionId: subscriptionId,
            interval: interval,
            redundancy: redundancy,
            node: node,
            input: input,
            output: output,
            proof: proof,
            containerId: containerId,
            index: index
        });
    }

    function typeAndVersion() external pure override returns (string memory) {
        return "MockCallbackConsumer_v1.0.0";
    }
}
