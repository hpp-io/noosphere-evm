// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;
import {PendingDelivery} from "../types/PendingDelivery.sol";

/// @title DeliveryInbox.sol
/// @notice Request-centric pending delivery store: stores at most one PendingDelivery per (requestId, node).
/// @dev Mixin to be inherited by consumer contracts. Use `_enqueuePendingDelivery` internally when useDeliveryInbox.
abstract contract DeliveryInbox {
    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a pending delivery is submitted/overwritten for (requestId, node).
    event DeliverySubmitted(bytes32 indexed requestId, address indexed node);

    /// @notice Emitted when a stored pending delivery is cleared for (requestId, node).
    event DeliveryCleared(bytes32 indexed requestId, address indexed node);

    /// @notice Emitted when a node is first recorded for a given requestId (for enumeration).
    event NodeAdded(bytes32 indexed requestId, address indexed node);

    /// @notice Emitted when a node entry is removed from the request's node index.
    event NodeRemoved(bytes32 indexed requestId, address indexed node);

    /*//////////////////////////////////////////////////////////////
                            DATA STRUCTURES
    //////////////////////////////////////////////////////////////*/

    /// @notice requestId => node => PendingDelivery (single-slot per node)
    mapping(bytes32 => mapping(address => PendingDelivery)) private _deliveriesByRequest;

    /// @notice requestId => list of nodes that submitted (for on-chain enumeration)
    mapping(bytes32 => address[]) private _nodesByRequest;

    /// @notice helper to check whether a node is already registered in _nodesByRequest
    mapping(bytes32 => mapping(address => bool)) private _isNodeRegistered;

    /*//////////////////////////////////////////////////////////////
                            INTERNAL API
    //////////////////////////////////////////////////////////////*/

    /// @notice Store or overwrite a pending delivery for (requestId, node).
    /// @dev Overwrites any prior delivery from same node for the same requestId.
    /// @param requestId Identifier for the request (e.g., keccak(subscriptionId, interval)).
    /// @param node Address of the node submitting the delivery.
    /// @param subscriptionId Subscription id (fits in uint32).
    /// @param interval Interval id (uint32).
    /// @param input Optional input bytes.
    /// @param output Optional output bytes.
    /// @param proof Optional proof/metadata bytes.
    function _enqueuePendingDelivery(
        bytes32 requestId,
        address node,
        uint64 subscriptionId,
        uint32 interval,
        bytes calldata input,
        bytes calldata output,
        bytes calldata proof
    ) internal {
        // record node for enumeration if first time
        if (!_isNodeRegistered[requestId][node]) {
            _isNodeRegistered[requestId][node] = true;
            _nodesByRequest[requestId].push(node);
            emit NodeAdded(requestId, node);
        }

        // store/overwrite delivery
        _deliveriesByRequest[requestId][node] = PendingDelivery({
            timestamp: uint32(block.timestamp),
            subscriptionId: subscriptionId,
            interval: interval,
            input: input,
            output: output,
            proof: proof
        });

        emit DeliverySubmitted(requestId, node);
    }

    /// @notice Internal: clear stored pending delivery for (requestId, node).
    /// @dev If `removeFromIndex` = true, node will also be removed from index (O(n)).
    function _clearDelivery(
        bytes32 requestId,
        address node,
        bool removeFromIndex
    ) internal {
        PendingDelivery storage pd = _deliveriesByRequest[requestId][node];
        // timestamp 0 indicates empty slot (we never store timestamp == 0)
        if (pd.timestamp == 0) return;

        delete _deliveriesByRequest[requestId][node];
        emit DeliveryCleared(requestId, node);

        if (removeFromIndex && _isNodeRegistered[requestId][node]) {
            _removeNodeFromRequest(requestId, node);
        }
    }

    /// @notice Internal: clear all pending deliveries for a requestId (careful: gas-heavy).
    /// @dev Iterates nodes list and deletes each slot. Limit access in production.
    function _clearAllForRequest(bytes32 requestId) internal {
        address[] storage nodes = _nodesByRequest[requestId];
        for (uint256 i = 0; i < nodes.length; ++i) {
            address n = nodes[i];
            PendingDelivery storage pd = _deliveriesByRequest[requestId][n];
            if (pd.timestamp != 0) {
                delete _deliveriesByRequest[requestId][n];
                emit DeliveryCleared(requestId, n);
            }
            _isNodeRegistered[requestId][n] = false;
            emit NodeRemoved(requestId, n);
        }
        delete _nodesByRequest[requestId];
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Return whether (requestId, node) currently has a stored pending delivery.
    /// @dev True if the node has submitted and its delivery hasn't been cleared yet.
    function hasDelivery(bytes32 requestId, address node) public view returns (bool) {
        return _deliveriesByRequest[requestId][node].timestamp != 0;
    }

    /// @notice Read stored pending delivery for (requestId, node).
    /// @return exists true if present, and the PendingDelivery payload (copied to memory).
    function getDelivery(bytes32 requestId, address node)
    public
    view
    returns (bool exists, PendingDelivery memory pd)
    {
        PendingDelivery storage r = _deliveriesByRequest[requestId][node];
        if (r.timestamp == 0) return (false, pd);

        pd = PendingDelivery({
            timestamp: r.timestamp,
            subscriptionId: r.subscriptionId,
            interval: r.interval,
            input: r.input,
            output: r.output,
            proof: r.proof
        });
        return (true, pd);
    }

    /// @notice Return nodes that have (or had) pending deliveries for `requestId`.
    /// @dev Nodes may still be present even if individual delivery was cleared without index removal.
    function getNodesForRequest(bytes32 requestId) public view returns (address[] memory) {
        return _nodesByRequest[requestId];
    }

    /*//////////////////////////////////////////////////////////////
                          INDEX MAINTENANCE (INTERNAL)
    //////////////////////////////////////////////////////////////*/

    /// @notice Remove a node from `_nodesByRequest[requestId]` (O(n)).
    function _removeNodeFromRequest(bytes32 requestId, address node) internal {
        if (!_isNodeRegistered[requestId][node]) return;

        address[] storage arr = _nodesByRequest[requestId];
        uint256 len = arr.length;
        for (uint256 i = 0; i < len; ++i) {
            if (arr[i] == node) {
                if (i != len - 1) arr[i] = arr[len - 1];
                arr.pop();
                break;
            }
        }
        _isNodeRegistered[requestId][node] = false;
        emit NodeRemoved(requestId, node);
    }

    /*//////////////////////////////////////////////////////////////
                              NOTES & SAFETY
    //////////////////////////////////////////////////////////////*/

    // - Semantics: one (latest) PendingDelivery per (requestId, node). Duplicate submissions by same node -> overwrite.
    // - Use getDelivery/hasDelivery/getNodesForRequest for inspection.
    // - Removing a node from the index is O(n); avoid doing it frequently on-chain if node lists grow large.
    // - Consider storing hashes of large payloads (output/proof) on-chain to save gas and putting full blobs off-chain (IPFS/Arweave).
    // - _enqueuePendingDelivery is internal so authorization (who may call it) should be enforced by caller (e.g., only Coordinator/Router).
}
