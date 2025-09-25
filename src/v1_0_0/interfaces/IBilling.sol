// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {BillingConfig} from "../types/BillingConfig.sol";

/// @title IBilling
/// @notice Interface for the Billing contract, which handles all fee calculations,
/// cost estimations, and commitment management.
interface IBilling {
    /// @notice Retrieves the current billing configuration.
    /// @return config The current BillingConfig struct.
    function getConfig() external view returns (BillingConfig memory);

    /// @notice Updates the billing configuration.
    /// @dev Should only be callable by the client.
    /// @param config The new BillingConfig struct.
    function updateConfig(BillingConfig memory config) external;

    /// @notice Gets the protocol fee.
    /// @return The protocol fee as a uint72.
    function getProtocolFee() external view returns (uint72);
}