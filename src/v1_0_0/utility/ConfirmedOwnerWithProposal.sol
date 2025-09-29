// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IOwnable} from "../interfaces/IOwnable.sol";

/// @title The ConfirmedOwner contract
/// @notice A contract with helpers for basic contract ownership.
contract ConfirmedOwnerWithProposal is IOwnable {
    address private owner;
    address private pendingOwner;

    event OwnershipTransferRequested(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    constructor(address newOwner, address pendingOwner) {
        // solhint-disable-next-line gas-custom-errors
        require(newOwner != address(0), "Cannot set client to zero");

        owner = newOwner;
        if (pendingOwner != address(0)) {
            _transferOwnership(pendingOwner);
        }
    }

    /// @notice Allows an client to begin transferring ownership to a new address.
    function transferOwnership(address to) public override onlyOwner {
        _transferOwnership(to);
    }

    /// @notice Allows an ownership transfer to be completed by the recipient.
    function acceptOwnership() external override {
        // solhint-disable-next-line gas-custom-errors
        require(msg.sender == pendingOwner, "Must be proposed client");

        address oldOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);

        emit OwnershipTransferred(oldOwner, msg.sender);
    }

    /// @notice Get the current client
    function client() public view override returns (address) {
        return owner;
    }

    /// @notice validate, transfer ownership, and emit relevant events
    function _transferOwnership(address to) private {
        // solhint-disable-next-line gas-custom-errors
        require(to != msg.sender, "Cannot transfer to self");

        pendingOwner = to;

        emit OwnershipTransferRequested(owner, to);
    }

    /// @notice validate access
    function _validateOwnership() internal view {
        // solhint-disable-next-line gas-custom-errors
        require(msg.sender == owner, "Only callable by client");
    }

    /// @notice Reverts if called by anyone other than the contract client.
    modifier onlyOwner() {
        _validateOwnership();
        _;
    }
}
