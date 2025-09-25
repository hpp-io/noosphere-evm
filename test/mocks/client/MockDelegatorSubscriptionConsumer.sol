// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.4;

import {Delegator} from "../../../src/v1_0_0/utility/Delegator.sol";
import {MockSubscriptionComputeClient} from "../../../test/mocks/client/MockSubscriptionComputeClient.sol";

/// @title MockDelegatorSubscriptionConsumer
/// @notice Mocks SubscriptionComputeClient.sol w/ delegator set to an address
/// @dev Does not contain `updateSigner` function mock because already tested via `MockDelegatorTransientComputeClient.sol`
contract MockDelegatorSubscriptionConsumer is Delegator, MockSubscriptionComputeClient {
    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Create new MockDelegatorSubscriptionConsumer
    /// @param registry registry address
    /// @param signer delegated signer address
    constructor(address registry, address signer) MockSubscriptionComputeClient(registry) Delegator(signer) {}
}
