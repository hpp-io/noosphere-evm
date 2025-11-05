// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

/// @title IVerifier
/// @notice Minimal asynchronous verifier interface used by the protocol.
/// @dev Verification requests are processed asynchronously. Implementations should either emit
///      an event containing a request identifier or return a requestId when a submission is accepted.
///      Final verification outcomes (success/failure) are delivered via events or callbacks and are
///      not returned synchronously by `submitProofForVerification`.
interface IVerifier {
    /// @notice Emitted when a verification request has been accepted by the verifier.
    /// @param subscriptionId Subscription identifier that this verification relates to.
    /// @param interval Interval index (or round) that this verification concerns.
    /// @param nodeWallet Address of the agent/node that submitted the proof.
    event VerificationRequested(uint64 indexed subscriptionId, uint32 indexed interval, address nodeWallet);

    /// @notice Returns the fee required by the verifier when paid in `token`.
    /// @param token ERC20 token address (or `address(0)` for native ETH).
    /// @return amount Fee amount denominated in `token` base units.
    function fee(address token) external view returns (uint256 amount);

    /// @notice Address that receives payments for this verifier.
    /// @return recipient Payment recipient address (commonly the verifier contract itself or a treasury).
    function paymentRecipient() external view returns (address recipient);

    /// @notice Returns whether the verifier accepts `token` as payment.
    /// @param token ERC20 token address. Use `address(0)` for native ETH if supported.
    /// @return accepted True when the token is accepted for payment.
    function isPaymentTokenSupported(address token) external view returns (bool accepted);

    /// @notice Submit a proof for asynchronous verification.
    /// @dev Implementations MUST either emit `VerificationRequested(requestId, ...)` or return a non-zero
    ///      `requestId` when a submission is accepted. Verification results are delivered out-of-band
    ///      (events, callbacks, or off-chain notifications). Do not expect synchronous verification here.
    /// @param subscriptionId Subscription identifier associated with this proof.
    /// @param interval Interval index (or round) that this proof corresponds to.
    /// @param submitter Address of the agent/node that produced and submitted the proof.
    /// @param nodeWallet Address of the node wallet.
    /// @param proof Arbitrary proof bytes understood by the verifier implementation.
    /// @param commitmentHash Hash of the commitment being verified.
    /// @param inputHash Hash of the input data used to generate the proof.
    /// @param resultHash Hash of the result data produced by the proof.
    function submitProofForVerification(
        uint64 subscriptionId,
        uint32 interval,
        address submitter,
        address nodeWallet,
        bytes calldata proof,
        bytes32 commitmentHash,
        bytes32 inputHash,
        bytes32 resultHash
    ) external;
}
