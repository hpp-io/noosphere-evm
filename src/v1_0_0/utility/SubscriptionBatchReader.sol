// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Coordinator} from "../Coordinator.sol";
import {Router} from "../Router.sol";
import {ComputeSubscription} from "../types/ComputeSubscription.sol";

/// @title SubscriptionBatchReader
/// @notice Read-only helper contract that exposes batch query helpers for Router and Coordinator state.
/// @dev Provides convenient multi-read functions for off-chain tooling. Functions are view-only and
///      intentionally perform minimal validation to avoid unexpected gas usage.
contract SubscriptionBatchReader {
    /*//////////////////////////////////////////////////////////////
                                 IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Router instance used to fetch subscription records.
    Router private immutable router;

    /// @notice Coordinator instance used to fetch commitments and redundancy data.
    Coordinator private immutable coordinator;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _router Address of the Router contract.
    /// @param _coordinator Address of the Coordinator contract.
    constructor(address _router, address _coordinator) {
        router = Router(_router);
        coordinator = Coordinator(_coordinator);
    }

    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Snapshot of interval-related state for a subscription interval.
    /// @param redundancyCount Number of redundant deliveries recorded for the requestId.
    /// @param commitmentExists True if the Coordinator holds a commitment for the requestId.
    struct IntervalStatus {
        uint16 redundancyCount;
        bool commitmentExists;
    }

    /*//////////////////////////////////////////////////////////////
                                 READ HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Return a contiguous slice of ComputeSubscription structs (inclusive start, exclusive end).
    /// @dev Reverts when endId <= startId.
    /// @param startId Inclusive start subscription id.
    /// @param endId Exclusive end subscription id.
    /// @return subscriptions Array of ComputeSubscription for ids in [startId, endId).
    function getSubscriptions(uint64 startId, uint64 endId)
        external
        view
        returns (ComputeSubscription[] memory subscriptions)
    {
        uint256 len = uint256(endId - startId);
        subscriptions = new ComputeSubscription[](len);

        for (uint64 id = startId; id < endId; ++id) {
            uint256 idx = uint256(id - startId);
            subscriptions[idx] = router.getComputeSubscription(id);
        }
    }

    /// @notice For each (subscriptionId, interval) pair returns redundancy count and whether a commitment exists.
    /// @dev Inputs must be of equal length and are matched element-wise. Computes requestId as keccak256(abi.encodePacked(id, interval)).
    /// @param ids Array of subscription IDs.
    /// @param intervals Array of interval indices; intervals[i] corresponds to ids[i].
    /// @return statuses Array of IntervalStatus for each input pair.
    function getIntervalStatuses(uint64[] calldata ids, uint32[] calldata intervals)
        external
        view
        returns (IntervalStatus[] memory statuses)
    {
        uint256 n = ids.length;
        statuses = new IntervalStatus[](n);

        for (uint256 i = 0; i < n; ++i) {
            bytes32 requestId = keccak256(abi.encodePacked(ids[i], intervals[i]));
            uint16 count = coordinator.redundancyCount(requestId);
            bool exists = coordinator.requestCommitments(requestId) != bytes32(0);
            statuses[i] = IntervalStatus({redundancyCount: count, commitmentExists: exists});
        }
    }
}
