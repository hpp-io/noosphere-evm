// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import "../../src/v1_0_0/types/ComputeSubscription.sol";

/// @title EIP712Utils
/// @notice Lightweight helpers for building and hashing EIP-712 typed messages for subscriptions.
/// @dev This library implements the specific EIP-712 encoding rules used for `ComputeSubscription`.
///      Keep the struct field ordering in sync with `ComputeSubscription` when computing hashes.
library EIP712Utils {
    /*//////////////////////////////////////////////////////////////
                               TYPE HASHES
    //////////////////////////////////////////////////////////////*/

    /// @notice keccak256 hash of the Subscription type-string used in EIP-712 struct hashing.
    bytes32 private constant SUBSCRIPTION_SCHEMA_HASH = keccak256(
        "Subscription(address client,uint32 activeAt,uint32 intervalSeconds,uint32 maxExecutions,uint16 redundancy,bytes32 containerId,bool useDeliveryInbox,address verifier,uint256 feeAmount,address feeToken,address wallet,bytes32 routeId)"
    );

    /// @notice keccak256 hash of the DelegateSubscription wrapper type used in EIP-712.
    bytes32 private constant DELEGATE_SCHEMA_HASH = keccak256(
        "DelegateSubscription(uint32 nonce,uint32 expiry,Subscription sub)Subscription(address client,uint32 activeAt,uint32 intervalSeconds,uint32 maxExecutions,uint16 redundancy,bytes32 containerId,bool useDeliveryInbox,address verifier,uint256 feeAmount,address feeToken,address wallet,bytes32 routeId)"
    );

    /*//////////////////////////////////////////////////////////////
                           DOMAIN & STRUCT HASHING
    //////////////////////////////////////////////////////////////*/

    /// @notice Build an EIP-712 domain separator for a given domain configuration.
    /// @param domainName Human-readable name for the signing domain (e.g., contract or protocol name).
    /// @param domainVersion Version string for the signing domain (major version recommended).
    /// @param verifyingContract Contract address that will verify signatures.
    /// @return domainSeparator The EIP-712 domain separator (keccak256 encoded).
    function buildDomainSeparator(string memory domainName, string memory domainVersion, address verifyingContract)
        public
        view
        returns (bytes32 domainSeparator)
    {
        domainSeparator = keccak256(
            abi.encode(
                // EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(domainName)),
                keccak256(bytes(domainVersion)),
                block.chainid,
                verifyingContract
            )
        );
    }

    /// @notice Compute the struct hash for a `ComputeSubscription` instance following EIP-712 rules.
    /// @dev The encoded order must match the SUBSCRIPTION_SCHEMA_HASH declaration above.
    /// @param s Subscription instance to hash (all fields included).
    /// @return structHash keccak256 of the encoded subscription fields prefixed by the schema hash.
    function computeSubscriptionHash(ComputeSubscription memory s) public pure returns (bytes32 structHash) {
        structHash = keccak256(
            abi.encode(
                SUBSCRIPTION_SCHEMA_HASH,
                s.client,
                s.activeAt,
                s.intervalSeconds,
                s.maxExecutions,
                s.redundancy,
                s.containerId,
                s.useDeliveryInbox,
                s.verifier,
                s.feeAmount,
                s.feeToken,
                s.wallet,
                s.routeId
            )
        );
    }

    /// @notice Compute the struct hash for a DelegateSubscription (nonce + expiry + subscription).
    /// @param nonce Nonce used by the delegating contract (uint32).
    /// @param expiry Expiration timestamp for the signature (uint32).
    /// @param s ComputeSubscription payload being delegated.
    /// @return delegateHash keccak256 of the encoded delegate wrapper.
    function computeDelegateHash(uint32 nonce, uint32 expiry, ComputeSubscription memory s)
        public
        pure
        returns (bytes32 delegateHash)
    {
        delegateHash = keccak256(abi.encode(DELEGATE_SCHEMA_HASH, nonce, expiry, computeSubscriptionHash(s)));
    }

    /*//////////////////////////////////////////////////////////////
                           EIP-712 FINAL MESSAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Build the final EIP-712 message digest to be signed/verified (EIP-191: "\x19\x01" || domain || structHash).
    /// @param domainName Domain name used for the domain separator.
    /// @param domainVersion Domain version used for the domain separator.
    /// @param verifyingContract Verifying contract address used for the domain separator.
    /// @param nonce Nonce for the delegate wrapper.
    /// @param expiry Signature expiry for the delegate wrapper.
    /// @param s Subscription object being signed/delegated.
    /// @return typedDataHash The 32-byte hash that should be signed (or recovered) off-chain/on-chain.
    function buildTypedDataHash(
        string memory domainName,
        string memory domainVersion,
        address verifyingContract,
        uint32 nonce,
        uint32 expiry,
        ComputeSubscription memory s
    ) external view returns (bytes32 typedDataHash) {
        bytes32 domainSeparator = buildDomainSeparator(domainName, domainVersion, verifyingContract);
        bytes32 delegateStruct = computeDelegateHash(nonce, expiry, s);
        typedDataHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, delegateStruct));
    }
}
