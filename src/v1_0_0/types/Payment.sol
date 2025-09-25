// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

/// @title Payment Struct
/// @dev Represents a payment to be made.
struct Payment {
    address recipient;       // Address of the payment recipient
    address feeToken;    // Token address for payment (e.g., ERC20 or address(0) for ETH)
    uint256 feeAmount;   // Amount of the payment
}