// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {ICoordinator} from "./interfaces/ICoordinator.sol";
import {FulfillResult} from "./types/FulfillResult.sol";
import {ConfirmedOwner} from "./utility/ConfirmedOwner.sol";
import {ContractProposalSet} from "./types/ContractProposalSet.sol";
import {IRouter} from "./interfaces/IRouter.sol";
import {ITypeAndVersion} from "./interfaces/ITypeAndVersion.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {Payment} from "./types/Payment.sol";
import {SubscriptionsManager} from "./SubscriptionManager.sol";
import {WalletFactory} from "./wallet/WalletFactory.sol";
import {Subscription} from "./types/Subscription.sol";
import {ProofVerificationRequest} from "./types/ProofVerificationRequest.sol";
import {Commitment} from "./types/Commitment.sol";

/**
 * @title Router
 * @notice Main entry point for Infernet network. Manages contract resolution, subscription management,
 * and provides a unified interface for interacting with the Infernet protocol.
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

    /// @notice Pending owner address during ownership transfer
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

    event RequestStart(
        bytes32 indexed requestId,
        uint64 indexed subscriptionId,
        bytes32 indexed containerId,
        uint32 interval,
        uint16 redundancy,
        bool lazy,
        uint256 paymentAmount,
        address paymentToken,
        address verifier,
        address coordinator
    );

    event RequestProcessed(
        bytes32 indexed requestId,
        uint64 indexed subscriptionId,
        bytes32 indexed containerId,
        uint32 interval,
        bool lazy,
        uint256 paymentAmount,
        address paymentToken,
        address verifier,
        address coordinator,
        FulfillResult result
    );

    /// @notice Emitted when funds are locked for verification.
    event VerificationFundsLocked(bytes32 indexed requestId, address indexed spender, uint256 amount);

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
     * @dev Can only be called once by the owner to break the circular dependency at deployment.
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
    function _whenNotPaused() internal override view {
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
    function sendRequest(
        uint64 subscriptionId,
        uint32 interval
    ) external override returns (bytes32) {
        return _sendRequest(subscriptionId, interval);
    }

    /**
     * @inheritdoc IRouter
     */
    function fulfill(
        bytes memory input,
        bytes memory output,
        bytes memory proof,
        uint256 index,
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

//        Subscription memory subscription = subscriptions[subscriptionId];
        _pay(commitment.requestId, commitment.walletAddress, 0, payments);

        delete requestCommitments[commitment.requestId];

        // Process payment and handle callback
        _callback(
            commitment.subscriptionId,
            commitment.interval,
            commitment.redundancy,
            msg.sender,
            input,
            output,
            proof,
            commitment.containerId,
            index
        );        
        resultCode = FulfillResult.FULFILLED;
        emit RequestProcessed(
            commitment.requestId,
            commitment.subscriptionId,
            commitment.containerId,
            commitment.interval,
            commitment.lazy,
            commitment.paymentAmount,
            commitment.paymentToken,
            commitment.verifier,
            commitment.coordinator,
            resultCode);
    }

    /**
     * @inheritdoc IRouter
     */
    function lockForVerification(ProofVerificationRequest calldata proofRequest, Commitment memory commitment) external override {
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
     * @inheritdoc IRouter
     */
    function writeInbox(
        bytes32 containerId,
        bytes calldata input,
        bytes calldata output,
        bytes calldata proof
    ) external override whenNotPaused {
        // Call to inbox contract to write data
        require(inbox != address(0), "Inbox not set");
        (bool success,) = inbox.call(
            abi.encodeWithSignature(
                "write(bytes32,bytes,bytes,bytes)",
                containerId,
                input,
                output,
                proof
            )
        );
        require(success, "Inbox write failed");
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
    function getContractById(bytes32 id) public view override returns (address) { // solhint-disable-line ordering
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
    function proposeContractsUpdate(
        bytes32[] calldata proposalSetIds,
        address[] calldata proposalSetAddresses
    ) external override {
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

    /*//////////////////////////////////////////////////////////////
                        TYPE & VERSION
    //////////////////////////////////////////////////////////////*/
    /// @inheritdoc ITypeAndVersion
    function typeAndVersion() external pure override returns (string memory) {
        return "route_v1_0_0";
    }

    /*//////////////////////////////////////////////////////////////
                       INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function _sendRequest(
        uint64 subscriptionId,
        uint32 interval
    ) private returns (bytes32) {
        _whenNotPaused();
        require(_isExistingSubscription(subscriptionId), "InvalidSubscription");
        Subscription storage subscription = subscriptions[subscriptionId];
        ICoordinator coordinator = ICoordinator(this.getContractById(subscription.routeId));
        bytes32 requestId = keccak256(abi.encodePacked(subscriptionId, interval));

        if (requestCommitments[requestId] != bytes32(0)) {
            revert DuplicateRequestId(requestId);
        }

        _markRequestInFlight(
            requestId,
            payable(subscription.wallet),
            subscriptionId,
            interval,
            subscription.redundancy,
            subscription.paymentToken,
            subscription.paymentAmount
        );

        Commitment memory commitment = coordinator.startRequest(
            requestId,
            subscriptionId,
            subscription.containerId,
            interval,
            subscription.redundancy,
            subscription.lazy,
            subscription.paymentToken,
            subscription.paymentAmount,
            subscription.wallet,
            subscription.verifier
        );
        requestCommitments[requestId] = keccak256(abi.encode(commitment));

        emit RequestStart(
            requestId,
            subscriptionId,
            subscription.containerId,
            interval,
            subscription.redundancy,
            subscription.lazy,
            subscription.paymentAmount,
            subscription.paymentToken,
            commitment.verifier,
            address(coordinator)
        );
        return requestId;
    }
}
