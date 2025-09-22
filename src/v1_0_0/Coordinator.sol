// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import "./utility/ConfirmedOwner.sol";
import {BillingConfig} from "./types/BillingConfig.sol";
import {Billing} from "./Billing.sol";
import {Commitment} from "./types/Commitment.sol";
import {ICoordinator} from "./interfaces/ICoordinator.sol";
import {IWalletFactory} from "./wallet/IWalletFactory.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Coordinator
 * @notice A default implementation of the ICoordinator interface. This contract orchestrates
 * the lifecycle of computation requests between the Router and off-chain nodes.
 * @dev This implementation is a basic example. Production coordinators may have more
 * complex logic for node selection, payment distribution, and verification handling.
 */
contract Coordinator is ICoordinator, Billing, ReentrancyGuard, ConfirmedOwner {
    // solhint-disable-next-line const-name-snakecase
    string public constant override typeAndVersion = "Coordinator_v1.0.0";
    /// @dev Tracks the number of redundant deliveries for an interval. key: keccak256(subId, interval)
    mapping(bytes32 => uint16) public redundancyCount;

    /// @dev Tracks if a node has already responded for an interval. key: keccak256(subId, interval, node)
    mapping(bytes32 => bool) public nodeResponded;

    /// @notice Emitted when a node delivers a computation result.
    event ComputeDelivered(bytes32 indexed requestId, address nodeWallet, uint16 numRedundantDeliveries);

    /// @notice Emitted when a new request is started and a commitment is created.
    event RequestStarted(
        uint64 indexed subscriptionId,
        bytes32 indexed requestId,
        bytes32 indexed containerId,
        Commitment commitment
    );
    error IntervalMismatch(uint32 deliveryInterval);
    error RequestCompleted(bytes32 requestId);
    error IntervalCompleted();
    error NodeRespondedAlready();
    error InvalidWallet();

    /**
     * @param _routerAddress The address of the main Router contract.
     * @param _initialOwner The initial owner of this Coordinator.
     */
    constructor(address _routerAddress, address _initialOwner) ConfirmedOwner(_initialOwner) Billing(_routerAddress) {}

    /**
     * @notice Initializes the Coordinator with its billing configuration.
     * @dev This is separate from the constructor to avoid owner-related issues during deployment.
     */
    function initialize(BillingConfig memory _config) public override onlyOwner {
        super.initialize(_config);
    }

    /**
     * @inheritdoc ICoordinator
     */
    function startRequest(
        bytes32 requestId,
        uint64 subscriptionId,
        bytes32 containerId,
        uint32 interval,
        uint16 redundancy,
        bool lazy,
        address paymentToken,
        uint256 paymentAmount,
        address wallet,
        address verifier) external override onlyRouter returns (Commitment memory) {
        Commitment memory commitment = _startBilling(
            requestId,
            subscriptionId,
            containerId,
            interval,
            redundancy,
            lazy,
            paymentToken,
            paymentAmount,
            wallet,
            verifier
        );
        emit RequestStarted(subscriptionId, requestId, containerId, commitment);
        return commitment;
    }

    /**
     * @inheritdoc ICoordinator
     */
    function deliverCompute(
        uint32 deliveryInterval,
        bytes memory input,
        bytes memory output,
        bytes memory proof,
        bytes memory commitmentData,
        address nodeWallet) external override nonReentrant {
        _deliverCompute(deliveryInterval, input, output, proof, commitmentData, nodeWallet);
    }

    /**
     * @inheritdoc ICoordinator
     */
    function cancelRequest(bytes32 requestId) external override onlyRouter {
        _cancelRequest(requestId);
    }

    /**
     * @inheritdoc ICoordinator
     */
    function finalizeProofVerification(
        uint64 subscriptionId,
        uint32 interval,
        address node,
        bool valid
    ) external override {
        revert("Not implemented");
    }

    /**
     * @inheritdoc ICoordinator
     */
    function prepareNextInterval(uint64 subscriptionId, uint32 nextInterval, address nodeWallet) external override {
        if (_getRouter().hasSubscriptionNextInterval(subscriptionId, nextInterval - 1) == true) {
            _prepareNextInterval(subscriptionId, nextInterval, nodeWallet);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function _prepareNextInterval(uint64 subscriptionId, uint32 nextInterval, address nodeWallet) internal {
        _getRouter().sendRequest(subscriptionId, nextInterval);
        _calculateNextTickFee(subscriptionId, nextInterval, nodeWallet);
    }

    function _onlyOwner() internal view override {
        _validateOwnership();
    }

    function _deliverCompute(
        uint32 deliveryInterval,
        bytes memory input,
        bytes memory output,
        bytes memory proof,
        bytes memory commitmentData,
        address nodeWallet) internal {
        Commitment memory commitment = abi.decode(commitmentData, (Commitment));
        uint32 interval = _getRouter().getSubscriptionInterval(commitment.subscriptionId);
        if (interval != deliveryInterval) {
            revert IntervalMismatch(deliveryInterval);
        }
        // Revert if redundancy requirements for this interval have been met
        uint16 numRedundantDeliveries = redundancyCount[commitment.requestId];
        if (numRedundantDeliveries == commitment.redundancy) {
            revert IntervalCompleted();
        }
        if (_getRouter().isValidWallet(nodeWallet) == false) {
            revert InvalidWallet();
        }
        unchecked {
            redundancyCount[commitment.requestId] = numRedundantDeliveries + 1;
        }

        bytes32 key = keccak256(abi.encode(commitment.subscriptionId, interval, msg.sender));
        if (nodeResponded[key]) {
            revert NodeRespondedAlready();
        }
        nodeResponded[key] = true;

        _processDelivery(
            commitment,
            msg.sender,
            nodeWallet,
            input,
            output,
            proof,
            redundancyCount[commitment.requestId],
            numRedundantDeliveries == commitment.redundancy - 1
        );

        emit ComputeDelivered(commitment.requestId, nodeWallet, redundancyCount[commitment.requestId]);
    }
}