// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {Router} from "../../../src/v1_0_0/Router.sol";
import {MockVerifier} from "./MockVerifier.sol";

/// @title MockDeferredVerifier
/// @notice Test helper verifier that accepts proofs asynchronously (optimistic / deferred model).
/// @dev This mock implements the asynchronous `submitProofForVerification` API: it **accepts**
///      submissions, emits `VerificationRequested` and returns a `requestId`, but does **not**
///      finalize verification immediately. A separate administrative helper (`mockFinalizeVerification`)
///      can be used in tests to simulate the verifier producing a result later and calling the
///      Coordinator's finalization entrypoint.
///
///      The contract stores lightweight submission metadata (no raw proof bytes — only a hash) so test
///      code can correlate later finalization with the original submission.
contract MockDeferredVerifier is MockVerifier {
    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Construct the mock deferred verifier and resolve Coordinator via the parent Verifier.
    /// @param router Router instance used by the parent to resolve protocol addresses.
    constructor(Router router) MockVerifier(router) {}

    /*//////////////////////////////////////////////////////////////
                      SUBMISSION (ASYNC) - IVerifier IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Accept a proof submission for asynchronous verification.
    /// @dev Records a light-weight submission record (stores proof hash only), emits
    ///      `VerificationRequested(requestId, ...)` and returns an implementation-assigned `requestId`.
    ///      The verification decision is expected to be produced later (e.g., via `mockFinalizeVerification`).
    function submitProofForVerification(
        uint64 subscriptionId,
        uint32 interval,
        address submitter,
        address, /* nodeWallet */
        bytes calldata, /* proof */
        bytes32, /* commitmentHash */
        bytes32, /* inputHash */
        bytes32 /* resultHash */
    ) external virtual override {
        // signal that the request was accepted
        emit VerificationRequested(subscriptionId, interval, submitter);
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN / TEST HELPERS (SIMULATED FINALIZE)
    //////////////////////////////////////////////////////////////*/

    /// @notice Simulate the verifier producing a result for a prior submission and finalize via Coordinator.
    /// @dev In tests, call this to emulate the off-chain verifier deciding whether a proof is valid.
    ///      Requires that the `requestId` exists. This calls `coordinator.finalizeProofVerification(...)`.
    /// @param subscriptionId The ID of the subscription.
    /// @param interval The interval index (round) this proof targets.
    /// @param node The address of the agent/node that submitted the proof.
    /// @param valid True if the proof is valid, false otherwise.

    function mockFinalizeVerification(uint64 subscriptionId, uint32 interval, address node, bool valid) external {
        // call into the Coordinator to finalize the verification outcome
        COORDINATOR.reportVerificationResult(subscriptionId, interval, node, valid);
    }
}
