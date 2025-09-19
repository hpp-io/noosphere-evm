// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Routable} from "./Routable.sol";
import {IBilling} from "./interfaces/IBilling.sol";
import {IRouter} from "./interfaces/IRouter.sol";
import {BillingConfig} from "./types/BillingConfig.sol";
import {Commitment} from "./types/Commitment.sol";
import {Payment} from "./types/Payment.sol";
import {IVerifier} from "./interfaces/IVerifier.sol";
import {ProofVerificationRequest} from "./types/ProofVerificationRequest.sol";

/// @title Billing
/// @notice An abstract contract that provides the core logic for billing, fee calculation,
/// and commitment management within the protocol.
/// @dev This contract is intended to be inherited by a concrete implementation like Coordinator.
abstract contract Billing is IBilling, Routable {
    /// @notice The current billing configuration.
    BillingConfig private billingConfig;

    /// @notice A mapping from a request's unique identifier to its commitment hash.
    /// @dev The key is typically keccak256(abi.encodePacked(subscriptionId, interval)).
    mapping(bytes32 => bytes32) public requestCommitments;

    error InvalidRequestCommitment(bytes32 requestId);
    error ProtocolFeeExceeds();
    error UnsupportedVerifierToken(address token);
    error InsufficientForVerifierFee();

    /// @param _router The address of the router contract.
    constructor(
        address _router
    ) Routable(_router) {}

    function initialize(BillingConfig memory _initialConfig) public virtual {
        _onlyOwner();
        _updateConfig(_initialConfig);
    }

    /*//////////////////////////////////////////////////////////////
                        IBilling IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBilling
    function getConfig() external view override returns (BillingConfig memory) {
        return billingConfig;
    }

    /// @inheritdoc IBilling
    function updateConfig(BillingConfig memory config) external virtual override {
        // In a concrete implementation, this should have access control (e.g., onlyOwner).
        _updateConfig(config);
    }

    /// @inheritdoc IBilling
    function getProtocolFee() external view override returns (uint72) {
        // The protocol fee is stored as uint256 for flexibility but returned as uint72.
        // Ensure the configured value does not exceed the uint72 range.
        uint256 fee = billingConfig.protocolFee;
        if (fee > type(uint72).max) {
            revert ProtocolFeeExceeds();
        }
        return uint72(fee);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL BILLING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Internal function to update the configuration, allowing for access control in child contracts.
    function _updateConfig(BillingConfig memory newConfig) internal virtual {
        _onlyOwner();
        billingConfig = newConfig;
    }

    /// @notice Calculates a fee based on a percentage in basis points.
    /// @param amount The base amount from which the fee is calculated.
    /// @param feeBps The fee in basis points (e.g., 100 for 1%).
    /// @return The calculated fee amount.
    function _calculateFee(uint256 amount, uint256 feeBps) internal pure virtual returns (uint256) {
        return (amount * feeBps) / 10000;
    }

    /// @notice Initiates the billing process for a new request.
    /// @return commitment A Commitment struct to be stored and verified upon fulfillment.
    function _startBilling(
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
    ) internal virtual returns (Commitment memory) {
        uint256 verifierFee = 0;
        if (verifier != address(0)) {
            IVerifier verifierContract = IVerifier(verifier);
            if (verifierContract.isSupportedToken(paymentToken) == false) {
                revert UnsupportedVerifierToken(paymentToken);
            }
            verifierFee = verifierContract.fee(paymentToken);
            if (paymentAmount < verifierFee) {
                revert InsufficientForVerifierFee();
            }
        }

        Commitment memory commitment = Commitment({
            requestId: requestId,
            subscriptionId: subscriptionId,
            containerId: containerId,
            interval: interval,
            redundancy: redundancy,
            lazy: lazy,
            walletAddress: wallet,
            paymentAmount: paymentAmount,
            paymentToken: paymentToken,
            verifier: verifier, // Use the address of the verifier
            coordinator: address(this)
        });
        requestCommitments[requestId] = keccak256(abi.encode(commitment));
        return commitment;
    }

    /// @notice Processes a computation delivery, calculating fees and orchestrating fulfillment and/or verification.
    /// @dev This is the main entry point for billing logic from the Coordinator.
    function _processDelivery(
        Commitment memory commitment,
        address proofSubmitter,
        address nodeWallet,
        bytes memory input,
        bytes memory output,
        bytes memory proof,
        uint16 numRedundantDeliveries,
        bool isLastDelivery
    ) internal virtual {
        bytes32 storedHash = requestCommitments[commitment.requestId];
        if (storedHash == bytes32(0)) {
            revert InvalidRequestCommitment(commitment.requestId);
        }
        if (keccak256(abi.encode(commitment)) != storedHash) {
            revert InvalidRequestCommitment(commitment.requestId);
        }

        if (commitment.verifier != address(0)) {
            _processVerifiedDelivery(commitment, proofSubmitter, nodeWallet, input, output, proof, numRedundantDeliveries);
        } else {
            _processStandardDelivery(commitment, nodeWallet, input, output, proof, numRedundantDeliveries);
        }

        if (isLastDelivery == true) {
            delete requestCommitments[commitment.requestId];
        }
    }

    /// @dev Private helper to handle the logic for a delivery that requires verification.
    function _processVerifiedDelivery(
        Commitment memory commitment,
        address proofSubmitter,
        address nodeWallet,
        bytes memory input,
        bytes memory output,
        bytes memory proof,
        uint16 numRedundantDeliveries
    ) private {
        Payment[] memory payments = _prepareVerificationPayments(commitment);
        _initiateVerification(commitment, proofSubmitter, nodeWallet, proof);
        _getRouter().fulfill(input, output, proof, numRedundantDeliveries, nodeWallet,payments, commitment);
    }

    /// @dev Private helper to handle the logic for a standard, non-verified delivery.
    function _processStandardDelivery(
        Commitment memory commitment,
        address nodeWallet,
        bytes memory input,
        bytes memory output,
        bytes memory proof,
        uint16 numRedundantDeliveries
    ) private {
        Payment[] memory payments = _prepareStandardPayments(commitment, nodeWallet);
        _getRouter().fulfill(input, output, proof, numRedundantDeliveries, nodeWallet, payments, commitment);
    }

    /// @dev Prepares the payment array for a standard, non-verified fulfillment.
    function _prepareStandardPayments(
        Commitment memory commitment,
        address nodeWallet
    ) internal view virtual returns (Payment[] memory) {
        uint256 paymentAmount = commitment.paymentAmount;

        // The original logic applies the fee twice, representing a fee on both
        // the consumer and the node from the total payment amount.
        uint256 paidToProtocol = _calculateFee(paymentAmount, billingConfig.protocolFee * 2);
        uint256 paidToNode = paymentAmount - paidToProtocol;

        Payment[] memory payments = new Payment[](2);
        payments[0] = Payment(billingConfig.protocolFeeRecipient, commitment.paymentToken, paidToProtocol);
        payments[1] = Payment(nodeWallet, commitment.paymentToken, paidToNode);

        return payments;
    }

    /// @dev Prepares the immediate payment array for a verified fulfillment (pays protocol and verifier).
    function _prepareVerificationPayments(Commitment memory commitment) internal view virtual returns (Payment[] memory) {
        uint256 tokenAvailable = commitment.paymentAmount;

        IVerifier verifier = IVerifier(commitment.verifier);
        if (!verifier.isSupportedToken(commitment.paymentToken)) {
            revert UnsupportedVerifierToken(commitment.paymentToken);
        }

        uint256 baseProtocolFee = _calculateFee(tokenAvailable, billingConfig.protocolFee);
        tokenAvailable -= baseProtocolFee;

        uint256 verifierFee = verifier.fee(commitment.paymentToken);
        if (tokenAvailable < verifierFee) {
            revert InsufficientForVerifierFee();
        }

        uint256 verifierProtocolFee = _calculateFee(verifierFee, billingConfig.protocolFee);

        Payment[] memory immediatePayments = new Payment[](3);
        immediatePayments[0] = Payment(billingConfig.protocolFeeRecipient, commitment.paymentToken, baseProtocolFee + verifierProtocolFee);
        immediatePayments[1] = Payment(verifier.getWallet(), commitment.paymentToken, verifierFee - verifierProtocolFee);
        return immediatePayments;
    }

    /// @dev Handles post-fulfillment steps for verification (locking funds, calling verifier).
    function _initiateVerification(
        Commitment memory commitment,
        address proofSubmitter,
        address submitterWallet,
        bytes memory proof
    ) internal virtual {
        ProofVerificationRequest memory verificationRequest = ProofVerificationRequest({
            requestId: commitment.requestId,
            submitterAddress: proofSubmitter,
            submitterWallet: submitterWallet,
            expiry: uint32(block.timestamp + 1 weeks), // Example expiry
            escrowedAmount: commitment.paymentAmount, // Slashable amount
            escrowToken: commitment.paymentToken
        });
        _getRouter().lockForVerification(verificationRequest, commitment);

        // Initiate verifier verification
        IVerifier(commitment.verifier).requestProofVerification(
            commitment.subscriptionId, commitment.interval, proofSubmitter, proof
        );
    }

    /// @notice Calculates the fee for a node that triggers the next interval.
    function _calculateNextTickFee(
        uint64 subscriptionId,
        uint32 nextInterval,
        address nodeWallet
    ) internal virtual {
        Payment[] memory payments = new Payment[](1);
        if (billingConfig.tickNodeFee > 0) {
            payments[0] = Payment(nodeWallet, billingConfig.tickNodeFeeToken, billingConfig.tickNodeFee);
        }
        _getRouter().payFromCoordinator(subscriptionId, nextInterval, billingConfig.protocolFeeRecipient, payments);
    }

    function _cancelRequest(bytes32 requestId) internal virtual {
        delete requestCommitments[requestId];
    }

    function _onlyOwner() internal view virtual;
}