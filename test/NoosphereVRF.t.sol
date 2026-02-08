// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {NoosphereVRF} from "../src/v1_0_0/vrf/NoosphereVRF.sol";
import {INoosphereVRF} from "../src/v1_0_0/vrf/INoosphereVRF.sol";
import {NoosphereVRFConsumer} from "../src/v1_0_0/vrf/NoosphereVRFConsumer.sol";
import {Commitment} from "../src/v1_0_0/types/Commitment.sol";
import {PayloadData} from "../src/v1_0_0/types/PayloadData.sol";

/*//////////////////////////////////////////////////////////////
                            MOCKS
//////////////////////////////////////////////////////////////*/

/// @dev Minimal router mock — returns sequential subscription IDs
contract MockRouter {
    uint64 private _nextSubId = 1;

    function createComputeSubscription(
        string memory,
        uint32,
        uint32,
        bool,
        address,
        uint256,
        address,
        address,
        bytes32
    ) external returns (uint64) {
        return _nextSubId++;
    }

    function cancelComputeSubscription(uint64) external {}
}

/// @dev Concrete VRF consumer for testing
contract TestVRFConsumer is NoosphereVRFConsumer {
    constructor(address router, address signer, address vrfAddr) NoosphereVRFConsumer(router, signer, vrfAddr) {}

    function _onRandomValueReceived(uint256, bytes32, bytes32) internal override {}
    function _onRandomValueExpired(uint256) internal override {}

    function typeAndVersion() external pure override returns (string memory) {
        return "TestVRFConsumer_v1.0.0";
    }
}

/*//////////////////////////////////////////////////////////////
            NoosphereVRF — CORE FUNCTIONALITY TESTS
//////////////////////////////////////////////////////////////*/

contract NoosphereVRFCoreTest is Test {
    NoosphereVRF public vrf;
    address public constant OWNER = address(0x1);
    address public constant CONSUMER = address(0x2);

    // 4-leaf Merkle tree test vectors
    bytes32 constant RV0 = bytes32(uint256(0x1111111111111111111111111111111111111111111111111111111111111111));
    bytes32 constant RV1 = bytes32(uint256(0x2222222222222222222222222222222222222222222222222222222222222222));
    bytes32 constant RV2 = bytes32(uint256(0x3333333333333333333333333333333333333333333333333333333333333333));
    bytes32 constant RV3 = bytes32(uint256(0x4444444444444444444444444444444444444444444444444444444444444444));

    bytes32 public leaf0;
    bytes32 public leaf1;
    bytes32 public leaf2;
    bytes32 public leaf3;
    bytes32 public node01;
    bytes32 public node23;
    bytes32 public merkleRoot;

    function setUp() public {
        // Mock ArbSys predeploy at 0x64
        vm.mockCall(address(0x64), abi.encodeWithSignature("arbBlockNumber()"), abi.encode(uint256(100)));
        vm.mockCall(
            address(0x64),
            abi.encodeWithSignature("arbBlockHash(uint256)"),
            abi.encode(keccak256("block100"))
        );

        vrf = new NoosphereVRF(OWNER);

        // Build 4-leaf Merkle tree (OZ commutative hash)
        leaf0 = keccak256(abi.encodePacked(uint256(0), RV0));
        leaf1 = keccak256(abi.encodePacked(uint256(1), RV1));
        leaf2 = keccak256(abi.encodePacked(uint256(2), RV2));
        leaf3 = keccak256(abi.encodePacked(uint256(3), RV3));
        node01 = _commHash(leaf0, leaf1);
        node23 = _commHash(leaf2, leaf3);
        merkleRoot = _commHash(node01, node23);

        vm.startPrank(OWNER);
        vrf.registerEpoch(0, merkleRoot);
        vrf.addConsumer(CONSUMER);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         EPOCH MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function test_registerEpoch() public view {
        assertEq(vrf.getEpochRoot(0), merkleRoot);
    }

    function test_registerEpoch_emitsEvent() public {
        vm.prank(OWNER);
        vm.expectEmit(true, false, false, true);
        emit INoosphereVRF.EpochRegistered(1, bytes32(uint256(0xBEEF)), 1000);
        vrf.registerEpoch(1, bytes32(uint256(0xBEEF)));
    }

    function test_registerEpoch_duplicate_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(NoosphereVRF.EpochAlreadyRegistered.selector);
        vrf.registerEpoch(0, bytes32(uint256(0xBEEF)));
    }

    function test_registerEpoch_onlyOwner() public {
        vm.prank(address(0x999));
        vm.expectRevert(NoosphereVRF.NotOwner.selector);
        vrf.registerEpoch(1, bytes32(uint256(0xBEEF)));
    }

    function test_getCurrentEpoch() public view {
        assertEq(vrf.getCurrentEpoch(), 0);
    }

    function test_getEpochRemaining() public {
        assertEq(vrf.getEpochRemaining(), 1000);

        vm.prank(CONSUMER);
        vrf.reserveRequestId();
        assertEq(vrf.getEpochRemaining(), 999);
    }

    function test_getEpochRemaining_noEpoch() public {
        NoosphereVRF freshVrf = new NoosphereVRF(address(this));
        assertEq(freshVrf.getEpochRemaining(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                       CONSUMER MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function test_addConsumer() public {
        address newConsumer = address(0x50);
        assertFalse(vrf.isAuthorizedConsumer(newConsumer));

        vm.prank(OWNER);
        vm.expectEmit(true, false, false, false);
        emit INoosphereVRF.ConsumerAdded(newConsumer);
        vrf.addConsumer(newConsumer);

        assertTrue(vrf.isAuthorizedConsumer(newConsumer));
    }

    function test_removeConsumer() public {
        assertTrue(vrf.isAuthorizedConsumer(CONSUMER));

        vm.prank(OWNER);
        vm.expectEmit(true, false, false, false);
        emit INoosphereVRF.ConsumerRemoved(CONSUMER);
        vrf.removeConsumer(CONSUMER);

        assertFalse(vrf.isAuthorizedConsumer(CONSUMER));
    }

    function test_addConsumer_onlyOwner() public {
        vm.prank(address(0x999));
        vm.expectRevert(NoosphereVRF.NotOwner.selector);
        vrf.addConsumer(address(0x50));
    }

    /*//////////////////////////////////////////////////////////////
                           OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    function test_transferOwnership() public {
        address newOwner = address(0x99);
        vm.prank(OWNER);
        vrf.transferOwnership(newOwner);
        assertEq(vrf.owner(), newOwner);

        // Old owner can no longer act
        vm.prank(OWNER);
        vm.expectRevert(NoosphereVRF.NotOwner.selector);
        vrf.addConsumer(address(0x50));
    }

    /*//////////////////////////////////////////////////////////////
                          CONSTANTS
    //////////////////////////////////////////////////////////////*/

    function test_constants() public view {
        assertEq(vrf.BLOCKHASH_TIMEOUT(), 256);
        assertEq(vrf.EPOCH_SIZE(), 1000);
    }

    function test_typeAndVersion() public view {
        assertEq(vrf.typeAndVersion(), "NoosphereVRF_v1.0.0");
    }

    /*//////////////////////////////////////////////////////////////
               reserveRequestId + bindRequest (Fix #1)
    //////////////////////////////////////////////////////////////*/

    function test_reserveRequestId_incrementsCounter() public {
        vm.startPrank(CONSUMER);
        uint256 id0 = vrf.reserveRequestId();
        uint256 id1 = vrf.reserveRequestId();
        vm.stopPrank();

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(vrf.nextRequestId(), 2);
    }

    function test_reserveRequestId_recordsBlock() public {
        vm.prank(CONSUMER);
        uint256 id = vrf.reserveRequestId();
        assertEq(vrf.getRequestBlock(id), 100);
    }

    function test_reserveRequestId_unauthorized_reverts() public {
        vm.prank(address(0x999));
        vm.expectRevert(NoosphereVRF.NotAuthorizedConsumer.selector);
        vrf.reserveRequestId();
    }

    function test_reserveRequestId_noEpoch_reverts() public {
        NoosphereVRF freshVrf = new NoosphereVRF(address(this));
        freshVrf.addConsumer(CONSUMER);

        vm.prank(CONSUMER);
        vm.expectRevert(NoosphereVRF.EpochNotRegistered.selector);
        freshVrf.reserveRequestId();
    }

    function test_bindRequest_succeeds() public {
        vm.prank(CONSUMER);
        uint256 id = vrf.reserveRequestId();

        vm.prank(CONSUMER);
        vrf.bindRequest(1, 42, id);
    }

    function test_bindRequest_invalidRequestId_reverts() public {
        vm.prank(CONSUMER);
        vm.expectRevert(NoosphereVRF.InvalidRequestId.selector);
        vrf.bindRequest(1, 42, 999);
    }

    function test_bindRequest_unauthorized_reverts() public {
        vm.prank(CONSUMER);
        uint256 id = vrf.reserveRequestId();

        vm.prank(address(0x999));
        vm.expectRevert(NoosphereVRF.NotAuthorizedConsumer.selector);
        vrf.bindRequest(1, 42, id);
    }

    function test_reserveAndBind_atomicFlow() public {
        vm.startPrank(CONSUMER);
        uint256 id = vrf.reserveRequestId();
        vrf.bindRequest(1, 7, id);
        vm.stopPrank();

        assertEq(id, 0);
        assertEq(vrf.getRequestBlock(id), 100);
    }

    function test_multipleConsumers_noIdClash() public {
        address consumer2 = address(0x3);
        vm.prank(OWNER);
        vrf.addConsumer(consumer2);

        vm.prank(CONSUMER);
        uint256 id1 = vrf.reserveRequestId();

        vm.prank(consumer2);
        uint256 id2 = vrf.reserveRequestId();

        assertEq(id1, 0);
        assertEq(id2, 1);
    }

    function test_interleavedReserveAndBind() public {
        address consumer2 = address(0x3);
        vm.prank(OWNER);
        vrf.addConsumer(consumer2);

        vm.prank(CONSUMER);
        uint256 idA = vrf.reserveRequestId();

        vm.prank(consumer2);
        uint256 idB = vrf.reserveRequestId();

        // Both bind — each gets their own reserved ID
        vm.prank(CONSUMER);
        vrf.bindRequest(10, 1, idA);

        vm.prank(consumer2);
        vrf.bindRequest(20, 1, idB);

        assertEq(idA, 0);
        assertEq(idB, 1);
    }

    function test_epochRunningLow_emitsAt100Remaining() public {
        vm.startPrank(CONSUMER);
        for (uint256 i = 0; i < 900; i++) {
            vrf.reserveRequestId();
        }

        // Request #900: usedInEpoch=901, remaining=99 → emits
        vm.expectEmit(true, false, false, true);
        emit INoosphereVRF.EpochRunningLow(0, 99);
        vrf.reserveRequestId();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
             fulfillRandomValue — FULL FLOW
    //////////////////////////////////////////////////////////////*/

    function test_fulfillRandomValue_fullFlow() public {
        vm.startPrank(CONSUMER);
        uint256 requestId = vrf.reserveRequestId();
        vrf.bindRequest(1, 7, requestId);

        // Build data URI with proof for leaf0: [leaf1, node23]
        bytes memory rawBytes = abi.encodePacked(RV0, leaf1, node23);
        bytes memory uri = _buildDataUri(rawBytes);

        (uint256 retId, bytes32 retRv, bytes32 retBlockHash, bool expired) = vrf.fulfillRandomValue(1, 7, uri);
        vm.stopPrank();

        assertEq(retId, requestId);
        assertEq(retRv, RV0);
        assertTrue(retBlockHash != bytes32(0));
        assertFalse(expired);
    }

    function test_fulfillRandomValue_emitsEvent() public {
        vm.startPrank(CONSUMER);
        uint256 requestId = vrf.reserveRequestId();
        vrf.bindRequest(1, 7, requestId);

        bytes memory rawBytes = abi.encodePacked(RV0, leaf1, node23);
        bytes memory uri = _buildDataUri(rawBytes);

        vm.expectEmit(true, false, false, true);
        emit INoosphereVRF.RandomValueVerified(requestId, RV0, keccak256("block100"));
        vrf.fulfillRandomValue(1, 7, uri);
        vm.stopPrank();
    }

    function test_fulfillRandomValue_replayReverts() public {
        vm.startPrank(CONSUMER);
        vrf.reserveRequestId();
        vrf.bindRequest(1, 7, 0);

        bytes memory rawBytes = abi.encodePacked(RV0, leaf1, node23);
        bytes memory uri = _buildDataUri(rawBytes);

        vrf.fulfillRandomValue(1, 7, uri);

        vm.expectRevert(NoosphereVRF.AlreadyFulfilledOrInvalid.selector);
        vrf.fulfillRandomValue(1, 7, uri);
        vm.stopPrank();
    }

    function test_fulfillRandomValue_invalidProof_reverts() public {
        vm.startPrank(CONSUMER);
        vrf.reserveRequestId();
        vrf.bindRequest(1, 7, 0);

        // Wrong proof: leaf2 instead of leaf1
        bytes memory rawBytes = abi.encodePacked(RV0, leaf2, node23);
        bytes memory uri = _buildDataUri(rawBytes);

        vm.expectRevert(NoosphereVRF.InvalidMerkleProof.selector);
        vrf.fulfillRandomValue(1, 7, uri);
        vm.stopPrank();
    }

    function test_fulfillRandomValue_expired() public {
        vm.startPrank(CONSUMER);
        vrf.reserveRequestId();
        vrf.bindRequest(1, 7, 0);
        vm.stopPrank();

        // Mock expired block hash (return 0)
        vm.mockCall(address(0x64), abi.encodeWithSignature("arbBlockHash(uint256)"), abi.encode(bytes32(0)));

        bytes memory rawBytes = abi.encodePacked(RV0, leaf1, node23);
        bytes memory uri = _buildDataUri(rawBytes);

        vm.prank(CONSUMER);
        (uint256 retId,, bytes32 retBlockHash, bool expired) = vrf.fulfillRandomValue(1, 7, uri);

        assertEq(retId, 0);
        assertEq(retBlockHash, bytes32(0));
        assertTrue(expired);
    }

    function test_fulfillRandomValue_secondLeaf() public {
        vm.startPrank(CONSUMER);
        // Reserve 2 IDs, use the second one (index 1 in epoch)
        vrf.reserveRequestId(); // id=0
        uint256 requestId = vrf.reserveRequestId(); // id=1
        vrf.bindRequest(1, 8, requestId);

        // Proof for leaf1 (index=1): [leaf0, node23]
        bytes memory rawBytes = abi.encodePacked(RV1, leaf0, node23);
        bytes memory uri = _buildDataUri(rawBytes);

        (uint256 retId, bytes32 retRv,, bool expired) = vrf.fulfillRandomValue(1, 8, uri);
        vm.stopPrank();

        assertEq(retId, 1);
        assertEq(retRv, RV1);
        assertFalse(expired);
    }

    /*//////////////////////////////////////////////////////////////
                       REQUEST EXPIRY
    //////////////////////////////////////////////////////////////*/

    function test_isRequestExpired_notExpired() public {
        vm.prank(CONSUMER);
        uint256 id = vrf.reserveRequestId();
        assertFalse(vrf.isRequestExpired(id));
    }

    function test_isRequestExpired_expired() public {
        vm.prank(CONSUMER);
        uint256 id = vrf.reserveRequestId();

        // Advance block past timeout (100 + 256 + 1 = 357)
        vm.mockCall(address(0x64), abi.encodeWithSignature("arbBlockNumber()"), abi.encode(uint256(400)));
        assertTrue(vrf.isRequestExpired(id));
    }

    function test_isRequestExpired_afterFulfillment() public {
        vm.startPrank(CONSUMER);
        vrf.reserveRequestId();
        vrf.bindRequest(1, 7, 0);

        bytes memory rawBytes = abi.encodePacked(RV0, leaf1, node23);
        bytes memory uri = _buildDataUri(rawBytes);
        vrf.fulfillRandomValue(1, 7, uri);
        vm.stopPrank();

        // After fulfillment, blockNum is deleted → treated as expired
        assertTrue(vrf.isRequestExpired(0));
    }

    function test_getRequestBlock_afterFulfillment() public {
        vm.startPrank(CONSUMER);
        vrf.reserveRequestId();
        vrf.bindRequest(1, 7, 0);

        bytes memory rawBytes = abi.encodePacked(RV0, leaf1, node23);
        bytes memory uri = _buildDataUri(rawBytes);
        vrf.fulfillRandomValue(1, 7, uri);
        vm.stopPrank();

        // Block number deleted after fulfillment (gas refund)
        assertEq(vrf.getRequestBlock(0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                  InvalidOutputData error (Fix #4)
    //////////////////////////////////////////////////////////////*/

    function test_InvalidOutputData_errorExists() public pure {
        bytes4 selector = NoosphereVRF.InvalidOutputData.selector;
        assertTrue(selector != bytes4(0));
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _commHash(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _buildDataUri(bytes memory rawBytes) internal pure returns (bytes memory) {
        string memory inner = _base64Encode(rawBytes);
        string memory outer = _base64Encode(bytes(inner));
        return abi.encodePacked("data:;base64,", outer);
    }

    function _base64Encode(bytes memory data) internal pure returns (string memory) {
        bytes memory TABLE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        if (data.length == 0) return "";

        uint256 encodedLen = 4 * ((data.length + 2) / 3);
        bytes memory result = new bytes(encodedLen);

        for (uint256 i = 0; i < data.length; i += 3) {
            uint256 a = uint8(data[i]);
            uint256 b = (i + 1 < data.length) ? uint8(data[i + 1]) : 0;
            uint256 c = (i + 2 < data.length) ? uint8(data[i + 2]) : 0;
            uint256 triple = (a << 16) | (b << 8) | c;

            uint256 j = (i / 3) * 4;
            result[j] = TABLE[(triple >> 18) & 0x3F];
            result[j + 1] = TABLE[(triple >> 12) & 0x3F];
            result[j + 2] = (i + 1 < data.length) ? TABLE[(triple >> 6) & 0x3F] : bytes1("=");
            result[j + 3] = (i + 2 < data.length) ? TABLE[triple & 0x3F] : bytes1("=");
        }

        return string(result);
    }
}

/*//////////////////////////////////////////////////////////////
        NoosphereVRFConsumer TESTS (Fix #2, #5 + basics)
//////////////////////////////////////////////////////////////*/

contract NoosphereVRFConsumerTest is Test {
    TestVRFConsumer public consumer;
    MockRouter public router;
    NoosphereVRF public vrf;

    address public constant USER1 = address(0x10);
    address public constant USER2 = address(0x20);

    // Re-declare events for expectEmit
    event SubscriptionCreated(uint64 indexed subscriptionId, address indexed owner);
    event SubscriptionCancelled(uint64 indexed subscriptionId, address indexed owner);

    function setUp() public {
        vm.mockCall(address(0x64), abi.encodeWithSignature("arbBlockNumber()"), abi.encode(uint256(100)));

        router = new MockRouter();
        vrf = new NoosphereVRF(address(this));
        vrf.registerEpoch(0, bytes32(uint256(0xDEAD)));
        consumer = new TestVRFConsumer(address(router), address(this), address(vrf));
        vrf.addConsumer(address(consumer));
    }

    function _createSub(address user) internal returns (uint64) {
        vm.prank(user);
        return consumer.createSubscription("vrng", false, address(0), 0, address(0), address(0), bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
                    createSubscription basics
    //////////////////////////////////////////////////////////////*/

    function test_createSubscription_recordsOwner() public {
        uint64 sub = _createSub(USER1);
        assertEq(consumer.getSubscriptionOwner(sub), USER1);
    }

    function test_createSubscription_addsToUserList() public {
        _createSub(USER1);
        _createSub(USER1);
        assertEq(consumer.getUserSubscriptionCount(USER1), 2);
    }

    function test_createSubscription_emitsEvent() public {
        vm.prank(USER1);
        vm.expectEmit(true, true, false, false);
        emit SubscriptionCreated(1, USER1); // MockRouter returns 1 for first sub
        consumer.createSubscription("vrng", false, address(0), 0, address(0), address(0), bytes32(0));
    }

    function test_createSubscription_multipleUsers_isolated() public {
        _createSub(USER1);
        _createSub(USER1);
        _createSub(USER2);

        assertEq(consumer.getUserSubscriptionCount(USER1), 2);
        assertEq(consumer.getUserSubscriptionCount(USER2), 1);
    }

    /*//////////////////////////////////////////////////////////////
              cancelSubscription cleanup (Fix #2)
    //////////////////////////////////////////////////////////////*/

    function test_cancelSubscription_removesFromArray() public {
        uint64 sub1 = _createSub(USER1);
        uint64 sub2 = _createSub(USER1);
        uint64 sub3 = _createSub(USER1);
        assertEq(consumer.getUserSubscriptionCount(USER1), 3);

        vm.prank(USER1);
        consumer.cancelSubscription(sub2);

        assertEq(consumer.getUserSubscriptionCount(USER1), 2);

        uint64[] memory subs = consumer.getUserSubscriptions(USER1, 0, 10);
        bool foundSub1;
        bool foundSub3;
        for (uint256 i = 0; i < subs.length; i++) {
            assertTrue(subs[i] != sub2, "Cancelled sub should be removed");
            if (subs[i] == sub1) foundSub1 = true;
            if (subs[i] == sub3) foundSub3 = true;
        }
        assertTrue(foundSub1, "sub1 should remain");
        assertTrue(foundSub3, "sub3 should remain");
    }

    function test_cancelSubscription_clearsOwnership() public {
        uint64 sub1 = _createSub(USER1);
        assertEq(consumer.getSubscriptionOwner(sub1), USER1);

        vm.prank(USER1);
        consumer.cancelSubscription(sub1);

        assertEq(consumer.getSubscriptionOwner(sub1), address(0));
    }

    function test_cancelSubscription_notOwner_reverts() public {
        uint64 sub1 = _createSub(USER1);

        vm.prank(USER2);
        vm.expectRevert(NoosphereVRFConsumer.NotSubscriptionOwner.selector);
        consumer.cancelSubscription(sub1);
    }

    function test_cancelSubscription_emitsEvent() public {
        uint64 sub1 = _createSub(USER1);

        vm.prank(USER1);
        vm.expectEmit(true, true, false, false);
        emit SubscriptionCancelled(sub1, USER1);
        consumer.cancelSubscription(sub1);
    }

    function test_cancelSubscription_doubleCancelReverts() public {
        uint64 sub1 = _createSub(USER1);

        vm.prank(USER1);
        consumer.cancelSubscription(sub1);

        vm.prank(USER1);
        vm.expectRevert(NoosphereVRFConsumer.NotSubscriptionOwner.selector);
        consumer.cancelSubscription(sub1);
    }

    function test_cancelSubscription_cancelAll() public {
        uint64 sub1 = _createSub(USER1);
        uint64 sub2 = _createSub(USER1);
        uint64 sub3 = _createSub(USER1);

        vm.startPrank(USER1);
        consumer.cancelSubscription(sub1);
        consumer.cancelSubscription(sub2);
        consumer.cancelSubscription(sub3);
        vm.stopPrank();

        assertEq(consumer.getUserSubscriptionCount(USER1), 0);
        assertEq(consumer.getSubscriptionOwner(sub1), address(0));
        assertEq(consumer.getSubscriptionOwner(sub2), address(0));
        assertEq(consumer.getSubscriptionOwner(sub3), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                       Pagination (Fix #5)
    //////////////////////////////////////////////////////////////*/

    function test_pagination_basicPages() public {
        for (uint256 i = 0; i < 5; i++) {
            _createSub(USER1);
        }

        uint64[] memory page1 = consumer.getUserSubscriptions(USER1, 0, 2);
        assertEq(page1.length, 2);

        uint64[] memory page2 = consumer.getUserSubscriptions(USER1, 2, 2);
        assertEq(page2.length, 2);

        uint64[] memory page3 = consumer.getUserSubscriptions(USER1, 4, 2);
        assertEq(page3.length, 1);
    }

    function test_pagination_offsetBeyondLength() public {
        _createSub(USER1);
        uint64[] memory result = consumer.getUserSubscriptions(USER1, 100, 10);
        assertEq(result.length, 0);
    }

    function test_pagination_zeroLimit() public {
        _createSub(USER1);
        uint64[] memory result = consumer.getUserSubscriptions(USER1, 0, 0);
        assertEq(result.length, 0);
    }

    function test_pagination_fullArray() public {
        uint64 sub1 = _createSub(USER1);
        uint64 sub2 = _createSub(USER1);
        uint64 sub3 = _createSub(USER1);

        uint64[] memory all = consumer.getUserSubscriptions(USER1, 0, 100);
        assertEq(all.length, 3);
        assertEq(all[0], sub1);
        assertEq(all[1], sub2);
        assertEq(all[2], sub3);
    }

    function test_pagination_noSubscriptions() public view {
        uint64[] memory result = consumer.getUserSubscriptions(USER1, 0, 10);
        assertEq(result.length, 0);
    }

    function test_pagination_correctValues() public {
        uint64 sub1 = _createSub(USER1);
        uint64 sub2 = _createSub(USER1);
        uint64 sub3 = _createSub(USER1);
        uint64 sub4 = _createSub(USER1);

        uint64[] memory mid = consumer.getUserSubscriptions(USER1, 1, 2);
        assertEq(mid.length, 2);
        assertEq(mid[0], sub2);
        assertEq(mid[1], sub3);

        uint64[] memory last = consumer.getUserSubscriptions(USER1, 3, 10);
        assertEq(last.length, 1);
        assertEq(last[0], sub4);

        // Suppress unused variable warnings
        assertGt(sub1, 0);
    }

    function test_getUserSubscriptionCount() public {
        assertEq(consumer.getUserSubscriptionCount(USER1), 0);

        _createSub(USER1);
        assertEq(consumer.getUserSubscriptionCount(USER1), 1);

        _createSub(USER1);
        assertEq(consumer.getUserSubscriptionCount(USER1), 2);

        _createSub(USER2);
        assertEq(consumer.getUserSubscriptionCount(USER2), 1);
        assertEq(consumer.getUserSubscriptionCount(USER1), 2);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_getRouterAddress() public view {
        assertEq(consumer.getRouterAddress(), address(router));
    }

    function test_typeAndVersion() public view {
        assertEq(consumer.typeAndVersion(), "TestVRFConsumer_v1.0.0");
    }
}
