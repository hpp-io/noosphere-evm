// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import "../client/ScheduledComputeClient.sol";
import {Commitment} from "../types/Commitment.sol";

/**
 * @title HelloWorldScheduledClient
 * @notice Simple scheduled client for testing SchedulerService
 * @dev Minimal implementation for interval-based subscription testing
 * @dev Inherits createComputeSubscription from ComputeClient (via ScheduledComputeClient)
 */
contract HelloWorldScheduledClient is ScheduledComputeClient {
    constructor(address router) ScheduledComputeClient(router) {}

    /**
     * @notice Manually trigger the first execution (optional)
     */
    function triggerFirstExecution(uint64 subscriptionId, bytes memory inputs)
        external
        returns (uint64, Commitment memory)
    {
        return _requestCompute(subscriptionId, inputs);
    }

    /**
     * @notice Returns contract type and version
     */
    function typeAndVersion() external pure override returns (string memory) {
        return "HelloWorldScheduledClient_v1.0.0";
    }
}
