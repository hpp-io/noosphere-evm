// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Commitment} from "../types/Commitment.sol";
import {FulfillResult} from "../types/FulfillResult.sol";
import {ProofVerificationRequest} from "../types/ProofVerificationRequest.sol";
import {Payment} from "../types/Payment.sol";
import {ComputeSubscription} from "../types/ComputeSubscription.sol";

/// @title IRouter
/// @notice Lightweight interface describing the Router entrypoints used by the Coordinator, Wallet and verifier
///         adapters. Functions are grouped by responsibility (request lifecycle, fulfillment & payments,
///         verification escrow, subscription management, contract governance, and misc admin).
interface IRouter {
    /*//////////////////////////////////////////////////////////////////////////
                              REQUEST LIFECYCLE - READ / SEND
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Create and announce a new request for a given subscription interval.
    /// @dev Returns a request identifier key and the Commitment struct that the Coordinator will persist.
    /// @param subscriptionId Subscription identifier for which the request is created.
    /// @param interval Interval index (round) that the request targets.
    /// @return requestKey Opaque request key (e.g. keccak256 of relevant fields) used for lookup/timeouts.
    /// @return commitment Commitment struct describing the request's long-lived on-chain metadata.
    function sendRequest(uint64 subscriptionId, uint32 interval)
        external
        returns (bytes32 requestKey, Commitment memory commitment);

    /// @notice Query whether the given subscription has a next interval after `currentInterval`.
    /// @dev Useful for nodes/planners to check if they should attempt to prepare/serve the next interval.
    /// @param subscriptionId Subscription identifier to check.
    /// @param currentInterval Current interval index.
    /// @return hasNext True if the subscription has another interval to process; false otherwise.
    function hasSubscriptionNextInterval(uint64 subscriptionId, uint32 currentInterval)
        external
        view
        returns (bool hasNext);

    /*//////////////////////////////////////////////////////////////////////////
                         FULFILLMENT & PAYMENT HANDLERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Accept fulfillment results and attempt on-chain settlement for a request.
    /// @dev Transfers/escrow operations are performed according to the provided `payments` array and the
    ///      Coordinator's business rules. Returns a FulfillResult enum code representing settlement outcome.
    /// @param input Original request input bytes.
    /// @param output Compute output bytes produced by the node.
    /// @param proof Proof bytes supporting the fulfillment (protocol-specific).
    /// @param numRedundantDeliveries Number of redundant deliveries reported for this fulfillment.
    /// @param nodeWallet Wallet address used by the reporting node for payout/escrow actions.
    /// @param payments Array of Payment entries describing recipients and amounts for this fulfillment.
    /// @param commitment The Commitment struct that corresponds to the original request.
    /// @return resultCode Fulfillment result code (see FulfillResult type).
    function fulfill(
        bytes memory input,
        bytes memory output,
        bytes memory proof,
        uint16 numRedundantDeliveries,
        address nodeWallet,
        Payment[] memory payments,
        Commitment memory commitment
    ) external returns (FulfillResult resultCode);

    /// @notice Instruct Router to execute coordinator-driven payouts on behalf of Coordinator.
    /// @dev Called by Coordinator after commitments are verified or timeouts processed.
    /// @param subscriptionId Subscription identifier related to the payout.
    /// @param spenderWallet Wallet address from which funds will be drawn (consumer wallet).
    /// @param spenderAddress Address that authorized the spend (consumer/owner).
    /// @param payments Array of payments to execute.
    function payFromCoordinator(
        uint64 subscriptionId,
        address spenderWallet,
        address spenderAddress,
        Payment[] memory payments
    ) external;

    /*//////////////////////////////////////////////////////////////////////////
                          VERIFICATION ESCROW (LOCK / UNLOCK)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Lock consumer funds for an upcoming or in-progress proof verification.
    /// @dev Coordinator calls this prior to invoking potentially expensive verification routines so funds
    ///      needed for verifier fees are reserved.
    /// @param proofRequest Proof verification request describing subscription/interval/verifier/token.
    /// @param commitment Commitment that proves the original request context and pricing.
    function lockForVerification(ProofVerificationRequest calldata proofRequest, Commitment memory commitment) external;

    /// @notice Release/unlock previously locked funds after verification completes or is aborted.
    /// @param proofRequest Proof verification request describing subscription/interval/verifier/token.
    function unlockForVerification(ProofVerificationRequest calldata proofRequest) external;

    /// @notice Prepare node-side verification parameters for the given subscription interval.
    /// @dev Typically used by Coordinator to pre-reserve verifier fees for node operations.
    /// @param subscriptionId Subscription identifier being prepared.
    /// @param nextInterval Interval number the node should prepare for.
    /// @param nodeWallet Node wallet address used for settlement bookkeeping.
    /// @param token Payment token used for verifier fees.
    /// @param amount Amount reserved for the verification (token base units).
    function prepareNodeVerification(
        uint64 subscriptionId,
        uint32 nextInterval,
        address nodeWallet,
        address token,
        uint256 amount
    ) external;

    /*//////////////////////////////////////////////////////////////////////////
                           SUBSCRIPTION MANAGEMENT
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Create a subscription on behalf of a client via EIP-712 delegated signature.
    /// @dev Validates the provided signature and, if accepted, creates or returns an existing subscription id.
    /// @param nonce Subscriber-supplied nonce (used to prevent replay).
    /// @param expiry Signature expiry timestamp.
    /// @param sub ComputeSubscription payload describing subscription parameters.
    /// @param signature EIP-712 encoded signature authorizing the creation.
    /// @return subscriptionId The id of the created (or existing) subscription.
    function createSubscriptionDelegatee(
        uint32 nonce,
        uint32 expiry,
        ComputeSubscription calldata sub,
        bytes calldata signature
    ) external returns (uint64 subscriptionId);

    /// @notice Returns the last subscription id issued by the Router.
    /// @return lastId The most recently created subscription identifier.
    function getLastSubscriptionId() external view returns (uint64 lastId);

    /*//////////////////////////////////////////////////////////////////////////
                         CONTRACT REGISTRY & GOVERNANCE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Resolve a registered contract address by its canonical id.
    /// @param id Well-known contract id (bytes32).
    /// @return addr Resolved deployed address (zero if not set).
    function getContractById(bytes32 id) external view returns (address addr);

    /// @notice Resolve a proposed (pending) contract address by its canonical id.
    /// @param id Well-known contract id (bytes32).
    /// @return addr Proposed address (zero if not set).
    function getProposedContractById(bytes32 id) external view returns (address addr);

    /// @notice Propose an updated set of contracts (ids + new addresses) for governance review.
    /// @param proposalSetIds Array of contract ids to update.
    /// @param proposalSetAddresses Corresponding array of proposed addresses.
    function proposeContractsUpdate(bytes32[] calldata proposalSetIds, address[] calldata proposalSetAddresses) external;

    /// @notice Commit the previously proposed contracts set into active use.
    function updateContracts() external;

    /*//////////////////////////////////////////////////////////////////////////
                             WALLET FACTORY / VALIDATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Get the WalletFactory contract address used to create consumer wallets.
    /// @return factory Address of the WalletFactory.
    function getWalletFactory() external view returns (address factory);

    /// @notice Validate whether the given address is a Wallet created by the WalletFactory.
    /// @param walletAddr Candidate wallet address to validate.
    /// @return isValid True when `walletAddr` was produced by the WalletFactory and is tracked.
    function isValidWallet(address walletAddr) external view returns (bool isValid);

    /*//////////////////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Pause router operations (governance/maintenance).
    function pause() external;

    /// @notice Resume router operations.
    function unpause() external;

    /*//////////////////////////////////////////////////////////////////////////
                                  TIMEOUTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Mark a request as timed out and run associated timeout handling.
    /// @param requestId The opaque request key to timeout (returned from sendRequest).
    /// @param subscriptionId Subscription id associated with the request (for convenience/verification).
    /// @param interval Interval number associated with the request.
    function timeoutRequest(bytes32 requestId, uint64 subscriptionId, uint32 interval) external;
}
