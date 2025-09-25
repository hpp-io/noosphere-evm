// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {Router} from "../../../src/v1_0_0/Router.sol";
import {MockVerifier} from "./MockVerifier.sol";

/// @title MockImmediateVerifier
/// @notice A minimal verifier used in tests which treats submissions **atomically**:
///         it accepts a proof submission, emits a request event, and immediately finalizes
///         the verification result on-chain by calling the Coordinator.
/// @dev This mock implements the asynchronous `submitProofForVerification` API but behaves
///     synchronously by immediately delivering the outcome. It is useful for unit tests
///     that want the verifier to be deterministic and instantaneousMockImmediateVerifier.
///
///     The contract intentionally provides a small `requestId` counter so callers and test
///     harnesses can correlate events and finalize calls. A deprecated compatibility wrapper
///     `requestProofVerification` is provided for code that still uses the old name.
contract MockImmediateVerifier is MockVerifier {
    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Next verification outcome that will be used for submissions.
    /// @dev Tests can set this to `true` or `false` to control the expected behavior.
    bool private nextValidity = false;

    /// @notice Monotonic counter used to issue simple requestIds for accepted submissions.
    uint256 private requestCounter;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Construct the mock verifier and resolve Coordinator via the Router.
    /// @param router Router instance used to resolve the Coordinator address in parent.
    constructor(Router router) MockVerifier(router) {}

    /*//////////////////////////////////////////////////////////////
                         SUBMISSION / VERIFICATION API
    //////////////////////////////////////////////////////////////*/

    /// @notice Submit a proof for verification (async API). This mock behaves atomically:
    ///         it immediately finalizes the verification result via the Coordinator.
    /// @dev Emits `VerificationRequested(requestId, ...)` and then calls
    ///      `coordinator.finalizeProofVerification(...)` with the preconfigured outcome.
    /// @param subscriptionId Identifier of the subscription this proof belongs to.
    /// @param interval Interval index (or round) that this proof corresponds to.
    /// @param node Address of the agent/node that produced the proof.
    /// @param proof Arbitrary proof bytes consumed by the verifier (ignored by mock).
    function submitProofForVerification(
        uint64 subscriptionId,
        uint32 interval,
        address node,
        bytes calldata proof
    ) external {
        // emit the acceptance event so tests/integrations can observe the submission
        emit VerificationRequested( subscriptionId, interval, node);

        // Immediately finalize the verification on the coordinator using the configured outcome.
        // The mock intentionally ignores the proof bytes and uses `nextValidity`.
        coordinator.reportVerificationResult(subscriptionId, interval, node, nextValidity);
    }

    /*//////////////////////////////////////////////////////////////
                                TEST HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the next submission to be considered valid.
    function setNextValidityTrue() external {
        nextValidity = true;
    }

    /// @notice Set the next submission to be considered invalid.
    function setNextValidityFalse() external {
        nextValidity = false;
    }

    /// @notice Set next validity in one call.
    /// @param valid desired next validity outcome
    function setNextValidity(bool valid) external {
        nextValidity = valid;
    }

    /// @notice View the next configured validity (useful for assertions in tests).
    /// @return current configured validity that will be applied to the next submission.
    function getNextValidity() external view returns (bool) {
        return nextValidity;
    }

    /// @notice Current request counter (useful for tests to inspect last issued id).
    function lastRequestId() external view returns (uint256) {
        return requestCounter;
    }
}
