// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {NoosphereX402Client} from "../src/v1_0_0/client/NoosphereX402Client.sol";

/// @title DeployNoosphereX402Client
/// @notice Deploys the x402 payment gateway client against an existing Noosphere
///         deployment. Does not modify any existing contracts; the deployer
///         only needs the Router address and the operator EOA address.
///
/// Required env:
///   - ROUTER_ADDRESS   : address of the Noosphere Router on the target chain
///   - OPERATOR_EOA     : address authorized to dispatch paid compute requests
///
/// Example usage (HPP Sepolia):
///   ROUTER_ADDRESS=0x480a4f75... \
///   OPERATOR_EOA=0x26907E8d...  \
///   forge script scripts/DeployNoosphereX402Client.sol:DeployNoosphereX402Client \
///     --rpc-url https://sepolia.hpp.io \
///     --private-key $PRIVATE_KEY \
///     --broadcast --verify
contract DeployNoosphereX402Client is Script {
    function run() external {
        address router = vm.envAddress("ROUTER_ADDRESS");
        address operator = vm.envAddress("OPERATOR_EOA");

        console.log("=== DeployNoosphereX402Client ===");
        console.log("Chain ID:        ", block.chainid);
        console.log("Deployer:        ", msg.sender);
        console.log("Router:          ", router);
        console.log("Operator EOA:    ", operator);
        console.log("=================================");

        vm.startBroadcast();
        NoosphereX402Client client = new NoosphereX402Client(router, operator);
        vm.stopBroadcast();

        console.log("Deployed NoosphereX402Client:", address(client));
    }
}
