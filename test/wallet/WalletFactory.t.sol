// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {Coordinator} from "../../src/v1_0_0/Coordinator.sol";
import {Router} from "../../src/v1_0_0/Router.sol";
import {Wallet} from "../../src/v1_0_0/wallet/Wallet.sol";
import {WalletFactory} from "../../src/v1_0_0/wallet/WalletFactory.sol";
import {DeployUtils} from "../lib/DeployUtils.sol";
import {Test} from "forge-std/Test.sol";

/// @title WalletFactoryTest
/// @notice Unit tests for WalletFactory deployment behavior and basic Router/Wallet integration.
/// @dev Uses Forge vm utilities to deterministically predict addresses and impersonate callers.
///      Tests assert provenance (factory-registered wallets) and Router-restricted wallet entrypoints.
contract WalletFactoryTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 FIXTURE
    //////////////////////////////////////////////////////////////*/

    /// @notice WalletFactory under test
    WalletFactory internal walletFactory;

    /// @notice Router instance deployed by LibDeploy
    Router internal router;

    /// @notice Coordinator instance deployed by LibDeploy (present for completeness)
    Coordinator internal coordinator;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy Router / Coordinator / WalletFactory via LibDeploy and wire Router -> WalletFactory.
    function setUp() public {
        // Deploy core contracts. LibDeploy returns (Router, Coordinator, SubscriptionBatchReader , WalletFactory)
        (Router deployedRouter, Coordinator deployedCoordinator,, WalletFactory deployedWalletFactory) =
            DeployUtils.deployContracts(address(this), address(0), 1, address(0));

        router = deployedRouter;
        coordinator = deployedCoordinator;
        walletFactory = deployedWalletFactory;

        // Complete wiring: inform Router about the WalletFactory address
        router.setWalletFactory(address(walletFactory));
    }

    /*//////////////////////////////////////////////////////////////
                                    TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Creating a Wallet via the factory should:
    ///         - deploy to the predictable CREATE address,
    ///         - register the wallet as factory-created,
    ///         - initialize the wallet owner,
    ///         - and allow Router-only calls (we verify by impersonating Router and observing an expected InsufficientFunds revert).
    function test_Succeeds_When_WalletCreatedByFactory_IsRegisteredAndRouterRestricted(address initialOwner) public {
        // skip zero address owners — factory requires a non-zero initial owner
        vm.assume(initialOwner != address(0));

        // predict next create address for factory
        uint256 factoryNonce = vm.getNonce(address(walletFactory));
        address expectedAddress = vm.computeCreateAddress(address(walletFactory), factoryNonce);

        // expect WalletCreated event to be emitted by the factory
        vm.expectEmit(true, true, false, false, address(walletFactory));
        emit WalletFactory.WalletCreated(address(this), initialOwner, expectedAddress);

        // create wallet via factory
        address deployed = walletFactory.createWallet(initialOwner);

        // returned address must match predicted address
        assertEq(deployed, expectedAddress, "deployed address mismatch");

        // factory should mark the wallet as valid / provenance-known
        assertTrue(walletFactory.isValidWallet(deployed), "factory did not register wallet");

        // instantiate wallet for assertions
        Wallet created = Wallet(payable(deployed));

        // wallet owner should be set to initialOwner
        assertEq(created.owner(), initialOwner, "wallet owner mismatch");

        // impersonate Router and call a Router-only function to verify routing auth path works;
        // since the wallet has no funds, the call should revert with InsufficientFunds (auth passed).
        vm.startPrank(address(router));
        vm.expectRevert(Wallet.InsufficientFunds.selector);
        created.lockEscrow(address(0), address(0), 1);
        vm.stopPrank();
    }

    /// @notice Wallets deployed directly (not created by the factory) must not be considered valid by the factory.
    /// @dev Deploys a Wallet from an arbitrary EOA and checks that isValidWallet returns false.
    function test_Succeeds_When_DirectlyDeployedWallet_IsNotRecognizedByFactory(address deployer) public {
        vm.assume(deployer != address(0));

        // impersonate deployer to increase entropy of the deployed address
        vm.startPrank(deployer);
        Wallet direct = new Wallet(address(router), deployer);
        vm.stopPrank();

        // factory should not register this directly deployed wallet
        assertFalse(walletFactory.isValidWallet(address(direct)), "directly deployed wallet incorrectly registered");
    }
}
