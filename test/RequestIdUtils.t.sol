// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {RequestIdUtils} from "../src/v1_0_0/utility/RequestIdUtils.sol";

contract RequestIdUtilsTest is Test {
    function testPackedMatchesAbiEncodePacked() public {
        uint64 sub = 1;
        uint32 i1 = 1;
        uint32 i2 = 2;

        bytes32 expected1 = keccak256(abi.encodePacked(sub, i1));
        bytes32 got1 = RequestIdUtils.requestIdPacked(sub, i1);
        assertEq(got1, expected1);

        bytes32 expected2 = keccak256(abi.encodePacked(sub, i2));
        bytes32 got2 = RequestIdUtils.requestIdPacked(sub, i2);
        assertEq(got2, expected2);

        assertTrue(got1 != got2);
    }

    function testEncodedMatchesAbiEncode() public {
        uint64 sub = 0x1234;
        uint32 interval = 0x42;

        bytes32 expected = keccak256(abi.encode(sub, interval));
        bytes32 got = RequestIdUtils.requestIdEncoded(sub, interval);
        assertEq(got, expected);
    }

    function testUint256Variant() public {
        uint256 a = 123;
        uint256 b = 456;
        bytes32 expected = keccak256(abi.encode(a, b));
        bytes32 got = RequestIdUtils.requestIdUint256(a, b);
        assertEq(got, expected);
    }
}
