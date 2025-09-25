// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {Coordinator} from "../../src/v1_0_0/Coordinator.sol";
import {Router} from "../../src/v1_0_0/Router.sol";
import {Wallet} from "../../src/v1_0_0/wallet/Wallet.sol";
import {WalletFactory} from "../../src/v1_0_0/wallet/WalletFactory.sol";
import "../lib/DeployUtils.sol";
import {Test} from "forge-std/Test.sol";

/// @title WalletFactory events used in tests
/// @notice Interface describing the WalletFactory `WalletCreated` event used by the test harness.
interface IWalletFactoryEvents {
    event WalletCreated(address indexed operator, address indexed owner, address wallet);
}

/// @title WalletFactoryTest
/// @notice Unit tests for WalletFactory deployment and basic integration with Router/Wallet.
/// @dev Tests focus on provenance (factory-created wallets) and basic Router access checks on the Wallet.
///      Uses Forge's `vm` utilities for address prediction and call impersonation.
contract WalletFactoryTest is Test, IWalletFactoryEvents {
    /*//////////////////////////////////////////////////////////////
                                 TEST FIXTURE
    //////////////////////////////////////////////////////////////*/

    /// @notice WalletFactory under test
    WalletFactory internal walletFactory;

    /// @notice Router instance created by LibDeploy
    Router internal router;

    /// @notice Coordinator instance created by LibDeploy (unused directly, included for completeness)
    Coordinator internal coordinator;

    /*//////////////////////////////////////////////////////////////
                                     SETUP
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy test fixture: Router, Coordinator, WalletFactory, WalletFactory -> Router wiring.
    function setUp() public {
        // Use a deterministic nonce to allow address prediction in tests
        uint256 initialNonce = vm.getNonce(address(this));

        // LibDeploy.deployContracts returns (Router, Coordinator, SubscriptionBatchReader , WalletFactory)
        (Router deployedRouter, Coordinator deployedCoordinator, , WalletFactory deployedWalletFactory) =
                            DeployUtils.deployContracts(address(this), initialNonce, address(0), 1, address(0));

        router = deployedRouter;
        coordinator = deployedCoordinator;
        walletFactory = deployedWalletFactory;

        // Wire the Router to know the walletFactory address (addresses circular-dependency resolution).
        router.setWalletFactory(address(walletFactory));
    }

    /*//////////////////////////////////////////////////////////////
                                     TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Wallets created via WalletFactory should be deployed to the predictable address and registered.
    /// @dev Verifies:
    ///      1) createWallet returns the predicted deployment address,
    ///      2) isValidWallet reports true for factory-created wallets,
    ///      3) the created Wallet is initialized with the correct owner,
    ///      4) Router-only entrypoints enforce access control (we observe a revert due to missing funds rather than auth failure).
    function test_Succeeds_When_WalletCreatedByFactory_IsRegisteredAndRouterRestricted(address initialOwner) public {
        // Discard zero-owner cases; factory requires non-zero initial owner
        vm.assume(initialOwner != address(0));

        // Predict the address where the factory will create the next Wallet
        uint256 factoryNonce = vm.getNonce(address(walletFactory));
        address expectedDeployedAddress = vm.computeCreateAddress(address(walletFactory), factoryNonce);

        // Expect the WalletCreated event with the operator (this contract), owner, and predicted address
        vm.expectEmit(true, true, false, false, address(walletFactory));
        emit WalletCreated(address(this), initialOwner, expectedDeployedAddress);

        // Deploy via factory and capture the returned address
        address deployedAddress = walletFactory.createWallet(initialOwner);

        // The return value should match our predicted create address
        assertEq(deployedAddress, expectedDeployedAddress, "deployed address mismatch");

        // The factory should report the new wallet as valid/provenance-known
        assertTrue(walletFactory.isValidWallet(deployedAddress), "factory did not register wallet");

        // Instantiate Wallet wrapper for assertions
        Wallet createdWallet = Wallet(payable(deployedAddress));

        // The wallet owner should match the provided initial owner
        assertEq(createdWallet.owner(), initialOwner, "wallet owner not set correctly");

        // Verify router-only call path: impersonate the Router and call a router-only function.
        // We expect the call to revert with InsufficientFunds (not an auth error) because the Wallet has no funds.
        vm.startPrank(address(router));
        vm.expectRevert(Wallet.InsufficientFunds.selector);
        // lockEscrow(spender, token, amount) - passing sample values; only Router may call.
        createdWallet.lockEscrow(address(0), address(0), 1);
        vm.stopPrank();
    }

    /// @notice Wallets deployed directly (not via the factory) must not be considered valid by the factory.
    /// @dev Deploys a Wallet from an arbitrary EOA and verifies isValidWallet returns false.
    function test_Succeeds_When_WalletDeployedDirectly_IsNotRecognizedByFactory(address deployer) public {
        vm.assume(deployer != address(0));
        vm.startPrank(deployer);

        // Deploy a Wallet directly (bypassing the factory)
        Wallet directWallet = new Wallet(address(router), deployer);

        // The factory should not mark this directly-deployed wallet as valid
        assertFalse(walletFactory.isValidWallet(address(directWallet)), "directly deployed wallet incorrectly registered");

        vm.stopPrank();
    }
}
