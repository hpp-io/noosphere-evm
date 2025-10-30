// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Coordinator} from "../Coordinator.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IVerifier} from "../interfaces/IVerifier.sol";
import {ICoordinator} from "../interfaces/ICoordinator.sol";

/**
 * @title ImmediateFinalizeVerifier
 * @author Noosphere
 * @notice This contract immediately verifies and finalizes a computation proof by
 *         validating an EIP-712 signature provided by a compute node.
 *         It does not have a challenge window; verification is instant.
 */
contract ImmediateFinalizeVerifier is IVerifier, EIP712, Ownable {
    /// @dev A struct to hold the decoded proof data to avoid stack too deep errors.
    struct ProofData {
        bytes32 requestId;
        bytes32 commitmentHash;
        bytes32 inputHash;
        bytes32 resultHash;
        address nodeAddress;
        uint256 timestamp;
        bytes signature;
    }

    // keccak256("ComputeSubmission(string requestId,bytes32 commitmentHash,bytes32 inputHash,bytes32 resultHash,address nodeAddress,uint256 timestamp)")
    bytes32 private constant _COMPUTE_SUBMISSION_TYPEHASH = keccak256(
        "ComputeSubmission(bytes32 requestId,bytes32 commitmentHash,bytes32 inputHash,bytes32 resultHash,address nodeAddress,uint256 timestamp)"
    );

    /// @notice Mapping from token address to whether it is supported for fee payments.
    mapping(address => bool) public supportedTokens;

    ICoordinator public coordinator;

    event CoordinatorChanged(address indexed oldCoordinator, address indexed newCoordinator);

    // --- Custom Errors ---
    error OnlyCoordinator();
    error CommitmentHashMismatch();
    error InputHashMismatch();
    error ResultHashMismatch();
    error NodeMismatch();
    error InvalidEOASignature();
    error ZeroAddressSigner();
    error InvalidContractSignature();

    /**
     * @notice Initializes the contract with the coordinator address and EIP-712 domain info.
     * @param coordinator_ The address of the Coordinator contract.
     * @param initialOwner_ The initial owner of this contract.
     */
    constructor(address coordinator_, address initialOwner_)
        EIP712("Noosphere Onchain Verifier", "1")
        Ownable(initialOwner_)
    {
        require(coordinator_ != address(0), "coordinator zero");
        coordinator = ICoordinator(coordinator_);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVerifier
    function fee(
        address /* token */
    )
        external
        view
        override
        returns (uint256 amount)
    {
        // This verifier does not charge a fee.
        return 0;
    }

    /// @inheritdoc IVerifier
    function paymentRecipient() external view override returns (address recipient) {
        // This verifier does not handle payments, but must return a valid address.
        return address(this);
    }

    /// @inheritdoc IVerifier
    function isPaymentTokenSupported(address token) external view override returns (bool accepted) {
        // This verifier does not charge a fee, but it must still indicate which tokens it "supports" for fee-less transactions.
        return supportedTokens[token];
    }

    /**
     * @notice Constructs the EIP-712 struct hash for a compute submission.
     * @dev This is a public helper to allow off-chain signers (and tests) to construct the exact same hash.
     * @param requestId The unique request identifier.
     * @param commitmentHash A hash representing the commitment details.
     * @param inputHash A hash of the computation inputs.
     * @param resultHash A hash of the computation results.
     * @param nodeAddress The address of the signing node.
     * @param timestamp The timestamp of the submission.
     * @return The EIP-712 struct hash.
     */
    function getStructHash(
        bytes32 requestId,
        bytes32 commitmentHash,
        bytes32 inputHash,
        bytes32 resultHash,
        address nodeAddress,
        uint256 timestamp
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _COMPUTE_SUBMISSION_TYPEHASH, requestId, commitmentHash, inputHash, resultHash, nodeAddress, timestamp
            )
        );
    }

    function getTypedDataHash(bytes32 structHash) public view returns (bytes32) {
        return _hashTypedDataV4(structHash);
    }

    /*//////////////////////////////////////////////////////////////
                            VERIFICATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Submits proof data for immediate verification using an EIP-712 signature.
     * @dev Only callable by the Coordinator. The `proof` bytes are expected to be the ABI-encoded
     *      (string requestId, bytes32 commitmentHash, bytes32 inputHash, bytes32 resultHash, uint256 timestamp, bytes signature).
     *      The `node` address from the arguments is expected to be the signer.
     * @param subscriptionId The ID of the subscription being verified.
     * @param interval The interval number for the computation being verified.
     * @param submitter The EOA address of the node that submitted the proof.
     * @param nodeWallet The smart contract wallet address of the node.
     * @param proof The ABI-encoded proof data and signature from the node.
     * @param commitmentHash The hash of the commitment data.
     * @param inputHash The hash of the input data.
     * @param resultHash The hash of the output data.
     */
    function submitProofForVerification(
        uint64 subscriptionId,
        uint32 interval,
        address submitter,
        address nodeWallet,
        bytes calldata proof,
        bytes32 commitmentHash,
        bytes32 inputHash,
        bytes32 resultHash
    ) external override {
        if (msg.sender != address(coordinator)) {
            revert OnlyCoordinator();
        }

        ProofData memory proofData;
        (
            proofData.requestId,
            proofData.commitmentHash,
            proofData.inputHash,
            proofData.resultHash,
            proofData.nodeAddress,
            proofData.timestamp,
            proofData.signature
        ) = abi.decode(proof, (bytes32, bytes32, bytes32, bytes32, address, uint256, bytes));
        emit VerificationRequested(subscriptionId, interval, nodeWallet);

        if (commitmentHash != proofData.commitmentHash) {
            revert CommitmentHashMismatch();
        }
        if (inputHash != proofData.inputHash) {
            revert InputHashMismatch();
        }
        if (resultHash != proofData.resultHash) {
            revert ResultHashMismatch();
        }

        bytes32 digest = getTypedDataHash(
            getStructHash(
                proofData.requestId,
                proofData.commitmentHash,
                proofData.inputHash,
                proofData.resultHash,
                proofData.nodeAddress,
                proofData.timestamp
            )
        );

        address signer = ECDSA.recover(digest, proofData.signature);

        if (signer != proofData.nodeAddress) {
            revert InvalidEOASignature();
        }
        if (signer == address(0)) {
            revert ZeroAddressSigner();
        }
        bytes4 magicValue = IERC1271(nodeWallet).isValidSignature(digest, proofData.signature);
        if (magicValue != IERC1271.isValidSignature.selector) {
            revert InvalidContractSignature();
        }
        coordinator.reportVerificationResult(subscriptionId, interval, submitter, true);
    }

    /*//////////////////////////////////////////////////////////////
                            OWNER-ONLY ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the Coordinator contract address.
     * @param newCoordinator The address of the new Coordinator contract.
     */
    function setCoordinator(address newCoordinator) external onlyOwner {
        require(newCoordinator != address(0), "zero coordinator");
        address old = address(coordinator);
        coordinator = ICoordinator(newCoordinator);
        emit CoordinatorChanged(old, newCoordinator);
    }

    /**
     * @notice Owner-only function to update whether a token is supported.
     * @param token The address of the token to support or unsupport.
     * @param isSupported True to support the token, false to unsupport.
     */
    function setTokenSupported(address token, bool isSupported) external onlyOwner {
        supportedTokens[token] = isSupported;
    }

    /*//////////////////////////////////////////////////////////////
                                FALLBACK
    //////////////////////////////////////////////////////////////*/

    // Allow the contract to receive ETH, even though it doesn't charge fees.
    receive() external payable {}
}
