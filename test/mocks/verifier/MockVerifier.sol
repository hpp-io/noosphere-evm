// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import "../../../src/v1_0_0/Coordinator.sol";
import "../../../src/v1_0_0/interfaces/IVerifier.sol";
import {Router} from "../../../src/v1_0_0/Router.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @title AbstractVerifier
/// @notice Abstract helper that implements common parts of an on-chain verifier used in tests and downstream mocks.
/// @dev Provides token fee bookkeeping, supported-token toggles and coordinator wiring.
///      Concrete verifier implementations MUST implement submitProofForVerification(...) to handle asynchronous submissions.
abstract contract MockVerifier is IVerifier {
    /*//////////////////////////////////////////////////////////////////////////
                                  IMMUTABLES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Coordinator instance resolved from the Router.
    Coordinator internal immutable coordinator;

    /*//////////////////////////////////////////////////////////////////////////
                                   STORAGE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Per-token fee amounts (token address => fee amount).
    mapping(address => uint256) private feeByToken;

    /// @notice Tracks which tokens this verifier accepts for payment.
    mapping(address => bool) private allowedTokens;

    /*//////////////////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Construct AbstractVerifier by resolving the Coordinator from the provided Router.
    /// @param router Router instance used to lookup the Coordinator address (by well-known id).
    constructor(Router router) {
        // resolve Coordinator using the id used throughout the test fixture
        address coordAddr = router.getContractById("Coordinator_v1.0.0");
        require(coordAddr != address(0), "AbstractVerifier: coordinator not found");
        coordinator = Coordinator(coordAddr);
    }

    /*//////////////////////////////////////////////////////////////////////////
                           IVerifier IMPLEMENTATION (COMMON PART)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Returns the payment recipient address for this verifier.
    /// @dev Default behaviour: verifier receives payments itself (address(this)). Override if payments go elsewhere.
    function paymentRecipient() external view override returns (address recipient) {
        return address(this);
    }

    /// @notice Returns whether the verifier supports `token` as a payment method.
    function isPaymentTokenSupported(address token) external view override returns (bool supported) {
        return allowedTokens[token];
    }

    /// @notice Returns fee required when paying in `token`.
    function fee(address token) external view override returns (uint256 amount) {
        return feeByToken[token];
    }

    /*//////////////////////////////////////////////////////////////////////////
                                 ADMIN HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Set the fee amount for a given payment token.
    /// @dev No access control here — tests should wrap or restrict as needed.
    /// @param token Token address to set fee for.
    /// @param newFee Fee amount in token base units.
    function updateFee(address token, uint256 newFee) external {
        feeByToken[token] = newFee;
    }

    /// @notice Toggle support for a given payment token.
    /// @param token Token address to update.
    /// @param enabled Whether the token should be accepted for payments.
    function updateSupportedToken(address token, bool enabled) external {
        allowedTokens[token] = enabled;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                 BALANCE HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Returns native ETH balance held by the verifier contract.
    function ethBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Returns ERC20 token balance held by the verifier contract.
    function tokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  FALLBACK
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Accept native ETH transfers (useful for tests).
    receive() external payable {}
}
