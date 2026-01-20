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
        PayloadData input,
        PayloadData output,
        PayloadData proof
    );

    // Optimized event (hashes only)
    event ComputeDeliveredOptimized(
        bytes32 indexed requestId,
        address indexed nodeWallet,
        bytes32 inputHash,
        bytes32 outputHash,
        bytes32 proofHash
    );

    // Storage patterns
    mapping(bytes32 => bool) private commitmentExists;

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
            keccak256("input"),
            keccak256("output"),
            bytes32(0)
        );
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Event with hashes only: ", gasUsed, "gas");
    }

    function test_StorageGas_CommitmentExists() public {
        console.log("\n=== Storage Gas: Commitment Exists ===");

        bytes32 requestId = keccak256("request1");

        uint256 gasBefore = gasleft();
        commitmentExists[requestId] = true;
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Set commitment exists:  ", gasUsed, "gas");

        gasBefore = gasleft();
        delete commitmentExists[requestId];
        gasUsed = gasBefore - gasleft();
        console.log("Delete commitment:      ", gasUsed, "gas");
    }

    function test_FullComparison() public {
        console.log("\n=== Full reportComputeResult Gas Comparison ===");
        console.log("-------------------------------------------");

        bytes32 requestId = keccak256("request1");

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

        // 1. commitmentExists storage (same for both - simplified from nodeResponded)
        gas = gasleft();
        commitmentExists[requestId] = true;
        gas = gas - gasleft();
        totalCurrent += gas;
        totalOptimized += gas;
        console.log("commitmentExists write:  ", gas);

        // 2. Event emission - Current
        gas = gasleft();
        emit ComputeDeliveredCurrent(requestId, address(0x1234), input, output, proof);
        gas = gas - gasleft();
        totalCurrent += gas;
        console.log("Event (current):         ", gas);

        // 3. Event emission - Optimized
        gas = gasleft();
        emit ComputeDeliveredOptimized(requestId, address(0x1234), input.contentHash, output.contentHash, proof.contentHash);
        gas = gas - gasleft();
        totalOptimized += gas;
        console.log("Event (optimized):       ", gas);

        console.log("-------------------------------------------");
        console.log("Total current:           ", totalCurrent);
        console.log("Total optimized:         ", totalOptimized);
        console.log("Potential savings:       ", totalCurrent - totalOptimized);
    }
}
