// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

interface ITypeAndVersion {
    function typeAndVersion() external pure returns (string memory);
}
