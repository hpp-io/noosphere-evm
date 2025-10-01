// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.23;

/// @title MockMultiSigWallet
/// @notice A simple mock multi-sig wallet contract for testing purposes.
/// @dev Instead of complex approval logic of a real multi-sig, this contract executes a transaction
///      if called by any of its owners.
contract MockMultiSigWallet {
    address[] public owners;
    mapping(address => bool) public isOwner;

    event Execution(address indexed to, bytes data, bool success, bytes returnData);

    /// @param _owners An array of initial owner addresses for the multi-sig wallet.
    constructor(address[] memory _owners) {
        require(_owners.length > 0, "Owners required");
        address[] memory localOwners = new address[](_owners.length);
        for (uint256 i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            require(owner != address(0), "Invalid owner");
            require(!isOwner[owner], "Duplicate owner");
            isOwner[owner] = true;
            localOwners[i] = owner;
        }
        owners = localOwners;
    }

    /// @notice Executes a function call on another contract through this wallet. Can only be called by an owner.
    /// @param to The address of the contract to call.
    /// @param data The encoded function data (calldata) to execute.
    function execute(address to, bytes calldata data) external returns (bool, bytes memory) {
        require(isOwner[msg.sender], "Not an owner");
        (bool success, bytes memory result) = to.call(data);
        if (success) {
            emit Execution(to, data, true, result);
        } else {
            emit Execution(to, data, false, result);
        }
        return (success, result);
    }
}
