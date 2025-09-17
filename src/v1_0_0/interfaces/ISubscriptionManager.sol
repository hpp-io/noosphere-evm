// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;
import {Subscription} from "../types/Subscription.sol";
interface ISubscriptionsManager {
    /**
     * @notice Retrieve details of a subscription by its ID.
     * @param subscriptionId The ID of the subscription.
     * @return The `Subscription` object.
     */
    function getSubscription(uint64 subscriptionId) external view returns (Subscription memory);

    /**
     * @notice Calculate the interval of a subscription based on activation time and period.
     * @param subscriptionId The ID of the subscription.
     * @return The computed interval.
     */
    function getSubscriptionInterval(uint64 subscriptionId) external view returns (uint32);

    /**
     * @notice Create a new subscription.
     * @return The ID of the newly created subscription.
     */
    function createSubscription(
        string memory containerId,
        uint32 frequency,
        uint32 period,
        uint16 redundancy,
        bool lazy,
        address paymentToken,
        uint256 paymentAmount,
        address wallet,
        address verifier,
        bytes32 routeId
    ) external returns (uint64);

    /**
     * @notice Cancel an existing subscription.
     * @param subscriptionId The ID of the subscription to cancel.
     */
    function cancelSubscription(uint64 subscriptionId) external;

    /**
     * @notice Check if there are pending requests for a specific subscription.
     * @param subscriptionId The subscription ID.
     * @return True if there are pending requests, false otherwise.
     */
    function pendingRequestExists(uint64 subscriptionId) external view returns (bool);
}