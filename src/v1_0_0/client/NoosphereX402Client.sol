// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {TransientComputeClient} from "./TransientComputeClient.sol";
import {Commitment} from "../types/Commitment.sol";
import {PayloadData} from "../types/PayloadData.sol";

/**
 * @title NoosphereX402Client
 * @notice A TransientComputeClient subclass purpose-built for x402 payment gateways.
 *
 * @dev Only the designated Operator EOA may create subscriptions or dispatch
 *      compute requests. Every dispatch records the x402 payer and the
 *      off-chain jobId as indexed events, so the pair (payer, jobId) can be
 *      recovered from chain logs alone — enabling audit, dispute resolution
 *      and off-chain correlation without any additional on-chain storage.
 *
 *      The generic entry points inherited from `ComputeClient`
 *      (`createComputeSubscription`, `sendRequest`) are disabled to prevent
 *      anonymous callers from creating subscriptions under this client's
 *      ownership or triggering Router charges against the Operator Wallet.
 */
contract NoosphereX402Client is TransientComputeClient {
    /*//////////////////////////////////////////////////////////////
                                  STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice EOA authorized to create subscriptions and dispatch requests.
    address public operator;

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the operator EOA is rotated.
    event OperatorUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when a paid compute request is dispatched on behalf of an x402 payer.
    /// @param subscriptionId Subscription routing this request.
    /// @param interval Interval/nonce assigned to this request within the subscription.
    /// @param payer x402 end-user that signed the EIP-3009 authorization.
    /// @param jobId Off-chain correlation id (uuid v4 encoded as bytes32).
    /// @param paidAmount USDC.e amount (smallest units) charged to the payer via x402.
    /// @param timestamp Block timestamp of dispatch.
    event X402Dispatched(
        uint64 indexed subscriptionId,
        uint32 indexed interval,
        address indexed payer,
        bytes32 jobId,
        uint96 paidAmount,
        uint64 timestamp
    );

    /// @notice Emitted when a compute result is delivered for a paid request.
    /// @dev The payer/jobId are resolved off-chain by joining on (subscriptionId, interval)
    ///      with the corresponding X402Dispatched event.
    event X402Delivered(
        uint64 indexed subscriptionId, uint32 indexed interval, address node, bytes32 outputHash, bytes outputUri
    );

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotOperator();
    error ZeroOperator();
    error DisabledUseDispatchPaidCompute();
    error DisabledUseCreateSubscription();

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param router Noosphere Router address.
    /// @param _operator EOA authorized to manage this client.
    constructor(address router, address _operator) TransientComputeClient(router) {
        if (_operator == address(0)) revert ZeroOperator();
        operator = _operator;
        emit OperatorUpdated(address(0), _operator);
    }

    /*//////////////////////////////////////////////////////////////
                           OPERATOR-ONLY ENTRY POINTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a transient subscription for a paid service (e.g., "hello-world", "llm-inference").
    /// @dev Delegates to the parent's internal `_createComputeSubscription` (transient semantics).
    function createSubscription(
        string memory containerId,
        bool useDeliveryInbox,
        address feeToken,
        uint256 feeAmount,
        address wallet,
        address verifier,
        bytes32 routeId
    ) external onlyOperator returns (uint64) {
        return _createComputeSubscription(containerId, useDeliveryInbox, feeToken, feeAmount, wallet, verifier, routeId);
    }

    /// @notice Dispatch a paid compute request bound to an x402 payment.
    /// @param subscriptionId Pre-existing subscription for the target service.
    /// @param inputs Compute inputs (RAW_DATA; stored on-chain via TransientComputeClient).
    /// @param payer x402 end-user EOA (recovered from the X-PAYMENT signature).
    /// @param jobId Resource Server's off-chain correlation id.
    /// @param paidAmount USDC.e amount (smallest units) settled via x402.
    function dispatchPaidCompute(
        uint64 subscriptionId,
        bytes memory inputs,
        address payer,
        bytes32 jobId,
        uint96 paidAmount
    ) external onlyOperator returns (uint64, Commitment memory commitment) {
        (uint64 sid, Commitment memory c) = _requestCompute(subscriptionId, inputs);
        commitment = c;

        emit X402Dispatched(subscriptionId, c.interval, payer, jobId, paidAmount, uint64(block.timestamp));

        return (sid, c);
    }

    /// @notice Cancel an existing subscription.
    function cancelSubscription(uint64 subscriptionId) external onlyOperator {
        _cancelComputeSubscription(subscriptionId);
    }

    /// @notice Rotate the operator EOA (key rotation / hand-off).
    function updateOperator(address newOperator) external onlyOperator {
        if (newOperator == address(0)) revert ZeroOperator();
        address prev = operator;
        operator = newOperator;
        emit OperatorUpdated(prev, newOperator);
    }

    /*//////////////////////////////////////////////////////////////
                        DISABLED PARENT ENTRY POINTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Inherited from ComputeClient; disabled to force callers to use
    ///      `createSubscription(...)` with operator-only access control.
    function createComputeSubscription(string memory, uint32, uint32, bool, address, uint256, address, address, bytes32)
        external
        pure
        override
        returns (uint64)
    {
        revert DisabledUseCreateSubscription();
    }

    /// @dev Inherited from ComputeClient; disabled to prevent callers from
    ///      charging the Operator Wallet via direct Router calls without
    ///      x402 payment context.
    function sendRequest(uint64, uint32) external pure override returns (bytes32, Commitment memory) {
        revert DisabledUseDispatchPaidCompute();
    }

    /*//////////////////////////////////////////////////////////////
                            CALLBACK OVERRIDE
    //////////////////////////////////////////////////////////////*/

    /// @dev Coordinator callback. Emits an x402-flavoured event; the payer/jobId
    ///      linkage is established off-chain via the earlier X402Dispatched event.
    function _receiveCompute(
        uint64 subscriptionId,
        uint32 interval,
        bool, /* useDeliveryInbox */
        address node,
        PayloadData calldata, /* input */
        PayloadData calldata output,
        PayloadData calldata, /* proof */
        bytes32 /* containerId */
    ) internal override {
        emit X402Delivered(subscriptionId, interval, node, output.contentHash, output.uri);
    }

    /*//////////////////////////////////////////////////////////////
                            TYPE & VERSION
    //////////////////////////////////////////////////////////////*/

    function typeAndVersion() external pure override returns (string memory) {
        return "NoosphereX402Client_v0.1.0";
    }
}
