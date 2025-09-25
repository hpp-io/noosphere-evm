// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {ITypeAndVersion} from "../interfaces/ITypeAndVersion.sol";
import {IOwnableRouter} from "../interfaces/IOwnableRouter.sol";

abstract contract Routable is ITypeAndVersion {
    IOwnableRouter private immutable I_ROUTER;

    /// event
    error RouterMustBeSet();
    error OnlyCallableByRouter();
    error OnlyCallableByRouterOwner();

    constructor(address router) {
        if (router == address(0)) {
            revert RouterMustBeSet();
        }
        I_ROUTER = IOwnableRouter(router);
    }

    function _getRouter() internal view returns (IOwnableRouter router) {
        return I_ROUTER;
    }

    modifier onlyRouter() {
        if (msg.sender != address(I_ROUTER)) {
            revert OnlyCallableByRouter();
        }
        _;
    }

    modifier onlyRouterOwner() {
        if (msg.sender != I_ROUTER.client()) {
            revert OnlyCallableByRouterOwner();
        }
        _;
    }
}