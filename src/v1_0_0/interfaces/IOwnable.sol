// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

interface IOwnable {
  function owner() external returns (address);

  function transferOwnership(address recipient) external;

  function acceptOwnership() external;
}
