// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

interface IOptimisticVerifier {
    struct Submission {
        uint64 subscriptionId;
        uint32 interval;
        address node;
        bytes32 execCommitment;
        bytes32 resultDigest;
        bytes32 dataHash; // keccak256(daBatchId) for on-chain reference
        uint256 submitAt;
        uint256 challengeWindowEnds;
        uint256 bondLockEnds;
        bool finalized;
        bool slashed;
    }

    /// @notice Emitted when a provisional submission is registered by the coordinator.
    /// @dev This is the primary event the off-chain worker should listen to.
    event ProvisionalSubmitted(
        uint64 indexed subscriptionId,
        uint32 indexed interval,
        address indexed node,
        bytes32 key,
        bytes32 execCommitment,
        bytes32 resultDigest,
        bytes32 dataHash
    );

    /// @notice Emitted when a submission is finalized as valid.
    event SubmissionFinalized(bytes32 indexed key, uint64 subscriptionId, uint32 interval, address node);

    /// @notice Emitted when a challenge is accepted.
    event ChallengeAccepted(bytes32 indexed key, address indexed challenger, bytes32 leafHash);

    /// @notice Emitted when a submission is successfully slashed.
    event Slashed(bytes32 indexed key, address indexed challenger);

    /**
     * @notice Challenge a submission by providing a leafHash and its Merkle proof.
     */
    function challengeAndSlash(
        uint64 subscriptionId,
        uint32 interval,
        address node,
        bytes32 leafHash,
        bytes32[] calldata proof
    ) external;

    /**
     * @notice Finalize a single submission as valid if the challenge window passed with no slash.
     */
    function finalizeSubmission(uint64 subscriptionId, uint32 interval, address node) external;

    /**
     * @notice Finalize a batch of submissions as valid if their challenge windows passed with no slash.
     * @dev This function is useful for gas optimization when finalizing multiple submissions at once.
     */
    function finalizeBatch(uint64[] calldata subscriptionIds, uint32[] calldata intervals, address[] calldata nodes)
        external;

    /**
     * @notice Retrieve a submission's details given its unique key.
     * @param key The unique identifier of the submission.
     */
    function getSubmission(bytes32 key) external view returns (Submission memory);
}
