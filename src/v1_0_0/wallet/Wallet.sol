// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

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

    /// @notice Per-spender escrowed balances: lockedBalanceOf[spender][token]
    mapping(address => mapping(address => uint256)) private lockedBalanceOf;

    /// @notice Off-chain allowance controlled by the wallet owner that routers may consume on behalf of a spender
    /// @dev allowance[spender][token] is decreased when the router locks funds or the router executes c-style transfers.
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice Per-request lock structure supporting redundancy and incremental payouts.
    struct RequestLock {
        address spender; // subscription client / spender
        address token; // token (address(0) == ETH)
        uint256 totalAmount; // total locked for the request (typically feeAmount * redundancy)
        uint256 remainingAmount; // amount remaining to be disbursed for this request
        uint16 redundancy; // number of allowed payouts for this request
        uint16 paidCount; // number of payouts already executed
        bool exists; // existence flag
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
        uint256 totalAmount,
        uint16 redundancy
    );

    /// @notice Emitted when a request-level lock is released and leftover is refunded to allowance.
    event RequestReleased(
        bytes32 indexed requestId, address indexed spender, address indexed token, uint256 amountRefunded
    );

    /// @notice Emitted for each disbursement made as part of a request.
    event RequestDisbursed(
        bytes32 indexed requestId, address indexed to, address indexed token, uint256 amount, uint16 paidCount
    );

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
    error ExceedsRemaining();
    error ZeroAmount();
    error RedundancyExhausted();
    error InconsistentLockedBalance();
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
        lockedBalanceOf[spender][token] += amount;
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
        if (amount > lockedBalanceOf[spender][token]) revert InsufficientFunds();

        lockedBalanceOf[spender][token] -= amount;
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

    /// @notice Create a request-level lock which reserves `totalAmount` for a specific `requestId`.
    /// @dev Typically totalAmount = feeAmount * redundancy. Router-only.
    /// @param spender spender on whose behalf the lock is created
    /// @param token token to lock
    /// @param totalAmount total amount reserved
    /// @param requestId opaque request identifier
    /// @param redundancy number of payouts allowed for this request
    function lockForRequest(address spender, address token, uint256 totalAmount, bytes32 requestId, uint16 redundancy)
        external
        onlyRouter
        nonReentrant
    {
        if (requestLocks[requestId].exists) revert RequestAlreadyLocked();
        if (totalAmount > _getUnlockedBalance(token)) revert InsufficientFunds();
        if (allowance[spender][token] < totalAmount) revert InsufficientAllowance();

        allowance[spender][token] -= totalAmount;
        lockedBalanceOf[spender][token] += totalAmount;
        totalLocked[token] += totalAmount;

        requestLocks[requestId] = RequestLock({
            spender: spender,
            token: token,
            totalAmount: totalAmount,
            remainingAmount: totalAmount,
            redundancy: redundancy,
            paidCount: 0,
            exists: true
        });

        emit RequestLocked(requestId, spender, token, totalAmount, redundancy);
    }

    /// @notice Disburse a single payout for `requestId` to `to`. Supports incremental redundancy payouts.
    /// @dev Router-only. Bookkeeping is performed before external transfer to minimize reentrancy risk.
    /// @param requestId request identifier
    /// @param to recipient address
    /// @param amount amount to transfer
    function disburseForRequest(bytes32 requestId, address to, uint256 amount) external onlyRouter nonReentrant {
        RequestLock storage rl = requestLocks[requestId];
        if (!rl.exists) revert NoSuchRequestLock();
        if (amount == 0) revert ZeroAmount();
        if (amount > rl.remainingAmount) revert ExceedsRemaining();
        if (rl.paidCount >= rl.redundancy) revert RedundancyExhausted();

        // Bookkeeping (effects)
        lockedBalanceOf[rl.spender][rl.token] -= amount;
        totalLocked[rl.token] -= amount;

        rl.remainingAmount -= amount;
        unchecked {
            rl.paidCount += 1;
        }
        uint16 paid = rl.paidCount;

        // Interaction
        _transferToken(rl.token, to, amount);
        emit RequestDisbursed(requestId, to, rl.token, amount, paid);

        // Finalize: refund leftover and cleanup if fully consumed or redundancy reached
        if (rl.remainingAmount == 0 || paid == rl.redundancy) {
            uint256 amountToRefund = rl.remainingAmount;
            address spender = rl.spender;
            address token = rl.token;
            if (amountToRefund > 0) {
                allowance[spender][token] += amountToRefund;
            }
            delete requestLocks[requestId];
            emit RequestReleased(requestId, spender, token, amountToRefund);
        }
    }

    /// @notice Disburse multiple payments as part of one fulfillment and increment paidCount once.
    /// @dev All payments must use the same token as specified in the lock.
    /// @param requestId request identifier
    /// @param payments array of Payment structs to execute
    function disburseForFulfillment(bytes32 requestId, Payment[] calldata payments) external onlyRouter nonReentrant {
        RequestLock storage rl = requestLocks[requestId];
        if (!rl.exists) revert NoSuchRequestLock();
        if (rl.paidCount >= rl.redundancy) revert RedundancyExhausted();

        uint256 len = payments.length;
        address token = rl.token;
        address spender = rl.spender;
        uint16 redundancy = rl.redundancy;
        uint16 paidCount = rl.paidCount;
        uint256 remaining = rl.remainingAmount;

        uint256 totalToDisburse = 0;
        for (uint256 i = 0; i < len; ) {
            Payment calldata p = payments[i];
            if (p.feeToken != token) revert MismatchPaymentToken();
            unchecked { totalToDisburse += p.feeAmount; }
            unchecked { ++i; }
        }

        if (totalToDisburse > remaining) revert ExceedsRemaining();

        uint256 lockedForSpender = lockedBalanceOf[spender][token];
        if (totalToDisburse > lockedForSpender) revert InconsistentLockedBalance();

        lockedBalanceOf[spender][token] = lockedForSpender - totalToDisburse;
        totalLocked[token] -= totalToDisburse;

        remaining -= totalToDisburse;
        unchecked { ++paidCount; }
        rl.remainingAmount = remaining;
        rl.paidCount = paidCount;
        uint16 paid = paidCount;
        for (uint256 i = 0; i < len; ) {
            Payment calldata p = payments[i];
            _transferToken(token, p.recipient, p.feeAmount);
            emit RequestDisbursed(requestId, p.recipient, token, p.feeAmount, paid);
            unchecked { ++i; }
        }

        if (paid == redundancy) {
            uint256 amountToRefund = remaining;
            if (amountToRefund > 0) {
                // increase allowance for spender (payback)
                allowance[spender][token] += amountToRefund;
            }
            delete requestLocks[requestId];
            emit RequestReleased(requestId, spender, token, amountToRefund);
        }
    }


    /// @notice Release remaining funds for a request (e.g., on timeout/cancel). Refunds remaining amount to spender allowance.
    /// @param requestId request identifier
    function releaseForRequest(bytes32 requestId) external onlyRouter nonReentrant {
        RequestLock memory rl = requestLocks[requestId];
        if (!rl.exists) revert NoSuchRequestLock();

        uint256 rem = rl.remainingAmount;
        uint256 lockedForSpender = lockedBalanceOf[rl.spender][rl.token];
        if (rem > lockedForSpender) revert InconsistentLockedBalance();

        lockedBalanceOf[rl.spender][rl.token] = lockedForSpender - rem;
        totalLocked[rl.token] -= rem;
        allowance[rl.spender][rl.token] += rem;

        delete requestLocks[requestId];

        emit RequestReleased(requestId, rl.spender, rl.token, rem);
    }

    /*//////////////////////////////////////////////////////////////
                                        VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Total locked (escrowed) amount for `token`.
    function totalLockedFor(address token) external view returns (uint256) {
        return totalLocked[token];
    }

    /// @notice Locked balance for a specific spender and token.
    function lockedOf(address spender, address token) external view returns (uint256) {
        return lockedBalanceOf[spender][token];
    }

    /// @notice Whether a given spender has any locked balance for `token`.
    function isLocked(address spender, address token) external view returns (bool) {
        return lockedBalanceOf[spender][token] > 0;
    }

    /// @notice Remaining locked amount for a given request.
    function lockedOfRequest(bytes32 requestId) external view returns (uint256) {
        return requestLocks[requestId].exists ? requestLocks[requestId].remainingAmount : 0;
    }

    /// @notice Number of payouts already executed for a request.
    function paidCountOfRequest(bytes32 requestId) external view returns (uint16) {
        return requestLocks[requestId].exists ? requestLocks[requestId].paidCount : 0;
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
