// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {NoosphereVRF} from "../src/v1_0_0/vrf/NoosphereVRF.sol";

/// @title DeployVRF
/// @notice Deploys the NoosphereVRF singleton contract.
///         The singleton is shared across all consumer dApps on a given chain.
///
/// Required environment variables:
///   PRIVATE_KEY          – Deployer private key (pays gas, becomes initial owner unless overridden)
///   VRF_OWNER            – (Optional) Owner address for the VRF contract. Defaults to deployer.
///
/// Usage:
///   forge script scripts/DeployVRF.sol:DeployVRF --broadcast --rpc-url $RPC_URL
contract DeployVRF is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        require(deployerPrivateKey != 0, "DeployVRF: PRIVATE_KEY env var required");

        address deployerAddress = vm.addr(deployerPrivateKey);

        // Owner defaults to deployer if VRF_OWNER is not set
        address vrfOwner = vm.envOr("VRF_OWNER", deployerAddress);

        console.log("=== DeployVRF: environment ===");
        console.log("Deployer address:", deployerAddress);
        console.log("VRF Owner:       ", vrfOwner);
        console.log("Chain ID:        ", block.chainid);
        console.log("==============================");

        vm.startBroadcast(deployerPrivateKey);

        NoosphereVRF vrf = new NoosphereVRF(vrfOwner);

        vm.stopBroadcast();

        console.log("=== DeployVRF: summary ===");
        console.log("NoosphereVRF:", address(vrf));
        console.log("Owner:       ", vrfOwner);
        console.log("Epoch size:  ", vrf.EPOCH_SIZE());
        console.log("==========================");
    }
}
