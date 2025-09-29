// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.4;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DeployUtils} from "../test/lib/DeployUtils.sol";
import {SubscriptionBatchReader} from "../src/v1_0_0/utility/SubscriptionBatchReader.sol";
import {Coordinator} from "../src/v1_0_0/Coordinator.sol";
import {Router} from "../src/v1_0_0/Router.sol";
import {WalletFactory} from "../src/v1_0_0/wallet/WalletFactory.sol";

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
        (Router router, Coordinator coordinator, SubscriptionBatchReader reader, WalletFactory walletFactory) =
                            DeployUtils.deployContracts(deployerAddress, deployerAddress, 1, address(0));

        // Wire the Router to the WalletFactory
        router.setWalletFactory(address(walletFactory));

        // Summary logs
        console.log("=== Deploy: summary ===");
        console.log("Router:        ", address(router));
        console.log("Coordinator:   ", address(coordinator));
        console.log("Reader:        ", address(reader));
        console.log("WalletFactory: ", address(walletFactory));
        console.log("=========================");

        // Stop broadcasting transactions
        vm.stopBroadcast();
    }
}
