// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Coordinator} from "../Coordinator.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IVerifier} from "../interfaces/IVerifier.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ICoordinator} from "../interfaces/ICoordinator.sol";
import {ProofVerificationRequest} from "../types/ProofVerificationRequest.sol";


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

    bytes32 private constant _COMPUTE_SUBMISSION_TYPEHASH = keccak256(
        "ComputeSubmission(bytes32 requestId,bytes32 commitmentHash,bytes32 inputHash,bytes32 resultHash,address nodeAddress,uint256 timestamp)"
    );

    /// @notice Mapping from token address to whether it is supported for fee payments.
    mapping(address => bool) public supportedTokens;

    /// @notice Mapping from token address to the fee amount.
    mapping(address => uint256) public tokenFees;

    ICoordinator public coordinator;

    event CoordinatorChanged(address indexed oldCoordinator, address indexed newCoordinator);

    event VerificationFailed(
        uint64 indexed subscriptionId, uint32 indexed interval, address indexed nodeaddress, string reason
    );

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
        EIP712("Noosphere On-chain Verifier", "1")
        Ownable(initialOwner_)
    {
        require(coordinator_ != address(0), "coordinator zero");
        coordinator = ICoordinator(coordinator_);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVerifier
    function fee(address token) external view override returns (uint256 amount) {
        return tokenFees[token];
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

    function submitProofForVerification(
        ProofVerificationRequest calldata request,
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

        emit VerificationRequested(request.subscriptionId, request.interval, request.submitterAddress);

        // hash checks -> failure reports (no revert)
        if (commitmentHash != proofData.commitmentHash) {
            emit VerificationFailed(
                request.subscriptionId, request.interval, request.submitterAddress, "commitmentHash_mismatch"
            );
            coordinator.reportVerificationResult(request, false);
            return;
        }
        if (inputHash != proofData.inputHash) {
            emit VerificationFailed(
                request.subscriptionId, request.interval, request.submitterAddress, "inputHash_mismatch"
            );
            coordinator.reportVerificationResult(request, false);
            return;
        }
        if (resultHash != proofData.resultHash) {
            emit VerificationFailed(
                request.subscriptionId, request.interval, request.submitterAddress, "resultHash_mismatch"
            );
            coordinator.reportVerificationResult(request, false);
            return;
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

        address signer;
        signer = ECDSA.recover(digest, proofData.signature);

        if (signer == address(0)) {
            emit VerificationFailed(
                request.subscriptionId, request.interval, request.submitterAddress, "zero_address_signer"
            );
            coordinator.reportVerificationResult(request, false);
            return;
        }

        if (signer != proofData.nodeAddress) {
            emit VerificationFailed(
                request.subscriptionId, request.interval, request.submitterAddress, "signer_mismatch"
            );
            coordinator.reportVerificationResult(request, false);
            return;
        }

        if (isContract(request.submitterWallet)) {
            bytes4 magic = IERC1271(request.submitterWallet).isValidSignature(digest, proofData.signature);
            if (magic != IERC1271.isValidSignature.selector) {
                emit VerificationFailed(
                    request.subscriptionId, request.interval, request.submitterAddress, "invalid_contract_signature"
                );
                coordinator.reportVerificationResult(request, false);
                return;
            }
        }
        coordinator.reportVerificationResult(request, true);
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
     */
    function setTokenSupported(address token, bool isSupported) external onlyOwner {
        supportedTokens[token] = isSupported;
    }

    /**
     * @notice Owner-only function to update the fee for a specific token.
     * @param token The address of the token.
     * @param amount The new fee amount.
     */
    function setFee(address token, uint256 amount) external onlyOwner {
        tokenFees[token] = amount;
    }

    /**
     * @notice Allows the owner to withdraw the entire ETH balance of the contract.
     */
    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        (bool success,) = owner().call{value: balance}("");
        require(success, "ETH transfer failed");
    }

    /**
     * @notice Allows the owner to withdraw a specific amount of an ERC20 token.
     * @param token The address of the ERC20 token.
     * @param amount The amount of the token to withdraw.
     */
    function withdrawToken(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "Invalid token address");
        IERC20 erc20 = IERC20(token);
        uint256 balance = erc20.balanceOf(address(this));
        require(amount > 0, "Amount must be greater than zero");
        require(amount <= balance, "Insufficient token balance");
        if (!erc20.transfer(owner(), amount)) {
            revert("Token transfer failed");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                FALLBACK
    //////////////////////////////////////////////////////////////*/

    // Allow the contract to receive ETH, even though it doesn't charge fees.
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                              INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }

    function domainSeparator() public view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
