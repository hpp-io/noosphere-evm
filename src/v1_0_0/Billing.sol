// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Routable} from "./utility/Routable.sol";
import {IBilling} from "./interfaces/IBilling.sol";
import {BillingConfig} from "./types/BillingConfig.sol";
import {Commitment} from "./types/Commitment.sol";
import {Payment} from "./types/Payment.sol";
import {ComputeSubscription} from "./types/ComputeSubscription.sol";
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

    /// @notice hash(subscriptionId, interval, caller) => proof request
    mapping(bytes32 => ProofVerificationRequest) public proofRequests;

    error InvalidRequestCommitment(bytes32 requestId);
    error ProtocolFeeExceeds();
    error UnsupportedVerifierToken(address token);
    error InsufficientForVerifierFee();
    error UnauthorizedVerifier();

    /// @param _router The address of the router contract.
    constructor(address _router) Routable(_router) {}

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
        bool useDeliveryInbox,
        address feeToken,
        uint256 feeAmount,
        address wallet,
        address verifier
    ) internal virtual returns (Commitment memory) {
        uint256 verifierFee = 0;
        if (verifier != address(0)) {
            IVerifier verifierContract = IVerifier(verifier);
            if (verifierContract.isPaymentTokenSupported(feeToken) == false) {
                revert UnsupportedVerifierToken(feeToken);
            }
            verifierFee = verifierContract.fee(feeToken);
            if (feeAmount < verifierFee) {
                revert InsufficientForVerifierFee();
            }
        }

        Commitment memory commitment = Commitment({
            requestId: requestId,
            subscriptionId: subscriptionId,
            containerId: containerId,
            interval: interval,
            redundancy: redundancy,
            useDeliveryInbox: useDeliveryInbox,
            walletAddress: wallet,
            feeAmount: feeAmount,
            feeToken: feeToken,
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
            _processVerifiedDelivery(
                commitment, proofSubmitter, nodeWallet, input, output, proof, numRedundantDeliveries
            );
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
        _initiateVerification(commitment, proofSubmitter, nodeWallet);
        _getRouter().fulfill(input, output, proof, numRedundantDeliveries, nodeWallet, payments, commitment);
        // Initiate verifier verification
        bytes32 commitmentHash = keccak256(abi.encode(commitment));
        bytes32 inputHash = keccak256(input);
        bytes32 resultHash = keccak256(output);
        IVerifier(commitment.verifier)
            .submitProofForVerification(
                commitment.subscriptionId,
                commitment.interval,
                proofSubmitter,
                nodeWallet,
                proof,
                commitmentHash,
                inputHash,
                resultHash
            );
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
    function _prepareStandardPayments(Commitment memory commitment, address nodeWallet)
        internal
        view
        virtual
        returns (Payment[] memory)
    {
        uint256 feeAmount = commitment.feeAmount;

        // The original logic applies the fee twice, representing a fee on both
        // the consumer and the node from the total payment amount.
        uint256 paidToProtocol = _calculateFee(feeAmount, billingConfig.protocolFee * 2);
        uint256 paidToNode = feeAmount - paidToProtocol;

        Payment[] memory payments = new Payment[](2);
        payments[0] = Payment(billingConfig.protocolFeeRecipient, commitment.feeToken, paidToProtocol);
        payments[1] = Payment(nodeWallet, commitment.feeToken, paidToNode);

        return payments;
    }

    /// @dev Prepares the immediate payment array for a verified fulfillment (pays protocol and verifier).
    function _prepareVerificationPayments(Commitment memory commitment)
        internal
        view
        virtual
        returns (Payment[] memory)
    {
        uint256 tokenAvailable = commitment.feeAmount;
        IVerifier verifier = IVerifier(commitment.verifier);
        if (!verifier.isPaymentTokenSupported(commitment.feeToken)) {
            revert UnsupportedVerifierToken(commitment.feeToken);
        }
        uint256 baseProtocolFee = _calculateFee(tokenAvailable, billingConfig.protocolFee) * 2;
        tokenAvailable -= baseProtocolFee;

        uint256 verifierFee = verifier.fee(commitment.feeToken);
        if (tokenAvailable < verifierFee) {
            revert InsufficientForVerifierFee();
        }
        uint256 verifierProtocolFee = _calculateFee(verifierFee, billingConfig.protocolFee);
        Payment[] memory immediatePayments = new Payment[](2);
        immediatePayments[0] =
            Payment(billingConfig.protocolFeeRecipient, commitment.feeToken, baseProtocolFee + verifierProtocolFee);
        immediatePayments[1] =
            Payment(verifier.paymentRecipient(), commitment.feeToken, verifierFee - verifierProtocolFee);
        return immediatePayments;
    }

    /// @dev Handles post-fulfillment steps for verification (locking funds, calling verifier).
    function _initiateVerification(Commitment memory commitment, address proofSubmitter, address submitterWallet)
        internal
        virtual
    {
        // Calculate the final amount that will be paid to the node after fees.
        // This is the amount that will be escrowed and potentially slashed.
        uint256 tokenAvailable = commitment.feeAmount;
        uint256 baseProtocolFee = _calculateFee(tokenAvailable, billingConfig.protocolFee) * 2;
        IVerifier verifier = IVerifier(commitment.verifier);
        uint256 verifierFee = verifier.fee(commitment.feeToken);
        uint256 nodePaymentAmount = tokenAvailable - baseProtocolFee - verifierFee;
        bytes32 key = keccak256(abi.encode(commitment.subscriptionId, commitment.interval, msg.sender));
        proofRequests[key] = ProofVerificationRequest({
            subscriptionId: commitment.subscriptionId,
            requestId: commitment.requestId,
            submitterAddress: proofSubmitter,
            submitterWallet: submitterWallet,
            expiry: uint32(block.timestamp + 1 weeks), // Example expiry
            escrowedAmount: nodePaymentAmount,
            escrowToken: commitment.feeToken,
            slashAmount: tokenAvailable
        });
        _getRouter().lockForVerification(proofRequests[key], commitment);
    }

    /// @notice Finalizes the verification process based on the verifier's result.
    /// @dev This internal function is expected to be called by a public function that authenticates the caller as the verifier.
    /// @param request The proof verification request details.
    /// @param valid True if the proof was valid, false otherwise.
    function _finalizeVerification(ProofVerificationRequest memory request, bool valid) internal virtual {
        bool expired = uint32(block.timestamp) >= request.expiry;
        ComputeSubscription memory sub = _getRouter().getComputeSubscription(request.subscriptionId);
        if (msg.sender != sub.verifier) {
            revert UnauthorizedVerifier();
        }

        // Unlock funds regardless of outcome, as the verification process is complete.
        _getRouter().unlockForVerification(request);

        Payment[] memory payments = new Payment[](1);
        // Pay the node if the proof is valid OR if the verification intervalSeconds has expired.
        if (valid || expired) {
            payments[0] = Payment({
                recipient: request.submitterWallet, feeToken: request.escrowToken, feeAmount: request.escrowedAmount
            });
            _getRouter().payFromCoordinator(request.subscriptionId, sub.wallet, sub.client, payments);
        } else {
            // Slash the node if the proof is invalid AND the intervalSeconds has not expired.
            payments[0] = Payment({recipient: sub.wallet, feeToken: sub.feeToken, feeAmount: sub.feeAmount});
            _getRouter()
                .payFromCoordinator(request.subscriptionId, request.submitterWallet, request.submitterAddress, payments);
        }
    }

    /// @notice Calculates the fee for a node that triggers the next interval.
    function _calculateNextTickFee(uint64 subscriptionId, address nodeWallet) internal virtual {
        Payment[] memory payments;
        if (billingConfig.tickNodeFee > 0) {
            payments = new Payment[](1);
            payments[0] = Payment({
                recipient: nodeWallet, feeToken: billingConfig.tickNodeFeeToken, feeAmount: billingConfig.tickNodeFee
            });
        }

        // The spender is the protocol fee recipient itself, as it's paying from its own wallet.
        _getRouter()
            .payFromCoordinator(
                subscriptionId,
                billingConfig.protocolFeeRecipient, // spenderWallet
                billingConfig.protocolFeeRecipient, // spenderAddress
                payments
            );
    }

    function _cancelRequest(bytes32 requestId) internal virtual {
        delete requestCommitments[requestId];
    }

    function _onlyOwner() internal view virtual;
}
