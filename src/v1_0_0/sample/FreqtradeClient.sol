// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import "../client/ScheduledComputeClient.sol";
import {PendingDelivery} from "../types/PendingDelivery.sol";
import {ComputeSubscription} from "../types/ComputeSubscription.sol";
import {PayloadData} from "../types/PayloadData.sol";

/**
 * @title FreqtradeClient
 * @notice This contract demonstrates scheduled compute subscriptions for cryptocurrency
 *         price predictions using a trading strategy (e.g., freqtrade-style algorithms).
 *         It runs predictions every 1 hour for 30 days (720 executions total) for BTC, ETH, and SOL.
 *         The raw output from the compute node is stored in the DeliveryInbox for off-chain processing.
 * @dev Uses ScheduledComputeClient for recurring compute tasks at fixed intervals.
 *      This version uses DeliveryInbox with the _receiveDelivery hook to track the latest request ID
 *      for each asset while storing raw output in the inbox, reducing on-chain processing gas costs.
 */
contract FreqtradeClient is ScheduledComputeClient {
    // --- Constants ---

    /// @notice Minimum interval between prediction runs (10 minutes = 600 seconds)
    uint32 public constant MIN_PREDICTION_INTERVAL = 600;

    /// @notice Maximum interval between prediction runs (24 hours = 86400 seconds)
    uint32 public constant MAX_PREDICTION_INTERVAL = 86400;

    /// @notice Maximum number of executions limit (24 times = 1 days total at 10-minute intervals)
    uint32 public constant MAX_EXECUTIONS_LIMIT = 24;

    // --- Events ---

    /// @notice Emitted when a prediction is received for an asset.
    /// @dev Stores the raw output bytes for off-chain parsing.
    event PredictionReceived(
        string indexed assetSymbol, uint64 indexed subscriptionId, uint32 interval, bytes output, uint32 timestamp
    );

    /// @notice Emitted when a new prediction subscription is created.
    event PredictionSubscriptionCreated(string assetSymbol, uint64 subscriptionId);

    /// @notice Emitted when an existing prediction subscription is cancelled during update.
    event PredictionSubscriptionCancelled(string indexed assetSymbol, uint64 indexed oldSubscriptionId, string reason);

    // --- State Variables ---

    /// @notice Maps an asset symbol to its corresponding subscription ID.
    mapping(string => uint64) public assetToSubscriptionId;

    /// @notice Maps a subscription ID back to its asset symbol for result processing.
    mapping(uint64 => string) public subscriptionIdToAsset;

    /// @notice Stores the latest request ID for each asset to easily retrieve the latest output from the DeliveryInbox.
    mapping(string => bytes32) public latestRequestIdForAsset;

    /**
     * @param router The address of the Noosphere Router contract.
     */
    constructor(address router) ScheduledComputeClient(router) {}

    /**
     * @notice Sets up a scheduled prediction subscription for a specific cryptocurrency asset.
     *         This creates a recurring compute job that runs at the specified interval.
     * @param assetSymbol The symbol of the asset (e.g., "BTC", "ETH", "SOL").
     * @param maxExecutions The number of executions (must be > 0 and <= MAX_EXECUTIONS_LIMIT).
     * @param interval The interval between predictions in seconds (must be >= MIN_PREDICTION_INTERVAL and <= MAX_PREDICTION_INTERVAL).
     * @param feeAmount The fee to be paid per computation request.
     * @param wallet The wallet address from which the fee will be paid.
     * @param verifier The verifier address for the compute request.
     * @param routeId The route ID for the compute request.
     */
    function setupAssetPrediction(
        string memory assetSymbol,
        uint32 maxExecutions,
        uint32 interval,
        uint256 feeAmount,
        address wallet,
        address verifier,
        bytes32 routeId
    ) external returns (uint64 subscriptionId) {
        require(maxExecutions > 0 && maxExecutions <= MAX_EXECUTIONS_LIMIT, "Invalid execution count");
        require(interval >= MIN_PREDICTION_INTERVAL && interval <= MAX_PREDICTION_INTERVAL, "Invalid interval");

        // Check if a subscription for this asset already exists and cancel it
        uint64 existingSubId = assetToSubscriptionId[assetSymbol];
        if (existingSubId != 0) {
            // Check if the existing subscription is still active before attempting to cancel
            ComputeSubscription memory existingSub = _getRouter().getComputeSubscription(existingSubId);

            if (existingSub.activeAt != 0) {
                // Subscription is still active, emit event before cancellation
                emit PredictionSubscriptionCancelled(assetSymbol, existingSubId, "Updating subscription settings");

                // Cancel the existing subscription
                _cancelComputeSubscription(existingSubId);
            } else {
                // Subscription is already cancelled, just emit event for tracking
                emit PredictionSubscriptionCancelled(
                    assetSymbol, existingSubId, "Cleaning up already cancelled subscription"
                );
            }

            // Clean up old mappings regardless of cancellation status
            delete subscriptionIdToAsset[existingSubId];
            delete latestRequestIdForAsset[assetSymbol];
        }

        // Create a new scheduled compute subscription
        subscriptionId = _createComputeSubscription(
            "noosphere-hello-world", // The prediction container to execute
            maxExecutions, // User-specified number of executions
            interval, // User-specified interval in seconds
            1, // Redundancy for reliability
            true, // Delivery pattern
            address(0), // feeToken (ETH)
            feeAmount, // Fee per execution
            wallet, // Payment wallet
            verifier, // Verifier address
            routeId // Route ID
        );

        // Store bidirectional mapping
        assetToSubscriptionId[assetSymbol] = subscriptionId;
        subscriptionIdToAsset[subscriptionId] = assetSymbol;

        emit PredictionSubscriptionCreated(assetSymbol, subscriptionId);

        return subscriptionId;
    }

    /**
     * @notice Starts the prediction subscription for a specific asset.
     *         This triggers the first execution and begins the scheduled interval.
     * @param assetSymbol The symbol of the asset to start predictions for.
     * @return subscriptionId The ID of the subscription.
     * @return commitment The commitment from the compute node.
     */
    function startPrediction(string memory assetSymbol) external returns (uint64, Commitment memory) {
        uint64 subscriptionId = assetToSubscriptionId[assetSymbol];
        require(subscriptionId != 0, "Prediction feed does not exist");

        // Request the first compute execution
        (uint64 subId, Commitment memory commitment) = _requestCompute(subscriptionId, bytes(assetSymbol));

        // Store the latest request ID immediately upon successful request
        latestRequestIdForAsset[assetSymbol] = commitment.requestId;

        return (subId, commitment);
    }

    /**
     * @notice Sets up and immediately starts a prediction subscription in a single transaction.
     *         This is a convenience function that combines setupAssetPrediction and startPrediction.
     * @param assetSymbol The symbol of the asset (e.g., "BTC", "ETH", "SOL").
     * @param maxExecutions The number of executions (must be > 0 and <= MAX_EXECUTIONS_LIMIT).
     * @param interval The interval between predictions in seconds (must be >= MIN_PREDICTION_INTERVAL and <= MAX_PREDICTION_INTERVAL).
     * @param feeAmount The fee to be paid per computation request.
     * @param wallet The wallet address from which the fee will be paid.
     * @param verifier The verifier address for the compute request.
     * @param routeId The route ID for the compute request.
     * @return subscriptionId The ID of the created subscription.
     * @return commitment The commitment from the first compute request.
     */
    function setupAndStartPrediction(
        string memory assetSymbol,
        uint32 maxExecutions,
        uint32 interval,
        uint256 feeAmount,
        address wallet,
        address verifier,
        bytes32 routeId
    ) external returns (uint64 subscriptionId, Commitment memory commitment) {
        require(maxExecutions > 0 && maxExecutions <= MAX_EXECUTIONS_LIMIT, "Invalid execution count");
        require(interval >= MIN_PREDICTION_INTERVAL && interval <= MAX_PREDICTION_INTERVAL, "Invalid interval");

        // Check if a subscription for this asset already exists and cancel it
        uint64 existingSubId = assetToSubscriptionId[assetSymbol];
        if (existingSubId != 0) {
            // Check if the existing subscription is still active before attempting to cancel
            ComputeSubscription memory existingSub = _getRouter().getComputeSubscription(existingSubId);

            if (existingSub.activeAt != 0) {
                // Subscription is still active, emit event before cancellation
                emit PredictionSubscriptionCancelled(assetSymbol, existingSubId, "Updating subscription settings");

                // Cancel the existing subscription
                _cancelComputeSubscription(existingSubId);
            } else {
                // Subscription is already cancelled, just emit event for tracking
                emit PredictionSubscriptionCancelled(
                    assetSymbol, existingSubId, "Cleaning up already cancelled subscription"
                );
            }

            // Clean up old mappings regardless of cancellation status
            delete subscriptionIdToAsset[existingSubId];
            delete latestRequestIdForAsset[assetSymbol];
        }

        // Create the subscription
        subscriptionId = _createComputeSubscription(
            "noosphere-hello-world", maxExecutions, interval, 1, true, address(0), feeAmount, wallet, verifier, routeId
        );

        // Store bidirectional mapping
        assetToSubscriptionId[assetSymbol] = subscriptionId;
        subscriptionIdToAsset[subscriptionId] = assetSymbol;

        emit PredictionSubscriptionCreated(assetSymbol, subscriptionId);

        // Immediately start the prediction
        (, commitment) = _requestCompute(subscriptionId, bytes(assetSymbol));

        // Store the latest request ID
        latestRequestIdForAsset[assetSymbol] = commitment.requestId;

        return (subscriptionId, commitment);
    }

    /**
     * @notice Internal hook called when a delivery is received via DeliveryInbox.
     *         This function tracks the latest request ID for each asset and emits events.
     *         It also cleans up old deliveries to save storage costs.
     * @param requestId The request ID for this delivery.
     * @param subscriptionId The ID of the subscription that produced the result.
     * @param interval The execution interval number.
     * @param output PayloadData for output (contentHash + uri).
     */
    function _receiveDelivery(
        bytes32 requestId,
        address,
        /* node */
        uint64 subscriptionId,
        uint32 interval,
        PayloadData calldata,
        /* input */
        PayloadData calldata output,
        PayloadData calldata /* proof */
    ) internal override {
        // Identify which asset this prediction is for
        string memory assetSymbol = subscriptionIdToAsset[subscriptionId];

        // Ignore unknown subscriptions
        if (bytes(assetSymbol).length == 0) {
            return;
        }

        // Clean up old delivery to save storage costs
        bytes32 oldRequestId = latestRequestIdForAsset[assetSymbol];
        if (oldRequestId != bytes32(0) && oldRequestId != requestId) {
            _clearAllForRequest(oldRequestId);
        }

        // Update the latest request ID for this asset to track the most recent delivery
        latestRequestIdForAsset[assetSymbol] = requestId;

        // Emit an event with the output contentHash for off-chain listeners
        emit PredictionReceived(assetSymbol, subscriptionId, interval, abi.encode(output), uint32(block.timestamp));
    }

    /**
     * @notice Cancels a prediction subscription for an asset.
     * @param assetSymbol The symbol of the asset to cancel predictions for.
     */
    function cancelPrediction(string memory assetSymbol) external {
        uint64 subscriptionId = assetToSubscriptionId[assetSymbol];
        require(subscriptionId != 0, "Prediction feed does not exist");

        _cancelComputeSubscription(subscriptionId);

        // Clean up mappings
        delete subscriptionIdToAsset[subscriptionId];
        delete assetToSubscriptionId[assetSymbol];
        delete latestRequestIdForAsset[assetSymbol];
    }

    /**
     * @notice Retrieves the latest prediction output for a given asset from the DeliveryInbox.
     * @dev This is a helper for DApps. It finds the latest request ID and returns the output from the first
     *      node that delivered a result for that request.
     * @param assetSymbol The symbol of the asset (e.g., "BTC").
     * @return output The PayloadData for output (contentHash + uri) from the compute node.
     * @return timestamp The timestamp of the delivery.
     */
    function getLatestPredictionOutput(string memory assetSymbol)
        public
        view
        returns (PayloadData memory output, uint32 timestamp)
    {
        bytes32 requestId = latestRequestIdForAsset[assetSymbol];
        if (requestId == bytes32(0)) {
            return (output, 0);
        }

        // Get the list of nodes that submitted a delivery for this request
        address[] memory nodes = getNodesForRequest(requestId);
        if (nodes.length > 0) {
            // Return the delivery from the first node in the list
            // A more complex implementation could iterate or select a specific node
            (bool exists, PendingDelivery memory pd) = getDelivery(requestId, nodes[0]);
            if (exists) {
                return (pd.output, pd.timestamp);
            }
        }

        return (output, 0);
    }

    /**
     * @notice Returns the address of the Noosphere Router this client is connected to.
     */
    function getRouter() external view returns (address) {
        return address(_getRouter());
    }

    /**
     * @notice Returns the contract type and version.
     */
    function typeAndVersion() external pure override returns (string memory) {
        return "FreqtradeClient_v1.1.0_RawOutput";
    }
}
