// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ImmediateFinalizeVerifier} from "../src/v1_0_0/verifier/ImmediateFinalizeVerifier.sol";
import {ProofVerificationRequest} from "../src/v1_0_0/types/ProofVerificationRequest.sol";
import {PayloadData} from "../src/v1_0_0/types/PayloadData.sol";

/// @dev Minimal coordinator stand-in that records the verification outcome so the test can
///      assert the verifier reports failures gracefully (instead of reverting).
contract RecordingCoordinator {
    bool public sawCall;
    bool public lastValid;
    uint256 public callCount;

    function reportVerificationResult(ProofVerificationRequest memory, bool valid) external {
        sawCall = true;
        lastValid = valid;
        callCount++;
    }
}

/// @title ImmediateFinalizeVerifierSigTest
/// @notice Focused tests for signature handling in `submitProofForVerification`.
/// @dev The full compute-flow verifier tests live in Compute.Verifier.t.sol (currently skipped
///      pending PayloadData redesign). These exercise the signature branch directly via a
///      stand-in coordinator, covering the regression where a malformed signature must be
///      reported as a failed verification rather than reverting the whole call.
contract ImmediateFinalizeVerifierSigTest is Test {
    ImmediateFinalizeVerifier internal verifier;
    RecordingCoordinator internal coordinator;

    bytes32 internal constant REQ = bytes32("req");
    bytes32 internal constant CH = bytes32("ch");
    bytes32 internal constant IH = bytes32("ih");
    bytes32 internal constant RH = bytes32("rh");

    function setUp() public {
        coordinator = new RecordingCoordinator();
        verifier = new ImmediateFinalizeVerifier(address(coordinator), address(this));
    }

    function _timestamp() internal view returns (uint256) {
        return block.timestamp + 10 minutes;
    }

    /// @dev Build the PayloadData `proof` whose `uri` encodes the proof tuple the verifier decodes.
    ///      commitment/input/result hashes are fixed so the call reaches the signature branch.
    function _buildProof(address nodeAddr, bytes memory signature) internal view returns (PayloadData memory) {
        bytes memory uri = abi.encode(REQ, CH, IH, RH, nodeAddr, _timestamp(), signature);
        return PayloadData({contentHash: keccak256(uri), uri: uri});
    }

    function _request() internal pure returns (ProofVerificationRequest memory) {
        return ProofVerificationRequest({
            subscriptionId: 1,
            interval: 7,
            submitterAddress: address(0xABCD),
            submitterWallet: address(0), // EOA submitter — skips the ERC-1271 branch
            escrowedAmount: 0,
            escrowToken: address(0),
            slashAmount: 0,
            expiry: 0
        });
    }

    /// @dev Regression: a malformed signature (length != 65) must be reported as a failed
    ///      verification, not revert. `ECDSA.recover` would have reverted on it.
    function test_malformedSignature_reportsFailureWithoutReverting() public {
        ProofVerificationRequest memory request = _request();
        PayloadData memory proof = _buildProof(address(0xBEEF), hex"1234");

        vm.expectEmit(true, true, true, true, address(verifier));
        emit ImmediateFinalizeVerifier.VerificationFailed(
            request.subscriptionId, request.interval, request.submitterAddress, "zero_address_signer"
        );

        vm.prank(address(coordinator));
        verifier.submitProofForVerification(request, proof, CH, IH, RH);

        assertTrue(coordinator.sawCall(), "coordinator should have been notified");
        assertEq(coordinator.lastValid(), false, "verification should be reported as failed");
    }

    /// @dev An empty signature is also reported as a failure rather than reverting.
    function test_emptySignature_reportsFailureWithoutReverting() public {
        ProofVerificationRequest memory request = _request();
        PayloadData memory proof = _buildProof(address(0xBEEF), bytes(""));

        vm.prank(address(coordinator));
        verifier.submitProofForVerification(request, proof, CH, IH, RH);

        assertTrue(coordinator.sawCall());
        assertEq(coordinator.lastValid(), false);
    }

    /// @dev A well-formed signature by the declared node still verifies successfully — the
    ///      tryRecover change does not regress the happy path.
    function test_validSignature_reportsSuccess() public {
        (address nodeAddr, uint256 nodeKey) = makeAddrAndKey("node");

        bytes32 digest = verifier.getTypedDataHash(verifier.getStructHash(REQ, CH, IH, RH, nodeAddr, _timestamp()));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(nodeKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        ProofVerificationRequest memory request = _request();
        PayloadData memory proof = _buildProof(nodeAddr, signature);

        vm.prank(address(coordinator));
        verifier.submitProofForVerification(request, proof, CH, IH, RH);

        assertTrue(coordinator.sawCall());
        assertEq(coordinator.lastValid(), true, "valid signature should pass verification");
    }
}
