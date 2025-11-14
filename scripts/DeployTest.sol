// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Coordinator} from "../src/v1_0_0/Coordinator.sol";
import {DeployUtils} from "../test/lib/DeployUtils.sol";
import {ImmediateFinalizeVerifier} from "../src/v1_0_0/verifier/ImmediateFinalizeVerifier.sol";
import {MyTransientClient} from "../src/v1_0_0/sample/MyTransientClient.sol";

/// @title DeployTest
/// @notice Deploys noosphere SDK to destination chain defined in environment
contract DeployTest is Script {
    function run(address _productionOwner, address _initialFeeRecipient) public {
        // The deployer is the address executing the script (e.g., hardware wallet, multisig)
        address deployerAddress = msg.sender;
        require(_productionOwner != address(0), "Deploy: Production owner address cannot be the zero address");

        // Log environment details for easier troubleshooting
        console.log("=== Deploy: environment ===");
        console.log("Deployer address:         ", deployerAddress);
        console.log("Chain ID:                 ", block.chainid);
        console.log("Production Owner:         ", _productionOwner);
        console.log("Deployer nonce (pre-deploy):", vm.getNonce(deployerAddress));
        console.log("=========================");


        vm.startBroadcast();
        // 1. Deploy all contracts using the deployer's address.
        DeployUtils.DeployedContracts memory contracts =
            DeployUtils.deployContracts(deployerAddress, _productionOwner, 1, address(0));

        vm.stopBroadcast();

        uint256 ownerPk = vm.envUint("PRODUCTION_OWNER_PRIVATE_KEY");

        vm.startBroadcast(ownerPk);
        DeployUtils.configureContracts(contracts, _productionOwner, _initialFeeRecipient, 1, address(0));

        // Deploy the new client contract, linking it to the router
        MyTransientClient myClient = new MyTransientClient(address(contracts.router), address(deployerAddress));

        // Stop broadcasting transactions
        vm.stopBroadcast();

        // Summary logs
        console.log("=== Deploy: summary ===");
        console.log("Router:                    ", address(contracts.router));
        console.log("MyTransientClient:         ", address(myClient));
        console.log("Coordinator:               ", address(contracts.coordinator));
        console.log("Reader:                    ", address(contracts.reader));
        console.log("ImmediateFinalizeVerifier: ", address(contracts.immediateFinalizeVerifier));
        console.log("WalletFactory:             ", address(contracts.walletFactory));
        console.log("MockToken:                 ", address(contracts.mockToken));
        console.log("=========================");
    }
}
