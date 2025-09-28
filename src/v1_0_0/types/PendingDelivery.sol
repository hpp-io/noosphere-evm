// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

/// @notice Pending delivery payload (kept exactly as requested)
struct PendingDelivery {
    uint32 timestamp; // when recorded
    uint64 subscriptionId; // 0 if none
    uint32 interval; // 0 if none
    bytes input;
    bytes output;
    bytes proof;
}
