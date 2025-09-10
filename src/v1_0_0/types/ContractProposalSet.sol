// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

/// @title Contract Proposal Set
/// @dev Represents a set of proposed contract updates
struct ContractProposalSet {
    /// @notice Array of contract identifiers
    bytes32[] ids;

    /// @notice Array of corresponding contract addresses
    address[] to;
}
