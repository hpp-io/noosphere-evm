// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.4;

import {Test, console} from "forge-std/Test.sol";
import {PayloadData} from "../src/v1_0_0/types/PayloadData.sol";

/**
 * @title ReportComputeResultGas
 * @notice Measures gas costs for different event emission patterns
 */
contract ReportComputeResultGas is Test {
    // Current event (with full PayloadData)
    event ComputeDeliveredCurrent(
        bytes32 indexed requestId,
        address indexed nodeWallet,
        uint16 numRedundantDeliveries,
        PayloadData input,
        PayloadData output,
        PayloadData proof
    );

    // Optimized event (hashes only)
    event ComputeDeliveredOptimized(
        bytes32 indexed requestId,
        address indexed nodeWallet,
        uint16 numRedundantDeliveries,
        bytes32 inputHash,
        bytes32 outputHash,
        bytes32 proofHash
    );

    // Storage patterns
    mapping(bytes32 => address[]) private s_respondedNodes;
    mapping(bytes32 => bool) private nodeResponded;
    mapping(bytes32 => uint16) private redundancyCount;

    // Alternative: bitmap instead of array
    mapping(bytes32 => uint256) private respondedBitmap;

    function test_EventGas_Current() public {
        console.log("\n=== Event Gas: Current (PayloadData) ===");

        PayloadData memory input = PayloadData({
            contentHash: keccak256("input"),
            uri: "ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG"
        });
        PayloadData memory output = PayloadData({
            contentHash: keccak256("output"),
            uri: "ipfs://QmOutput12345678901234567890123456789012345678"
        });
        PayloadData memory proof = PayloadData({
            contentHash: bytes32(0),
            uri: ""
        });

        uint256 gasBefore = gasleft();
        emit ComputeDeliveredCurrent(
            keccak256("request1"),
            address(0x1234),
            1,
            input,
            output,
            proof
        );
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Event with PayloadData: ", gasUsed, "gas");
    }

    function test_EventGas_Optimized() public {
        console.log("\n=== Event Gas: Optimized (hashes only) ===");

        uint256 gasBefore = gasleft();
        emit ComputeDeliveredOptimized(
            keccak256("request1"),
            address(0x1234),
            1,
            keccak256("input"),
            keccak256("output"),
            bytes32(0)
        );
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Event with hashes only: ", gasUsed, "gas");
    }

    function test_StorageGas_ArrayPush() public {
        console.log("\n=== Storage Gas: Array Push ===");

        bytes32 requestId = keccak256("request1");

        uint256 gasBefore = gasleft();
        s_respondedNodes[requestId].push(address(0x1234));
        uint256 gasUsed = gasBefore - gasleft();
        console.log("First array push:  ", gasUsed, "gas");

        gasBefore = gasleft();
        s_respondedNodes[requestId].push(address(0x5678));
        gasUsed = gasBefore - gasleft();
        console.log("Second array push: ", gasUsed, "gas");
    }

    function test_StorageGas_BoolMapping() public {
        console.log("\n=== Storage Gas: Bool Mapping ===");

        bytes32 key1 = keccak256(abi.encode(uint64(1), uint32(1), address(0x1234)));
        bytes32 key2 = keccak256(abi.encode(uint64(1), uint32(1), address(0x5678)));

        uint256 gasBefore = gasleft();
        nodeResponded[key1] = true;
        uint256 gasUsed = gasBefore - gasleft();
        console.log("First bool set:    ", gasUsed, "gas");

        gasBefore = gasleft();
        nodeResponded[key2] = true;
        gasUsed = gasBefore - gasleft();
        console.log("Second bool set:   ", gasUsed, "gas");
    }

    function test_StorageGas_RedundancyCount() public {
        console.log("\n=== Storage Gas: Redundancy Count ===");

        bytes32 requestId = keccak256("request1");

        uint256 gasBefore = gasleft();
        redundancyCount[requestId] = 0;
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Init to 0:         ", gasUsed, "gas");

        gasBefore = gasleft();
        redundancyCount[requestId] = 1;
        gasUsed = gasBefore - gasleft();
        console.log("Update to 1:       ", gasUsed, "gas");

        gasBefore = gasleft();
        redundancyCount[requestId] = 2;
        gasUsed = gasBefore - gasleft();
        console.log("Update to 2:       ", gasUsed, "gas");
    }

    function test_CleanupGas_ArrayDelete() public {
        console.log("\n=== Cleanup Gas: Array Delete ===");

        bytes32 requestId = keccak256("request1");

        // Setup: add 3 responders
        s_respondedNodes[requestId].push(address(0x1));
        s_respondedNodes[requestId].push(address(0x2));
        s_respondedNodes[requestId].push(address(0x3));

        nodeResponded[keccak256(abi.encode(uint64(1), uint32(1), address(0x1)))] = true;
        nodeResponded[keccak256(abi.encode(uint64(1), uint32(1), address(0x2)))] = true;
        nodeResponded[keccak256(abi.encode(uint64(1), uint32(1), address(0x3)))] = true;

        uint256 gasBefore = gasleft();

        // Current cleanup pattern
        address[] storage responders = s_respondedNodes[requestId];
        for (uint256 i = 0; i < responders.length; i++) {
            bytes32 nodeResponseKey = keccak256(abi.encode(uint64(1), uint32(1), responders[i]));
            delete nodeResponded[nodeResponseKey];
        }
        delete s_respondedNodes[requestId];

        uint256 gasUsed = gasBefore - gasleft();
        console.log("Cleanup 3 nodes:   ", gasUsed, "gas");
    }

    function test_FullComparison() public {
        console.log("\n=== Full reportComputeResult Gas Comparison ===");
        console.log("-------------------------------------------");

        // Simulate current pattern costs
        bytes32 requestId = keccak256("request1");
        bytes32 nodeKey = keccak256(abi.encode(uint64(1), uint32(1), msg.sender));

        PayloadData memory input = PayloadData({
            contentHash: keccak256("input"),
            uri: "ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG"
        });
        PayloadData memory output = PayloadData({
            contentHash: keccak256("output"),
            uri: "ipfs://QmOutput12345678901234567890123456789012345678"
        });
        PayloadData memory proof = PayloadData({
            contentHash: bytes32(0),
            uri: ""
        });

        uint256 totalCurrent = 0;
        uint256 totalOptimized = 0;
        uint256 gas;

        // 1. nodeResponded storage (same for both)
        gas = gasleft();
        nodeResponded[nodeKey] = true;
        gas = gas - gasleft();
        totalCurrent += gas;
        totalOptimized += gas;
        console.log("nodeResponded write: ", gas);

        // 2. s_respondedNodes array push (current only)
        gas = gasleft();
        s_respondedNodes[requestId].push(msg.sender);
        gas = gas - gasleft();
        totalCurrent += gas;
        console.log("Array push (current):", gas);

        // 3. redundancyCount update (same for both)
        gas = gasleft();
        redundancyCount[requestId] = 1;
        gas = gas - gasleft();
        totalCurrent += gas;
        totalOptimized += gas;
        console.log("redundancyCount:     ", gas);

        // 4. Event emission - Current
        gas = gasleft();
        emit ComputeDeliveredCurrent(requestId, address(0x1234), 1, input, output, proof);
        gas = gas - gasleft();
        totalCurrent += gas;
        console.log("Event (current):     ", gas);

        // 5. Event emission - Optimized
        gas = gasleft();
        emit ComputeDeliveredOptimized(requestId, address(0x1234), 1, input.contentHash, output.contentHash, proof.contentHash);
        gas = gas - gasleft();
        totalOptimized += gas;
        console.log("Event (optimized):   ", gas);

        console.log("-------------------------------------------");
        console.log("Total current:       ", totalCurrent);
        console.log("Total optimized:     ", totalOptimized);
        console.log("Potential savings:   ", totalCurrent - totalOptimized);
    }
}
