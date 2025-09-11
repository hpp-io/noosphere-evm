// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.4;

import {Coordinator} from "../../src/v1_0_0/Coordinator.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {Router} from "../../src/v1_0_0/Router.sol";

/// @title MockNode
/// @notice Mocks the functionality of an off-chain Infernet node
/// @dev Inherited functions contain state checks but not event or error checks and do not interrupt parent reverts (with reverting pre-checks)
contract MockNode is StdAssertions {
    /*//////////////////////////////////////////////////////////////
                               IMMUTABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Coordinator
    Coordinator private immutable COORDINATOR;

    /// @notice Inbox
//    Inbox private immutable INBOX;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// Creates new MockNode
    /// @param router router contract
    constructor(Router router) {
        bytes32 coordinatorId = bytes32("Coordinator_v1.0.0");
        address coordinatorAddress = router.getContractById(coordinatorId);
        Coordinator coordinator = Coordinator(coordinatorAddress);
        COORDINATOR = coordinator;
    }

    /*//////////////////////////////////////////////////////////////
                           INHERITED FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Wrapper function (calling Coordinator with msg.sender == node)
    function deliverCompute(
        uint32 deliveryInterval,
        bytes calldata input,
        bytes calldata output,
        bytes calldata proof,
        bytes memory commitmentData,
        address nodeWallet
    ) external {
        COORDINATOR.deliverCompute(deliveryInterval, input, output, proof, commitmentData, nodeWallet);
    }

    /*//////////////////////////////////////////////////////////////
                                FALLBACK
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}

    /// @dev Wrapper function (calling Coordinator with msg.sender == node)
//    function deliverComputeDelegatee(
//        uint32 nonce,
//        uint32 expiry,
//        Subscription calldata sub,
//        uint8 v,
//        bytes32 r,
//        bytes32 s,
//        uint32 deliveryInterval,
//        bytes calldata input,
//        bytes calldata output,
//        bytes calldata proof,
//        address nodeWallet
//    ) external {
//        COORDINATOR.deliverComputeDelegatee(
//            nonce, expiry, sub, v, r, s, deliveryInterval, input, output, proof, nodeWallet
//        );
//    }

//    /// @dev Wrapper function (calling Inbox with msg.sender == node)
//    function write(bytes32 containerId, bytes calldata input, bytes calldata output, bytes calldata proof)
//        external
//        returns (uint256)
//    {
//        return INBOX.write(containerId, input, output, proof);
//    }
}
