// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.4;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {LibDeploy} from "../test/lib/LibDeploy.sol";
import {Reader} from "../src/v1_0_0/utility/Reader.sol";
import {Coordinator} from "../src/v1_0_0/Coordinator.sol";
import {Router} from "../src/v1_0_0/Router.sol";
import {WalletFactory} from "../src/v1_0_0/wallet/WalletFactory.sol";

/// @title Deploy
/// @notice Deploys Infernet SDK to destination chain defined in environment
contract Deploy is Script {
    function run() public { // solhint-disable-line ordering
        // Setup wallet
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Log address
        address deployerAddress = vm.addr(deployerPrivateKey);
        console.log("Loaded deployer: ", deployerAddress);

        // Get deployer address nonce
        uint256 initialNonce = vm.getNonce(deployerAddress);

        // Deploy contracts via LibDeploy
        (Router router, Coordinator coordinator, Reader reader, WalletFactory walletFactory) = LibDeploy
            .deployContracts(deployerAddress, initialNonce, deployerAddress, 1);

        // Complete the setup by linking the Router to the WalletFactory
        router.setWalletFactory(address(walletFactory));

        // Log deployed contracts
        console.log("Using protocol fee: 1%");
        console.log("Deployed Router: ", address(router));
        console.log("Deployed Coordinator: ", address(coordinator));
        console.log("Deployed Reader: ", address(reader));
        console.log("Deployed WalletFactory: ", address(walletFactory));

        // Execute
        vm.stopBroadcast();
    }
}
