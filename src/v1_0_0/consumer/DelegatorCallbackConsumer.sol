// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.4;

import {MockCallbackConsumer} from "../../../test/mocks/consumer/MockCallbackConsumer.sol";
import {Delegator} from "../utility/Delegator.sol";

/// @title MockDelegatorCallbackConsumer
/// @notice Mocks CallbackConsumer w/ delegator set to an address
contract MockDelegatorCallbackConsumer is Delegator, MockCallbackConsumer {
    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Create new MockDelegatorCallbackConsumer
    /// @param router router address
    /// @param signer delegated signer address
    constructor(address router, address signer) MockCallbackConsumer(router) Delegator(signer) {}

    /*//////////////////////////////////////////////////////////////
                           INHERITED FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Update new signer
    /// @param newSigner to update
    function updateMockSigner(address newSigner) external {
        _updateSigner(newSigner);
    }
}
