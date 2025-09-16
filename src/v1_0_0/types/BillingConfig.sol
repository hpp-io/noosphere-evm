// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

/// @title BillingConfig
/// @notice Configuration for billing, fees, and timeouts within the protocol.
struct BillingConfig {
    // Timeout for a request before it can be cancelled.
    uint32 verificationTimeout;
    // The address that receives protocol fees.
    address protocolFeeRecipient;
    // The fee charged by the protocol for each transaction, in basis points (1% = 100).
    uint16 protocolFee;
    // The minimum gas price (in Wei) to be used for cost estimations.
    uint256 minimumEstimateGasPriceWei;
    // The fee paid to the node that triggers a new interval tick.
    uint256 tickNodeFee;

//    address tickNodeFeeToken;
}