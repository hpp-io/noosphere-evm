// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PayloadData} from "../src/v1_0_0/types/PayloadData.sol";

/// @title PayloadDataTest
/// @notice Unit tests for PayloadData struct
contract PayloadDataTest is Test {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sample IPFS content hash (keccak256 of "test content")
    bytes32 internal constant SAMPLE_CONTENT_HASH = keccak256("test content");

    /*//////////////////////////////////////////////////////////////
                          STRUCT CREATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PayloadData_CreateInline() public pure {
        PayloadData memory data = PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: bytes("data:inline")});

        assertEq(data.contentHash, SAMPLE_CONTENT_HASH);
        assertEq(string(data.uri), "data:inline");
    }

    function test_PayloadData_CreateIpfs() public pure {
        PayloadData memory data = PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: bytes("ipfs://QmTestHash")});

        assertEq(data.contentHash, SAMPLE_CONTENT_HASH);
        assertEq(string(data.uri), "ipfs://QmTestHash");
    }

    function test_PayloadData_CreateArweave() public pure {
        PayloadData memory data =
            PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: bytes("ar://bNbA3TEQVL60xlgCcqdz4ZPH")});

        assertEq(data.contentHash, SAMPLE_CONTENT_HASH);
        assertEq(string(data.uri), "ar://bNbA3TEQVL60xlgCcqdz4ZPH");
    }

    function test_PayloadData_CreateHttps() public pure {
        PayloadData memory data =
            PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: bytes("https://example.com/data")});

        assertEq(data.contentHash, SAMPLE_CONTENT_HASH);
        assertEq(string(data.uri), "https://example.com/data");
    }

    /*//////////////////////////////////////////////////////////////
                            ENCODING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PayloadData_EncodedSize() public pure {
        PayloadData memory data = PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: bytes("ipfs://QmTestHash")});

        // Encode the struct
        bytes memory encoded = abi.encode(data);

        // abi.encode for PayloadData:
        // - contentHash (bytes32) -> 32 bytes
        // - uri (bytes) -> 32 bytes offset + 32 bytes length + ceil(uri.length/32)*32 bytes data
        // For "ipfs://QmTestHash" (17 chars): 32 + 32 + 32 = 96 bytes for uri
        // Total: 32 (contentHash) + 96 (uri with padding) = 128 bytes minimum
        assertTrue(encoded.length >= 96, "Encoded length should be at least 96 bytes");
    }

    /*//////////////////////////////////////////////////////////////
                            DECODE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PayloadData_EncodeDecodeCycle() public pure {
        PayloadData memory original = PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: bytes("ipfs://QmTestHash")});

        // Encode
        bytes memory encoded = abi.encode(original);

        // Decode
        PayloadData memory decoded = abi.decode(encoded, (PayloadData));

        // Verify
        assertEq(decoded.contentHash, original.contentHash);
        assertEq(keccak256(decoded.uri), keccak256(original.uri));
    }

    /*//////////////////////////////////////////////////////////////
                          GAS COMPARISON TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GasComparison_LargePayloadVsPayloadData() public pure {
        // Simulate large payload (50KB)
        bytes memory largePayload = new bytes(50000);
        for (uint256 i = 0; i < 50000; i++) {
            largePayload[i] = bytes1(uint8(i % 256));
        }

        // PayloadData with short URI
        PayloadData memory data = PayloadData({contentHash: keccak256(largePayload), uri: bytes("ipfs://QmTestHash")});

        bytes memory encodedData = abi.encode(data);

        // Size comparison
        assertEq(largePayload.length, 50000);
        assertTrue(
            encodedData.length < largePayload.length / 100, "PayloadData should be much smaller than raw payload"
        );
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_PayloadData_AnyContentHash(bytes32 contentHash) public pure {
        PayloadData memory data = PayloadData({contentHash: contentHash, uri: bytes("data:inline")});

        assertEq(data.contentHash, contentHash);
    }

    function testFuzz_PayloadData_AnyUri(bytes memory uri) public pure {
        PayloadData memory data = PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: uri});

        assertEq(keccak256(data.uri), keccak256(uri));
    }

    /*//////////////////////////////////////////////////////////////
                        URI SCHEME TESTS
    //////////////////////////////////////////////////////////////*/

    function test_UriSchemeComparison() public pure {
        PayloadData memory ipfsData = PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: bytes("ipfs://QmTestHash")});

        PayloadData memory arData = PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: bytes("ar://txid")});

        PayloadData memory httpsData =
            PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: bytes("https://example.com")});

        // Verify different URIs are distinguishable
        assertTrue(keccak256(ipfsData.uri) != keccak256(arData.uri));
        assertTrue(keccak256(ipfsData.uri) != keccak256(httpsData.uri));
        assertTrue(keccak256(arData.uri) != keccak256(httpsData.uri));
    }

    function test_EmptyUri() public pure {
        PayloadData memory data = PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: bytes("")});

        assertEq(data.uri.length, 0);
        assertEq(data.contentHash, SAMPLE_CONTENT_HASH);
    }

    /*//////////////////////////////////////////////////////////////
                        CHAIN SCHEME TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PayloadData_CreateChain() public pure {
        // chain://chainId/txHash/logIndex format
        PayloadData memory data = PayloadData({
            contentHash: SAMPLE_CONTENT_HASH,
            uri: bytes("chain://1/0xabc123def456789012345678901234567890123456789012345678901234abcd/0")
        });

        assertEq(data.contentHash, SAMPLE_CONTENT_HASH);
        assertTrue(data.uri.length > 0);
    }

    /*//////////////////////////////////////////////////////////////
                        LONG URI TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PayloadData_LongHttpsUrl() public pure {
        // Simulate a long HTTPS URL with query parameters (200+ chars)
        bytes memory longUrl = bytes(
            "https://api.noosphere.io/v1/payloads/request-12345678-abcd-efgh-ijkl-mnopqrstuvwx"
            "?token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIn0"
            "&timestamp=1234567890&signature=abcdef123456789012345678901234567890"
        );

        PayloadData memory data = PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: longUrl});

        assertTrue(data.uri.length > 200, "URI should be > 200 chars");
        assertEq(data.contentHash, SAMPLE_CONTENT_HASH);
    }

    function test_PayloadData_VeryLongUri() public pure {
        // Test with 500 character URI
        bytes memory veryLongUrl = new bytes(500);
        // Fill with "https://example.com/" pattern
        bytes memory prefix = bytes("https://example.com/");
        for (uint256 i = 0; i < 500; i++) {
            veryLongUrl[i] = prefix[i % prefix.length];
        }

        PayloadData memory data = PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: veryLongUrl});

        assertEq(data.uri.length, 500);
    }

    /*//////////////////////////////////////////////////////////////
                        DATA URI BASE64 TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PayloadData_DataUriBase64() public pure {
        // Standard data URI with base64 encoded JSON
        // {"action":"ping"} -> eyJhY3Rpb24iOiJwaW5nIn0=
        bytes memory dataUri = bytes("data:application/json;base64,eyJhY3Rpb24iOiJwaW5nIn0=");

        PayloadData memory data = PayloadData({contentHash: keccak256('{"action":"ping"}'), uri: dataUri});

        assertEq(string(data.uri), "data:application/json;base64,eyJhY3Rpb24iOiJwaW5nIn0=");
    }

    function test_PayloadData_DataUriPlainText() public pure {
        // Data URI with plain text
        bytes memory dataUri = bytes("data:text/plain;charset=utf-8,Hello%20World");

        PayloadData memory data = PayloadData({contentHash: keccak256("Hello World"), uri: dataUri});

        assertTrue(data.uri.length > 0);
    }

    /*//////////////////////////////////////////////////////////////
                        CALLDATA GAS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CalldataGas_ShortUri() public pure {
        // IPFS URI (~53 bytes typical)
        bytes memory ipfsUri = bytes("ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG");

        PayloadData memory data = PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: ipfsUri});

        bytes memory encoded = abi.encode(data);

        // Calldata cost estimation:
        // - Zero bytes: 4 gas each
        // - Non-zero bytes: 16 gas each
        // For rough estimate, assume all non-zero: encoded.length * 16
        uint256 estimatedGas = encoded.length * 16;

        // Should be reasonable for short URIs
        assertTrue(estimatedGas < 5000, "Calldata gas should be < 5000 for short URI");
    }

    function test_CalldataGas_LongUri() public pure {
        // Long HTTPS URL (~200 bytes)
        bytes memory longUrl = bytes(
            "https://api.noosphere.io/v1/payloads/request-12345678-abcd-efgh-ijkl-mnopqrstuvwx"
            "?token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0"
        );

        PayloadData memory data = PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: longUrl});

        bytes memory encoded = abi.encode(data);
        uint256 estimatedGas = encoded.length * 16;

        // Even long URIs should have bounded gas cost
        assertTrue(estimatedGas < 10000, "Calldata gas should be bounded for long URI");
    }

    function test_CalldataGas_CompareUriLengths() public pure {
        // Compare gas costs for different URI lengths
        bytes memory shortUri = bytes("ipfs://QmTest");
        bytes memory mediumUri = bytes("https://api.example.com/data/12345");
        bytes memory longUri = bytes("https://api.noosphere.io/v1/payloads/request-12345678?token=abcdef123456789");

        PayloadData memory shortData = PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: shortUri});
        PayloadData memory mediumData = PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: mediumUri});
        PayloadData memory longData = PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: longUri});

        bytes memory shortEncoded = abi.encode(shortData);
        bytes memory mediumEncoded = abi.encode(mediumData);
        bytes memory longEncoded = abi.encode(longData);

        // Verify size ordering
        assertTrue(shortEncoded.length <= mediumEncoded.length, "Short should be <= medium");
        assertTrue(mediumEncoded.length <= longEncoded.length, "Medium should be <= long");
    }

    /*//////////////////////////////////////////////////////////////
                        SPECIAL CHARACTERS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PayloadData_UriWithQueryParams() public pure {
        bytes memory uri = bytes("https://api.example.com/data?key=value&foo=bar&baz=123");

        PayloadData memory data = PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: uri});

        assertEq(string(data.uri), "https://api.example.com/data?key=value&foo=bar&baz=123");
    }

    function test_PayloadData_UriWithEncodedChars() public pure {
        // URL with encoded special characters
        bytes memory uri = bytes("https://api.example.com/data?name=hello%20world&path=%2Froot%2Ffile");

        PayloadData memory data = PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: uri});

        assertTrue(data.uri.length > 0);
    }

    function test_PayloadData_UriWithFragment() public pure {
        bytes memory uri = bytes("https://docs.example.com/api#section-payloads");

        PayloadData memory data = PayloadData({contentHash: SAMPLE_CONTENT_HASH, uri: uri});

        assertEq(string(data.uri), "https://docs.example.com/api#section-payloads");
    }

    /*//////////////////////////////////////////////////////////////
                        CONTENT HASH VERIFICATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PayloadData_ContentHashVerification() public pure {
        bytes memory content = bytes('{"result": "success", "value": 42}');
        bytes32 expectedHash = keccak256(content);

        PayloadData memory data = PayloadData({contentHash: expectedHash, uri: bytes("ipfs://QmTestHash")});

        // Simulate verification: hash of content should match contentHash
        assertEq(keccak256(content), data.contentHash);
    }

    function test_PayloadData_ContentHashMismatchDetection() public pure {
        bytes memory originalContent = bytes('{"result": "success"}');
        bytes memory tamperedContent = bytes('{"result": "failure"}');

        PayloadData memory data =
            PayloadData({contentHash: keccak256(originalContent), uri: bytes("ipfs://QmTestHash")});

        // Tampered content should NOT match
        assertTrue(keccak256(tamperedContent) != data.contentHash);
    }

    /*//////////////////////////////////////////////////////////////
                        MULTIPLE PAYLOADS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PayloadData_MultiplePayloadsEncoding() public pure {
        PayloadData memory input = PayloadData({contentHash: keccak256("input data"), uri: bytes("ipfs://QmInput")});

        PayloadData memory output = PayloadData({contentHash: keccak256("output data"), uri: bytes("ipfs://QmOutput")});

        PayloadData memory proof = PayloadData({contentHash: keccak256("proof data"), uri: bytes("ipfs://QmProof")});

        // Encode all three (simulating reportComputeResult call)
        bytes memory encoded = abi.encode(input, output, proof);

        // Decode and verify
        (PayloadData memory decodedInput, PayloadData memory decodedOutput, PayloadData memory decodedProof) =
            abi.decode(encoded, (PayloadData, PayloadData, PayloadData));

        assertEq(decodedInput.contentHash, input.contentHash);
        assertEq(decodedOutput.contentHash, output.contentHash);
        assertEq(decodedProof.contentHash, proof.contentHash);
    }

    function test_PayloadData_ThreePayloadsGasCost() public pure {
        // Typical scenario: 3 PayloadData for input, output, proof
        PayloadData memory input = PayloadData({contentHash: keccak256("input"), uri: bytes("ipfs://QmInputHash12345")});

        PayloadData memory output =
            PayloadData({contentHash: keccak256("output"), uri: bytes("ipfs://QmOutputHash12345")});

        PayloadData memory proof = PayloadData({contentHash: keccak256("proof"), uri: bytes("ipfs://QmProofHash12345")});

        bytes memory allEncoded = abi.encode(input, output, proof);

        // Estimate total calldata gas for 3 PayloadData
        uint256 estimatedGas = allEncoded.length * 16;

        // Should be reasonable (< 15000 gas for calldata)
        assertTrue(estimatedGas < 15000, "3 PayloadData calldata should be < 15000 gas");
    }
}
