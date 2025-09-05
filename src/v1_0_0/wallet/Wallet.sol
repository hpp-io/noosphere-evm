// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ITypeAndVersion} from "../interfaces/ITypeAndVersion.sol";
import {Routable} from "../Routable.sol";

/// @title Wallet
/// @notice Lightweight payments wallet with per-request escrow + redundancy-aware disbursements.
/// @dev Ownable for admin, Routable to restrict router-only operations, ReentrancyGuard for safety.
contract Wallet is Ownable, Routable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    /// token address => total locked balance in escrow (aggregated across spenders). address(0) == ETH
    mapping(address => uint256) private totalLocked;

    /// spender => token => locked amount for that spender
    mapping(address => mapping(address => uint256)) private lockedBalanceOf;

    /// spender (consumer) => token => spend allowance maintained inside Wallet
    mapping(address => mapping(address => uint256)) public allowance;

    /// requestId => per-request lock metadata (supports redundancy)
    struct RequestLock {
        address spender;        // subscription owner / spender
        address token;          // token (address(0) == ETH)
        uint256 totalAmount;    // locked total (paymentAmount * redundancy)
        uint256 remainingAmount;// remaining amount available to disburse
        uint16 redundancy;      // allowed number of payouts
        uint16 paidCount;       // number of payouts already made
        bool exists;
    }

    mapping(bytes32 => RequestLock) private requestLocks;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// Emitted when ETH is deposited into the wallet
    event Deposit(address indexed token, uint256 amount);

    /// Emitted when `Wallet` owner withdraws funds
    event Withdraw(address token, uint256 amount);

    /// Emitted when owner sets an allowance for a spender
    event Approval(address indexed spender, address indexed token, uint256 amount);

    /// Emitted when a request-level lock is created
    event RequestLocked(bytes32 indexed requestId, address indexed spender, address token, uint256 totalAmount, uint16 redundancy);

    /// Emitted when a request-level lock is released (refund)
    event RequestReleased(bytes32 indexed requestId, address indexed spender, address token, uint256 amountRefunded);

    /// Emitted when a request-level disbursement is made to `to`
    event RequestDisbursed(bytes32 indexed requestId, address indexed to, address token, uint256 amount);

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

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address router, address initialOwner) Routable(router) Ownable(initialOwner) {}

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// Returns wallet balance of `token` minus amounts currently locked
    function _getUnlockedBalance(address token) internal view returns (uint256) {
        uint256 lockedAmt = totalLocked[token];
        uint256 balance = (token == address(0)) ? address(this).balance : IERC20(token).balanceOf(address(this));
        return balance - lockedAmt; // safe underflow checks in >=0.8
    }

    /// Transfer token/ETH from this contract to `to`
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

    /// Withdraw unlocked funds (owner)
    function withdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        if (amount > _getUnlockedBalance(token)) revert InsufficientFunds();
        _transferToken(token, msg.sender, amount);
        emit Withdraw(token, amount);
    }

    /// Approve a spender (owner)
    function approve(address spender, address token, uint256 amount) external onlyOwner {
        allowance[spender][token] = amount;
        emit Approval(spender, token, amount);
    }

    /*//////////////////////////////////////////////////////////////
                      REQUEST-LEVEL ESCROW & PAYMENTS
    //////////////////////////////////////////////////////////////*/

    /// Lock funds for a specific requestId. `totalAmount` usually = paymentAmount * redundancy.
    /// Caller must be router/manager.
    function lockForRequest(
        address spender,
        address token,
        uint256 totalAmount,
        bytes32 requestId,
        uint16 redundancy
    ) external onlyRouter nonReentrant {
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

    /// Disburse `amount` from a request lock to `to`. Multiple payouts supported up to `redundancy`.
    /// Accounting updated before external transfer.
    function disburseForRequest(bytes32 requestId, address to, uint256 amount) external onlyRouter nonReentrant {
        RequestLock storage rl = requestLocks[requestId];
        if (!rl.exists) revert NoSuchRequestLock();
        if (amount == 0) revert ZeroAmount();
        if (amount > rl.remainingAmount) revert ExceedsRemaining();
        if (rl.paidCount >= rl.redundancy) revert RedundancyExhausted();

        // bookkeeping first
        uint256 lockedForSpender = lockedBalanceOf[rl.spender][rl.token];
        if (amount > lockedForSpender) revert InconsistentLockedBalance();
        lockedBalanceOf[rl.spender][rl.token] = lockedForSpender - amount;
        totalLocked[rl.token] -= amount;

        rl.remainingAmount -= amount;
        unchecked { rl.paidCount += 1; }

        // external transfer
        _transferToken(rl.token, to, amount);

        // finalize: if fully consumed or redundancy reached, refund leftover and cleanup
        if (rl.remainingAmount == 0 || rl.paidCount == rl.redundancy) {
            if (rl.remainingAmount > 0) {
                // refund leftover back to spender's allowance
                allowance[rl.spender][rl.token] += rl.remainingAmount;
            }
            delete requestLocks[requestId];
        }

        emit RequestDisbursed(requestId, to, rl.token, amount);
    }

    /// Release remaining funds for a request (timeout/cancel). Refunds remaining amount to spender's allowance.
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

    function totalLockedFor(address token) external view returns (uint256) {
        return totalLocked[token];
    }

    function lockedOf(address spender, address token) external view returns (uint256) {
        return lockedBalanceOf[spender][token];
    }

    function isLocked(address spender, address token) external view returns (bool) {
        return lockedBalanceOf[spender][token] > 0;
    }

    function lockedOfRequest(bytes32 requestId) external view returns (uint256) {
        return requestLocks[requestId].exists ? requestLocks[requestId].remainingAmount : 0;
    }

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
}
