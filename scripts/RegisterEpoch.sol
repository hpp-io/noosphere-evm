// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {NoosphereVRF} from "@noosphere-evm/v1_0_0/vrf/NoosphereVRF.sol";

contract RegisterEpoch is Script {
    function run() external {
        address vrfAddr = vm.envAddress("NOOSPHERE_VRF_ADDRESS");
        uint256 epoch = vm.envUint("EPOCH");
        bytes32 merkleRoot = vm.envBytes32("MERKLE_ROOT");

        vm.startBroadcast();
        NoosphereVRF(vrfAddr).registerEpoch(epoch, merkleRoot);
        vm.stopBroadcast();

        console.log("Registered epoch", epoch);
        console.logBytes32(merkleRoot);
    }
}
