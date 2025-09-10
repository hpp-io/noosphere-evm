// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

struct Commitment {
    bytes32 requestId;
    uint64 subscriptionId;
    bytes32 containerId;
    uint32 interval;
    bool lazy;
    uint16 redundancy;
    address walletAddress;
    uint256 paymentAmount;
    address paymentToken;
    address verifier;
    address coordinator;
}