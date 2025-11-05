// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {ICoordinator} from "./interfaces/ICoordinator.sol";
import {Commitment} from "./types/Commitment.sol";
import {ConfirmedOwner} from "./utility/ConfirmedOwner.sol";
import {ContractProposalSet} from "./types/ContractProposalSet.sol";
import {FulfillResult} from "./types/FulfillResult.sol";
import {IRouter} from "./interfaces/IRouter.sol";
import {ITypeAndVersion} from "./interfaces/ITypeAndVersion.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {Payment} from "./types/Payment.sol";
import {ProofVerificationRequest} from "./types/ProofVerificationRequest.sol";
import {SubscriptionsManager} from "./SubscriptionManager.sol";
import {ComputeSubscription} from "./types/ComputeSubscription.sol";
import {WalletFactory} from "./wallet/WalletFactory.sol";
import {CommitmentUtils} from "./utility/CommitmentUtils.sol";
import {RequestIdUtils} from "./utility/RequestIdUtils.sol";

/**
 * @title Router
 * @notice Main entry point for network. Manages contract resolution, subscription management,
 * and provides a unified interface for interacting with the protocol.
 */
contract Router is IRouter, ITypeAndVersion, SubscriptionsManager, Pausable, ConfirmedOwner {
    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Mapping of contract IDs to their addresses
    mapping(bytes32 => address) private route;

    /// @notice Set of proposed contract updates
    ContractProposalSet private proposedContractSet;

    /// @notice Current allow list ID
    bytes32 private allowListId;

    /// @notice Inbox contract address
    address private inbox;

    /// @notice WalletFactory instance
    WalletFactory private walletFactory;

    /// @notice Pending client address during ownership transfer
    address private pendingOwner;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a contract update is proposed
    event ContractsUpdateProposed(bytes32[] ids, address[] addresses);

    /// @notice Emitted when contracts are updated
    event ContractsUpdated(bytes32 id, address contractAddress);

    /// @notice Emitted when the allow list ID is updated
    event AllowListIdSet(bytes32 indexed newAllowListId);

    /// @notice Emitted when a request is started
    event RequestStart(
        bytes32 indexed requestId,
        uint64 indexed subscriptionId,
        bytes32 indexed containerId,
        uint32 interval,
        uint16 redundancy,
        bool useDeliveryInbox,
        uint256 feeAmount,
        address feeToken,
        address verifier,
        address coordinator
    );

    /// @notice Emitted when a request is processed
    event RequestProcessed(
        bytes32 indexed requestId,
        uint64 indexed subscriptionId,
        bytes32 indexed containerId,
        uint32 interval,
        bool useDeliveryInbox,
        uint256 feeAmount,
        address feeToken,
        address verifier,
        address coordinator,
        address nodeWallet,
        FulfillResult result
    );

    /// @notice Emitted when funds are locked for verification.
    event VerificationFundsLocked(bytes32 indexed requestId, address indexed spender, uint256 amount);

    /// @notice Emitted when funds are unlocked for verification.
    event VerificationFundsUnlocked(bytes32 indexed requestId, address indexed spender, uint256 amount);

    /// @notice Emitted when a payment is made via a coordinator.
    event PaymentMade(
        uint64 indexed subscriptionId,
        address indexed spenderWallet,
        address indexed recipient,
        address token,
        uint256 amount
    );
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidProposedUpdate();
    error OnlyCallableByOwner();
    error NotPendingOwner();
    error RouteNotFound(bytes32 id);
    error EmptyRequestData();
    error DuplicateRequestId(bytes32 requestId);
    error OnlyCallableFromCoordinator();
    error TokenMismatch();
    error InvalidRequestCommitment(bytes32 requestId);
    error MismatchedRequestId();
    error MismatchedSubscriptionId();

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Constructor initializes the Router with essential dependencies
     */
    constructor() ConfirmedOwner(msg.sender) {
        //        inbox = initInbox;
    }
    /**
     * @notice Sets the WalletFactory contract address.
     * @dev Can only be called once by the client to break the circular dependency at deployment.
     * @param _walletFactory The address of the deployed WalletFactory contract.
     */

    function setWalletFactory(address _walletFactory) external onlyOwner {
        require(address(walletFactory) == address(0), "WalletFactory already set");
        require(_walletFactory != address(0), "Invalid WalletFactory address");
        walletFactory = WalletFactory(_walletFactory);
    }

    /*//////////////////////////////////////////////////////////////
                              IOWNABLE MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Implementation of abstract function in SubscriptionsManager
    function _whenNotPaused() internal view override {
        _requireNotPaused();
    }

    /// @dev Used within FunctionsSubscriptions.sol
    function _onlyRouterOwner() internal view override {
        _validateOwnership();
    }

    /*//////////////////////////////////////////////////////////////
                             ROUTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @inheritdoc IRouter
     */
    function getLastSubscriptionId() external view override returns (uint64) {
        return currentSubscriptionId;
    }
    /**
     * @inheritdoc IRouter
     */

    function sendRequest(uint64 subscriptionId, uint32 interval)
        external
        override
        returns (bytes32, Commitment memory)
    {
        return _sendRequest(subscriptionId, interval);
    }

    function timeoutRequest(bytes32 requestId, uint64 subscriptionId, uint32 interval) external override {
        _timeoutRequest(requestId, subscriptionId, interval);
    }

    function payFromCoordinator(
        uint64 subscriptionId,
        address spenderWallet,
        address spenderAddress,
        Payment[] memory payments
    ) external override {
        if (_isExistingSubscription(subscriptionId) == false) {
            revert InvalidSubscription();
        }
        ComputeSubscription memory sub = subscriptions[subscriptionId];
        if (msg.sender != getContractById(sub.routeId)) {
            revert OnlyCallableFromCoordinator();
        }
        _pay(spenderWallet, spenderAddress, payments);
        for (uint256 i = 0; i < payments.length; i++) {
            Payment memory p = payments[i];
            emit PaymentMade(subscriptionId, spenderWallet, p.recipient, p.feeToken, p.feeAmount);
        }

    }

    /**
     * @inheritdoc IRouter
     */
    function fulfill(
        bytes memory input,
        bytes memory output,
        bytes memory proof,
        uint16 numRedundantDeliveries,
        address nodeWallet,
        Payment[] memory payments,
        Commitment memory commitment
    ) external override returns (FulfillResult resultCode) {
        if (msg.sender != commitment.coordinator) {
            revert OnlyCallableFromCoordinator();
        }
        bytes32 commitmentHash = requestCommitments[commitment.requestId];
        if (commitmentHash == bytes32(0)) {
            resultCode = FulfillResult.INVALID_REQUEST_ID;
            return resultCode;
        }
        if (keccak256(abi.encode(commitment)) != commitmentHash) {
            resultCode = FulfillResult.INVALID_COMMITMENT;
            return resultCode;
        }

        _payForFulfillment(commitment.requestId, commitment.walletAddress, payments);

        if (numRedundantDeliveries == commitment.redundancy) {
            delete requestCommitments[commitment.requestId];
        }

        // Process payment and handle callback
        _callback(
            commitment.subscriptionId,
            commitment.interval,
            numRedundantDeliveries,
            commitment.useDeliveryInbox,
            nodeWallet,
            input,
            output,
            proof
        );

        // Deactivate the subscription only if the current delivery is the last one for this interval
        // and there are no more intervals to execute.
        if (
            numRedundantDeliveries == commitment.redundancy
                && _hasSubscriptionNextInterval(commitment.subscriptionId, commitment.interval) == false
        ) {
            _makeSubscriptionInactive(commitment.subscriptionId);
        }

        resultCode = FulfillResult.FULFILLED;
        emit RequestProcessed(
            commitment.requestId,
            commitment.subscriptionId,
            commitment.containerId,
            commitment.interval,
            commitment.useDeliveryInbox,
            commitment.feeAmount,
            commitment.feeToken,
            commitment.verifier,
            commitment.coordinator,
            nodeWallet,
            resultCode
        );
    }

    /**
     * @inheritdoc IRouter
     */
    function lockForVerification(ProofVerificationRequest calldata proofRequest, Commitment memory commitment)
        external
        override
    {
        if (msg.sender != commitment.coordinator) {
            revert OnlyCallableFromCoordinator();
        }
        bytes32 commitmentHash = requestCommitments[commitment.requestId];
        if (commitmentHash == bytes32(0)) {
            revert InvalidRequestCommitment(commitment.requestId);
        }

        if (keccak256(abi.encode(commitment)) != commitmentHash) {
            revert InvalidRequestCommitment(commitment.requestId);
        }
        _lockForVerification(proofRequest);
        emit VerificationFundsLocked(proofRequest.requestId, proofRequest.submitterAddress, proofRequest.escrowedAmount);
    }

    /**
     * @notice Unlocks funds after verification.
     * @param proofRequest The proof verification request details.
     */
    function unlockForVerification(ProofVerificationRequest calldata proofRequest) external override {
        address coordinatorAddress = getContractById(subscriptions[proofRequest.subscriptionId].routeId);
        if (msg.sender != coordinatorAddress) {
            revert OnlyCallableFromCoordinator();
        }
        _unlockForVerification(proofRequest);
        emit VerificationFundsUnlocked(
            proofRequest.requestId, proofRequest.submitterAddress, proofRequest.escrowedAmount
        );
    }

    function hasSubscriptionNextInterval(uint64 subscriptionId, uint32 currentInterval)
        external
        view
        override
        returns (bool)
    {
        return _hasSubscriptionNextInterval(subscriptionId, currentInterval);
    }

    function createSubscriptionDelegatee(
        uint32 nonce,
        uint32 expiry,
        ComputeSubscription calldata sub,
        bytes calldata signature
    ) public override(IRouter, SubscriptionsManager) returns (uint64) {
        return super.createSubscriptionDelegatee(nonce, expiry, sub, signature);
    }

    /**
     * @inheritdoc IRouter
     */
    function prepareNodeVerification(
        uint64 subscriptionId,
        uint32 nextInterval,
        address nodeWallet,
        address token,
        uint256 amount
    ) external override whenNotPaused {
        // Implementation would handle node verification preparation
    }

    // ================================================================
    // |                 Contract Proposal methods                    |
    // ================================================================
    /**
     * @inheritdoc IRouter
     */
    function getContractById(bytes32 id) public view override returns (address) {
        // solhint-disable-line ordering
        return route[id];
    }

    /**
     * @inheritdoc IRouter
     */
    function getProposedContractById(bytes32 id) external view override returns (address) {
        for (uint256 i = 0; i < proposedContractSet.ids.length; i++) {
            if (proposedContractSet.ids[i] == id) {
                return proposedContractSet.to[i];
            }
        }
        revert RouteNotFound(id);
    }

    /**
     * @inheritdoc IRouter
     */
    function proposeContractsUpdate(bytes32[] calldata proposalSetIds, address[] calldata proposalSetAddresses)
        external
        override
    {
        if (proposalSetIds.length != proposalSetAddresses.length || proposalSetIds.length == 0) {
            revert InvalidProposedUpdate();
        }

        uint256 idsArrayLength = proposalSetIds.length;
        for (uint256 i = 0; i < idsArrayLength; ++i) {
            bytes32 id = proposalSetIds[i];
            address proposedContract = proposalSetAddresses[i];
            if (proposedContract == address(0) || route[id] == proposedContract) {
                revert InvalidProposedUpdate();
            }
        }

        proposedContractSet.ids = proposalSetIds;
        proposedContractSet.to = proposalSetAddresses;
        emit ContractsUpdateProposed(proposalSetIds, proposalSetAddresses);
    }

    /**
     * @inheritdoc IRouter
     */
    function updateContracts() external override onlyOwner {
        for (uint256 i = 0; i < proposedContractSet.ids.length; i++) {
            route[proposedContractSet.ids[i]] = proposedContractSet.to[i];
            emit ContractsUpdated(proposedContractSet.ids[i], proposedContractSet.to[i]);
        }
        delete proposedContractSet;
    }

    /**
     * @inheritdoc IRouter
     */
    function pause() external override onlyOwner {
        _pause();
    }

    /**
     * @inheritdoc IRouter
     */
    function unpause() external override onlyOwner {
        _unpause();
    }

    /**
     * @inheritdoc IRouter
     */
    function getAllowListId() external view override returns (bytes32) {
        return allowListId;
    }

    /**
     * @inheritdoc IRouter
     */
    function setAllowListId(bytes32 newAllowListId) external override onlyOwner {
        allowListId = newAllowListId;
        emit AllowListIdSet(allowListId);
    }

    /*//////////////////////////////////////////////////////////////
                     Wallet Factory
    //////////////////////////////////////////////////////////////*/
    /// @inheritdoc IRouter
    function getWalletFactory() external view override returns (address) {
        return address(walletFactory);
    }

    function isValidWallet(address walletAddr) external view override returns (bool) {
        return walletFactory.isValidWallet(walletAddr);
    }

    /*//////////////////////////////////////////////////////////////
                        TYPE & VERSION
    //////////////////////////////////////////////////////////////*/
    /// @inheritdoc ITypeAndVersion
    function typeAndVersion() external pure override returns (string memory) {
        return "Router_v1.0.0";
    }

    /*//////////////////////////////////////////////////////////////
                       SUBSCRIPTION MANAGER OVERRIDES
    //////////////////////////////////////////////////////////////*/
    function _getWalletFactory() internal view override returns (WalletFactory) {
        return walletFactory;
    }

    /*//////////////////////////////////////////////////////////////
                       INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function _sendRequest(uint64 subscriptionId, uint32 interval) private returns (bytes32, Commitment memory) {
        _whenNotPaused();
        require(_isExistingSubscription(subscriptionId), "InvalidSubscription");

        ComputeSubscription storage subscription = subscriptions[subscriptionId];
        address coordinatorAddr = getContractById(subscription.routeId);
        require(coordinatorAddr != address(0), "Coordinator not found");

        bytes32 requestId = RequestIdUtils.requestIdPacked(subscriptionId, interval);
        Commitment memory commitment;

        if (requestCommitments[requestId] != bytes32(0)) {
            // Request already exists, reconstruct the commitment to make the call idempotent.
            commitment = CommitmentUtils.build(subscription, subscriptionId, interval, coordinatorAddr);
        } else {
            // New request, mark it and start it in the coordinator.
            _markRequestInFlight(
                requestId,
                payable(subscription.wallet),
                subscriptionId,
                subscription.redundancy,
                subscription.feeToken,
                subscription.feeAmount
            );

            /// Update the activeAt timestamp to reflect the last activity
            if (subscription.activeAt == type(uint32).max) {
                subscription.activeAt = uint32(block.timestamp);
            }

            ICoordinator coordinator = ICoordinator(coordinatorAddr);
            commitment = coordinator.startRequest(
                requestId,
                subscriptionId,
                subscription.containerId,
                interval,
                subscription.redundancy,
                subscription.useDeliveryInbox,
                subscription.feeToken,
                subscription.feeAmount,
                subscription.wallet,
                subscription.verifier
            );
            requestCommitments[requestId] = keccak256(abi.encode(commitment));
        }

        emit RequestStart(
            requestId,
            subscriptionId,
            subscription.containerId,
            interval,
            subscription.redundancy,
            subscription.useDeliveryInbox,
            subscription.feeAmount,
            subscription.feeToken,
            commitment.verifier,
            coordinatorAddr
        );

        return (requestId, commitment);
    }

    function _timeoutRequest(bytes32 requestId, uint64 subscriptionId, uint32 interval) internal {
        ComputeSubscription storage subscription = subscriptions[subscriptionId];
        address coordinatorAddr = getContractById(subscription.routeId);
        require(coordinatorAddr != address(0), "Coordinator not found");
        ICoordinator coordinator = ICoordinator(coordinatorAddr);
        _releaseTimeoutRequestLock(requestId, subscriptionId, interval);
        coordinator.cancelRequest(requestId);
    }
}
