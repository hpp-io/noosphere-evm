// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Coordinator} from "../Coordinator.sol";
import {IVerifier} from "../interfaces/IVerifier.sol";
import {ICoordinator} from "../interfaces/ICoordinator.sol";

contract OptimisticVerifier is IVerifier, Ownable {
    using MerkleProof for bytes32[];

    struct Submission {
        uint64 subscriptionId;
        uint32 interval;
        address node;
        bytes32 execCommitment;
        bytes32 resultDigest;
        uint256 submitAt;
        uint256 challengeWindowEnds;
        uint256 bondLockEnds;
        bool finalized;
        bool slashed;
    }

    ICoordinator public coordinator;
    address private _paymentRecipient;
    mapping(address => bool) public supportedToken;
    mapping(address => uint256) private _fee;
    uint256 public defaultChallengeWindow = 1 days;
    uint256 public defaultBondLock = 7 days;
    mapping(bytes32 => Submission) public submissions;

    /// New: emit when verifier registers a provisional submission (useful for watchers)
    event ProvisionalSubmitted(
        uint64 indexed subscriptionId,
        uint32 indexed interval,
        address indexed node,
        bytes32 key,
        bytes32 execCommitment,
        bytes32 resultDigest
    );

    event SubmissionRegistered(
        bytes32 indexed key,
        uint64 subscriptionId,
        uint32 interval,
        address node,
        bytes32 execCommitment,
        bytes32 resultDigest,
        uint256 challengeWindowEnds,
        uint256 bondLockEnds
    );
    event ChallengeAccepted(bytes32 indexed key, address indexed challenger, bytes32 leafHash);
    event Slashed(bytes32 indexed key, address indexed challenger);
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

    function submitProofForVerification(uint64 subscriptionId, uint32 interval, address node, bytes calldata proof)
        external
        override
    {
        require(msg.sender == address(coordinator), "only coordinator");
        bytes32 key = submissionKey(subscriptionId, interval, node);
        require(!submissions[key].finalized && !submissions[key].slashed, "submission closed");

        bytes32 execCommitment;
        bytes32 resultDigest;
        if (proof.length >= 32) {
            execCommitment = bytes32(_slice32(proof, 0));
        }
        if (proof.length >= 64) {
            resultDigest = bytes32(_slice32(proof, 32));
        }

        uint256 nowTs = block.timestamp;
        uint256 cEnd = nowTs + defaultChallengeWindow;
        uint256 bEnd = nowTs + defaultBondLock;

        submissions[key] = Submission({
            subscriptionId: subscriptionId,
            interval: interval,
            node: node,
            execCommitment: execCommitment,
            resultDigest: resultDigest,
            submitAt: nowTs,
            challengeWindowEnds: cEnd,
            bondLockEnds: bEnd,
            finalized: false,
            slashed: false
        });

        // Interface event (IVerifier.expected)
        emit VerificationRequested(subscriptionId, interval, node);

        // Keep the original registration event
        emit SubmissionRegistered(key, subscriptionId, interval, node, execCommitment, resultDigest, cEnd, bEnd);

        emit ProvisionalSubmitted(subscriptionId, interval, node, key, execCommitment, resultDigest);
    }

    function challengeAndSlash(
        uint64 subscriptionId,
        uint32 interval,
        address node,
        bytes32 leafHash,
        bytes32[] calldata proof
    ) external onlyOwner {
        bytes32 key = submissionKey(subscriptionId, interval, node);
        Submission storage s = submissions[key];
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

    /// @notice Emitted when a submission is finalized as valid (no successful challenge within window).
    event SubmissionFinalized(bytes32 indexed key, uint64 subscriptionId, uint32 interval, address node);

    /// @notice Finalize a single submission as valid if the challenge window passed with no slash.
    /// @dev Anyone (relayer/off-chain) may call this after `challengeWindowEnds`.
    function finalizeSubmission(uint64 subscriptionId, uint32 interval, address node) external onlyOwner {
        bytes32 key = submissionKey(subscriptionId, interval, node);
        Submission storage s = submissions[key];

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
            Submission storage s = submissions[key];

            // skip invalid / already handled ones to make batch robust
            if (s.subscriptionId == 0 && s.node == address(0)) continue;
            if (s.finalized || s.slashed) continue;
            if (block.timestamp <= s.challengeWindowEnds) continue;
            if (s.execCommitment == bytes32(0)) continue;

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

    function getSubmission(bytes32 key)
        external
        view
        returns (
            uint64 subscriptionId,
            uint32 interval,
            address node,
            bytes32 execCommitment,
            bytes32 resultDigest,
            uint256 submitAt,
            uint256 challengeWindowEnds,
            uint256 bondLockEnds,
            bool finalized,
            bool slashed
        )
    {
        Submission storage s = submissions[key];
        return (
            s.subscriptionId,
            s.interval,
            s.node,
            s.execCommitment,
            s.resultDigest,
            s.submitAt,
            s.challengeWindowEnds,
            s.bondLockEnds,
            s.finalized,
            s.slashed
        );
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
