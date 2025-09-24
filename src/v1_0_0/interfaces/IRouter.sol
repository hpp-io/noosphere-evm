// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Commitment} from "../types/Commitment.sol";
import {FulfillResult} from "../types/FulfillResult.sol";
import {ProofVerificationRequest} from "../types/ProofVerificationRequest.sol";
import {Payment} from "../types/Payment.sol";
import {Subscription} from "../types/Subscription.sol";

interface IRouter {
    /**
     * @notice Sends a subscription request
     * @param subscriptionId The ID of the subscription
     * @param interval The interval of the subscription.
     */
    function sendRequest(
        uint64 subscriptionId,
        uint32 interval
    ) external returns (bytes32, Commitment memory);

    /**
     * @notice Checks if a subscription has a next interval to be processed.
     * @param subscriptionId The ID of the subscription.
     * @param currentInterval The current interval of the subscription.
     * @return True if there is a next interval, false otherwise.
     */
    function hasSubscriptionNextInterval(
        uint64 subscriptionId,
        uint32 currentInterval
    ) external view returns (bool);


    /**
     * @notice Fulfills a subscription request.
     * @param input The input data for the fulfillment.
     * @param output The output data from the fulfillment.
     * @param proof The proof of execution for the fulfillment.
     * @param numRedundantDeliveries The number of the RedundantDeliveries.
     * @param nodeWallet The wallet address of the node fulfilling the request.
     * @param payments An array of payments associated with the fulfillment.
     * @param commitment The commitment object for the original request.
     */
    function fulfill(
        bytes memory input,
        bytes memory output,
        bytes memory proof,
        uint16 numRedundantDeliveries,
        address nodeWallet,
        Payment[] memory payments,
        Commitment memory commitment
    ) external returns (FulfillResult resultCode);


    function payFromCoordinator(
        uint64 subscriptionId,
        uint32 interval,
        address spenderWallet,
        address spenderAddress,
        Payment[] memory payments
    ) external;

    /**
     * @notice Locks funds in the consumer's wallet for proof verification.
     * @dev This is called by a Coordinator before a potentially costly verification process.
     * @param proofRequest The details of the proof verification request.
     * @param commitment The original request commitment object, proving the request's validity.
     */
    function lockForVerification(ProofVerificationRequest calldata proofRequest, Commitment memory commitment) external;

    /**
     * @notice Unlocks funds in the consumer's wallet after proof verification.
     * @dev This is called by a Coordinator after the verification process is complete.
     * @param proofRequest The details of the proof verification request.
     */
    function unlockForVerification(ProofVerificationRequest calldata proofRequest) external;

    /**
     * @notice Write data to the inbox
     * @param containerId Container ID hash
     * @param input Input data
     * @param output Output data
     * @param proof Verification proof
     */
    function writeInbox(
        bytes32 containerId,
        bytes calldata input,
        bytes calldata output,
        bytes calldata proof
    ) external;

    /**
     * @notice Prepare node verification for a subscription interval
     * @param subscriptionId The subscription ID
     * @param nextInterval The interval to prepare
     * @param nodeWallet The node's wallet address
     * @param token Payment token
     * @param amount Payment amount
     */
    function prepareNodeVerification(
        uint64 subscriptionId,
        uint32 nextInterval,
        address nodeWallet,
        address token,
        uint256 amount
    ) external;

    /**
     * @notice Get a contract address by its ID
     * @param id The contract identifier
     * @return The contract address
     */
    function getContractById(bytes32 id) external view returns (address);

    /**
     * @notice Get a proposed contract address by its ID
     * @param id The contract identifier
     * @return The proposed contract address
     */
    function getProposedContractById(bytes32 id) external view returns (address);

    /**
     * @notice Get the WalletFactory contract address
     * @return The WalletFactory contract address
     */
    function getWalletFactory() external view returns (address);

    /**
     * @notice Checks if a given address is a valid wallet managed by the WalletFactory.
     * @param walletAddr The address to check.
     * @return The address of the wallet if valid, otherwise the zero address.
     */
    function isValidWallet(address walletAddr) external view returns (bool);

    /**
     * @notice Propose a set of contract updates
     * @param proposalSetIds Array of contract IDs
     * @param proposalSetAddresses Array of contract addresses
     */
    function proposeContractsUpdate(
        bytes32[] calldata proposalSetIds,
        address[] calldata proposalSetAddresses
    ) external;

    /**
     * @notice Update contracts to the proposed set
     */
    function updateContracts() external;

    /**
     * @notice Pause the router
     */
    function pause() external;

    /**
     * @notice Unpause the router
     */
    function unpause() external;

    /**
     * @notice Get the current allow list ID
     * @return The allow list ID
     */
    function getAllowListId() external view returns (bytes32);

    /**
     * @notice Set the allow list ID
     * @param allowListId New allow list ID
     */
    function setAllowListId(bytes32 allowListId) external;

    /**
     * @notice Handle the timeout of requests.
     * @param requestId The id of requests to timeout.
     */
    function timeoutRequest(bytes32 requestId, uint64 subscriptionId, uint32 interval) external;

    /**
     * @notice Creates a subscription via an EIP-712 signature.
     * @dev Validates the signature and then creates the subscription.
     */
    function createSubscriptionDelegatee(
        uint32 nonce,
        uint32 expiry,
        Subscription calldata sub,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint64);

    function getLastSubscriptionId() external view returns (uint64);
}
