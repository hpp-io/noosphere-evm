// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import "../../src/v1_0_0/types/BillingConfig.sol";
import {Commitment} from "../../src/v1_0_0/types/Commitment.sol";
import {ICoordinator} from "../../src/v1_0_0/interfaces/ICoordinator.sol";

/// @dev A mock Coordinator for testing version routing.
contract MockCoordinatorV2 is ICoordinator {
    // solhint-disable-next-line const-name-snakecase
    string public constant typeAndVersion = "Coordinator_v2.0.0";

    function initialize(BillingConfig calldata) external pure {}

    function startRequest(bytes32, uint64, bytes32, uint32, uint16, bool, address, uint256, address, address)
        external
        pure
        override
        returns (Commitment memory)
    {}

    function reportComputeResult(uint32, bytes calldata, bytes calldata, bytes calldata, bytes calldata, address)
        external
        pure
        override
    {}

    function cancelRequest(bytes32) external pure override {}

    function reportVerificationResult(uint64, uint32, address, bool) external pure override {}

    function prepareNextInterval(uint64, uint32, address) external pure override {}

    function getCommitment(uint64, uint32) external pure override returns (Commitment memory) {}
}
