// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {Test} from "forge-std/Test.sol";
import {PayloadRef, PayloadScheme} from "../src/v1_0_0/types/PayloadRef.sol";

/// @title PayloadRefTest
/// @notice Unit tests for PayloadRef struct and PayloadScheme enum
contract PayloadRefTest is Test {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sample IPFS content hash (keccak256 of "test content")
    bytes32 internal constant SAMPLE_CONTENT_HASH = keccak256("test content");

    /// @notice Sample IPFS CID prefix (0x1220 = sha2-256)
    bytes32 internal constant SAMPLE_IPFS_LOCATION = bytes32(uint256(0x1220));

    /// @notice Sample Arweave TX ID
    bytes32 internal constant SAMPLE_AR_TX_ID = bytes32("bNbA3TEQVL60xlgCcqdz4ZPH");

    /*//////////////////////////////////////////////////////////////
                            SCHEME ENUM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PayloadScheme_Values() public pure {
        assertEq(uint8(PayloadScheme.DATA_INLINE), 0);
        assertEq(uint8(PayloadScheme.IPFS), 1);
        assertEq(uint8(PayloadScheme.ARWEAVE), 2);
        assertEq(uint8(PayloadScheme.HTTPS), 3);
        assertEq(uint8(PayloadScheme.CHAIN), 4);
    }

    /*//////////////////////////////////////////////////////////////
                          STRUCT CREATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PayloadRef_CreateInline() public pure {
        PayloadRef memory ref = PayloadRef({
            schemeType: uint8(PayloadScheme.DATA_INLINE),
            contentHash: SAMPLE_CONTENT_HASH,
            locationData: bytes32(0)
        });

        assertEq(ref.schemeType, uint8(PayloadScheme.DATA_INLINE));
        assertEq(ref.contentHash, SAMPLE_CONTENT_HASH);
        assertEq(ref.locationData, bytes32(0));
    }

    function test_PayloadRef_CreateIpfs() public pure {
        PayloadRef memory ref = PayloadRef({
            schemeType: uint8(PayloadScheme.IPFS),
            contentHash: SAMPLE_CONTENT_HASH,
            locationData: SAMPLE_IPFS_LOCATION
        });

        assertEq(ref.schemeType, uint8(PayloadScheme.IPFS));
        assertEq(ref.contentHash, SAMPLE_CONTENT_HASH);
        assertEq(ref.locationData, SAMPLE_IPFS_LOCATION);
    }

    function test_PayloadRef_CreateArweave() public pure {
        PayloadRef memory ref = PayloadRef({
            schemeType: uint8(PayloadScheme.ARWEAVE),
            contentHash: SAMPLE_CONTENT_HASH,
            locationData: SAMPLE_AR_TX_ID
        });

        assertEq(ref.schemeType, uint8(PayloadScheme.ARWEAVE));
        assertEq(ref.contentHash, SAMPLE_CONTENT_HASH);
        assertEq(ref.locationData, SAMPLE_AR_TX_ID);
    }

    /*//////////////////////////////////////////////////////////////
                            ENCODING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PayloadRef_EncodedSize() public pure {
        PayloadRef memory ref = PayloadRef({
            schemeType: uint8(PayloadScheme.IPFS),
            contentHash: SAMPLE_CONTENT_HASH,
            locationData: SAMPLE_IPFS_LOCATION
        });

        // Encode the struct
        bytes memory encoded = abi.encode(ref);

        // abi.encode pads to 32-byte slots:
        // - schemeType (uint8) → 32 bytes (padded)
        // - contentHash (bytes32) → 32 bytes
        // - locationData (bytes32) → 32 bytes
        // Total: 96 bytes with abi.encode
        assertEq(encoded.length, 96);
    }

    function test_PayloadRef_PackedEncodedSize() public pure {
        PayloadRef memory ref = PayloadRef({
            schemeType: uint8(PayloadScheme.IPFS),
            contentHash: SAMPLE_CONTENT_HASH,
            locationData: SAMPLE_IPFS_LOCATION
        });

        // Using abi.encodePacked for compact encoding
        bytes memory packed = abi.encodePacked(
            ref.schemeType,
            ref.contentHash,
            ref.locationData
        );

        // Packed: 1 + 32 + 32 = 65 bytes
        assertEq(packed.length, 65);
    }

    /*//////////////////////////////////////////////////////////////
                            DECODE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PayloadRef_EncodeDecodeCycle() public pure {
        PayloadRef memory original = PayloadRef({
            schemeType: uint8(PayloadScheme.IPFS),
            contentHash: SAMPLE_CONTENT_HASH,
            locationData: SAMPLE_IPFS_LOCATION
        });

        // Encode
        bytes memory encoded = abi.encode(original);

        // Decode
        PayloadRef memory decoded = abi.decode(encoded, (PayloadRef));

        // Verify
        assertEq(decoded.schemeType, original.schemeType);
        assertEq(decoded.contentHash, original.contentHash);
        assertEq(decoded.locationData, original.locationData);
    }

    /*//////////////////////////////////////////////////////////////
                          GAS COMPARISON TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GasComparison_LargePayloadVsPayloadRef() public pure {
        // Simulate large payload (50KB)
        bytes memory largePayload = new bytes(50000);
        for (uint256 i = 0; i < 50000; i++) {
            largePayload[i] = bytes1(uint8(i % 256));
        }

        // PayloadRef (65 bytes packed)
        PayloadRef memory ref = PayloadRef({
            schemeType: uint8(PayloadScheme.IPFS),
            contentHash: keccak256(largePayload),
            locationData: SAMPLE_IPFS_LOCATION
        });

        bytes memory packedRef = abi.encodePacked(
            ref.schemeType,
            ref.contentHash,
            ref.locationData
        );

        // Size comparison
        assertEq(largePayload.length, 50000);
        assertEq(packedRef.length, 65);

        // Gas savings: ~99.87% reduction in calldata size
        assertTrue(packedRef.length < largePayload.length / 100);
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_PayloadRef_AnyScheme(uint8 schemeType) public pure {
        // Bound to valid scheme range (0-4)
        schemeType = uint8(bound(schemeType, 0, 4));

        PayloadRef memory ref = PayloadRef({
            schemeType: schemeType,
            contentHash: SAMPLE_CONTENT_HASH,
            locationData: SAMPLE_IPFS_LOCATION
        });

        assertEq(ref.schemeType, schemeType);
    }

    function testFuzz_PayloadRef_AnyHashes(
        bytes32 contentHash,
        bytes32 locationData
    ) public pure {
        PayloadRef memory ref = PayloadRef({
            schemeType: uint8(PayloadScheme.IPFS),
            contentHash: contentHash,
            locationData: locationData
        });

        assertEq(ref.contentHash, contentHash);
        assertEq(ref.locationData, locationData);
    }
}
