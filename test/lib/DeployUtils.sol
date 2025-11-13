// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import "../../src/v1_0_0/verifier/ImmediateFinalizeVerifier.sol";
import {BillingConfig} from "../../src/v1_0_0/types/BillingConfig.sol";
import {DelegateeCoordinator} from "../../src/v1_0_0/DelegateeCoordinator.sol";
import {Router} from "../../src/v1_0_0/Router.sol";
import {SubscriptionBatchReader} from "../../src/v1_0_0/utility/SubscriptionBatchReader.sol";
import {Vm} from "forge-std/Vm.sol";
import {WalletFactory} from "../../src/v1_0_0/wallet/WalletFactory.sol";
import {MockToken} from "../mocks/MockToken.sol";

/// @title LibDeploy
/// @notice Small deployment helpers used by tests to deploy and wire protocol contracts.
/// @dev The library purposefully keeps deployment logic minimal and splits complex constructor
///      initialization into helper functions to avoid "stack too deep" issues inside a single function.
library DeployUtils {
    struct DeployedContracts {
        Router router;
        DelegateeCoordinator coordinator;
        SubscriptionBatchReader reader;
        ImmediateFinalizeVerifier immediateFinalizeVerifier;
        WalletFactory walletFactory;
        MockToken mockToken;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Forge `vm` cheat code handle.
    /// @dev Used by tests for address prediction and low-level utilities. Kept here to avoid
    ///      having to import Vm in every test that wants to use LibDeploy helpers.
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /*//////////////////////////////////////////////////////////////////////////
                              MAIN DEPLOY HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Deploy the core suite of test contracts and wire them into the Router.
    /// @param deployerAddress Address which will be used as the nominal deployer/owner for certain contracts.
    /// @param initialOwner Address that will receive protocol fees during test setup.
    /// @param initialFee Protocol fee (basis points or protocol-defined unit).
    /// @param tokenAddr Optional token address used for tick fees / mocks (may be address(0)).
    /// @return contracts A struct containing all deployed contract instances.
    function deployContracts(address deployerAddress, address initialOwner, uint16 initialFee, address tokenAddr)
        internal
        returns (DeployedContracts memory contracts)
    {
        // --- DEPLOYMENT (as deployerAddress) ---
        contracts.mockToken = new MockToken();
        contracts.mockToken.mint(initialOwner, 1_000_000e18);

        contracts.router = new Router(initialOwner);
        contracts.coordinator = new DelegateeCoordinator(address(contracts.router), initialOwner);
        contracts.reader = new SubscriptionBatchReader(address(contracts.router), address(contracts.coordinator));
        contracts.walletFactory = new WalletFactory(address(contracts.router));
        contracts.immediateFinalizeVerifier =
            new ImmediateFinalizeVerifier(address(contracts.coordinator), initialOwner);
    }

    /// @notice Configures and wires up the deployed contracts.
    /// @dev This function should be called after `deployContracts`. It performs all owner-only actions.
    /// @param contracts A struct containing all deployed contract instances.
    /// @param owner The address that has ownership of the main contracts (e.g., Router, Coordinator).
    function configureContracts(
        DeployedContracts memory contracts,
        address owner,
        address initialFeeRecipient,
        uint16 initialFee,
        address tokenAddr
    ) internal {
        // --- CONFIGURATION (as owner) ---
        // Initialize the Coordinator's billing configuration.
        contracts.coordinator
            .initialize(
                BillingConfig({
                    verificationTimeout: 1 weeks,
                    protocolFeeRecipient: initialFeeRecipient,
                    protocolFee: initialFee,
                    tickNodeFee: 0,
                    tickNodeFeeToken: tokenAddr
                })
            );

        // Register the Coordinator contract in the Router.
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = "Coordinator_v1.0.0";
        address[] memory addrs = new address[](1);
        addrs[0] = address(contracts.coordinator);

        contracts.router.proposeContractsUpdate(ids, addrs);
        contracts.router.updateContracts();

        // Wire up remaining owner-only configurations
        contracts.router.setWalletFactory(address(contracts.walletFactory));
        contracts.immediateFinalizeVerifier.setTokenSupported(address(0), true);
    }
}
