// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.4;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Coordinator} from "../src/v1_0_0/Coordinator.sol";
import {DeployUtils} from "../test/lib/DeployUtils.sol";
import {ImmediateFinalizeVerifier} from "../src/v1_0_0/verifier/ImmediateFinalizeVerifier.sol";
import {MyTransientClient} from "../src/v1_0_0/sample/MyTransientClient.sol";

/// @title Deploy
/// @notice Deploys noosphere SDK to destination chain defined in environment
contract Deploy is Script {
    function run() public {
        // Read deployer private key from environment (required)
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        require(deployerPrivateKey != 0, "Deploy: PRIVATE_KEY env var required");

        // Start broadcasting transactions using deployer key
        vm.startBroadcast(deployerPrivateKey);

        // Derive deployer address and current nonce
        address deployerAddress = vm.addr(deployerPrivateKey);
        uint256 initialNonce = vm.getNonce(deployerAddress);

        // Log environment details for easier troubleshooting
        console.log("=== Deploy: environment ===");
        console.log("Deployer address:         ", deployerAddress);
        console.log("Chain ID:                 ", block.chainid);
        console.log("Deployer nonce (pre-deploy):", initialNonce);

        // Deploy contracts via DeployUtils
        DeployUtils.DeployedContracts memory contracts =
            DeployUtils.deployContracts(deployerAddress, deployerAddress, 1, address(0));

        // Deploy the new client contract, linking it to the router
        MyTransientClient myClient = new MyTransientClient(address(contracts.router), address(deployerAddress));

        // Wire the Router to the WalletFactory
        contracts.router.setWalletFactory(address(contracts.walletFactory));
        contracts.immediateFinalizeVerifier.setTokenSupported(address(0), true);

        // Summary logs
        console.log("=== Deploy: summary ===");
        console.log("Router:             ", address(contracts.router));
        console.log("MyTransientClient:    ", address(myClient));
        console.log("Coordinator:        ", address(contracts.coordinator));
        console.log("Reader:             ", address(contracts.reader));
        console.log("ImmediateFinalizeVerifier: ", address(contracts.immediateFinalizeVerifier));
        console.log("WalletFactory:      ", address(contracts.walletFactory));
        console.log("MockToken:             ", address(contracts.mockToken));
        console.log("=========================");

        // Stop broadcasting transactions
        vm.stopBroadcast();
    }
}
