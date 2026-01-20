// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

//import {EIP712} from "solady/utils/EIP712.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ProofVerificationRequest} from "./types/ProofVerificationRequest.sol";
import {ISubscriptionsManager} from "./interfaces/ISubscriptionManager.sol";
import {Payment} from "./types/Payment.sol";
import {ComputeSubscription} from "./types/ComputeSubscription.sol";
import {Wallet} from "./wallet/Wallet.sol";
import {WalletFactory} from "./wallet/WalletFactory.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {Delegator} from "./utility/Delegator.sol";
import {RequestIdUtils} from "./utility/RequestIdUtils.sol";
import {ComputeClient} from "./client/ComputeClient.sol";
import {ICoordinator} from "./interfaces/ICoordinator.sol";
import {PayloadData} from "./types/PayloadData.sol";

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
    bytes32 private constant EIP712_SUBSCRIPTION_TYPEHASH = keccak256(
        "Subscription(address client,uint32 activeAt,uint32 intervalSeconds,uint32 maxExecutions,bytes32 containerId,bool useDeliveryInbox,address verifier,uint256 feeAmount,address feeToken,address wallet,bytes32 routeId)"
    );

    /// @notice EIP-712 struct(DelegateSubscription) typeHash.
    /// @dev The `nonce` prevents signature replay for a given subscriber.
    /// @dev The `expiry` defines when the delegated subscription signature expires.
    bytes32 private constant EIP712_DELEGATE_SUBSCRIPTION_TYPEHASH = keccak256(
        "DelegateSubscription(uint32 nonce,uint32 expiry,Subscription sub)Subscription(address client,uint32 activeAt,uint32 intervalSeconds,uint32 maxExecutions,bytes32 containerId,bool useDeliveryInbox,address verifier,uint256 feeAmount,address feeToken,address wallet,bytes32 routeId)"
    );

    /// @dev Mapping of subscription IDs to `Subscription` objects.
    mapping(uint64 /* subscriptionId */ => ComputeSubscription) internal subscriptions;

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

    /// @notice Minimum repeat interval for scheduled subscriptions
    uint32 public minRepeatInterval;

    /// @notice Gas limit for client callbacks (protects agents from expensive client logic)
    uint32 public callbackGasLimit;

    // ================================================================
    // |                       Initialization                         |
    // ================================================================
    constructor() EIP712(EIP712_NAME, EIP712_VERSION) {
        minRepeatInterval = 600;
        callbackGasLimit = 500_000; // Default 500k gas for callbacks
    }

    /*//////////////////////////////////////////////////////////////
                         ISubscriptionsManager IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Get stored subscription (use uint64 to match mapping key)
    function getComputeSubscription(uint64 subscriptionId) external view returns (ComputeSubscription memory) {
        return subscriptions[subscriptionId];
    }

    function getComputeSubscriptionInterval(uint64 subscriptionId) external view returns (uint32) {
        return _getSubscriptionInterval(subscriptionId);
    }

    /// @notice Creates a new compute subscription.
    /// @param containerId The ID of the container to execute.
    /// @param maxExecutions The maximum number of times the subscription can be executed.
    /// @param intervalSeconds The time interval between executions in seconds.
    /// @param useDeliveryInbox Whether to use a delivery inbox for results.
    /// @param feeToken The address of the ERC20 token used for fees.
    /// @param feeAmount The amount of fee per execution.
    /// @param wallet The address of the wallet associated with the subscription.
    /// @param verifier The address of the verifier contract.
    /// @param routeId The ID of the route for the subscription.
    /// @return The ID of the newly created subscription.
    function createComputeSubscription(
        string calldata containerId,
        uint32 maxExecutions,
        uint32 intervalSeconds,
        bool useDeliveryInbox,
        address feeToken,
        uint256 feeAmount,
        address wallet,
        address verifier,
        bytes32 routeId
    ) external virtual override returns (uint64) {
        _whenNotPaused();
        if (_getWalletFactory().isValidWallet(wallet) == false) {
            revert InvalidWallet();
        }
        if (intervalSeconds > 0 && intervalSeconds < minRepeatInterval) {
            revert SubscriptionIntervalTooShort(intervalSeconds, minRepeatInterval);
        }
        uint64 subscriptionId = ++currentSubscriptionId;
        subscriptions[subscriptionId] = ComputeSubscription({
            activeAt: type(uint32).max,
            client: msg.sender,
            maxExecutions: maxExecutions,
            intervalSeconds: intervalSeconds,
            containerId: keccak256(abi.encode(containerId)),
            useDeliveryInbox: useDeliveryInbox,
            verifier: payable(verifier),
            feeAmount: feeAmount,
            feeToken: feeToken,
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
    function createSubscriptionFor(ComputeSubscription calldata sub) public virtual returns (uint64) {
        _whenNotPaused();
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
        ComputeSubscription calldata sub,
        bytes calldata signature
    ) public override returns (uint64) {
        _whenNotPaused();
        // Check if this delegated subscription has already been created.
        bytes32 key = keccak256(abi.encodePacked(sub.client, nonce));
        uint64 subscriptionId = delegateCreatedIds[key];
        // If it exists, verify subscription is still active before returning.
        if (subscriptionId != 0) {
            ComputeSubscription storage existing = subscriptions[subscriptionId];
            // If subscription was deleted or cancelled (activeAt == max), revert
            // For transient subscriptions, activeAt is set to max after fulfillment
            if (existing.client == address(0) || existing.activeAt == type(uint32).max) {
                revert SubscriptionCompleted();
            }
            return subscriptionId;
        }
        // If it's a new creation, verify the signature has not expired.
        if (block.timestamp >= expiry) {
            revert SignatureExpired();
        }
        if (sub.intervalSeconds > 0 && sub.intervalSeconds < minRepeatInterval) {
            revert SubscriptionIntervalTooShort(sub.intervalSeconds, minRepeatInterval);
        }

        // Hash the subscription struct.
        bytes32 subHash = _hashSubscription(sub);

        // Hash the full delegated subscription data.
        bytes32 digest =
            _hashTypedDataV4(keccak256(abi.encode(EIP712_DELEGATE_SUBSCRIPTION_TYPEHASH, nonce, expiry, subHash)));

        // Recover the signer from the signature.
        address recoveredSigner = ECDSA.recover(digest, signature);

        // Collect delegated signer from subscribing contract
        address delegatedSigner = Delegator(sub.client).getSigner();

        // The signer must be the client of the subscription being created.
        if (recoveredSigner != delegatedSigner) {
            revert SignerMismatch();
        }

        // At this point, the signature is valid. Create the subscription.
        subscriptionId = createSubscriptionFor(sub);

        // Store the link between the delegate creation parameters and the new ID.
        delegateCreatedIds[key] = subscriptionId;

        // Update the max known nonce for the subscriber to help off-chain clients.
        if (nonce > maxSubscriberNonce[sub.client]) {
            maxSubscriberNonce[sub.client] = nonce;
        }
        return subscriptionId;
    }

    function cancelComputeSubscription(uint64 subscriptionId) external override {
        _whenNotPaused();
        if (subscriptions[subscriptionId].client == address(0)) {
            revert SubscriptionNotFound();
        }
        if (subscriptions[subscriptionId].client != msg.sender) {
            revert NotSubscriptionOwner();
        }

        // Clean up all past interval commitments before deletion
        uint32 currentInterval = _getSubscriptionInterval(subscriptionId);
        // For recurring subscriptions (intervalSeconds > 0), clean up past intervals
        // For transient subscriptions (intervalSeconds == 0), currentInterval is type(uint32).max,
        // so we only clean up the current interval in _cancelSubscriptionHelper
        if (currentInterval > 1 && currentInterval != type(uint32).max) {
            // Timeout all intervals up to currentInterval - 1
            // Use max uint32 for maxIter to process all intervals
            this.timeoutSubscriptionIntervalsUpTo(subscriptionId, currentInterval - 1, type(uint32).max);
        }

        _cancelSubscriptionHelper(subscriptionId);
    }

    function pendingRequestExists(uint64 subscriptionId) external view override returns (bool) {
        return _pendingRequestExists(subscriptionId);
    }

    mapping(uint64 => uint32) internal subscriptionLastProcessedInterval; // optional progress tracker

    /// @notice Batch timeout up to `uptoInterval` for a subscription; bounded by `maxIter`.
    /// @dev Uses Wallet.releaseForRequest for each timed-out request. Optimized to reduce SLOAD/SSTORE in loops.
    function timeoutSubscriptionIntervalsUpTo(uint64 subscriptionId, uint32 uptoInterval, uint32 maxIter) external {
        _whenNotPaused();
        // Load subscription once (storage) and some hot fields into locals
        ComputeSubscription storage sub = subscriptions[subscriptionId];
        uint32 currentInterval = _getSubscriptionInterval(subscriptionId);
        if (currentInterval == 0) {
            return;
        }

        if (uptoInterval > currentInterval) uptoInterval = currentInterval;
        uint32 lastProcessed = subscriptionLastProcessedInterval[subscriptionId];
        uint32 start = lastProcessed + 1;
        if (start == 0) start = 1; // guard (though lastProcessed default is 0 -> start = 1)

        uint32 processed = 0;
        uint32 intervalSeconds = sub.intervalSeconds;
        uint32 activeAt = sub.activeAt;
        address payable walletAddr = sub.wallet;

        Wallet consumer = Wallet(walletAddr);

        for (uint32 i = start; i <= uptoInterval && processed < maxIter;) {
            bytes32 rid = RequestIdUtils.requestIdPacked(subscriptionId, i);
            bytes32 stored = requestCommitments[rid];

            if (stored != bytes32(0)) {
                bool timeoutable;
                if (intervalSeconds == 0) {
                    timeoutable = uint32(block.timestamp) >= activeAt;
                } else {
                    timeoutable = i < currentInterval;
                }

                if (timeoutable) {
                    consumer.releaseForRequest(rid);
                    delete requestCommitments[rid];

                    // Clean up Coordinator state
                    address coordinatorAddr = _getCoordinatorByRouteId(sub.routeId);
                    if (coordinatorAddr != address(0)) {
                        try ICoordinator(coordinatorAddr).cancelRequest(rid) {} catch {}
                    }

                    emit CommitmentTimedOut(rid, subscriptionId, i);
                }
                unchecked {
                    ++processed;
                }
            } else {
                lastProcessed = i;
            }
            unchecked {
                ++i;
            }
        }
        if (processed > 0) {
            uint32 last = start + processed - 1;
            if (last > lastProcessed) {
                lastProcessed = last;
            }
        }

        if (lastProcessed > subscriptionLastProcessedInterval[subscriptionId]) {
            subscriptionLastProcessedInterval[subscriptionId] = lastProcessed;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL LOGIC HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Hashes the `Subscription` struct for EIP-712 signing.
     * @param sub The subscription struct to hash.
     * @return The EIP-712 hash of the struct.
     */
    function _hashSubscription(ComputeSubscription calldata sub) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_SUBSCRIPTION_TYPEHASH,
                sub.client,
                sub.activeAt,
                sub.intervalSeconds,
                sub.maxExecutions,
                sub.containerId,
                sub.useDeliveryInbox,
                sub.verifier,
                sub.feeAmount,
                sub.feeToken,
                sub.wallet,
                sub.routeId
            )
        );
    }

    function _getSubscriptionInterval(uint64 subscriptionId) internal view returns (uint32) {
        ComputeSubscription storage sub = subscriptions[subscriptionId];
        if (subscriptionId == 0 || sub.client == address(0)) {
            revert SubscriptionNotFound();
        }
        uint32 activeAt = sub.activeAt;
        uint32 intervalSeconds = sub.intervalSeconds;

        if (uint32(block.timestamp) < activeAt) return 0;
        if (intervalSeconds == 0) return type(uint32).max;

        unchecked {
            return ((uint32(block.timestamp) - activeAt) / intervalSeconds) + 1;
        }
    }

    function _pendingRequestExists(uint64 subscriptionId) internal view returns (bool) {
        uint32 interval = _getSubscriptionInterval(subscriptionId);
        bytes32 requestId = RequestIdUtils.requestIdPacked(subscriptionId, interval);
        return requestCommitments[requestId] != bytes32(0);
    }

    /// @notice Lock funds (request-level). Coordinator will return/issue commitment externally.
    /// @dev This locks `feeAmount` on the Wallet (via lockForRequest). Single payout per request.
    /// @param walletAddr Wallet address (subscriptions[subscriptionId].wallet)
    /// @param client subscription client address (spender for lockForRequest)
    /// @param feeToken token used for payment
    /// @param feeAmount per-response payment amount
    function _markRequestInFlight(bytes32 requestId, address payable walletAddr, address client, address feeToken, uint256 feeAmount) internal {
        // Gas optimization: wallet was already validated in createComputeSubscription(),
        // and createdWallets mapping never becomes false once set to true.
        // Removing redundant isValidWallet() call saves ~47k gas on Arbitrum Nitro v3.9+.
        // Gas optimization #8: client is passed as parameter to avoid redundant SLOAD (~2.1k gas).
        Wallet(walletAddr).lockForRequest(client, feeToken, feeAmount, requestId);
    }

    /// @notice Locks funds in the consumer's wallet for proof verification.
    /// @param proofRequest The details of the proof verification request.
    function _lockForVerification(ProofVerificationRequest calldata proofRequest) internal {
        Wallet submitterWallet = Wallet(payable(proofRequest.submitterWallet));
        submitterWallet.lockEscrow(proofRequest.submitterAddress, proofRequest.escrowToken, proofRequest.slashAmount);
    }

    /// @notice Unlocks funds in the consumer's wallet after proof verification.
    /// @param proofRequest The details of the proof verification request.
    function _unlockForVerification(ProofVerificationRequest calldata proofRequest) internal {
        Wallet submitterWallet = Wallet(payable(proofRequest.submitterWallet));
        submitterWallet.releaseEscrow(proofRequest.submitterAddress, proofRequest.escrowToken, proofRequest.slashAmount);
    }

    function _payForFulfillment(bytes32 requestId, address walletAddress, Payment[] calldata payments) internal {
        Wallet consumer = Wallet(payable(walletAddress));
        consumer.disburseForFulfillment(requestId, payments);
    }

    function _pay(address walletAddress, address spenderAddress, Payment[] calldata payments) internal {
        if (_getWalletFactory().isValidWallet(address(walletAddress)) == false) {
            revert InvalidWallet();
        }
        Wallet wallet = Wallet(payable(walletAddress));
        wallet.transferByRouter(spenderAddress, payments);
    }

    /// @dev Executes client callback with gas limit protection.
    ///      If callback fails (out of gas or revert), emits CallbackFailed but doesn't revert the tx.
    ///      This protects agents from malicious/inefficient client implementations.
    function _callback(
        uint64 subscriptionId,
        uint32 interval,
        bool useDeliveryInbox,
        address node,
        PayloadData calldata input,
        PayloadData calldata output,
        PayloadData calldata proof
    ) internal {
        address client = subscriptions[subscriptionId].client;

        // Encode the callback call
        bytes memory callData = abi.encodeCall(
            ComputeClient.receiveRequestCompute, (subscriptionId, interval, useDeliveryInbox, node, input, output, proof, bytes32(0))
        );

        // Execute with gas limit - failure doesn't revert the whole tx
        // solhint-disable-next-line avoid-low-level-calls
        (bool success,) = client.call{gas: callbackGasLimit}(callData);

        if (!success) {
            emit CallbackFailed(subscriptionId, interval, client);
        }
    }

    function _makeSubscriptionInactive(uint64 subscriptionId) internal {
        subscriptions[subscriptionId].activeAt = type(uint32).max;
    }

    function _cancelSubscriptionHelper(uint64 subscriptionId) internal {
        ComputeSubscription memory subscription = subscriptions[subscriptionId];
        subscription.activeAt = type(uint32).max;

        // Attempt to release any request-level lock for the current interval (if exists).
        // Note: we don't scan all historical intervals here for gas reasons.
        uint32 currentInterval = _getSubscriptionInterval(subscriptionId);
        if (currentInterval > 0) {
            bytes32 rid = RequestIdUtils.requestIdPacked(subscriptionId, currentInterval);
            if (requestCommitments[rid] != bytes32(0)) {
                Wallet consumer = Wallet(subscription.wallet);
                // release funds for that single requestId
                consumer.releaseForRequest(rid);
                delete requestCommitments[rid];

                // Also delete from Coordinator's s_requestCommitments to keep in sync
                address coordinatorAddr = _getCoordinatorByRouteId(subscription.routeId);
                if (coordinatorAddr != address(0)) {
                    try ICoordinator(coordinatorAddr).cancelRequest(rid) {} catch {}
                }

                emit CommitmentTimedOut(rid, subscriptionId, currentInterval);
            }
        }
        delete subscriptions[subscriptionId];
        emit SubscriptionCancelled(subscriptionId);
    }

    function _computeCommitmentHash(uint64 subscriptionId, uint32 interval, address coordinator)
        internal
        view
        returns (bytes32)
    {
        ComputeSubscription storage s = subscriptions[subscriptionId];
        return keccak256(
            abi.encode(subscriptionId, interval, s.containerId, s.useDeliveryInbox, s.verifier, s.feeAmount, s.feeToken, coordinator)
        );
    }

    function _isExistingSubscription(uint64 subscriptionId) internal view returns (bool) {
        if (subscriptionId == 0 || subscriptions[subscriptionId].client == address(0)) {
            return false;
        }
        return true;
    }

    function _hasSubscriptionNextInterval(uint64 subscriptionId, uint32 currentInterval) internal view returns (bool) {
        if (!_isExistingSubscription(subscriptionId) || currentInterval >= subscriptions[subscriptionId].maxExecutions) {
            return false;
        }
        ComputeSubscription storage sub = subscriptions[subscriptionId];

        // If a payment is required for the subscription, check for sufficient funds and allowance.
        if (sub.feeAmount > 0) {
            Wallet wallet = Wallet(sub.wallet);
            uint256 requiredAmount = sub.feeAmount; // Single payout per request

            // Gas optimization: single external call instead of 3 separate calls
            // Saves ~90,000 gas on Arbitrum Nitro v3.9+ (Multi-Constraint Pricing)
            (uint256 spenderAllowance, uint256 availableBalance) = wallet.getSpenderInfo(sub.client, sub.feeToken);

            // Check if the consumer has enough allowance and wallet has enough unlocked balance.
            if (spenderAllowance < requiredAmount || availableBalance < requiredAmount) {
                return false;
            }
        }

        // Check if a request for the next interval has already been created.
        uint32 nextInterval = currentInterval + 1;
        bytes32 nextRequestId = RequestIdUtils.requestIdPacked(subscriptionId, nextInterval);
        if (requestCommitments[nextRequestId] != bytes32(0)) {
            return false;
        }

        return true;
    }

    function _releaseTimeoutRequestLock(bytes32 requestId, uint64 subscriptionId, uint32 interval) internal {
        bytes32 expectedId = RequestIdUtils.requestIdPacked(subscriptionId, interval);
        if (expectedId != requestId) revert NoSuchCommitment();

        bytes32 stored = requestCommitments[requestId];
        if (stored == bytes32(0)) revert NoSuchCommitment();

        ComputeSubscription storage sub = subscriptions[subscriptionId];
        if (sub.activeAt == type(uint32).max) revert SubscriptionNotActive();

        uint32 currentInterval = _getSubscriptionInterval(subscriptionId);
        if (currentInterval == 0) revert SubscriptionNotActive();

        bool timeoutable;
        if (sub.intervalSeconds == 0) {
            // transient: activeAt passed => timeout allowed
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

        // Clean up all past interval commitments before deletion
        uint32 currentInterval = _getSubscriptionInterval(subscriptionId);
        if (currentInterval > 1) {
            // Timeout all intervals up to currentInterval - 1
            // Use max uint32 for maxIter to process all intervals
            this.timeoutSubscriptionIntervalsUpTo(subscriptionId, currentInterval - 1, type(uint32).max);
        }

        _cancelSubscriptionHelper(subscriptionId);
    }

    function setMinRepeatInterval(uint32 _minRepeatInterval) external {
        _onlyRouterOwner();
        minRepeatInterval = _minRepeatInterval;
        emit MinRepeatIntervalSet(_minRepeatInterval);
    }

    /// @notice Set the gas limit for client callbacks
    /// @param _callbackGasLimit New gas limit (must be >= 50,000)
    function setCallbackGasLimit(uint32 _callbackGasLimit) external {
        _onlyRouterOwner();
        require(_callbackGasLimit >= 50_000, "Callback gas limit too low");
        callbackGasLimit = _callbackGasLimit;
        emit CallbackGasLimitSet(_callbackGasLimit);
    }

    // ================================================================
    // |                         Modifiers                            |
    // ================================================================

    /// @dev Abstract function to be implemented by child contracts to provide the WalletFactory instance.
    function _getWalletFactory() internal view virtual returns (WalletFactory);

    /// @dev Abstract function to be implemented by child contracts to get coordinator address by route ID.
    function _getCoordinatorByRouteId(bytes32 routeId) internal view virtual returns (address);

    /// @dev Overriden in FunctionsRouter.sol
    function _whenNotPaused() internal virtual;

    function _onlyRouterOwner() internal virtual;
}
