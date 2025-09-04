pragma solidity ^0.8.23;

import {IOwnable} from "./IOwnable.sol";
import {IRouter} from "./IRouter.sol";
import {ISubscriptionsManager} from "./ISubscriptionManager.sol";

interface IOwnableRouter is IOwnable, IRouter, ISubscriptionsManager {}