// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {BillingConfig} from "./types/BillingConfig.sol";
import {Billing} from "./Billing.sol";
import {Commitment} from "./types/Commitment.sol";
import {ICoordinator} from "./interfaces/ICoordinator.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IWalletFactory} from "./wallet/IWalletFactory.sol";

/**
 * @title Coordinator
 * @notice A default implementation of the ICoordinator interface. This contract orchestrates
 * the lifecycle of computation requests between the Router and off-chain nodes.
 * @dev This implementation is a basic example. Production coordinators may have more
 * complex logic for node selection, payment distribution, and verification handling.
 */
contract Coordinator is ICoordinator, Ownable, Billing, ReentrancyGuard {

    // solhint-disable-next-line const-name-snakecase
    string public constant override typeAndVersion = "Coordinator_v1.0.0";
    /// @dev Tracks the number of redundant deliveries for an interval. key: keccak256(subId, interval)
    mapping(bytes32 => uint16) public redundancyCount;

    /// @dev Tracks if a node has already responded for an interval. key: keccak256(subId, interval, node)
    mapping(bytes32 => bool) public nodeResponded;

    /// @notice Emitted when a node delivers a computation result.
    event ComputeDelivered(bytes32 indexed requestId, address nodeWallet);

    /// @notice Emitted when a new request is started and a commitment is created.
    event RequestStarted(
        uint64 indexed subscriptionId,
        bytes32 indexed requestId,
        bytes32 indexed containerId,
        Commitment commitment
    );

    error SubscriptionNotFound();
    error SubscriptionNotActive();
    error IntervalMismatch();
    error SubscriptionCompleted();
    error IntervalCompleted();
    error NodeRespondedAlready();
    error InvalidWallet();

    /**
     * @param _routerAddress The address of the main Router contract.
     * @param _initialOwner The initial owner of this Coordinator.
     * @param _config The initial billing configuration.
     */
    constructor(
        address _routerAddress,
        address _initialOwner,
        BillingConfig memory _config
    ) Ownable(_initialOwner) Billing(_routerAddress, _config) {

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
        address verifier
    ) external override onlyRouter returns (Commitment memory) {
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
        address nodeWallet
    ) external override nonReentrant {
        Commitment memory commitment = abi.decode(commitmentData, (Commitment));
        uint32 interval = _getRouter().getSubscriptionInterval(commitment.subscriptionId);
        if (interval != deliveryInterval) {
            revert IntervalMismatch();
        }
        // Revert if redundancy requirements for this interval have been met
        uint16 numRedundantDeliveries = redundancyCount[commitment.requestId];
        if (numRedundantDeliveries == commitment.redundancy) {
            revert IntervalCompleted();
        }

        unchecked {
            redundancyCount[commitment.requestId] = numRedundantDeliveries + 1;
        }
        _processDelivery(
            commitment,
            msg.sender,
            nodeWallet,
            input,
            output,
            proof,
            0,
            numRedundantDeliveries == commitment.redundancy - 1
        );

        emit ComputeDelivered(commitment.requestId, nodeWallet);
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
    function finalizeProofVerification(uint64 subscriptionId, uint32 interval, address node, bool valid) external override {
        revert("Not implemented");
    }

    /**
     * @inheritdoc ICoordinator
     */
    function prepareNextInterval(uint64 subscriptionId, uint32 nextInterval) external override {
        revert("Not implemented");
    }
}