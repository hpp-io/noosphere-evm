// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

struct Commitment {
    bytes32 requestId;
    address coordinator;
    uint64 subscriptionId;
    bytes32 containerId;
    bool lazy;
    address payable verifier;
    uint256 paymentAmount;
    address paymentToken;
    uint32 timeoutTimestamp;
    uint16 redundancy;
    uint32 interval;
}