// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {Commitment} from "../types/Commitment.sol";
import {PayloadData} from "../types/PayloadData.sol";
import {TransientComputeClient} from "../client/TransientComputeClient.sol";
import {Delegator} from "../utility/Delegator.sol";
import {INoosphereVRF} from "./INoosphereVRF.sol";

/// @title NoosphereVRFConsumer
/// @notice Abstract contract for dApps that consume Noosphere VRF random values.
/// @dev Inherit this contract and implement the two virtual hooks:
///      - `_onRandomValueReceived(requestId, randomValue, blockHash)` — called on successful verification
///      - `_onRandomValueExpired(requestId)` — called when blockhash is no longer available
///
///      Flow:
///      1. dApp calls `_requestRandomValue(subscriptionId)` — sends compute request + registers with NoosphereVRF
///      2. Node executes VRNG container, delivers result via Noosphere pipeline
///      3. `_receiveCompute()` delegates proof verification to NoosphereVRF singleton
///      4. NoosphereVRF verifies Merkle proof, returns random value + block hash
///      5. Appropriate hook is called based on expiry status
///
///      Subscription management (createSubscription, cancelSubscription) is also provided.
abstract contract NoosphereVRFConsumer is TransientComputeClient, Delegator {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The NoosphereVRF singleton (shared across all consumers)
    INoosphereVRF public immutable noosphereVRF;

    /// @notice Subscription ownership
    mapping(uint64 => address) public subscriptionOwner;

    /// @notice User → subscription IDs
    mapping(address => uint64[]) private userSubscriptions;

    /// @notice Contract owner
    address public owner;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event SubscriptionCreated(uint64 indexed subscriptionId, address indexed owner);

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotOwner();
    error NotSubscriptionOwner();

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address router, address signer, address _noosphereVRF)
        TransientComputeClient(router)
        Delegator(signer)
    {
        noosphereVRF = INoosphereVRF(_noosphereVRF);
        owner = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                        SUBSCRIPTION MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function createSubscription(
        string memory containerId,
        bool useDeliveryInbox,
        address feeToken,
        uint256 feeAmount,
        address wallet,
        address verifier,
        bytes32 routeId
    ) external returns (uint64) {
        uint64 subscriptionId = _createComputeSubscription(
            containerId, useDeliveryInbox, feeToken, feeAmount, wallet, verifier, routeId
        );
        subscriptionOwner[subscriptionId] = msg.sender;
        userSubscriptions[msg.sender].push(subscriptionId);
        emit SubscriptionCreated(subscriptionId, msg.sender);
        return subscriptionId;
    }

    function cancelSubscription(uint64 subscriptionId) external {
        if (subscriptionOwner[subscriptionId] != msg.sender) revert NotSubscriptionOwner();
        _cancelComputeSubscription(subscriptionId);
    }

    /*//////////////////////////////////////////////////////////////
                         REQUEST RANDOM VALUE
    //////////////////////////////////////////////////////////////*/

    /// @notice Request a random value via the Noosphere VRF pipeline
    /// @dev Sends compute request to VRNG container, then registers with NoosphereVRF singleton.
    ///      Uses Peek+Commit pattern: reads nextRequestId first, includes it in container input,
    ///      then registers with NoosphereVRF which assigns the actual requestId.
    /// @param subscriptionId The subscription to use for VRNG
    /// @return requestId The globally unique request ID assigned by NoosphereVRF
    function _requestRandomValue(uint64 subscriptionId) internal returns (uint256 requestId) {
        // Peek at the next request ID (for container input)
        uint256 expectedId = noosphereVRF.nextRequestId();

        // Send compute request to VRNG container
        bytes memory input = abi.encodePacked('{"action":"reveal","game_id":', _uint2str(expectedId), "}");
        (, Commitment memory commitment) = _requestCompute(subscriptionId, input);

        // Register with NoosphereVRF (assigns requestId, records block number)
        requestId = noosphereVRF.requestRandomValue(subscriptionId, commitment.interval);
    }

    /*//////////////////////////////////////////////////////////////
                      CALLBACK (VRF VERIFICATION)
    //////////////////////////////////////////////////////////////*/

    /// @dev Callback from Noosphere compute pipeline. Delegates proof verification to NoosphereVRF.
    function _receiveCompute(
        uint64 subscriptionId,
        uint32 interval,
        bool,
        address,
        PayloadData calldata,
        PayloadData calldata output,
        PayloadData calldata,
        bytes32
    ) internal override {
        // Delegate all verification to NoosphereVRF singleton
        (uint256 requestId, bytes32 randomValue, bytes32 blockHash, bool expired) =
            noosphereVRF.fulfillRandomValue(subscriptionId, interval, output.uri);

        if (expired) {
            _onRandomValueExpired(requestId);
        } else {
            _onRandomValueReceived(requestId, randomValue, blockHash);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          VIRTUAL HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Called when a random value is successfully received and verified
    /// @param requestId The globally unique request ID
    /// @param randomValue The verified random value from the Merkle tree
    /// @param blockHash The L2 block hash for 2-party entropy
    function _onRandomValueReceived(uint256 requestId, bytes32 randomValue, bytes32 blockHash) internal virtual;

    /// @notice Called when a request has expired (blockhash no longer available)
    /// @param requestId The globally unique request ID
    function _onRandomValueExpired(uint256 requestId) internal virtual;

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getUserSubscriptions(address user) external view returns (uint64[] memory) {
        return userSubscriptions[user];
    }

    function getSubscriptionOwner(uint64 subscriptionId) external view returns (address) {
        return subscriptionOwner[subscriptionId];
    }

    function updateSigner(address newSigner) external onlyOwner {
        _updateSigner(newSigner);
    }

    function getRouterAddress() external view returns (address) {
        return address(_getRouter());
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _uint2str(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
