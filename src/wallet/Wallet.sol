// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CoordinatorAuth} from "../utillity/CoordinatorAuth.sol";


/// @title Secure Wallet
/// @notice A wallet managed by the owner, allowing registered spenders to transfer funds within escrow limits
/// @dev Event signatures maintain the same names for compatibility with the existing wallet.sol (including the 'Withdrawl' spelling)
contract Wallet is CoordinatorAuth, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Events (maintaining compatibility) ============
    event Withdrawl(address token, uint256 amount);
    event Approval(address indexed spender, address token, uint256 amount);
    event Escrow(address indexed spender, address token, uint256 amount, bool locked);
    event Transfer(address indexed spender, address token, address indexed to, uint256 amount);

    // ============ State ============
    // Spender authorization status
    mapping(address => bool) public isSpender;

    // Token allowance limit per spender (escrow characteristic)
    mapping(address => mapping(address => uint256)) public allowanceOf; // spender => token => amount

    // Lock status per token per spender
    mapping(address => mapping(address => bool)) public locked;

    // Total locked amount per token (token => total locked amount)
    mapping(address => uint256) public lockedBalance;

    // ============ Receive ============
    receive() external payable {}
    fallback() external payable {}

    // ============ Constructor ============
    // OpenZeppelin v5: Ownable constructor requires initialOwner parameter
    constructor(address initialOwner) Ownable(initialOwner) {}

    // ============ Admin (Owner) ============
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setSpender(address account, bool allowed) external onlyOwner {
        isSpender[account] = allowed;
    }

    /// @notice Set (or update) the token limit and lock status for a spender
    function setEscrow(address spender_, address token, uint256 amount, bool lockStatus) external onlyCoordinator {
        // Check current lock status
        bool currentlyLocked = locked[spender_][token];
        uint256 currentAllowance = allowanceOf[spender_][token];

        // Set new allowance
        allowanceOf[spender_][token] = amount;

        // Update lockedBalance when lock status changes
        if (!currentlyLocked && lockStatus) {
            // Lock enabled: increase lockedBalance
            lockedBalance[token] += amount;
        } else if (currentlyLocked && !lockStatus) {
            // Lock disabled: decrease lockedBalance
            lockedBalance[token] = lockedBalance[token] > currentAllowance ? 
                                   lockedBalance[token] - currentAllowance : 0;
        } else if (currentlyLocked && lockStatus && amount != currentAllowance) {
            // Adjust lockedBalance while maintaining lock status and changing amount
            if (amount > currentAllowance) {
                lockedBalance[token] += (amount - currentAllowance);
            } else {
                lockedBalance[token] = lockedBalance[token] > (currentAllowance - amount) ? 
                                       lockedBalance[token] - (currentAllowance - amount) : 0;
            }
        }

        // Set lock status
        locked[spender_][token] = lockStatus;
        emit Escrow(spender_, token, amount, lockStatus);
    }

    /// @notice Safely approve token spending
    function approveToken(address token, address spender_, uint256 amount) external onlyOwner nonReentrant {
        IERC20(token).forceApprove(spender_, amount);
        emit Approval(spender_, token, amount);
    }

    /// @notice Direct token withdrawal by owner (ERC20)
    function withdrawToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "invalid to");
        // Check lock status even for owner
        require(!locked[owner()][token], "escrow locked");

        uint256 unlockedBalance = getUnlockedBalance(token);
        require(amount <= unlockedBalance, "insufficient unlocked balance");

        IERC20(token).safeTransfer(to, amount);
        emit Withdrawl(token, amount);
    }

    /// @notice Direct ETH withdrawal by owner
    function withdrawETH(address payable to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "invalid to");
        require(!locked[owner()][address(0)], "escrow locked");

        // Check available balance
        uint256 unlockedBalance = getUnlockedBalance(address(0));
        require(amount <= unlockedBalance, "insufficient unlocked balance");

        Address.sendValue(to, amount);
        emit Withdrawl(address(0), amount);
    }

    /// @notice Emergency recovery (owner): Recover all or part of any token
    function rescueToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "invalid to");
        require(!locked[owner()][token], "escrow locked");
        IERC20(token).safeTransfer(to, amount);
        // No separate event needed as Withdrawl event provides sufficient tracking
        emit Withdrawl(token, amount);
    }

    /// @notice Coordinator transfers funds on behalf of a spender
    /// @param spender The consumer requesting the fund transfer
    /// @param token The token to transfer (ETH is address(0))
    /// @param to Recipient address
    /// @param amount Amount to transfer
    function transferByCoordinator(address spender, address token, address to, uint256 amount) external onlyCoordinator nonReentrant whenNotPaused {
        require(to != address(0), "invalid to");
        require(isSpender[spender], "not authorized spender");

        // Check recipient whitelist
        if (recipientWhitelistEnabled[address(this)]) {
            require(isRecipientWhitelisted[to], "recipient not whitelisted");
        }

        // Check lock status
        require(!locked[spender][token], "escrow locked");

        // Verify spender allowance
        uint256 remaining = allowanceOf[spender][token];
        require(remaining >= amount, "allowance exceeded");

        // Decrease allowance
        unchecked {
            allowanceOf[spender][token] = remaining - amount;
        }

        // Transfer funds
        if (token == address(0)) {
            // ETH
            Address.sendValue(payable(to), amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }

        emit Transfer(spender, token, to, amount);
    }

    // ============ Spending (Owner or Spender) ============
    /// @notice Transfer ERC20/ETH. Called by owner or registered spender
    /// @dev Spenders can only transfer if not locked and within their allowance
    function transferFromWallet(address token, address to, uint256 amount)
    external
    nonReentrant
    whenNotPaused
    {
        require(to != address(0), "invalid to");
        if (recipientWhitelistEnabled[address(this)]) {
            require(isRecipientWhitelisted[to], "recipient not whitelisted");
        }

        bool ownerCall = msg.sender == owner();
        if (!ownerCall) {
            require(isSpender[msg.sender], "not spender");

            uint256 remaining = allowanceOf[msg.sender][token];
            require(remaining >= amount, "allowance exceeded");
            unchecked {
                allowanceOf[msg.sender][token] = remaining - amount;
            }
        }

        // Lock status check applies to all users including owner
        if (ownerCall) {
            // For owner, check their own lock status
            require(!locked[owner()][token], "escrow locked");
        } else {
            // For spender, check their own lock status
            require(!locked[msg.sender][token], "escrow locked");
        }

        if (token == address(0)) {
            // ETH
            Address.sendValue(payable(to), amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }

        emit Transfer(msg.sender, token, to, amount);
    }

    // ============ Views ============
    function remainingAllowance(address spender_, address token) external view returns (uint256) {
        return allowanceOf[spender_][token];
    }

    function isLocked(address spender_, address token) external view returns (bool) {
        return locked[spender_][token];
    }

    /// @notice Query the unlocked available balance of a token
    /// @param token Token address to query (ETH is address(0))
    /// @return Unlocked token balance
    function getUnlockedBalance(address token) public view returns (uint256) {
        // Get locked token balance
        uint256 locked = lockedBalance[token];

        // Get total token balance
        uint256 balance;
        if (token == address(0)) {
            // For ETH, use contract balance
            balance = address(this).balance;
        } else {
            // For ERC20 tokens, query contract's token balance
            balance = IERC20(token).balanceOf(address(this));
        }

        // Return total token balance - locked token balance
        return balance > locked ? balance - locked : 0;
    }
}