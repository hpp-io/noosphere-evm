// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Commitment} from "../types/Commitment.sol";
import {FulfillResult} from "../types/FulfillResult.sol";
import {ProofVerificationRequest} from "../types/ProofVerificationRequest.sol";
import {Payment} from "../types/Payment.sol";

interface IRouter {

    /**
     * @notice Sends a subscription request
     * @param subscriptionId The ID of the subscription
     * @param interval The interval of the subscription.
     */
    function sendRequest(
        uint64 subscriptionId,
        uint32 interval
    ) external returns (bytes32);

    /**
     * @notice Fulfill a subscription request
     * @param commitment The commitment to the request
     * @param input The input data
     * @param output The output data
     * @param proof The proof of the request
     * @param payments The payments for the request
     * @param index The index of the request
     */
    function fulfill(
        bytes memory input,
        bytes memory output,
        bytes memory proof,
        uint256 index,
        Payment[] memory payments,
        Commitment memory commitment
    ) external returns (FulfillResult resultCode);

    /**
     * @notice Locks funds in the consumer's wallet for proof verification.
     * @dev This is called by a Coordinator before a potentially costly verification process.
     * @param proofRequest The details of the proof verification request.
     * @param commitment The original request commitment object, proving the request's validity.
     */
    function lockForVerification(ProofVerificationRequest calldata proofRequest, Commitment memory commitment) external;

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
}
