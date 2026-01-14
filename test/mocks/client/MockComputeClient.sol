// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.4;

import {PayloadRef} from "../../../src/v1_0_0/types/PayloadRef.sol";

/*//////////////////////////////////////////////////////////////
                            PUBLIC STRUCTS
//////////////////////////////////////////////////////////////*/

/// @notice Output delivered from node
/// @param subscriptionId subscription ID
/// @param interval subscription interval
/// @param redundancy after this call succeeds, how many nodes will have delivered a response for this interval
/// @param node responding node address
/// @param inputRef PayloadRef pointing to input data
/// @param outputRef PayloadRef pointing to output data
/// @param proofRef PayloadRef pointing to proof data
/// @param containerId if useDeliveryInbox subscription, subscription compute container ID, else empty
struct DeliveredOutput {
    uint64 subscriptionId;
    uint32 interval;
    uint16 redundancy;
    bool useDeliveryInbox;
    address node;
    PayloadRef inputRef;
    PayloadRef outputRef;
    PayloadRef proofRef;
    bytes32 containerId;
}

/// @title MockComputeClient.sol
/// @notice Mocks ComputeClient.sol contract
abstract contract MockComputeClient {
    /*//////////////////////////////////////////////////////////////
                                MUTABLE
    //////////////////////////////////////////////////////////////*/

    error DeliveredOutputNotFount(uint64 subscriptionId, uint32 interval, uint16 redundancy);

    /// @notice Subscription ID => Interval => Redundancy => DeliveredOutput
    /// @dev Visibility restricted to `internal` to allow downstream inheriting contracts to modify mapping
    mapping(uint64 => mapping(uint64 => mapping(uint16 => DeliveredOutput))) internal outputs;

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Read `DeliveredOutput` from `outputs`
    /// @dev Useful read interface to return `DeliveredOutput` struct rather than destructured parameters
    /// @param subscriptionId subscription ID
    /// @param interval subscription interval
    /// @param redundancy after this call succeeds, how many nodes will have delivered a response for this interval
    /// @return output delivered from node
    function getDeliveredOutput(uint64 subscriptionId, uint32 interval, uint16 redundancy)
        external
        view
        returns (DeliveredOutput memory)
    {
        return outputs[subscriptionId][interval][redundancy];
    }
}
