// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Coordinator} from "../Coordinator.sol";
import {IVerifier} from "../interfaces/IVerifier.sol";
import {ICoordinator} from "../interfaces/ICoordinator.sol";
import {IOptimisticVerifier} from "../interfaces/IOptimisticVerifier.sol";

contract OptimisticVerifier is IVerifier, IOptimisticVerifier, Ownable {
    using MerkleProof for bytes32[];

    ICoordinator public coordinator;
    address private _paymentRecipient;
    mapping(address => bool) public supportedToken;
    mapping(address => uint256) private _fee;
    uint256 public defaultChallengeWindow = 10 seconds;
    uint256 public defaultBondLock = 7 days;
    mapping(bytes32 => IOptimisticVerifier.Submission) public submissions;

    event SubmissionRegistered(
        bytes32 indexed key,
        uint64 subscriptionId,
        uint32 interval,
        address node,
        bytes32 execCommitment,
        bytes32 resultDigest,
        bytes32 dataHash,
        uint256 challengeWindowEnds,
        uint256 bondLockEnds
    );
    event CoordinatorChanged(address indexed oldCoordinator, address indexed newCoordinator);
    event FeeUpdated(address indexed token, uint256 amount);
    event PaymentRecipientChanged(address indexed oldRecipient, address indexed newRecipient);
    event TokenSupportChanged(address indexed token, bool supported);
    event TimingUpdated(uint256 challengeWindow, uint256 bondLock);

    constructor(address coordinator_, address paymentRecipient_, address initialOwner_) Ownable(initialOwner_) {
        require(coordinator_ != address(0), "coordinator zero");
        require(paymentRecipient_ != address(0), "paymentRecipient zero");
        coordinator = ICoordinator(coordinator_);
        _paymentRecipient = paymentRecipient_;
        supportedToken[address(0)] = true;
        emit TokenSupportChanged(address(0), true);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function fee(address token) external view override returns (uint256 amount) {
        return _fee[token];
    }

    function paymentRecipient() external view override returns (address recipient) {
        return _paymentRecipient;
    }

    function isPaymentTokenSupported(address token) external view override returns (bool accepted) {
        return supportedToken[token];
    }

    function submissionKey(uint64 subscriptionId, uint32 interval, address node) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(subscriptionId, interval, node));
    }

    /**
     * @notice Submit proof data produced by adapter for verification.
     * @dev Only callable by Coordinator. The `proof` bytes are expected to be abi.encode of:
     *      (uint8 version,
     *       bytes32 execCommitment,
     *       bytes32 resultDigest,
     *       bytes   daBatchId,      // arbitrary-length CID bytes
     *       uint32  leafIndex,
     *       bytes   proof,          // concatenated 32-byte sibling nodes
     *       address adapter,        // optional adapter address
     *       bytes   adapterSig)     // optional adapter signature (65 bytes)
     *
     * The contract stores execCommitment/resultDigest and keccak256(daBatchId) for on-chain reference,
     * and emits events so watchers can fetch the DA via daBatchId from the off-chain proof bytes.
     */
    function submitProofForVerification(
        uint64 subscriptionId,
        uint32 interval,
        address submitter,
        address, /* nodeWallet */
        bytes calldata proof,
        bytes32, /* commitmentHash */
        bytes32, /* inputHash */
        bytes32 /* resultHash */
    ) external override {
        require(msg.sender == address(coordinator), "only coordinator");
        bytes32 key = submissionKey(subscriptionId, interval, submitter);
        require(!submissions[key].finalized && !submissions[key].slashed, "submission closed");

        // Default empty values
        bytes32 execCommitment = bytes32(0);
        bytes32 resultDigest = bytes32(0);
        bytes32 dataHash = bytes32(0);

        // Try decode according to agreed ABI layout. If decoding fails, we revert.
        // Expected layout:
        // (uint8 version, bytes32 execCommitment, bytes32 resultDigest, bytes daBatchId, uint32 leafIndex, bytes proof, address adapter, bytes adapterSig)
        {
            // Minimal length check: need at least 1 + 32 + 32 = 65 bytes to contain version + two 32-byte fields.
            require(proof.length >= 65, "proof too short for header");

            // Decode with abi.decode; will revert if format mismatch
            // Note: decoding dynamic bytes fields reads offsets; calldata decoding works here because we pass `proof` as calldata
            (
                uint8 version,
                bytes32 decodedExec,
                bytes32 decodedResult,
                bytes memory daBatchId,
                /*uint32 leafIndex*/,
                /*bytes memory proofNodes*/,
                /*address adapter*/, /*bytes memory adapterSig*/
            ) = abi.decode(proof, (uint8, bytes32, bytes32, bytes, uint32, bytes, address, bytes));

            // Basic version check (allow only version 1 for now)
            require(version == 1, "unsupported proof version");

            execCommitment = decodedExec;
            resultDigest = decodedResult;

            if (daBatchId.length > 0) {
                dataHash = keccak256(daBatchId);
            } else {
                dataHash = bytes32(0);
            }
        }

        uint256 nowTs = block.timestamp;
        uint256 cEnd = nowTs + defaultChallengeWindow;
        uint256 bEnd = nowTs + defaultBondLock;

        submissions[key] = IOptimisticVerifier.Submission({
            subscriptionId: subscriptionId,
            interval: interval,
            node: submitter,
            execCommitment: execCommitment,
            resultDigest: resultDigest,
            dataHash: dataHash,
            submitAt: nowTs,
            challengeWindowEnds: cEnd,
            bondLockEnds: bEnd,
            finalized: false,
            slashed: false
        });

        // Interface event (IVerifier.expected)
        emit VerificationRequested(subscriptionId, interval, submitter);

        // Keep the original registration event with dataHash for watchers
        emit SubmissionRegistered(
            key, subscriptionId, interval, submitter, execCommitment, resultDigest, dataHash, cEnd, bEnd
        );

        emit ProvisionalSubmitted(subscriptionId, interval, submitter, key, execCommitment, resultDigest, dataHash);
    }

    /**
     * @notice Challenge a submission by providing a leafHash and its Merkle proof (as bytes32[]).
     * @dev For MVP, owner-only action is used for challenge flow; in production this should be open to watchers
     *      with appropriate economic incentives/permissioning.
     */
    function challengeAndSlash(
        uint64 subscriptionId,
        uint32 interval,
        address node,
        bytes32 leafHash,
        bytes32[] calldata proof
    ) external onlyOwner {
        bytes32 key = submissionKey(subscriptionId, interval, node);
        IOptimisticVerifier.Submission storage s = submissions[key];
        require(s.subscriptionId != 0 || s.node != address(0), "unknown submission");
        require(!s.finalized, "already finalized");
        require(!s.slashed, "already slashed");
        require(block.timestamp <= s.challengeWindowEnds, "challenge window passed");
        require(s.execCommitment != bytes32(0), "no execCommitment");

        bool included = MerkleProof.verify(proof, s.execCommitment, leafHash);
        require(included, "leaf not included in commitment");

        emit ChallengeAccepted(key, msg.sender, leafHash);

        if (s.resultDigest != bytes32(0) && leafHash != s.resultDigest) {
            s.slashed = true;
            try coordinator.reportVerificationResult(subscriptionId, interval, node, false) {} catch {}
            emit Slashed(key, msg.sender);
        }
    }

    /// @notice Finalize a single submission as valid if the challenge window passed with no slash.
    /// @dev Anyone (relayer/off-chain) may call this after `challengeWindowEnds`.
    function finalizeSubmission(uint64 subscriptionId, uint32 interval, address node) external onlyOwner {
        bytes32 key = submissionKey(subscriptionId, interval, node);
        IOptimisticVerifier.Submission storage s = submissions[key];

        require(s.subscriptionId != 0 || s.node != address(0), "unknown submission");
        require(!s.finalized, "already finalized");
        require(!s.slashed, "already slashed");
        require(block.timestamp > s.challengeWindowEnds, "challenge window not ended");
        require(s.execCommitment != bytes32(0), "no execCommitment");

        // mark finalized first (prevent reentrancy / double-calls)
        s.finalized = true;

        // Try to notify Coordinator. Use try/catch so if Coordinator call reverts we still mark finalized.
        try coordinator.reportVerificationResult(subscriptionId, interval, node, true) {
        // ok
        }
            catch {
            // Coordinator call failed, but we've already marked finalized locally.
            // Off-chain tooling / operator can later reconcile if needed.
        }

        emit SubmissionFinalized(key, subscriptionId, interval, node);
    }

    /// @notice Finalize multiple submissions in a batch (gas-efficient for relayers).
    /// @dev Accepts arrays of equal length for subscriptionId/interval/node.
    function finalizeBatch(uint64[] calldata subscriptionIds, uint32[] calldata intervals, address[] calldata nodes)
        external
        onlyOwner
    {
        uint256 len = subscriptionIds.length;
        require(intervals.length == len && nodes.length == len, "length mismatch");

        for (uint256 i = 0; i < len; i++) {
            bytes32 key = submissionKey(subscriptionIds[i], intervals[i], nodes[i]);
            IOptimisticVerifier.Submission storage s = submissions[key];

            // Instead of skipping, revert with a reason to make debugging easier for the relayer.
            require(s.subscriptionId != 0 || s.node != address(0), "unknown submission");
            require(!s.finalized, "already finalized");
            require(!s.slashed, "already slashed");
            require(block.timestamp > s.challengeWindowEnds, "challenge window not ended");
            require(s.execCommitment != bytes32(0), "no execCommitment");

            s.finalized = true;

            // Try to notify Coordinator per item. Optionally this could be a single batch call if Coordinator supports it.
            try coordinator.reportVerificationResult(subscriptionIds[i], intervals[i], nodes[i], true) {
            // ok
            }
                catch {
                // swallow errors; record of success/failure can be handled off-chain by reading events or storage
            }

            emit SubmissionFinalized(key, subscriptionIds[i], intervals[i], nodes[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            OWNER-ONLY ACTIONS
    //////////////////////////////////////////////////////////////*/

    function setCoordinator(address newCoordinator) external onlyOwner {
        require(newCoordinator != address(0), "zero coordinator");
        address old = address(coordinator);
        coordinator = ICoordinator(newCoordinator);
        emit CoordinatorChanged(old, newCoordinator);
    }

    function setPaymentRecipient(address recipient) external onlyOwner {
        require(recipient != address(0), "zero recipient");
        address old = _paymentRecipient;
        _paymentRecipient = recipient;
        emit PaymentRecipientChanged(old, recipient);
    }

    function setTokenSupported(address token, bool supported) external onlyOwner {
        supportedToken[token] = supported;
        emit TokenSupportChanged(token, supported);
    }

    function setFeeForToken(address token, uint256 amount) external onlyOwner {
        _fee[token] = amount;
        emit FeeUpdated(token, amount);
    }

    function setDefaultWindows(uint256 challengeWindowSec, uint256 bondLockSec) external onlyOwner {
        defaultChallengeWindow = challengeWindowSec;
        defaultBondLock = bondLockSec;
        emit TimingUpdated(challengeWindowSec, bondLockSec);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function getSubmission(bytes32 key) external view override returns (IOptimisticVerifier.Submission memory) {
        return submissions[key];
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _slice32(bytes calldata b, uint256 index) internal pure returns (bytes32 out) {
        require(b.length >= index + 32, "slice OOB");
        assembly {
            out := calldataload(add(b.offset, index))
        }
    }

    /*//////////////////////////////////////////////////////////////
                                FALLBACK
    //////////////////////////////////////////////////////////////*/

    // Allow the contract to receive ETH
    receive() external payable {}
}
