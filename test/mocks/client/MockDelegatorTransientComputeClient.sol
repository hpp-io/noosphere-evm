// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.4;

import "../../../src/v1_0_0/utility/Delegator.sol";
import "./MockTransientComputeClient.sol";

/// @title MockDelegatorTransientComputeClient.sol
/// @notice Mocks TransientComputeClient.sol w/ delegator set to an address
contract MockDelegatorTransientComputeClient is Delegator, MockTransientComputeClient {
    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Create new MockDelegatorTransientComputeClient.sol
    /// @param router router address
    /// @param signer delegated signer address
    constructor(address router, address signer) MockTransientComputeClient(router) Delegator(signer) {}

    /*//////////////////////////////////////////////////////////////
                           INHERITED FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Update new signer
    /// @param newSigner to update
    function updateMockSigner(address newSigner) external {
        _updateSigner(newSigner);
    }
}
