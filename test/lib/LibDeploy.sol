// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import "../../src/v1_0_0/types/BillingConfig.sol";
import {BillingConfig} from "../../src/v1_0_0/types/BillingConfig.sol";
import {Coordinator} from "../../src/v1_0_0/Coordinator.sol";
import {Reader} from "../../src/v1_0_0/utility/Reader.sol";
import {Router} from "../../src/v1_0_0/Router.sol";
import {Vm} from "forge-std/Vm.sol";
import {WalletFactory} from "../../src/v1_0_0/wallet/WalletFactory.sol";

/// @title LibDeploy
/// @dev Useful helpers to deploy contracts + register with Registry contract
library LibDeploy {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Setup Vm cheatcode
    /// @dev Can't inherit abstract contracts in libraries, forces us to redeclare
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /*//////////////////////////////////////////////////////////////
                           UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function deployContracts(
        address deployerAddress,
        uint256 /* initialNonce */, // No longer used for address prediction inside this function
        address initialFeeRecipient,
        uint16 initialFee,
        address tokenAddr
    ) internal returns (Router, Coordinator, Reader, WalletFactory) {
        // By breaking the deployment into smaller pieces and using helper functions,
        // we reduce the number of local variables in this function's scope,
        // preventing the "Stack too deep" error.

        // Deploy Router first as it's a dependency for others.
        Router router = new Router();

        // Deploy other contracts, using a helper for the complex Coordinator deployment.
        Coordinator coordinator =
            _deployCoordinator(address(router), deployerAddress, initialFeeRecipient, initialFee, tokenAddr);
        Reader reader = new Reader(address(router), address(coordinator));
        WalletFactory walletFactory = new WalletFactory(address(router));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = "Coordinator_v1.0.0";
        address[] memory addrs = new address[](1);
        addrs[0] = address(coordinator);
        router.proposeContractsUpdate(ids, addrs);
        router.updateContracts();

        return (router, coordinator, reader, walletFactory);
    }

    function updateBillingConfig(
        Coordinator coordinator,
        uint32 verificationTimeout,
        address protocolFeeRecipient,
        uint16 protocolFee,
        uint256 minimumEstimateGasPriceWei,
        uint256 tickNodeFee,
        address tickNodeFeeToken
    ) internal {
        coordinator.updateConfig(
            BillingConfig({
                verificationTimeout: verificationTimeout,
                protocolFeeRecipient: protocolFeeRecipient,
                protocolFee: protocolFee,
                minimumEstimateGasPriceWei: minimumEstimateGasPriceWei,
                tickNodeFee: tickNodeFee,
                tickNodeFeeToken: tickNodeFeeToken
            })
        );
    }


    /// @dev Helper function to deploy the Coordinator to avoid "Stack too deep" errors.
    function _deployCoordinator(
        address routerAddress,
        address owner,
        address initialFeeRecipient,
        uint16 protocolFee,
        address tokenAddr
    ) private returns (Coordinator) {
        // The constructor now only takes the router and owner addresses.
        Coordinator coordinator = new Coordinator(routerAddress, owner);

        // Initialize it in a separate step to avoid constructor/owner issues
        coordinator.initialize(
            BillingConfig({
                verificationTimeout: 1 weeks,
                protocolFeeRecipient: initialFeeRecipient,
                protocolFee: protocolFee,
                minimumEstimateGasPriceWei: 0,
                tickNodeFee: 0,
                tickNodeFeeToken: tokenAddr
            })
        );

        return coordinator;
    }
}
