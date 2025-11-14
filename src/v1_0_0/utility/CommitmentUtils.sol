// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {Commitment} from "../types/Commitment.sol";
import {ComputeSubscription} from "../types/ComputeSubscription.sol";
import {RequestIdUtils} from "./RequestIdUtils.sol";

/**
 * @title CommitmentUtils
 * @notice A library for creating and managing Commitment structs.
 * @dev Provides a standardized way to build commitments from subscription data.
 */
library CommitmentUtils {
    /**
     * @notice Builds a Commitment struct from a subscription and interval data.
     * @param sub The compute subscription memory pointer.
     * @param interval The interval for which the commitment is being created.
     * @param coordinator The address of the coordinator that will handle the request.
     * @return A memory-resident Commitment struct.
     */
    function build(ComputeSubscription memory sub, uint64 subscriptionId, uint32 interval, address coordinator)
        internal
        pure
        returns (Commitment memory)
    {
        bytes32 requestId = RequestIdUtils.requestIdPacked(subscriptionId, interval);

        return Commitment({
            requestId: requestId,
            subscriptionId: subscriptionId,
            containerId: sub.containerId,
            interval: interval,
            useDeliveryInbox: sub.useDeliveryInbox,
            redundancy: sub.redundancy,
            walletAddress: sub.wallet,
            feeAmount: sub.feeAmount,
            feeToken: sub.feeToken,
            verifier: sub.verifier,
            coordinator: coordinator
        });
    }
}
