// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

struct ProofVerificationRequest {
    uint64 subscriptionId;
    uint32 interval;
    address submitterAddress;
    address submitterWallet;
    uint256 escrowedAmount;
    address escrowToken;
    uint256 slashAmount;
    uint32 expiry;
}
