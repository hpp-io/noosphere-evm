// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.4;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @title MockToken
/// @notice Mocks ERC20 token with exposed mint functionality
contract MockToken is ERC20 {
    /// @notice Initializes the mock token with a name and symbol.
    constructor() ERC20("TOKEN", "TOKEN") {}

    /// @notice Overrides ERC20.decimals
    /// @dev Purposefully selects a weird decimal implementation (WBTC) to test accurancy independent of standard
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mints `amount` tokens to `to` address
    /// @param to address to mint tokens to
    /// @param amount quantity of tokens to mint
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
