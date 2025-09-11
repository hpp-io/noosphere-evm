// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;
import {Routable} from "../Routable.sol";

/// @title BaseConsumer
/// @notice Handles receiving container compute responses from Infernet coordinator
/// @notice Handles exposing container inputs to Infernet nodes via `getContainerInputs()`
/// @notice Declares internal `INBOX` reference to allow downstream consumers to read from `Inbox`
/// @dev Contains a single public entrypoint `rawReceiveCompute` callable only by the Infernet coordinator.
///      Once msg.sender is verified, parameters are proxied to internal function `_receiveCompute`
/// @dev Does not inherit `Coordinated` for `rawReceiveCompute` coordinator-permissioned check to keep error scope localized
abstract contract BaseConsumer is Routable {
    /*//////////////////////////////////////////////////////////////
                               IMMUTABLE
    //////////////////////////////////////////////////////////////*/

    /// @dev The router contract interface, accessible by derived contracts.
//    IOwnableRouter internal immutable I_ROUTER;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown if attempting to call `rawReceiveCompute` from a `msg.sender != address(COORDINATOR)`
    /// @dev 4-byte signature: `0x9ec853e6`
    error NotRouter();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes a new BaseConsumer.
    /// @param router The address of the router contract.
    constructor(address router) Routable(router) {}

    /*//////////////////////////////////////////////////////////////
                           VIRTUAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Callback entrypoint to receive container compute responses from validated Coordinator source
    /// @dev Called by `rawReceiveCompute` once validated that `msg.sender == address(COORDINATOR)`
    /// @dev This function should be implemented by derived contracts to handle the compute result.
    /// @param subscriptionId id of subscription being responded to
    /// @param interval subscription interval
    /// @param redundancy after this call succeeds, how many nodes will have delivered a response for this interval
    /// @param node address of responding Infernet node
    /// @param input optional off-chain container input recorded by Infernet node (empty, hashed input, processed input, or both), empty for lazy subscriptions
    /// @param output optional off-chain container output (empty, hashed output, processed output, both, or fallback: all encodeable data), empty for lazy subscriptions
    /// @param proof optional off-chain container execution proof (or arbitrary metadata), empty for lazy subscriptions
    /// @param containerId if lazy subscription, subscription compute container ID, else empty
    /// @param index if lazy subscription, `Inbox` lazy store index, else empty
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
    ) internal virtual {}

    /// @notice View function to broadcast dynamic container inputs to off-chain Infernet nodes
    /// @dev Developers can modify this function to return dynamic inputs
    /// @param subscriptionId subscription ID to collect container inputs for
    /// @param interval subscription interval to collect container inputs for
    /// @param timestamp timestamp at which container inputs are collected
    /// @param caller calling address
    /// @return The container inputs as bytes.
    function getContainerInputs(uint64 subscriptionId, uint32 interval, uint32 timestamp, address caller)
        external
        view
        virtual
        returns (bytes memory)
    {}

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Callback entrypoint called by Infernet Coordinator to return container compute responses
    /// @dev Callable only by `address(COORDINATOR)`, else throws `NotCoordinator()` error
    /// @param subscriptionId id of subscription being responded to
    /// @param interval subscription interval
    /// @param redundancy after this call succeeds, how many nodes will have delivered a response for this interval
    /// @param node address of responding Infernet node
    /// @param input optional off-chain container input recorded by Infernet node (empty, hashed input, processed input, or both), empty for lazy subscriptions
    /// @param output optional off-chain container output (empty, hashed output, processed output, both, or fallback: all encodeable data), empty for lazy subscriptions
    /// @param proof optional off-chain container execution proof (or arbitrary metadata), empty for lazy subscriptions
    /// @param containerId if lazy subscription, subscription compute container ID, else empty
    /// @param index if lazy subscription, `Inbox` lazy store index, else empty
    function rawReceiveCompute(
        uint64 subscriptionId,
        uint32 interval,
        uint16 redundancy,
        address node,
        bytes calldata input,
        bytes calldata output,
        bytes calldata proof,
        bytes32 containerId,
        uint256 index
    ) external {
        // Note: The original check was against a `COORDINATOR` variable that is no longer defined.
        // This check should be updated to reflect the current authorization mechanism, likely via the router.
        if (msg.sender != address (_getRouter())) { // Example check, might need adjustment based on router logic.
            revert NotRouter();
        }

        // Call internal receive function, since caller is validated
        _receiveCompute(subscriptionId, interval, redundancy, node, input, output, proof, containerId, index);
    }

    /// @notice Creates a new compute subscription.
    /// @param containerId The ID of the container to subscribe to.
    /// @param frequency The frequency of the subscription in seconds.
    /// @param period The period of the subscription in seconds.
    /// @param redundancy The number of redundant nodes required for the computation.
    /// @param lazy Whether the subscription is lazy (i.e., computation is triggered on demand).
    /// @param paymentToken The address of the payment token.
    /// @param paymentAmount The amount of payment token to be paid.
    /// @param wallet The address of the wallet to receive payments.
    /// @param verifier The address of the verifier contract.
    /// @param routeId The ID of the route to use for the subscription.
    /// @return The ID of the newly created subscription.
    function createComputeSubscription(
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
    ) external returns (uint64) {
        return _getRouter().createSubscription(
            containerId, frequency, period, redundancy, lazy, paymentToken, paymentAmount, wallet, verifier, routeId
        );
    }
}
