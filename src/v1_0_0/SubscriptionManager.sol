// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {BaseConsumer} from "./consumer/BaseConsumer.sol";
import {ProofVerificationRequest} from "./types/ProofVerificationRequest.sol";
import {ISubscriptionsManager} from "./interfaces/ISubscriptionManager.sol";
import {Payment} from "./types/Payment.sol";
import {Subscription} from "./types/Subscription.sol";
import {Wallet} from "./wallet/Wallet.sol";

abstract contract SubscriptionsManager is ISubscriptionsManager {
    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    /// @dev Mapping of subscription IDs to `Subscription` objects.
    mapping(uint64 /* subscriptionId */ => Subscription) internal subscriptions;

    /// @dev A mapping storing request commitments. The key is `keccak256(abi.encode(subscriptionId, interval))`
    /// and the value is the commitment hash.
    /// This allows tracking pending requests for a given subscription and interval.
    mapping(bytes32 /* requestId */ => bytes32 /* commitmentHash */) internal requestCommitments;

    // Keep a count of the number of subscriptions so that its possible to
    // loop through all the current subscriptions via .getSubscription().
    uint64 private currentSubscriptionId;

    /// @notice Emitted when a new subscription is created
    /// @param id subscription ID
    event SubscriptionCreated(uint64 indexed id);

    /// @notice Emitted when a subscription is cancelled
    /// @param id subscription ID
    event SubscriptionCancelled(uint64 indexed id);

    /// @notice Emitted when a subscription is fulfilled
    /// @param id subscription ID
    /// @param node address of fulfilling node
    event SubscriptionFulfilled(uint64 indexed id, address indexed node);

    /// @notice Emitted when a commitment times out and is cleaned up
    event CommitmentTimedOut(bytes32 indexed requestId, uint64 indexed subscriptionId, uint32 indexed interval);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotSubscriptionOwner();
    error SubscriptionNotFound();
    error SubscriptionNotActive();
    error SubscriptionCompleted();
    error CannotRemoveWithPendingRequests();
    error InvalidSubscription();
    error NoSuchCommitment();
    error CommitmentNotTimeoutable();

    // ================================================================
    // |                       Initialization                         |
    // ================================================================
    constructor() {}

    /*//////////////////////////////////////////////////////////////
                         ISubscriptionsManager IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Get stored subscription (use uint64 to match mapping key)
    function getSubscription(uint64 subscriptionId) external view returns (Subscription memory) {
        return subscriptions[subscriptionId];
    }

    function getSubscriptionInterval(uint64 subscriptionId) external view returns (uint32) {
        return _getSubscriptionInterval(subscriptionId);
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
        address verifier,
        bytes32 routeId
    ) external virtual override returns (uint64) {
        uint64 subscriptionId = ++currentSubscriptionId;
        unchecked {
        }
        subscriptions[subscriptionId] = Subscription({
            activeAt: uint32(block.timestamp) + period,
            owner: msg.sender,
            redundancy: redundancy,
            frequency: frequency,
            period: period,
            containerId: keccak256(abi.encode(containerId)),
            lazy: lazy,
            verifier: payable(verifier),
            paymentAmount: paymentAmount,
            paymentToken: paymentToken,
            wallet: payable(wallet),
            routeId: routeId
        });

        emit SubscriptionCreated(subscriptionId);
        return subscriptionId;
    }

    function cancelSubscription(uint64 subscriptionId) external override {
        if (subscriptions[subscriptionId].owner != msg.sender) {
            revert NotSubscriptionOwner();
        }
        if (_pendingRequestExists(subscriptionId)) {
            revert CannotRemoveWithPendingRequests();
        }
        subscriptions[subscriptionId].activeAt = type(uint32).max;
        emit SubscriptionCancelled(subscriptionId);
    }

    function pendingRequestExists(uint64 subscriptionId) external view override returns (bool) {
        return _pendingRequestExists(subscriptionId);
    }

    /// @notice Time out a single request identified by requestId (and the subscriptionId/interval used to build it).
    /// @dev Uses Wallet.releaseForRequest(requestId) to refund remaining locked funds for that request.
    function timeoutRequest(bytes32 requestId, uint64 subscriptionId, uint32 interval) external override {
        bytes32 expectedId = keccak256(abi.encodePacked(subscriptionId, interval));
        if (expectedId != requestId) revert NoSuchCommitment();

        bytes32 stored = requestCommitments[requestId];
        if (stored == bytes32(0)) revert NoSuchCommitment();

        Subscription storage sub = subscriptions[subscriptionId];
        uint32 currentInterval = _getSubscriptionInterval(subscriptionId);
        if (currentInterval == 0) revert CommitmentNotTimeoutable();

        bool timeoutable;
        if (sub.period == 0) {
            // one-shot: activeAt passed => timeout allowed
            timeoutable = uint32(block.timestamp) >= sub.activeAt;
        } else {
            // recurring: only if this interval is already in the past
            timeoutable = interval < currentInterval;
        }

        if (!timeoutable) revert CommitmentNotTimeoutable();

        // Use request-level release (Wallet.releaseForRequest)
        Wallet consumer = Wallet(sub.wallet);
        consumer.releaseForRequest(requestId);

        delete requestCommitments[requestId];

        emit CommitmentTimedOut(requestId, subscriptionId, interval);
    }

    mapping(uint64 => uint32) internal subscriptionLastProcessedInterval; // optional progress tracker

    /// @notice Batch timeout up to `uptoInterval` for a subscription; bounded by `maxIter`.
    /// @dev Uses Wallet.releaseForRequest for each timed-out request.
    function timeoutSubscriptionIntervalsUpTo(uint64 subscriptionId, uint32 uptoInterval, uint32 maxIter) external {
        Subscription storage sub = subscriptions[subscriptionId];
        uint32 currentInterval = _getSubscriptionInterval(subscriptionId);
        if (currentInterval == 0) {
            return; // not active yet
        }
        if (uptoInterval > currentInterval) uptoInterval = currentInterval;

        uint32 start = subscriptionLastProcessedInterval[subscriptionId] + 1;
        if (start == 0) start = 1;

        uint32 processed = 0;
        for (uint32 i = start; i <= uptoInterval && processed < maxIter; ++i) {
            bytes32 rid = keccak256(abi.encodePacked(subscriptionId, i));
            bytes32 stored = requestCommitments[rid];
            if (stored != bytes32(0)) {
                bool timeoutable;
                if (sub.period == 0) {
                    timeoutable = uint32(block.timestamp) >= sub.activeAt;
                } else {
                    timeoutable = i < currentInterval;
                }

                if (timeoutable) {
                    Wallet consumer = Wallet(sub.wallet);
                    consumer.releaseForRequest(rid);
                    delete requestCommitments[rid];
                    emit CommitmentTimedOut(rid, subscriptionId, i);
                }
                processed++;
            } else {
                // advance lastProcessed even when no commitment exists, to avoid revisiting
                subscriptionLastProcessedInterval[subscriptionId] = i;
            }
        }

        if (processed > 0) {
            uint32 last = start + processed - 1;
            if (last > subscriptionLastProcessedInterval[subscriptionId]) {
                subscriptionLastProcessedInterval[subscriptionId] = last;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL LOGIC HELPERS
    //////////////////////////////////////////////////////////////*/

    function _getSubscriptionInterval(uint64 subscriptionId) internal view returns (uint32) {
        Subscription storage sub = subscriptions[subscriptionId];
        if (!_isExistingSubscription(subscriptionId)) {
            revert SubscriptionNotFound();
        }

        uint32 activeAt = sub.activeAt;
        uint32 period = sub.period;
        if (uint32(block.timestamp) < activeAt) {
            revert SubscriptionNotActive();
        }
        if (period == 0) {
            return 1;
        }
        unchecked {
            return ((uint32(block.timestamp) - activeAt) / period) + 1;
        }
    }

    function _pendingRequestExists(uint64 subscriptionId) internal view returns (bool) {
        uint32 interval = _getSubscriptionInterval(subscriptionId);
        bytes32 requestId = keccak256(abi.encodePacked(subscriptionId, interval));
        return requestCommitments[requestId] != bytes32(0);
    }

    /// @notice Lock funds (request-level). Coordinator will return/issue commitment externally.
    /// @dev This locks `paymentAmount * redundancy` on the Wallet (via lockForRequest).
    /// @param walletAddr Wallet address (subscriptions[subscriptionId].wallet)
    /// @param subscriptionId subscription id
    /// @param interval interval for this request
    /// @param redundancy number of expected payouts
    /// @param paymentToken token used for payment
    /// @param paymentAmount per-response payment amount
    function _markRequestInFlight(
        bytes32 requestId,
        address payable walletAddr,
        uint64 subscriptionId,
        uint32 interval,
        uint16 redundancy,
        address paymentToken,
        uint256 paymentAmount
    ) internal {
        // compute total to lock (paymentAmount * redundancy)
        uint256 total = uint256(paymentAmount) * uint256(redundancy);
        // lock on wallet (this will revert if insufficient funds/allowance)
        Wallet consumer = Wallet(walletAddr);
        require(address(consumer) != address(0), "Invalid wallet address");
        consumer.lockForRequest(subscriptions[subscriptionId].owner, paymentToken, total, requestId, redundancy);
    }

    /// @notice Locks funds in the consumer's wallet for proof verification.
    /// @param proofRequest The details of the proof verification request.
    function _lockForVerification(ProofVerificationRequest calldata proofRequest) internal {
        Wallet submitterWallet = Wallet(payable(proofRequest.submitterWallet));
        submitterWallet.cLock(proofRequest.submitterAddress, proofRequest.escrowToken, proofRequest.escrowedAmount);
    }

    function _pay(
        bytes32 requestId,
        address walletAddress,
        uint64 commitmentId,
        Payment[] memory payments
    ) internal {
        Wallet consumer = Wallet(payable(walletAddress));
        consumer.disburseForFulfillment(requestId, payments);
    }

    function _callback(
        uint64 subscriptionId,
        uint32 interval,
        uint16 numRedundantDeliveries,
        address node,
        bytes memory input,
        bytes memory output,
        bytes memory proof,
        bytes32 containerId
    ) internal {
        Subscription memory subscription = subscriptions[subscriptionId];
        BaseConsumer(subscription.owner).rawReceiveCompute(
            subscriptionId, interval, numRedundantDeliveries,
            node, input, output, proof, bytes32(0), 0
        );
    }

    function _cancelSubscriptionHelper(uint64 subscriptionId) internal {
        Subscription memory subscription = subscriptions[subscriptionId];
        subscription.activeAt = type(uint32).max;

        // Attempt to release any request-level lock for the current interval (if exists).
        // Note: we don't scan all historical intervals here for gas reasons.
        uint32 currentInterval = _getSubscriptionInterval(subscriptionId);
        if (currentInterval > 0) {
            bytes32 rid = keccak256(abi.encodePacked(subscriptionId, currentInterval));
            if (requestCommitments[rid] != bytes32(0)) {
                Wallet consumer = Wallet(subscription.wallet);
                // release funds for that single requestId
                consumer.releaseForRequest(rid);
                delete requestCommitments[rid];
                emit CommitmentTimedOut(rid, subscriptionId, currentInterval);
            }
        }

        // Mark subscription inactive
        subscriptions[subscriptionId].activeAt = type(uint32).max;
        emit SubscriptionCancelled(subscriptionId);
    }

    function _timeoutPrepareNextIntervalRequests(uint32 subscriptionId) internal {
        // Internal implementation placeholder
    }

    function _computeCommitmentHash(
        uint64 subscriptionId,
        uint32 interval,
        address coordinator
    ) internal view returns (bytes32) {
        Subscription storage s = subscriptions[subscriptionId];
        return keccak256(
            abi.encode(
                subscriptionId,
                interval,
                s.containerId,
                s.lazy,
                s.verifier,
                s.paymentAmount,
                s.paymentToken,
                s.redundancy,
                coordinator
            )
        );
    }

    function _isExistingSubscription(uint64 subscriptionId) internal view returns (bool) {
        if (subscriptionId == 0 || subscriptions[subscriptionId].owner == address(0)) {
            return false;
        }
        return subscriptions[subscriptionId].activeAt != type(uint32).max;
    }

    // ================================================================
    // |                      Owner methods                           |
    // ================================================================

    function ownerCancelSubscription(uint64 subscriptionId) external {
        _onlyRouterOwner();
        _cancelSubscriptionHelper(subscriptionId);
    }

    // ================================================================
    // |                         Modifiers                            |
    // ================================================================

    /// @dev Overriden in FunctionsRouter.sol
    function _whenNotPaused() internal virtual;

    function _onlyRouterOwner() internal virtual;
}
