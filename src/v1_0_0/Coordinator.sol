// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {ConfirmedOwner} from "./utility/ConfirmedOwner.sol";
import {BillingConfig} from "./types/BillingConfig.sol";
import {Billing} from "./Billing.sol";
import {Commitment} from "./types/Commitment.sol";
import {ICoordinator} from "./interfaces/ICoordinator.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ComputeSubscription} from "./types/ComputeSubscription.sol";
import {CommitmentUtils} from "./utility/CommitmentUtils.sol";
import {ProofVerificationRequest} from "./types/ProofVerificationRequest.sol";

/// @title Coordinator
/// @notice Orchestrates request lifecycle: start -> deliver -> verify -> settlement.
/// @dev This is a straightforward coordinator example used in tests — production-grade logic
///      (node selection, slashing, bonding, advanced settlement) is out of scope.
contract Coordinator is ICoordinator, Billing, ReentrancyGuard, ConfirmedOwner {
    // ---------- TYPE & VERSION ----------
    // solhint-disable-next-line const-name-snakecase
    string public constant override typeAndVersion = "Coordinator_v1.0.0";

    /*//////////////////////////////////////////////////////////////////////////
                                     STORAGE
    //////////////////////////////////////////////////////////////////////////*/
    /// @notice Address of the SubscriptionBatchReader utility contract.
    address private subscriptionBatchReader;

    /// @notice Counts redundant deliveries for a request: key = keccak256(requestId)
    mapping(bytes32 => uint16) public redundancyCount;

    /// @notice Tracks whether a node has already responded for a given subscription/interval.
    /// key = keccak256(subscriptionId, interval, nodeAddress)
    mapping(bytes32 => bool) public nodeResponded;

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
        uint16 redundancy,
        bool useDeliveryInbox,
        address feeToken,
        uint256 feeAmount,
        address wallet,
        address verifier
    ) external override onlyRouter returns (Commitment memory) {
        Commitment memory commitment = _startBilling(
            requestId,
            subscriptionId,
            containerId,
            interval,
            redundancy,
            useDeliveryInbox,
            feeToken,
            feeAmount,
            wallet,
            verifier
        );

        emit RequestStarted(requestId, subscriptionId, containerId, commitment);
        return commitment;
    }

    /// @inheritdoc ICoordinator
    /// @dev Entrypoint for nodes to submit compute outputs. Non-reentrant to protect settlement paths.
    function reportComputeResult(
        uint32 deliveryInterval,
        bytes memory input,
        bytes memory output,
        bytes memory proof,
        bytes memory commitmentData,
        address nodeWallet
    ) external override nonReentrant {
        _reportComputeResult(deliveryInterval, input, output, proof, commitmentData, nodeWallet);
    }

    /// @inheritdoc ICoordinator
    /// @dev Cancel a pending request (router-only). Delegates to internal helper.
    function cancelRequest(bytes32 requestId) external override onlyRouter {
        _cancelRequest(requestId);
        emit RequestCancelled(requestId);
    }

    /// @inheritdoc ICoordinator
    /// @dev Called by verifier adapters (mocks or real) to publish verification outcome.
    function reportVerificationResult(uint64 subscriptionId, uint32 interval, address node, bool valid)
        external
        override
    {
        // Lookup the proof request entry keyed by (subscriptionId, interval, node)
        bytes32 key = keccak256(abi.encode(subscriptionId, interval, node));
        ProofVerificationRequest memory request = proofRequests[key];

        // Remove the stored request to avoid replay
        delete proofRequests[key];

        // If no request existed (expiry == 0), treat as error
        if (request.expiry == 0) {
            revert ProofVerificationRequestNotFound();
        }

        // finalize verification (internal handles settlement/state update)
        _finalizeVerification(request, valid);

        // emit a high-level event for observability
        emit ProofVerified(subscriptionId, interval, node, valid, msg.sender);
    }

    /// @inheritdoc ICoordinator
    /// @dev Prepare next interval for subscription if previous interval indicates a next exists.
    function prepareNextInterval(uint64 subscriptionId, uint32 nextInterval, address nodeWallet) external override {
        // ask router whether subscription should advance (guard)
        if (_getRouter().hasSubscriptionNextInterval(subscriptionId, nextInterval - 1) == true) {
            _prepareNextInterval(subscriptionId, nextInterval, nodeWallet);
        }
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
        return CommitmentUtils.build(sub, subscriptionId, interval, address(this));
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
    ///      Validates interval, redundancy, node wallet, deduplicates per-node responses, then processes delivery.
    function _reportComputeResult(
        uint32 deliveryInterval,
        bytes memory input,
        bytes memory output,
        bytes memory proof,
        bytes memory commitmentData,
        address nodeWallet
    ) internal {
        // decode commitment supplied by caller (router produced this when request was started)
        Commitment memory commitment = abi.decode(commitmentData, (Commitment));

        // check redundancy limit for this request: if already reached, revert
        uint16 currentRedundancy = redundancyCount[commitment.requestId];
        if (currentRedundancy >= commitment.redundancy) {
            revert IntervalCompleted();
        }

        // verify the delivery interval matches subscription's current interval
        uint32 interval = _getRouter().getComputeSubscriptionInterval(commitment.subscriptionId);
        if (interval != deliveryInterval) {
            revert IntervalMismatch(deliveryInterval);
        }

        // validate the nodeWallet is a recognized wallet produced by the WalletFactory
        if (_getRouter().isValidWallet(nodeWallet) == false) {
            revert InvalidWallet();
        }
        // prevent the same node (msg.sender) from responding twice for the same subscription/interval
        bytes32 key = keccak256(abi.encode(commitment.subscriptionId, interval, msg.sender));
        if (nodeResponded[key]) {
            revert NodeRespondedAlready();
        }
        nodeResponded[key] = true;
        // increment redundancy count (unchecked for gas; safe as it's bounded by commitment.redundancy)
        uint16 newRedundancyCount;
        unchecked {
            newRedundancyCount = currentRedundancy + 1;
        }
        redundancyCount[commitment.requestId] = newRedundancyCount;

        // delegate to delivery processing routine (handles payments/settlement/notify)
        _processDelivery(
            commitment,
            msg.sender,
            nodeWallet,
            input,
            output,
            proof,
            newRedundancyCount,
            newRedundancyCount == commitment.redundancy
        );

        // emit human-friendly event for off-chain indexing
        emit ComputeDelivered(commitment.requestId, nodeWallet, newRedundancyCount);
    }

    /// @dev ConfirmedOwner abstract hook (required override).
    function _onlyOwner() internal view override {
        _validateOwnership();
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
