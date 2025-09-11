// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Coordinator} from "../Coordinator.sol";
import {Router} from "../Router.sol";
import {Subscription} from "../types/Subscription.sol";

/// @title Reader
/// @notice Utility contract: implements multicall like batch reading functionality
/// @dev Multicall src: https://github.com/mds1/multicall
/// @dev Functions forgo validation assuming correct off-chain inputs are used
contract Reader {
    /*//////////////////////////////////////////////////////////////
                               IMMUTABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Coordinator
    /// @dev `Coordinator` used over `EIP712Coordinator` since no EIP-712 functionality consumed
    Router private immutable ROUTER;
    Coordinator private immutable COORDINATOR;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes new Reader
    /// @param _router The address of the main Router contract.
    /// @param _coordinator The address of the Coordinator contract.
    constructor(address _router, address _coordinator) {
        ROUTER = Router(_router);
        COORDINATOR = Coordinator(_coordinator);
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Struct to hold information about a specific subscription interval.
    struct IntervalInfo {
        uint16 redundancyCount;
        bool commitmentExists;
    }

    /// @notice Reads `Subscription`(s) from `Coordinator` in batch
    /// @dev Does not validate that subscriptions between `startId` and `endId` exist
    /// @dev Does not validate that `startId` is at least `0`
    /// @dev Does not validate that `endId` is greater than `startId`
    /// @param startId start subscription ID (inclusive)
    /// @param endId end subscription ID (exclusive)
    /// @return `Subscription`(s)
    function readSubscriptionBatch(uint64 startId, uint64 endId) external view returns (Subscription[] memory) {
        // Setup array to populate
        uint256 length = endId - startId;
        Subscription[] memory subscriptions = new Subscription[](length);

        // Iterate and collect subscriptions
        for (uint64 id = startId; id < endId; id++) {
            // Collect 0-index array id
            uint256 idx = id - startId;
            // Collect and store subscription
            subscriptions[idx] = ROUTER.getSubscription(id);
        }

        return subscriptions;
    }

    /// @notice Given `Subscription` ids and intervals, collects redundancy count of (subscription, interval)-pair
    /// @dev By default, if a (subscription ID, interval)-pair does not exist, function will return `redundancyCount == 0`
    /// @param ids array of subscription IDs
    /// @param intervals array of intervals to check where each `ids[i]` corresponds to `intervals[i]`
    /// @return An array of `IntervalInfo` structs, each containing the redundancy count and whether a commitment exists.
    function readRedundancyCountBatch(uint64[] calldata ids, uint32[] calldata intervals)
        external
        view
        returns (IntervalInfo[] memory)
    {
        require(ids.length == intervals.length, "Reader: input array length mismatch");
        IntervalInfo[] memory intervalInfos = new IntervalInfo[](ids.length);

        for (uint256 i = 0; i < ids.length; i++) {
            // Compute `requestId`, which is the key for both mappings.
            // Use `encodePacked` to match the `requestId` generation in the Router.
            bytes32 requestId = keccak256(abi.encodePacked(ids[i], intervals[i]));
            // Collect redundancy for (id, interval)
            uint16 count = COORDINATOR.redundancyCount(requestId);
            // Check if a commitment exists for this requestId in the Coordinator.
            bool exists = COORDINATOR.requestCommitments(requestId) != bytes32(0);
            intervalInfos[i] = IntervalInfo(count, exists);
        }

        return intervalInfos;
    }



}
