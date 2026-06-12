// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {PayloadData} from "./PayloadData.sol";

/// @notice Pending delivery payload (kept exactly as requested)
struct PendingDelivery {
    uint32 timestamp; // when recorded
    uint64 subscriptionId; // 0 if none
    uint32 interval; // 0 if none
    PayloadData input;
    PayloadData output;
    PayloadData proof;
}
