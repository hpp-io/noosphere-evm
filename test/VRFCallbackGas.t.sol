// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {NoosphereVRF} from "../src/v1_0_0/vrf/NoosphereVRF.sol";
import {INoosphereVRF} from "../src/v1_0_0/vrf/INoosphereVRF.sol";

/// @title VRF Callback Gas Measurement
/// @notice Measures gas for fulfillRandomValue() with pre-decoded params (optimized architecture).
///         External call now only does Merkle verify + storage ops.
contract VRFCallbackGasTest is Test {
    NoosphereVRF public vrf;
    address public constant OWNER = address(0x1);
    address public constant CONSUMER = address(0x2);

    // 4-leaf Merkle tree test vectors
    bytes32 constant RV0 = bytes32(uint256(0x1111111111111111111111111111111111111111111111111111111111111111));
    bytes32 constant RV1 = bytes32(uint256(0x2222222222222222222222222222222222222222222222222222222222222222));
    bytes32 constant RV2 = bytes32(uint256(0x3333333333333333333333333333333333333333333333333333333333333333));
    bytes32 constant RV3 = bytes32(uint256(0x4444444444444444444444444444444444444444444444444444444444444444));

    bytes32 public leaf0;
    bytes32 public leaf1;
    bytes32 public leaf2;
    bytes32 public leaf3;
    bytes32 public node01;
    bytes32 public node23;
    bytes32 public merkleRoot;

    function setUp() public {
        // Mock ArbSys predeploy
        vm.mockCall(address(0x64), abi.encodeWithSignature("arbBlockNumber()"), abi.encode(uint256(100)));
        vm.mockCall(address(0x64), abi.encodeWithSignature("arbBlockHash(uint256)"), abi.encode(keccak256("block100")));

        vrf = new NoosphereVRF(OWNER);

        // Build 4-leaf Merkle tree (OZ commutative hash)
        leaf0 = keccak256(abi.encodePacked(uint256(0), RV0));
        leaf1 = keccak256(abi.encodePacked(uint256(1), RV1));
        leaf2 = keccak256(abi.encodePacked(uint256(2), RV2));
        leaf3 = keccak256(abi.encodePacked(uint256(3), RV3));
        node01 = _commHash(leaf0, leaf1);
        node23 = _commHash(leaf2, leaf3);
        merkleRoot = _commHash(node01, node23);

        vm.startPrank(OWNER);
        vrf.registerEpoch(0, merkleRoot);
        vrf.addConsumer(CONSUMER);
        vm.stopPrank();
    }

    /// @notice Measure gas for fulfillRandomValue with pre-decoded params (optimized architecture)
    function test_CallbackGas_optimizedArchitecture() public {
        vm.startPrank(CONSUMER);
        uint256 requestId = vrf.reserveRequestId();
        vrf.bindRequest(1, 7, requestId);
        vm.stopPrank();

        // Pre-decoded: randomValue + proof (what Consumer now passes after internal decode)
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leaf1;
        proof[1] = node23;

        vm.prank(CONSUMER);
        uint256 gasBefore = gasleft();
        vrf.fulfillRandomValue(1, 7, RV0, proof);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== OPTIMIZED ARCHITECTURE (pre-decoded params) ===");
        console.log("Gas used for fulfillRandomValue():", gasUsed);
        console.log("Under 500k limit:", gasUsed < 500_000);

        // External call should be well under 100k (just Merkle verify + storage)
        assertLt(gasUsed, 100_000, "fulfillRandomValue should use < 100k gas");
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _commHash(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
