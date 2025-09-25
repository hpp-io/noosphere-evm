// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {ECDSA} from "solady/utils/ECDSA.sol";
import {EIP712} from "solady/utils/EIP712.sol";
//import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {BaseConsumer} from "./consumer/BaseConsumer.sol";
import {ProofVerificationRequest} from "./types/ProofVerificationRequest.sol";
import {ISubscriptionsManager} from "./interfaces/ISubscriptionManager.sol";
import {Payment} from "./types/Payment.sol";
import {Subscription} from "./types/Subscription.sol";
import {Wallet} from "./wallet/Wallet.sol";
import {WalletFactory} from "./wallet/WalletFactory.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";
import {Delegator} from "./utility/Delegator.sol";

abstract contract SubscriptionsManager is ISubscriptionsManager, EIP712 {
    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice EIP-712 signing domain major version
    string public constant EIP712_VERSION = "1";

    /// @notice EIP-712 signing domain name
    string public constant EIP712_NAME = "noosphere";

    /// @notice EIP-712 struct(Subscription) typeHash.
    /// @dev The fields must exactly match the order and types in the `Subscription` struct.
    bytes32 private constant EIP712_SUBSCRIPTION_TYPEHASH =
        keccak256(
            "Subscription(address owner,uint32 activeAt,uint32 period,uint32 frequency,uint16 redundancy,bytes32 containerId,bool lazy,address verifier,uint256 paymentAmount,address paymentToken,address wallet,bytes32 routeId)"
        );

    /// @notice EIP-712 struct(DelegateSubscription) typeHash.
    /// @dev The `nonce` prevents signature replay for a given subscriber.
    /// @dev The `expiry` defines when the delegated subscription signature expires.
    bytes32 private constant EIP712_DELEGATE_SUBSCRIPTION_TYPEHASH =
        keccak256(
            "DelegateSubscription(uint32 nonce,uint32 expiry,Subscription sub)Subscription(address owner,uint32 activeAt,uint32 period,uint32 frequency,uint16 redundancy,bytes32 containerId,bool lazy,address verifier,uint256 paymentAmount,address paymentToken,address wallet,bytes32 routeId)"
        );

    /// @dev Mapping of subscription IDs to `Subscription` objects.
    mapping(uint64 /* subscriptionId */ => Subscription) internal subscriptions;

    /// @dev A mapping storing request commitments. The key is `keccak256(abi.encode(subscriptionId, interval))`
    /// and the value is the commitment hash.
    /// This allows tracking pending requests for a given subscription and interval.
    mapping(bytes32 /* requestId */ => bytes32 /* commitmentHash */) internal requestCommitments;

    /// @notice Mapping from a subscribing contract to the maximum nonce seen.
    mapping(address => uint32) public maxSubscriberNonce;

    /// @notice Mapping from a hash of (subscriber, nonce) to a subscription ID.
    /// @dev Allows lookup of atomically created subscriptions to prevent duplicates.
    mapping(bytes32 => uint64) public delegateCreatedIds;

    // Keep a count of the number of subscriptions so that its possible to
    // loop through all the current subscriptions via .getSubscription().
    uint64 internal currentSubscriptionId;

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
    error InvalidWallet();

    error SignerMismatch();
    error SignatureExpired();

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

//    /**
//     * @inheritdoc ISubscriptionsManager
//     */
//    function hasSubscriptionNextInterval(uint64 subscriptionId, uint32 currentInterval)
//        external
//        view
//        virtual
//        returns (bool)
//    {
//        return _hasSubscriptionNextInterval(subscriptionId, currentInterval);
//    }

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
        // If period is = 0 (one-time), active immediately
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

    /**
     * @notice Creates a subscription from a pre-filled Subscription struct.
     * @dev This is an internal implementation. Access control should be handled by the inheriting contract (e.g., Router).
     * @param sub The subscription data.
     * @return The ID of the newly created subscription.
     */
    function createSubscriptionFor(Subscription calldata sub) public virtual returns (uint64) {
        uint64 subscriptionId = ++currentSubscriptionId;
        subscriptions[subscriptionId] = sub;
        emit SubscriptionCreated(subscriptionId);
        return subscriptionId;
    }

    /**
     * @notice Creates a subscription via an EIP-712 signature.
     * @dev Validates the signature and then creates the subscription.
     */
    function createSubscriptionDelegatee(
        uint32 nonce,
        uint32 expiry,
        Subscription calldata sub,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual returns (uint64) {
        // Check if this delegated subscription has already been created.
        bytes32 key = keccak256(abi.encodePacked(sub.owner, nonce));
        uint64 subscriptionId = delegateCreatedIds[key];
        // If it exists, return the ID, preventing replay.
        if (subscriptionId != 0) {
            return subscriptionId;
        }

        // If it's a new creation, verify the signature has not expired.
        if (block.timestamp >= expiry) {
            revert SignatureExpired();
        }

        // Hash the subscription struct.
        bytes32 subHash = _hashSubscription(sub);

        // Hash the full delegated subscription data.
        bytes32 digest = _hashTypedData(keccak256(abi.encode(EIP712_DELEGATE_SUBSCRIPTION_TYPEHASH, nonce, expiry, subHash)));

        // Recover the signer from the signature.
        address recoveredSigner = ECDSA.recover(digest, v, r, s);

        // Collect delegated signer from subscribing contract
        address delegatedSigner = Delegator(sub.owner).getSigner();

        // The signer must be the owner of the subscription being created.
        if (recoveredSigner != delegatedSigner) {
            revert SignerMismatch();
        }

        // At this point, the signature is valid. Create the subscription.
        subscriptionId = createSubscriptionFor(sub);

        // Store the link between the delegate creation parameters and the new ID.
        delegateCreatedIds[key] = subscriptionId;

        // Update the max known nonce for the subscriber to help off-chain clients.
        if (nonce > maxSubscriberNonce[sub.owner]) {
            maxSubscriberNonce[sub.owner] = nonce;
        }

        return subscriptionId;
    }

    /**
     * @dev Hashes the `Subscription` struct for EIP-712 signing.
      * @param sub The subscription struct to hash.
      * @return The EIP-712 hash of the struct.
      */
    function _hashSubscription(Subscription calldata sub) internal pure returns (bytes32) {
        return
            keccak256(
            abi.encode(
                EIP712_SUBSCRIPTION_TYPEHASH,
                sub.owner,
                sub.activeAt,
                sub.period,
                sub.frequency,
                sub.redundancy,
                sub.containerId,
                sub.lazy,
                sub.verifier,
                sub.paymentAmount,
                sub.paymentToken,
                sub.wallet,
                sub.routeId
            )
        );
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
        uint256 total = paymentAmount * redundancy; // solhint-disable-line no-inline-assembly
        // lock on wallet (this will revert if insufficient funds/allowance)
        Wallet consumer = Wallet(walletAddr);
        if (_getWalletFactory().isValidWallet(walletAddr) == false || address(consumer) == address(0)) {
            revert InvalidWallet();
        }
        consumer.lockForRequest(subscriptions[subscriptionId].owner, paymentToken, total, requestId, redundancy);
    }

    /// @notice Locks funds in the consumer's wallet for proof verification.
    /// @param proofRequest The details of the proof verification request.
    function _lockForVerification(ProofVerificationRequest calldata proofRequest) internal {
        Wallet submitterWallet = Wallet(payable(proofRequest.submitterWallet));
        submitterWallet.cLock(proofRequest.submitterAddress, proofRequest.escrowToken, proofRequest.slashAmount);
    }

    /// @notice Unlocks funds in the consumer's wallet after proof verification.
    /// @param proofRequest The details of the proof verification request.
    function _unlockForVerification(ProofVerificationRequest calldata proofRequest) internal {
        Wallet submitterWallet = Wallet(payable(proofRequest.submitterWallet));
        submitterWallet.cUnlock(proofRequest.submitterAddress, proofRequest.escrowToken, proofRequest.slashAmount);
    }


    function _payForFulfillment(
        bytes32 requestId,
        address walletAddress,
        Payment[] memory payments
    ) internal {
        if (requestCommitments[requestId] == bytes32(0)) {
            revert NoSuchCommitment();
        }
        Wallet consumer = Wallet(payable(walletAddress));
        if (_getWalletFactory().isValidWallet(address(consumer)) == false) {
            revert InvalidWallet();
        }
        consumer.disburseForFulfillment(requestId, payments);
    }

    function _pay(
        address walletAddress,
        address spenderAddress,
        Payment[] memory payments
    ) internal {
        Wallet wallet = Wallet(payable(walletAddress));
        if (_getWalletFactory().isValidWallet(address(wallet)) == false) {
            revert InvalidWallet();
        }
        wallet.cTransfer(spenderAddress, payments);
    }

    function _callback(
        uint64 subscriptionId,
        uint32 interval,
        uint16 numRedundantDeliveries,
        bool lazy,
        address node,
        bytes memory input,
        bytes memory output,
        bytes memory proof,
        bytes32 containerId
    ) internal {
        Subscription memory subscription = subscriptions[subscriptionId];
        BaseConsumer(subscription.owner).rawReceiveCompute(subscriptionId, interval, numRedundantDeliveries, lazy, node,
            input, output, proof, bytes32(0));
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

    function _hasSubscriptionNextInterval(
        uint64 subscriptionId,
        uint32 currentInterval
    ) internal view returns (bool) {
        if (!_isExistingSubscription(subscriptionId) || currentInterval >= subscriptions[subscriptionId].frequency) {
            return false;
        }
        Subscription storage sub = subscriptions[subscriptionId];

        // If a payment is required for the subscription, check for sufficient funds and allowance.
        if (sub.paymentAmount > 0) {
            Wallet wallet = Wallet(sub.wallet);
            uint256 requiredAmount = sub.paymentAmount * sub.redundancy;

            // Check if the consumer has enough allowance from the wallet.
            if (wallet.allowance(sub.owner, sub.paymentToken) < requiredAmount) {
                return false;
            }

            // Check if the wallet has enough unlocked balance.
            uint256 totalBalance =
                (sub.paymentToken == address(0)) ? address(wallet).balance : IERC20(sub.paymentToken).balanceOf(address(wallet));
            uint256 totalLocked = wallet.totalLockedFor(sub.paymentToken);
            if (totalBalance < totalLocked || (totalBalance - totalLocked) < requiredAmount) {
                return false;
            }
        }

        // Check if a request for the next interval has already been created.
        uint32 nextInterval = currentInterval + 1;
        bytes32 nextRequestId = keccak256(abi.encodePacked(subscriptionId, nextInterval));
        if (requestCommitments[nextRequestId] != bytes32(0)) {
            return false;
        }

        return true;
    }

    function _releaseTimeoutRequestLock(bytes32 requestId, uint64 subscriptionId, uint32 interval) internal {
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

    /// @dev Abstract function to be implemented by child contracts to provide the WalletFactory instance.
    function _getWalletFactory() internal view virtual returns (WalletFactory);

    /// @dev Overriden in FunctionsRouter.sol
    function _whenNotPaused() internal virtual;

    function _onlyRouterOwner() internal virtual;
}
