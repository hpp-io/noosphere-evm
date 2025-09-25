// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

/// @notice Interface for the WalletFactory, used to verify wallet authenticity.
interface IWalletFactory {
    /// @notice Checks if a given address is a valid wallet created by this factory.
    function isValidWallet(address wallet) external view returns (bool);
}