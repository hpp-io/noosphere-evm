// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {BillingConfig} from "../../src/v1_0_0/types/BillingConfig.sol";
import {DelegateeCoordinator} from "../../src/v1_0_0/DelegateeCoordinator.sol";
import {SubscriptionBatchReader} from "../../src/v1_0_0/utility/SubscriptionBatchReader.sol";
import {Router} from "../../src/v1_0_0/Router.sol";
import {Vm} from "forge-std/Vm.sol";
import {OptimisticVerifier} from "../../src/v1_0_0/verifier/OptimisticVerifier.sol";
import {WalletFactory} from "../../src/v1_0_0/wallet/WalletFactory.sol";

/// @title LibDeploy
/// @notice Small deployment helpers used by tests to deploy and wire protocol contracts.
/// @dev The library purposefully keeps deployment logic minimal and splits complex constructor
///      initialization into helper functions to avoid "stack too deep" issues inside a single function.
library DeployUtils {
    struct DeployedContracts {
        Router router;
        DelegateeCoordinator coordinator;
        SubscriptionBatchReader reader;
        OptimisticVerifier optimisticVerifier;
        WalletFactory walletFactory;
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
    /// @param initialFeeRecipient Address that will receive protocol fees during test setup.
    /// @param initialFee Protocol fee (basis points or protocol-defined unit).
    /// @param tokenAddr Optional token address used for tick fees / mocks (may be address(0)).
    /// @return contracts A struct containing all deployed contract instances.
    function deployContracts(
        address deployerAddress,
        address initialFeeRecipient,
        uint16 initialFee,
        address tokenAddr
    ) internal returns (DeployedContracts memory contracts) {
        Router router;
        DelegateeCoordinator coordinator;

        // Deploy Router first (dependency for the other contracts).
        router = new Router();

        // Deploy delegatee coordinator and initialize its billing config via helper.
        coordinator = _deployCoordinator(address(router), deployerAddress, initialFeeRecipient, initialFee, tokenAddr);

        // Deploy lightweight reader and wallet factory wired to the router + coordinator.
        contracts.reader = new SubscriptionBatchReader(address(router), address(coordinator));
        contracts.walletFactory = new WalletFactory(address(router));
        coordinator.setSubscriptionBatchReader(address(contracts.reader));

        // Deploy OptimisticVerifier
        contracts.optimisticVerifier = new OptimisticVerifier(
            address(coordinator),
            initialFeeRecipient, // Using initialFeeRecipient as paymentRecipient for tests
            deployerAddress // Using deployerAddress as initialOwner
        );

        // Register Coordinator into the Router's contract registry so lookups succeed.
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = "Coordinator_v1.0.0";
        address[] memory addrs = new address[](1);
        addrs[0] = address(coordinator);

        router.proposeContractsUpdate(ids, addrs);
        router.updateContracts();

        contracts.router = router;
        contracts.coordinator = coordinator;

        return contracts;
    }

    /*//////////////////////////////////////////////////////////////////////////
                             CONFIGURATION HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Convenience helper to update Coordinator billing configuration in tests.
    /// @param coordinator DelegateeCoordinator instance to configure.
    /// @param verificationTimeout Timeout used by verifier-related logic.
    /// @param protocolFeeRecipient Recipient address for protocol fees.
    /// @param protocolFee Protocol fee value.
    /// @param tickNodeFee Per-tick node fee paid to nodes.
    /// @param tickNodeFeeToken Token used to pay tick node fees.
    function updateBillingConfig(
        DelegateeCoordinator coordinator,
        uint32 verificationTimeout,
        address protocolFeeRecipient,
        uint16 protocolFee,
        uint256 tickNodeFee,
        address tickNodeFeeToken
    ) internal {
        coordinator.updateConfig(
            BillingConfig({
                verificationTimeout: verificationTimeout,
                protocolFeeRecipient: protocolFeeRecipient,
                protocolFee: protocolFee,
                tickNodeFee: tickNodeFee,
                tickNodeFeeToken: tickNodeFeeToken
            })
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                               INTERNAL HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Internal helper to deploy and initialize the DelegateeCoordinator.
    ///      Split out to reduce local variable pressure in `deployContracts`.
    function _deployCoordinator(
        address routerAddress,
        address client,
        address initialFeeRecipient,
        uint16 protocolFee,
        address tokenAddr
    ) private returns (DelegateeCoordinator) {
        // Deploy coordinator with minimal constructor args.
        DelegateeCoordinator coordinator = new DelegateeCoordinator(routerAddress, client);

        // Initialize billing configuration in a separate transaction to avoid constructor complexity.
        coordinator.initialize(
            BillingConfig({
                verificationTimeout: 1 weeks,
                protocolFeeRecipient: initialFeeRecipient,
                protocolFee: protocolFee,
                tickNodeFee: 0,
                tickNodeFeeToken: tokenAddr
            })
        );

        return coordinator;
    }
}
