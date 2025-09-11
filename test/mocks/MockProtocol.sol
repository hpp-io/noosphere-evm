// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.4;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {BillingConfig} from "../../src/v1_0_0/types/BillingConfig.sol";
import {Coordinator} from "../../src/v1_0_0/Coordinator.sol";

/// @title MockProtocol
/// @notice Mocks functionality of a protocol `feeRecipient`
contract MockProtocol {
    /*//////////////////////////////////////////////////////////////
                               IMMUTABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Fee
    Coordinator private immutable COORDINATOR;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// Creates new MockProtocol
    /// @param _coordinator coordinator contract
    constructor(Coordinator _coordinator) {
        // Collect Fee from coordinator
        COORDINATOR = _coordinator;
    }

    /*//////////////////////////////////////////////////////////////
                           INHERITED FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Wrapper function (calling Ownable.updateFee)
    function updateFee(uint16 newFee) external {
        BillingConfig memory billingConfig = COORDINATOR.getConfig();
        billingConfig.protocolFee = newFee;
        COORDINATOR.updateConfig(billingConfig);
    }

    /*//////////////////////////////////////////////////////////////
                           UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns Ether balance of contract
    /// @return Ether balance of this address
    function getEtherBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Returns `token` balance of contract
    /// @param token address of ERC20 token contract
    /// @return `token` balance of this address
    function getTokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                FALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice Allow receiving ETH
    receive() external payable {}
}
