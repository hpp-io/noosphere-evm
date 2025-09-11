// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Coordinator} from "../../src/v1_0_0/Coordinator.sol";
import {Router} from "../../src/v1_0_0/Router.sol";
import {Wallet} from "../../src/v1_0_0/wallet/Wallet.sol";
import {WalletFactory} from "../../src/v1_0_0/wallet/WalletFactory.sol";
import "../lib/LibDeploy.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

/// @title IWalletFactoryEvents
/// @notice Events emitted by WalletFactory
interface IWalletFactoryEvents {
    event WalletCreated(address indexed caller, address indexed owner, address wallet);
}

/// @title WalletFactoryTest
/// @notice Tests WalletFactory implementation
contract WalletFactoryTest is Test, IWalletFactoryEvents {
    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Wallet factory
    WalletFactory internal WALLET_FACTORY;

    Router internal ROUTER;
    Coordinator internal COORDINATOR;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // Initialize contracts
        uint256 initialNonce = vm.getNonce(address(this));
        (Router router, Coordinator coordinator, , WalletFactory walletFactory) =
                            LibDeploy.deployContracts(address(this), initialNonce, address(0), 1);

        // Assign contracts
        WALLET_FACTORY = walletFactory;
        ROUTER = router;
        COORDINATOR = coordinator;

        // Complete deployment by setting the WalletFactory address in the Router.
        // This breaks the circular dependency during deployment.
        router.setWalletFactory(address(walletFactory));
    }

    /*//////////////////////////////////////////////////////////////
                                 TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Wallets created via `WalletFactory.createWallet()` are appropriately setup
    function testFuzzWalletsAreCreatedCorrectly(address initialOwner) public {
        vm.assume(initialOwner != address(0));
        // Predict expected wallet address
        uint256 nonce = vm.getNonce(address(WALLET_FACTORY));
        address expected = vm.computeCreateAddress(address(WALLET_FACTORY), nonce);
        bytes32 NAME = bytes32("Coordinator_v1.0.0");
        // Create new wallet
        vm.expectEmit(address(WALLET_FACTORY));
        emit WalletCreated(address(this), initialOwner, expected);
        address walletAddress = WALLET_FACTORY.createWallet(initialOwner);

        // Verify wallet is deployed to correct address
        assertEq(expected, walletAddress);

        // Verify wallet is valid
        assertTrue(WALLET_FACTORY.isValidWallet(walletAddress));

        // Setup created wallet
        Wallet wallet = Wallet(payable(walletAddress));

        // Verify wallet owner is correctly set
        assertEq(wallet.owner(), initialOwner);
        // Verify router-only functions can be called by the router.
        // We expect it to revert with InsufficientFunds, which confirms the auth check passed.
        vm.startPrank(address(ROUTER));
        vm.expectRevert(Wallet.InsufficientFunds.selector);
        wallet.cLock(address(0), address(0), 1);

        vm.stopPrank();
    }

    /// @notice Wallets not created via `WalletFactory` do not return as valid
    function testFuzzWalletsCreatedDirectlyAreNotValid(address deployer) public {
        vm.assume(deployer != address(0));
        // Deploy from a different address to increase entropy
        vm.startPrank(deployer);

        // Create wallet directly
        Wallet wallet = new Wallet(address(ROUTER), deployer);

        // Verify wallet is not valid
        assertFalse(WALLET_FACTORY.isValidWallet(address(wallet)));

        vm.stopPrank();
    }
}
