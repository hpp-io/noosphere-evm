// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {PayloadRef} from "./PayloadRef.sol";

/// @notice Pending delivery payload (kept exactly as requested)
struct PendingDelivery {
    uint32 timestamp; // when recorded
    uint64 subscriptionId; // 0 if none
    uint32 interval; // 0 if none
    PayloadRef inputRef;
    PayloadRef outputRef;
    PayloadRef proofRef;
}
