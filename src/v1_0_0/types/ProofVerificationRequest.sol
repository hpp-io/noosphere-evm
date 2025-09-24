// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

struct ProofVerificationRequest {
    uint64 subscriptionId;
    bytes32 requestId;
    address submitterAddress;
    address submitterWallet;
    uint32 expiry;
    uint256 escrowedAmount;
    address escrowToken;
    uint256 slashAmount;
}