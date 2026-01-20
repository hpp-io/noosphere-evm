// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {ConfirmedOwner} from "./utility/ConfirmedOwner.sol";
import {BillingConfig} from "./types/BillingConfig.sol";
import {Billing} from "./Billing.sol";
import {Commitment} from "./types/Commitment.sol";
import {ICoordinator} from "./interfaces/ICoordinator.sol";
import {IVerifier} from "./interfaces/IVerifier.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ComputeSubscription} from "./types/ComputeSubscription.sol";
import {CommitmentUtils} from "./utility/CommitmentUtils.sol";
import {ProofVerificationRequest} from "./types/ProofVerificationRequest.sol";
import {PayloadData} from "./types/PayloadData.sol";

/// @title Coordinator
/// @notice Orchestrates request lifecycle: start -> deliver -> verify -> settlement.
/// @dev This contract manages the entire lifecycle of compute requests, from initiation to settlement.

contract Coordinator is ICoordinator, Billing, ReentrancyGuard, ConfirmedOwner {
    // ---------- TYPE & VERSION ----------
    // solhint-disable-next-line const-name-snakecase
    string public constant override typeAndVersion = "Coordinator_v1.0.0";
    /*//////////////////////////////////////////////////////////////////////////
                                     STORAGE
    //////////////////////////////////////////////////////////////////////////*/
    /// @notice Address of the SubscriptionBatchReader utility contract.
    address private subscriptionBatchReader;

    /*//////////////////////////////////////////////////////////////////////////
                                  CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Initialize Coordinator with router address (via Billing) and initial owner.
    /// @param _routerAddress Router contract address used by Billing to resolve contracts.
    /// @param _initialOwner Owner of this Coordinator contract (ConfirmedOwner).
    constructor(address _routerAddress, address _initialOwner) ConfirmedOwner(_initialOwner) Billing(_routerAddress) {}

    /// @notice Initialize billing config (separate from constructor to simplify deployment ordering).
    /// @param _config Billing configuration to initialize.
    function initialize(BillingConfig memory _config) public override onlyOwner {
        super.initialize(_config);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                EXTERNAL API (CALLED BY ROUTER / NODES / VERIFIERS)
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICoordinator
    /// @dev Creates and stores a Commitment via Billing._startBilling and emits RequestStarted.
    function startRequest(
        bytes32 requestId,
        uint64 subscriptionId,
        bytes32 containerId,
        uint32 interval,
        bool useDeliveryInbox,
        address feeToken,
        uint256 feeAmount,
        address wallet,
        address verifier
    ) external override onlyRouter returns (Commitment memory) {
        Commitment memory commitment =
            _startBilling(requestId, subscriptionId, containerId, interval, useDeliveryInbox, feeToken, feeAmount, wallet, verifier);
        emit RequestStarted(requestId, subscriptionId, containerId, commitment);
        return commitment;
    }

    /// @inheritdoc ICoordinator
    /// @dev Entrypoint for nodes to submit compute outputs. Non-reentrant to protect settlement paths.
    function reportComputeResult(
        uint32 deliveryInterval,
        PayloadData calldata input,
        PayloadData calldata output,
        PayloadData calldata proof,
        bytes calldata commitmentData,
        address nodeWallet
    ) external override nonReentrant {
        _reportComputeResult(deliveryInterval, input, output, proof, commitmentData, nodeWallet, bytes32(0));
    }

    /// @inheritdoc ICoordinator
    /// @dev Cancel a pending request (router-only). Delegates to internal helper.
    function cancelRequest(bytes32 requestId) external override onlyRouter nonReentrant {
        _cancelRequest(requestId);
        emit RequestCancelled(requestId);
    }

    /// @inheritdoc ICoordinator
    /// @dev Called by verifier adapters (mocks or real) to publish verification outcome.
    function reportVerificationResult(ProofVerificationRequest memory request, bool valid) external override {
        bytes32 key = keccak256(abi.encode(request.subscriptionId, request.interval, request.submitterAddress));
        bytes32 storedHash = s_proofRequests[key];
        if (storedHash == bytes32(0) || keccak256(abi.encode(request)) != storedHash) {
            revert ProofVerificationRequestNotFound();
        }
        delete s_proofRequests[key];
        _finalizeVerification(request, valid);
        emit ProofVerified(request.subscriptionId, request.interval, request.submitterAddress, valid, msg.sender);
    }

    /// @inheritdoc ICoordinator
    /// @dev Prepare next interval for subscription if previous interval indicates a next exists.
    function prepareNextInterval(uint64 subscriptionId, uint32 nextInterval, address nodeWallet)
        external
        override
        nonReentrant
    {
        if (_getRouter().hasSubscriptionNextInterval(subscriptionId, nextInterval - 1) == false) {
            revert NoNextInterval();
        }
        uint32 currentInterval = _getRouter().getComputeSubscriptionInterval(subscriptionId);
        if (currentInterval != nextInterval - 1 && currentInterval != nextInterval) {
            revert NotReadyForNextInterval();
        }
        _prepareNextInterval(subscriptionId, nextInterval, nodeWallet);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Reconstructs and returns the Commitment for a given request.
     * @dev This function is useful for on-chain services or other contracts that need to
     *      retrieve the full commitment data using only the requestId.
     * @param subscriptionId The ID of the subscription associated with the request.
     * @param interval The interval of the request.
     * @return A memory-resident Commitment struct.
     */
    function getCommitment(uint64 subscriptionId, uint32 interval) public view override returns (Commitment memory) {
        ComputeSubscription memory sub = _getRouter().getComputeSubscription(subscriptionId);
        uint256 verifierFee = 0;
        if (sub.verifier != address(0)) {
            (, verifierFee) = IVerifier(sub.verifier).getTokenFeeInfo(sub.feeToken);
        }
        return CommitmentUtils.build(sub, subscriptionId, interval, address(this), verifierFee);
    }

    /**
     * @notice Returns the commitment hash for a given request ID.
     * @param requestId The unique identifier of the request.
     * @return The keccak256 hash of the commitment struct.
     */
    function requestCommitments(bytes32 requestId) external view override returns (bytes32) {
        return s_requestCommitments[requestId];
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  INTERNAL HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Internal: prepare the next interval by sending a request via Router and calculating fees.
    function _prepareNextInterval(uint64 subscriptionId, uint32 nextInterval, address nodeWallet) internal {
        // instruct router to create/send the request for the next interval
        (bytes32 requestId, Commitment memory commitment) = _getRouter().sendRequest(subscriptionId, nextInterval);
        delete requestId;
        delete commitment;
        _calculateNextTickFee(subscriptionId, nodeWallet);
    }

    /// @dev Internal: core logic for processing a compute delivery from a node.
    ///      Validates interval, wallet, checks commitment exists (prevents duplicate), then processes delivery.
    function _reportComputeResult(
        uint32 deliveryInterval,
        PayloadData calldata input,
        PayloadData calldata output,
        PayloadData calldata proof,
        bytes memory commitmentData,
        address nodeWallet,
        bytes32 delegatedSubHash
    ) internal {
        // decode commitment supplied by caller (router produced this when request was started)
        Commitment memory commitment = abi.decode(commitmentData, (Commitment));

        // Compute commitmentHash once here to avoid duplicate computation in _processDelivery
        bytes32 commitmentHash = keccak256(commitmentData);
        // Check commitment exists - this also prevents duplicate responses since commitment is deleted after processing
        if (s_requestCommitments[commitment.requestId] != commitmentHash) {
            revert InvalidCommitment();
        }
        // gas optimization: combined interval fetch + wallet validation reduces external calls from 2 to 1
        // saves ~45k gas on Arbitrum Nitro v3.9+ (Multi-Constraint Pricing)
        address[] memory walletsToValidate = new address[](2);
        walletsToValidate[0] = nodeWallet;
        walletsToValidate[1] = commitment.walletAddress;
        (uint32 interval, bool walletsValid) =
            _getRouter().getIntervalAndValidateWallets(commitment.subscriptionId, walletsToValidate);
        // Verify the delivery interval. For recurring subscriptions, it must match the current calculated interval.
        // For transient subscriptions (`interval` is `type(uint32).max`), it must match the interval stored in the commitment.
        if (
            (interval != type(uint32).max && interval != deliveryInterval)
                || (interval == type(uint32).max && commitment.interval != deliveryInterval)
        ) {
            revert IntervalMismatch(deliveryInterval);
        }
        // validate the nodeWallet and consumer wallet are recognized wallets produced by the WalletFactory
        if (!walletsValid) {
            revert InvalidWallet();
        }
        // Single delivery: process and cleanup
        _processDelivery(commitment, commitmentHash, msg.sender, nodeWallet, input, output, proof, delegatedSubHash);
        emit ComputeDelivered(commitment.requestId, nodeWallet, input.contentHash, output.contentHash, proof.contentHash);
    }

    /// @dev ConfirmedOwner abstract hook (required override).
    function _onlyOwner() internal view override {
        _validateOwnership();
    }

    /// @dev Cleanup request state after fulfillment. Simply delegates to parent.
    function _cleanupRequestState(bytes32 requestId, uint64 subscriptionId, uint32 interval, address proofSubmitter)
        internal
        override
    {
        super._cleanupRequestState(requestId, subscriptionId, interval, proofSubmitter);
    }

    /*//////////////////////////////////////////////////////////////
                           UTILITY CONTRACTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the address of the SubscriptionBatchReader contract.
    /// @dev Can only be called by the owner.
    /// @param _reader The address of the deployed SubscriptionBatchReader.
    function setSubscriptionBatchReader(address _reader) external onlyOwner {
        require(_reader != address(0), "Coordinator: Invalid reader address");
        subscriptionBatchReader = _reader;
    }

    /// @notice Gets the address of the SubscriptionBatchReader contract.
    /// @return The address of the reader contract.
    function getSubscriptionBatchReader() external view returns (address) {
        return subscriptionBatchReader;
    }
}
