// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {ISubscriptionsManager} from "./interfaces/ISubscriptionManager.sol";
import {Subscription} from "./types/Subscription.sol";
import {Payment} from "./types/Payment.sol";

abstract contract SubscriptionsManager is ISubscriptionsManager {
    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    /// @dev Mapping of subscription IDs to `Subscription` objects.
    mapping(uint32 => Subscription) internal subscriptions;

    /// @dev A mapping storing request commitments.
    mapping(bytes32 => bytes32) internal requestCommitments;

    /// @notice Emitted when a new subscription is created
    /// @param id subscription ID
    event SubscriptionCreated(uint32 indexed id);

    /// @notice Emitted when a subscription is cancelled
    /// @param id subscription ID
    event SubscriptionCancelled(uint32 indexed id);

    /// @notice Emitted when a subscription is fulfilled
    /// @param id subscription ID
    /// @param node address of fulfilling node
    event SubscriptionFulfilled(uint32 indexed id, address indexed node);

    /// @notice Thrown by `cancelSubscription()` if attempting to modify a subscription not owned by caller
    /// @dev 4-byte signature: `0xa7fba711`
    error NotSubscriptionOwner();

    /// @notice Thrown by `deliverCompute()` if attempting to deliver a completed subscription
    /// @dev 4-byte signature: `0xae6704a7`
    error SubscriptionCompleted();

    /// @notice Thrown by `deliverCompute()` if attempting to deliver a subscription before `activeAt`
    /// @dev 4-byte signature: `0xefb74efe`
    error SubscriptionNotActive();

    /*//////////////////////////////////////////////////////////////
                         ISubscriptionsManager IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    function getSubscription(uint32 subscriptionId) external view returns (Subscription memory) {
        return subscriptions[subscriptionId];
    }

    function getSubscriptionInterval(uint32 activeAt, uint32 period) external view returns (uint32){
        if (uint32(block.timestamp) < activeAt) {
            return 0;
        }
        if (period == 0) {
            return 1;
        }
        unchecked {
            return ((uint32(block.timestamp) - activeAt) / period) + 1;
        }
    }

    function createSubscription(
        string memory containerId,
        uint32 frequency,
        uint32 period,
        uint16 redundancy,
        bool lazy,
        address paymentToken,
        uint256 paymentAmount,
        address wallet,
        address verifier
    ) external virtual override returns (uint32) {

    }

    function cancelSubscription(uint32 subscriptionId) external virtual override {
        if (subscriptions[subscriptionId].owner != msg.sender) {
            revert NotSubscriptionOwner();
        }

//        if (pendingRequestExists(subscriptionId)) {
//
//        }
    }

    function pendingRequestExists(uint32 subscriptionId) external view virtual override returns (bool) {
        // Implementation Placeholder
    }

    function timeoutRequests(bytes32 requestsToTimeoutByCommitment) external virtual override {
        // Implementation Placeholder
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL LOGIC HELPERS
    //////////////////////////////////////////////////////////////*/

    function _markRequestInFlight(
        address wallet,
        uint64 subscriptionId,
        uint16 redundancy,
        address paymentToken,
        uint256 paymentAmount
    ) internal {
        // Internal implementation placeholder
    }

    function _pay(
        uint64 subscriptionId,
        uint64 commitmentId,
        Payment[] memory payments
    ) internal {
        // Internal implementation placeholder
    }

    function _callback(
        uint32 subscriptionId,
        uint32 interval,
        uint16 redundancy,
        address node,
        bytes memory input,
        bytes memory output,
        bytes memory proof,
        bytes32 containerId,
        uint256 index
    ) internal {
        // Internal implementation placeholder
    }

    function _cancelSubscriptionHelper(uint32 subscriptionId) internal {
        // Internal implementation placeholder
    }

    function _timeoutPrepareNextIntervalRequests(uint32 subscriptionId) internal {
        // Internal implementation placeholder
    }
}