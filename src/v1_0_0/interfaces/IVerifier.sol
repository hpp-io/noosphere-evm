// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

/// @title IVerifier
/// @notice Interface for verifier contracts that can validate proofs and manage fees.
interface IVerifier {
    /// @notice Checks if the verifier supports a given payment token.
    function isSupportedToken(address token) external view returns (bool);

    /// @notice Returns the fee required by the verifier for a given token.
    function fee(address token) external view returns (uint256);

    /// @notice Returns the wallet address where the verifier receives payments.
    function getWallet() external view returns (address);

    /// @notice Initiates the proof verification process.
    function requestProofVerification(uint64 subscriptionId, uint32 interval, address node, bytes calldata proof) external;
}