// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Coordinator} from "../../src/v1_0_0/Coordinator.sol";
import {BillingConfig} from "../../src/v1_0_0/types/BillingConfig.sol";
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
        uint256 initialNonce,
        address initialFeeRecipient,
        uint16 initialFee
    )
        internal
        returns (
            Router,
            Coordinator,
            Reader,
            WalletFactory
        )
    {
        address routerAddr = vm.computeCreateAddress(deployerAddress, initialNonce);
        address coordinatorAddr = vm.computeCreateAddress(deployerAddress, initialNonce + 1);
        address readerAddr = vm.computeCreateAddress(deployerAddress, initialNonce + 2);
        address walletFactoryAddr = vm.computeCreateAddress(deployerAddress, initialNonce + 3);


        Router router = new Router(); // This uses nonce: initialNonce + 0
        require(address(router) == routerAddr, "Router address mismatch");
        Coordinator coordinator = new Coordinator(
            routerAddr,
            deployerAddress,
            BillingConfig({
                verificationTimeout: 1 weeks,
                protocolFeeRecipient: initialFeeRecipient,
                protocolFee: initialFee,
                minimumEstimateGasPriceWei: 0,
                tickNodeFee: 0
            })
        );

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = "Coordinator_v1.0.0";
        address[] memory addrs = new address[](1);
        addrs[0] = coordinatorAddr;
        router.proposeContractsUpdate(ids, addrs);
        router.updateContracts();
        Reader reader = new Reader(routerAddr, coordinatorAddr);
        WalletFactory walletFactory = new WalletFactory(routerAddr);
        return (router, coordinator, reader, walletFactory);
    }
}
