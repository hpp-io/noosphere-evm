// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Coordinator} from "./Coordinator.sol";
import {ComputeSubscription} from "./types/ComputeSubscription.sol";
import {Commitment} from "./types/Commitment.sol";

contract DelegateeCoordinator is Coordinator {
    constructor(address routerAddress, address initialOwner) Coordinator(routerAddress, initialOwner) {}

    function reportDelegatedComputeResult(
        uint32 nonce,
        uint32 expiry,
        ComputeSubscription calldata sub,
        bytes calldata signature,
        uint32 deliveryInterval,
        bytes calldata input,
        bytes calldata output,
        bytes calldata proof,
        address nodeWallet
    ) external {
        // By breaking the logic into helper functions, we reduce the stack depth in any single function.
        bytes memory commitmentData =
            _createSubscriptionAndGetCommitmentData(nonce, expiry, sub, signature, deliveryInterval);
        _reportComputeResult(deliveryInterval, input, output, proof, commitmentData, nodeWallet);
    }

    function _createSubscriptionAndGetCommitmentData(
        uint32 nonce,
        uint32 expiry,
        ComputeSubscription calldata sub,
        bytes calldata signature,
        uint32 deliveryInterval
    ) internal returns (bytes memory) {
        uint64 subscriptionId = _getRouter().createSubscriptionDelegatee(nonce, expiry, sub, signature);
        (, Commitment memory commitment) = _getRouter().sendRequest(subscriptionId, deliveryInterval);
        return abi.encode(commitment);
    }
}
