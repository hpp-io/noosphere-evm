// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "openzeppelin-contracts/contracts/interfaces/IERC1271.sol";
import {Routable} from "../utility/Routable.sol";
import {Payment} from "../types/Payment.sol";

/// @title Wallet
/// @notice A smart contract wallet that manages funds, allowances, and request-level locks for various tokens (including native ETH).
contract Wallet is Ownable, Routable, ReentrancyGuard, IERC1271 {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                      STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Total escrowed amount per token across all spenders (address(0) == native ETH)
    mapping(address => uint256) private totalLocked;

    /// @notice Off-chain allowance controlled by the wallet owner that routers may consume on behalf of a spender
    /// @dev allowance[spender][token] is decreased when the router locks funds or the router executes c-style transfers.
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice Per-request lock structure for single payout.
    /// @dev Gas optimized: 2 storage slots. Existence check: spender != address(0).
    struct RequestLock {
        // Slot 0: 20 bytes
        address spender; // subscription client / spender (20 bytes)
        // Slot 1: 20 bytes
        address token; // token (address(0) == ETH)
        // Slot 2: 32 bytes
        uint256 amount; // amount locked for this request (single payout)
    }

    /// @notice Mapping from requestId (opaque bytes32) to RequestLock
    mapping(bytes32 => RequestLock) private requestLocks;

    /*//////////////////////////////////////////////////////////////
                                      EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when native ETH is received by the wallet via the receive() fallback.
    event Deposit(address indexed token, uint256 amount);

    /// @notice Emitted when the wallet owner withdraws unlocked funds.
    event Withdraw(address indexed token, uint256 amount);

    /// @notice Emitted when owner updates the internal allowance for a spender.
    event Approval(address indexed spender, address indexed token, uint256 amount);

    /// @notice Emitted when a new request-level lock is created.
    event RequestLocked(
        bytes32 indexed requestId,
        address indexed spender,
        address indexed token,
        uint256 amount
    );

    /// @notice Emitted when a request-level lock is released and leftover is refunded to allowance.
    event RequestReleased(
        bytes32 indexed requestId, address indexed spender, address indexed token, uint256 amountRefunded
    );

    /// @notice Emitted for each disbursement made as part of a request.
    event RequestDisbursed(bytes32 indexed requestId, address indexed to, address indexed token, uint256 amount);

    /// @notice Emitted when router locks/unlocks escrow on behalf of a spender.
    /// @param spender spender whose balance was modified
    /// @param token token address involved
    /// @param amount amount that was locked/unlocked
    /// @param locked true if locked, false if unlocked
    event Escrow(address indexed spender, address indexed token, uint256 amount, bool locked);

    /// @notice Emitted when the wallet transfers token to a recipient via router-driven payments.
    /// @param spender authorized spender on whose behalf the transfer happens
    /// @param token token transferred
    /// @param to recipient address
    /// @param amount transferred amount
    event Transfer(address indexed spender, address token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                      ERRORS
    //////////////////////////////////////////////////////////////*/

    error InsufficientFunds();
    error InsufficientAllowance();
    error RequestAlreadyLocked();
    error NoSuchRequestLock();
    error ExceedsAmount();
    error ZeroAmount();
    error MismatchPaymentToken();

    /*//////////////////////////////////////////////////////////////
                                   CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Construct a Wallet.
    /// @param router Router contract address (Routable).
    /// @param initialOwner Owner/client that controls allowances and withdraws.
    constructor(address router, address initialOwner) Routable(router) Ownable(initialOwner) {}

    /*//////////////////////////////////////////////////////////////
                                INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the currently unlocked (available) balance for `token`.
    /// @dev For ERC20, reads token balanceOf(this). For ETH, uses address(this).balance.
    function _getUnlockedBalance(address token) internal view returns (uint256) {
        uint256 lockedAmt = totalLocked[token];
        uint256 balance = (token == address(0)) ? address(this).balance : IERC20(token).balanceOf(address(this));
        // Solidity 0.8.x checked math -> safe to subtract as long as invariants hold
        return balance - lockedAmt;
    }

    /// @notice Execute an outwards transfer of token/ETH from this contract to `to`.
    /// @dev Uses SafeERC20 for token transfers and Address.sendValue for ETH.
    function _transferToken(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            Address.sendValue(payable(to), amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 OWNER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Owner can withdraw unlocked funds (not currently reserved/locked).
    /// @param token token to withdraw (address(0) for native ETH)
    /// @param amount amount to withdraw
    function withdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        if (amount > _getUnlockedBalance(token)) revert InsufficientFunds();
        _transferToken(token, msg.sender, amount);
        emit Withdraw(token, amount);
    }

    /// @notice Owner sets an internal allowance for a spender for a specific token.
    /// @dev Router operations will respect this allowance when locking/transferring.
    /// @param spender authorized spender
    /// @param token token address
    /// @param amount allowed amount
    function approve(address spender, address token, uint256 amount) external onlyOwner {
        allowance[spender][token] = amount;
        emit Approval(spender, token, amount);
    }

    /*//////////////////////////////////////////////////////////////
                          ESCROW: router-driven (renamed)
    //////////////////////////////////////////////////////////////*/

    /// @notice Lock `amount` of `token` into escrow on behalf of `spender`.
    /// @dev Router-only. Decreases the internal allowance and increments locked accounting.
    ///      This function replaces legacy `cLock`.
    /// @param spender the spender on whose behalf tokens are reserved
    /// @param token token being locked (address(0) => ETH)
    /// @param amount amount to lock
    function lockEscrow(address spender, address token, uint256 amount) external onlyRouter nonReentrant {
        if (amount > _getUnlockedBalance(token)) revert InsufficientFunds();
        if (allowance[spender][token] < amount) revert InsufficientAllowance();

        // Effect
        allowance[spender][token] -= amount;
        totalLocked[token] += amount;

        emit Escrow(spender, token, amount, true);
    }

    /// @notice Unlock previously escrowed `amount` of `token` for `spender`.
    /// @dev Router-only. Adds the unlocked amount back to the spender's allowance.
    ///      This function replaces legacy `cUnlock`.
    /// @param spender spender whose escrow is to be unlocked
    /// @param token token to unlock
    /// @param amount amount to unlock
    function releaseEscrow(address spender, address token, uint256 amount) external onlyRouter nonReentrant {
        if (amount > totalLocked[token]) revert InsufficientFunds();

        totalLocked[token] -= amount;
        allowance[spender][token] += amount;

        emit Escrow(spender, token, amount, false);
    }

    /// @notice Transfer payments on behalf of `spender` to recipients. Router-only.
    /// @dev Replaces legacy `cTransfer`. For each Payment, allowance[spender][token] is decreased
    ///      and the ERC20/native transfer is executed.
    /// @param spender authorized spender whose allowance pays for the given payments
    /// @param payments array of Payment structs describing recipients and amounts
    function transferByRouter(address spender, Payment[] calldata payments) external onlyRouter nonReentrant {
        for (uint256 i = 0; i < payments.length; i++) {
            Payment calldata p = payments[i];
            if (p.feeAmount > 0) {
                uint256 currentAllowance = allowance[spender][p.feeToken];
                if (currentAllowance < p.feeAmount) revert InsufficientAllowance();
                allowance[spender][p.feeToken] = currentAllowance - p.feeAmount;
                _transferToken(p.feeToken, p.recipient, p.feeAmount);
                emit Transfer(spender, p.feeToken, p.recipient, p.feeAmount);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                      REQUEST-LEVEL LOCKS & PAYOUTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a request-level lock which reserves `amount` for a specific `requestId`.
    /// @dev Router-only. Single payout per request.
    /// @param spender spender on whose behalf the lock is created
    /// @param token token to lock
    /// @param amount amount reserved for this request
    /// @param requestId opaque request identifier
    function lockForRequest(address spender, address token, uint256 amount, bytes32 requestId)
        external
        onlyRouter
        nonReentrant
    {
        // Existence check: spender != address(0) (gas optimization: no separate bool)
        if (requestLocks[requestId].spender != address(0)) revert RequestAlreadyLocked();
        if (amount > _getUnlockedBalance(token)) revert InsufficientFunds();
        if (allowance[spender][token] < amount) revert InsufficientAllowance();

        allowance[spender][token] -= amount;
        totalLocked[token] += amount;

        requestLocks[requestId] = RequestLock({spender: spender, token: token, amount: amount});

        emit RequestLocked(requestId, spender, token, amount);
    }

    /// @notice Disburse a single payout for `requestId` to `to`.
    /// @dev Router-only. Single payout then cleanup. Bookkeeping before transfer for reentrancy safety.
    /// @param requestId request identifier
    /// @param to recipient address
    /// @param amount amount to transfer
    function disburseForRequest(bytes32 requestId, address to, uint256 amount) external onlyRouter nonReentrant {
        RequestLock memory rl = requestLocks[requestId];
        if (rl.spender == address(0)) revert NoSuchRequestLock();
        if (amount == 0) revert ZeroAmount();
        if (amount > rl.amount) revert ExceedsAmount();

        // Bookkeeping (effects)
        totalLocked[rl.token] -= amount;
        uint256 amountToRefund = rl.amount - amount;
        if (amountToRefund > 0) {
            allowance[rl.spender][rl.token] += amountToRefund;
        }
        delete requestLocks[requestId];

        // Interaction
        _transferToken(rl.token, to, amount);
        emit RequestDisbursed(requestId, to, rl.token, amount);
        emit RequestReleased(requestId, rl.spender, rl.token, amountToRefund);
    }

    /// @notice Disburse multiple payments as part of one fulfillment.
    /// @dev All payments must use the same token as specified in the lock. Single fulfillment then cleanup.
    /// @param requestId request identifier
    /// @param payments array of Payment structs to execute
    function disburseForFulfillment(bytes32 requestId, Payment[] calldata payments) external onlyRouter nonReentrant {
        RequestLock memory rl = requestLocks[requestId];
        if (rl.spender == address(0)) revert NoSuchRequestLock();

        uint256 len = payments.length;
        address token = rl.token;
        address spender = rl.spender;
        uint256 lockedAmount = rl.amount;

        uint256 totalToDisburse = 0;
        for (uint256 i = 0; i < len;) {
            Payment calldata p = payments[i];
            if (p.feeToken != token) revert MismatchPaymentToken();
            unchecked {
                totalToDisburse += p.feeAmount;
                ++i;
            }
        }

        if (totalToDisburse > lockedAmount) revert ExceedsAmount();

        // Bookkeeping (effects)
        totalLocked[token] -= totalToDisburse;
        uint256 amountToRefund = lockedAmount - totalToDisburse;
        if (amountToRefund > 0) {
            allowance[spender][token] += amountToRefund;
        }
        delete requestLocks[requestId];

        // Interaction: execute all transfers
        for (uint256 i = 0; i < len;) {
            Payment calldata p = payments[i];
            // Skip zero-amount transfers to save gas (avoids unnecessary CALL)
            if (p.feeAmount > 0) {
                _transferToken(token, p.recipient, p.feeAmount);
                emit RequestDisbursed(requestId, p.recipient, token, p.feeAmount);
            }
            unchecked {
                ++i;
            }
        }

        emit RequestReleased(requestId, spender, token, amountToRefund);
    }

    /// @notice Release locked funds for a request (e.g., on timeout/cancel). Refunds full amount to spender allowance.
    /// @param requestId request identifier
    function releaseForRequest(bytes32 requestId) external onlyRouter nonReentrant {
        RequestLock memory rl = requestLocks[requestId];
        if (rl.spender == address(0)) revert NoSuchRequestLock();

        totalLocked[rl.token] -= rl.amount;
        allowance[rl.spender][rl.token] += rl.amount;

        delete requestLocks[requestId];

        emit RequestReleased(requestId, rl.spender, rl.token, rl.amount);
    }

    /*//////////////////////////////////////////////////////////////
                                        VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Total locked (escrowed) amount for `token`.
    function totalLockedFor(address token) external view returns (uint256) {
        return totalLocked[token];
    }

    /// @notice Returns spender's allowance and wallet's available (unlocked) balance for a token in a single call.
    /// @dev Gas optimization: combines 3 external calls into 1 for SubscriptionManager._hasSubscriptionNextInterval().
    ///      Saves ~90,000 gas on Arbitrum Nitro v3.9+ (Multi-Constraint Pricing).
    /// @param spender The address of the spender to check allowance for.
    /// @param token The token address (address(0) for native ETH).
    /// @return spenderAllowance The allowance granted to the spender for this token.
    /// @return availableBalance The wallet's unlocked balance (total balance - locked amount).
    function getSpenderInfo(address spender, address token)
        external
        view
        returns (uint256 spenderAllowance, uint256 availableBalance)
    {
        spenderAllowance = allowance[spender][token];
        uint256 totalBalance = (token == address(0)) ? address(this).balance : IERC20(token).balanceOf(address(this));
        uint256 lockedAmount = totalLocked[token];
        availableBalance = totalBalance >= lockedAmount ? totalBalance - lockedAmount : 0;
    }

    /// @notice Locked amount for a given request.
    function lockedOfRequest(bytes32 requestId) external view returns (uint256) {
        return requestLocks[requestId].spender != address(0) ? requestLocks[requestId].amount : 0;
    }

    /*//////////////////////////////////////////////////////////////
                                FALLBACK
    //////////////////////////////////////////////////////////////*/

    receive() external payable {
        emit Deposit(address(0), msg.value);
    }

    /*//////////////////////////////////////////////////////////////
                            TYPE & VERSION
    //////////////////////////////////////////////////////////////*/

    function typeAndVersion() external pure returns (string memory) {
        return "Wallet 1.0.0";
    }

    /*//////////////////////////////////////////////////////////////
                                EIP-1271
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Verifies that a signature is valid for this contract.
     * @dev Implements EIP-1271. It checks if the signature was made by the owner of this wallet.
     * @param hash_ The hash of the message that was signed.
     * @param signature_ The signature to verify.
     * @return `bytes4(keccak256("isValidSignature(bytes32,bytes)"))` if the signature is valid, and `0xffffffff` otherwise.
     */
    function isValidSignature(bytes32 hash_, bytes memory signature_) external view override returns (bytes4) {
        if (ECDSA.recover(hash_, signature_) == owner()) {
            return IERC1271.isValidSignature.selector;
        }
        return bytes4(0xffffffff);
    }
}
