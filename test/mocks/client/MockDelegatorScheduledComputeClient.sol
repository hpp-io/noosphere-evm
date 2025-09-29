// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.4;

import {Delegator} from "../../../src/v1_0_0/utility/Delegator.sol";
import {MockScheduledComputeClient} from "../../../test/mocks/client/MockScheduledComputeClient.sol";

/// @title MockDelegatorScheduledComputeClient
/// @notice Mocks ScheduledComputeClient.sol w/ delegator set to an address
/// @dev Does not contain `updateSigner` function mock because already tested via `MockDelegatorTransientComputeClient.sol`
contract MockDelegatorScheduledComputeClient is Delegator, MockScheduledComputeClient {
    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Create new MockDelegatorScheduledComputeClient
    /// @param registry registry address
    /// @param signer delegated signer address
    constructor(address registry, address signer) MockScheduledComputeClient(registry) Delegator(signer) {}
}
