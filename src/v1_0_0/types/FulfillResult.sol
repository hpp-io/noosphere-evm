// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

/// @dev Represents the result of a fulfill operation.
/// It indicates whether the fulfillment was successful or why it failed.

enum FulfillResult {
    FULFILLED,
    INVALID_REQUEST_ID,
    INVALID_COMMITMENT
}
