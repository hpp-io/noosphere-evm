// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.4;

import {Test, console} from "forge-std/Test.sol";
import {PayloadData} from "../src/v1_0_0/types/PayloadData.sol";

/**
 * @title GasMeasurement
 * @notice Measures actual gas costs for PayloadData vs raw bytes
 */
contract GasMeasurement is Test {

    /*//////////////////////////////////////////////////////////////////////////
                                    GAS MEASUREMENT
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Measure calldata cost for raw bytes of various sizes
     */
    function test_GasCost_RawBytes() public {
        console.log("\n=== Raw Bytes Gas Measurement ===");

        // 1KB
        bytes memory data1KB = new bytes(1024);
        for (uint i = 0; i < 1024; i++) {
            data1KB[i] = 0x42; // Non-zero byte
        }
        uint256 gas1KB = gasleft();
        this.consumeRawBytes(data1KB);
        gas1KB = gas1KB - gasleft();
        console.log("1KB raw bytes:  ", gas1KB, "gas");

        // 10KB
        bytes memory data10KB = new bytes(10240);
        for (uint i = 0; i < 10240; i++) {
            data10KB[i] = 0x42;
        }
        uint256 gas10KB = gasleft();
        this.consumeRawBytes(data10KB);
        gas10KB = gas10KB - gasleft();
        console.log("10KB raw bytes: ", gas10KB, "gas");

        // 50KB (near block limit for single call)
        bytes memory data50KB = new bytes(51200);
        for (uint i = 0; i < 51200; i++) {
            data50KB[i] = 0x42;
        }
        uint256 gas50KB = gasleft();
        this.consumeRawBytes(data50KB);
        gas50KB = gas50KB - gasleft();
        console.log("50KB raw bytes: ", gas50KB, "gas");
    }

    /**
     * @notice Measure calldata cost for PayloadData
     */
    function test_GasCost_PayloadData() public {
        console.log("\n=== PayloadData Gas Measurement ===");

        // Inline (empty URI)
        PayloadData memory inlinePayload = PayloadData({
            contentHash: keccak256("test data"),
            uri: ""
        });
        uint256 gasInline = gasleft();
        this.consumePayloadData(inlinePayload);
        gasInline = gasInline - gasleft();
        console.log("Inline (empty uri):     ", gasInline, "gas");

        // IPFS URI (~53 bytes)
        PayloadData memory ipfsPayload = PayloadData({
            contentHash: keccak256("test data"),
            uri: "ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG"
        });
        uint256 gasIpfs = gasleft();
        this.consumePayloadData(ipfsPayload);
        gasIpfs = gasIpfs - gasleft();
        console.log("IPFS URI (~53 bytes):   ", gasIpfs, "gas");

        // HTTPS URI (~80 bytes)
        PayloadData memory httpsPayload = PayloadData({
            contentHash: keccak256("test data"),
            uri: "https://api.noosphere.io/payloads/12345?token=abc123def456"
        });
        uint256 gasHttps = gasleft();
        this.consumePayloadData(httpsPayload);
        gasHttps = gasHttps - gasleft();
        console.log("HTTPS URI (~80 bytes):  ", gasHttps, "gas");
    }

    /**
     * @notice Compare PayloadData vs raw bytes for same logical content
     */
    function test_GasCost_Comparison() public {
        console.log("\n=== Gas Cost Comparison ===");
        console.log("Scenario: 10KB of actual data");
        console.log("-------------------------------------------");

        // Raw bytes approach: send 10KB directly
        bytes memory rawData = new bytes(10240);
        for (uint i = 0; i < 10240; i++) {
            rawData[i] = 0x42;
        }
        uint256 gasRaw = gasleft();
        this.consumeRawBytes(rawData);
        gasRaw = gasRaw - gasleft();
        console.log("Raw bytes (10KB):       ", gasRaw, "gas");

        // PayloadData approach: send hash + IPFS URI
        PayloadData memory payload = PayloadData({
            contentHash: keccak256(rawData),
            uri: "ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG"
        });
        uint256 gasPayload = gasleft();
        this.consumePayloadData(payload);
        gasPayload = gasPayload - gasleft();
        console.log("PayloadData (hash+uri): ", gasPayload, "gas");

        // Calculate savings
        uint256 savings = ((gasRaw - gasPayload) * 100) / gasRaw;
        console.log("-------------------------------------------");
        console.log("Gas savings:            ", savings, "%");
    }

    /**
     * @notice Measure 3x PayloadData (input, output, proof) like reportComputeResult
     */
    function test_GasCost_ThreePayloads() public {
        console.log("\n=== Three PayloadData (reportComputeResult style) ===");

        PayloadData memory input = PayloadData({
            contentHash: keccak256("input data"),
            uri: "ipfs://QmInput123456789012345678901234567890123456"
        });
        PayloadData memory output = PayloadData({
            contentHash: keccak256("output data"),
            uri: "ipfs://QmOutput12345678901234567890123456789012345"
        });
        PayloadData memory proof = PayloadData({
            contentHash: bytes32(0),
            uri: ""
        });

        uint256 gasThree = gasleft();
        this.consumeThreePayloads(input, output, proof);
        gasThree = gasThree - gasleft();
        console.log("3x PayloadData total:   ", gasThree, "gas");

        // Compare with 3x 10KB raw bytes
        bytes memory raw1 = new bytes(10240);
        bytes memory raw2 = new bytes(10240);
        bytes memory raw3 = new bytes(1024);
        for (uint i = 0; i < 10240; i++) {
            raw1[i] = 0x42;
            raw2[i] = 0x42;
        }
        for (uint i = 0; i < 1024; i++) {
            raw3[i] = 0x42;
        }

        uint256 gasRawThree = gasleft();
        this.consumeThreeRaw(raw1, raw2, raw3);
        gasRawThree = gasRawThree - gasleft();
        console.log("3x Raw (10KB+10KB+1KB): ", gasRawThree, "gas");

        uint256 savings = ((gasRawThree - gasThree) * 100) / gasRawThree;
        console.log("-------------------------------------------");
        console.log("Gas savings:            ", savings, "%");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function consumeRawBytes(bytes calldata data) external pure returns (bytes32) {
        return keccak256(data);
    }

    function consumePayloadData(PayloadData calldata payload) external pure returns (bytes32) {
        return payload.contentHash;
    }

    function consumeThreePayloads(
        PayloadData calldata input,
        PayloadData calldata output,
        PayloadData calldata proof
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(input.contentHash, output.contentHash, proof.contentHash));
    }

    function consumeThreeRaw(
        bytes calldata data1,
        bytes calldata data2,
        bytes calldata data3
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(keccak256(data1), keccak256(data2), keccak256(data3)));
    }
}
