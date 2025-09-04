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
/// @notice Payments wallet that allows: (1) managing ETH & ERC20 token balances, (2) allowing consumers to spend balance, (3) allowing coordinator to manage balance
/// @dev Implements `Ownable` to setup an update-able `Wallet` `owner`
/// @dev Implements `Routable` to restrict payment-handling functions to being called from the router.
/// @dev ReentrancyGuard used to prevent reentrancy on external-transfer functions
contract Wallet is Ownable, Routable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice token address => total locked balance in escrow (aggregated across spenders)
    /// @dev address(0) represents ETH
    mapping(address => uint256) private totalLocked;

    /// @notice spender => token => locked amount for that spender
    mapping(address => mapping(address => uint256)) private lockedBalanceOf;

    /// @notice consumer => token => spend limit
    /// @dev Exposes public getter to enable checking allowance
    mapping(address => mapping(address => uint256)) public allowance;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when ETH is deposited into the wallet
    event Deposit(address indexed token, uint256 amount);

    /// @notice Emitted when `Wallet` owner processes a withdrawl
    event Withdraw(address token, uint256 amount);

    /// @notice Emitted when `Wallet` owner approves a `spender` to use `amount` `token`
    event Approval(address indexed spender, address indexed token, uint256 amount);

    /// @notice Emitted when `Coordinator` locks or unlocks some `amount` `token` in `Wallet` escrow
    event Escrow(address indexed spender, address indexed token, uint256 amount, bool locked);

    /// @notice Emitted when `Wallet` transfers some quantity of tokens
    event Transfer(address indexed spender, address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown if attempting to transfer or lock tokens in quantity greater than possible
    error InsufficientFunds();

    /// @notice Thrown if attempting to transfer or lock tokens in quantity greater than allowed to a `spender`
    error InsufficientAllowance();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes new Wallet
    constructor(address router, address initialOwner) Routable(router) Ownable(initialOwner) {}

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns balance of `token` that is not currently locked in escrow
    function _getUnlockedBalance(address token) internal view returns (uint256) {
        uint256 lockedAmt = totalLocked[token];
        uint256 balance = (token == address(0))
            ? address(this).balance
            : IERC20(token).balanceOf(address(this));

        // Underflow is guarded by solidity >=0.8
        return balance - lockedAmt;
    }

    /// @notice Transfers `amount` `token` from `address(this)` to `to`
    function _transferToken(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            Address.sendValue(payable(to), amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Allows `owner` to withdraw `amount` `token`(s)
    function withdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        if (amount > _getUnlockedBalance(token)) {
            revert InsufficientFunds();
        }
        _transferToken(token, msg.sender, amount);
        emit Withdraw(token, amount);
    }

    /// @notice Allows `owner` to approve `spender` as a consumer that can spend `amount` `token`(s) from `Wallet`
    function approve(address spender, address token, uint256 amount) external onlyOwner {
        allowance[spender][token] = amount;
        emit Approval(spender, token, amount);
    }

    /// @notice Allows router to transfer `amount` `tokens` to `to` on behalf of `spender`
    function transferByRouter(address spender, address token, address to, uint256 amount) external onlyRouter nonReentrant {
        if (allowance[spender][token] < amount) {
            revert InsufficientAllowance();
        }
        allowance[spender][token] -= amount;
        _transferToken(token, to, amount);
        emit Transfer(spender, token, to, amount);
    }

    /// @notice Unified escrow setter. If `lock==true` locks `amount` tokens for `spender`. If `lock==false` unlocks `amount`.
    function setEscrow(address spender, address token, uint256 amount, bool lock) external onlyRouter nonReentrant {
        if (lock) {
            if (amount > _getUnlockedBalance(token)) revert InsufficientFunds();
            if (allowance[spender][token] < amount) revert InsufficientAllowance();

            allowance[spender][token] -= amount;
            lockedBalanceOf[spender][token] += amount;
            totalLocked[token] += amount;

            emit Escrow(spender, token, amount, true);
        } else {
            uint256 lockedForSpender = lockedBalanceOf[spender][token];
            if (amount > lockedForSpender) revert InsufficientFunds();

            lockedBalanceOf[spender][token] = lockedForSpender - amount;
            totalLocked[token] -= amount;
            allowance[spender][token] += amount;

            emit Escrow(spender, token, amount, false);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            TYPE & VERSION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ITypeAndVersion
    function typeAndVersion() external pure override returns (string memory) {
        return "Wallet 1.0.0";
    }
    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns total locked amount for a token (across all spenders)
    function totalLockedFor(address token) external view returns (uint256) {
        return totalLocked[token];
    }

    /// @notice Returns locked amount for a specific spender-token pair
    function lockedOf(address spender, address token) external view returns (uint256) {
        return lockedBalanceOf[spender][token];
    }

    /// @notice Convenience view: is there any locked amount for (spender, token)?
    function isLocked(address spender, address token) external view returns (bool) {
        return lockedBalanceOf[spender][token] > 0;
    }

    /*//////////////////////////////////////////////////////////////
                                FALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice Allow ETH deposits to `Wallet`
    receive() external payable {}
}
