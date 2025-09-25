// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {BillingConfig} from "../../src/v1_0_0/types/BillingConfig.sol";
import {Coordinator} from "../../src/v1_0_0/Coordinator.sol";

/// @title MockProtocol
/// @notice Test helper that simulates a protocol fee recipient and exposes a simple coordinator-facing admin helper.
/// @dev Intended for use in tests. Keeps minimal surface: (1) allow tests to update the Coordinator billing config's
///      `protocolFee` through a convenience API, and (2) helpers to inspect this mock's balances.
contract MockProtocol {
    /*//////////////////////////////////////////////////////////////
                                 IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Reference to the Coordinator that owns billing configuration.
    Coordinator private immutable coordinator;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Construct a MockProtocol bound to an existing Coordinator instance.
    /// @param _coordinator Coordinator contract used to read and update billing configuration.
    constructor(Coordinator _coordinator) {
        require(address(_coordinator) != address(0), "MockProtocol: zero coordinator");
        coordinator = _coordinator;
    }

    /*//////////////////////////////////////////////////////////////
                            CONFIGURATION HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Update the Coordinator's protocol fee value within its BillingConfig.
    /// @dev Convenience wrapper that fetches the current BillingConfig, updates `protocolFee`, and writes it back.
    ///      This exists to make tests able to simulate governance or admin fee changes.
    /// @param newFee New protocol fee value to set (semantic meaning depends on Coordinator/BillingConfig).
    function setProtocolFee(uint16 newFee) external {
        BillingConfig memory cfg = coordinator.getConfig();
        cfg.protocolFee = newFee;
        coordinator.updateConfig(cfg);
    }

    /// @notice Deprecated compatibility wrapper for `setProtocolFee`.
    /// @dev Kept so tests using the older `updateFee` name continue to work.
    /// @param newFee New protocol fee value to set.
    function updateFee(uint16 newFee) external {
        this.setProtocolFee(newFee);
    }

    /*//////////////////////////////////////////////////////////////
                               BALANCE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns this contract's native ETH balance.
    /// @return ethBalance Native ETH balance held by this mock.
    function getEtherBalance() external view returns (uint256 ethBalance) {
        return address(this).balance;
    }

    /// @notice Returns ERC20 token balance of this contract.
    /// @param token ERC20 token contract address to query.
    /// @return tokenBalance Balance of `token` held by this mock.
    function getTokenBalance(address token) external view returns (uint256 tokenBalance) {
        return IERC20(token).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                FALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice Accept native ETH transfers (used by tests).
    receive() external payable {}
}
