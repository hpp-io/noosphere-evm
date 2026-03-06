// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {BillingConfig} from "../src/v1_0_0/types/BillingConfig.sol";
import {DelegateeCoordinator} from "../src/v1_0_0/DelegateeCoordinator.sol";
import {ImmediateFinalizeVerifier} from "../src/v1_0_0/verifier/ImmediateFinalizeVerifier.sol";
import {Router} from "../src/v1_0_0/Router.sol";
import {SubscriptionBatchReader} from "../src/v1_0_0/utility/SubscriptionBatchReader.sol";
import {WalletFactory} from "../src/v1_0_0/wallet/WalletFactory.sol";

/// @title DeployMainnet
/// @notice Deploys noosphere protocol to mainnet. The Deployer acts as temporary Owner,
///         performing contract deployment (Phase 1), configuration (Phase 2), and ownership
///         transfer to Safe multisigs (Phase 3) in a single script execution.
///
/// Required environment variables:
///   PRIVATE_KEY                              – Deployer private key (temporary owner)
///   IMMEDIATE_FINALIZE_VERIFIER_OWNER_ADDR   – Verifier Safe address
///
/// Usage:
///   forge script scripts/DeployMainnet.sol:DeployMainnet \
///     --broadcast --rpc-url $RPC_URL \
///     --sig "run(address,address)" <PROTOCOL_SAFE> <FEE_RECIPIENT>
contract DeployMainnet is Script {
    function run(address _protocolSafe, address _initialFeeRecipient) public {
        address deployer = msg.sender;
        address verifierSafe = vm.envAddress("IMMEDIATE_FINALIZE_VERIFIER_OWNER_ADDR");

        require(_protocolSafe != address(0), "DeployMainnet: Protocol Safe address cannot be zero");
        require(_initialFeeRecipient != address(0), "DeployMainnet: Fee recipient address cannot be zero");
        require(verifierSafe != address(0), "DeployMainnet: Verifier Safe address cannot be zero");
        require(_protocolSafe != deployer, "DeployMainnet: Protocol Safe must differ from deployer");

        console.log("=== DeployMainnet: environment ===");
        console.log("Deployer:          ", deployer);
        console.log("Chain ID:          ", block.chainid);
        console.log("Protocol Safe:     ", _protocolSafe);
        console.log("Verifier Safe:     ", verifierSafe);
        console.log("Fee Recipient:     ", _initialFeeRecipient);
        console.log("==================================");

        vm.startBroadcast();

        // ─── Phase 1: Contract deployment (Deployer = temporary Owner) ───

        Router router = new Router(deployer);
        DelegateeCoordinator coordinator = new DelegateeCoordinator(address(router), deployer);
        SubscriptionBatchReader reader = new SubscriptionBatchReader(address(router), address(coordinator));
        WalletFactory walletFactory = new WalletFactory(address(router));
        ImmediateFinalizeVerifier verifier = new ImmediateFinalizeVerifier(address(coordinator), deployer);

        // ─── Phase 2: Configuration (Deployer as temporary Owner) ───

        router.setWalletFactory(address(walletFactory));

        address protocolWallet = walletFactory.createWallet(_initialFeeRecipient);

        coordinator.initialize(
            BillingConfig({
                verificationTimeout: 1 weeks,
                protocolFeeRecipient: protocolWallet,
                protocolFee: 100, // 1%
                tickNodeFee: 0,
                tickNodeFeeToken: address(0)
            })
        );

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = "Coordinator_v1.0.0";
        address[] memory addrs = new address[](1);
        addrs[0] = address(coordinator);

        router.proposeContractsUpdate(ids, addrs);
        router.updateContracts();

        verifier.setTokenSupported(address(0), true);
        coordinator.setSubscriptionBatchReader(address(reader));

        // ─── Phase 3: Ownership transfer (Deployer → Safe) ───

        // Router & Coordinator: ConfirmedOwner (2-step transfer)
        // Safe must call acceptOwnership() after this script completes
        router.transferOwnership(_protocolSafe);
        coordinator.transferOwnership(_protocolSafe);

        // Verifier: OZ Ownable (1-step transfer, immediate)
        verifier.transferOwnership(verifierSafe);

        vm.stopBroadcast();

        // ─── Summary ───

        console.log("=== DeployMainnet: summary ===");
        console.log("Router:              ", address(router));
        console.log("Coordinator:         ", address(coordinator));
        console.log("Reader:              ", address(reader));
        console.log("WalletFactory:       ", address(walletFactory));
        console.log("Verifier:            ", address(verifier));
        console.log("Protocol Wallet:     ", protocolWallet);
        console.log("==============================");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("  1. Fund Protocol Safe with gas via Ops dashboard");
        console.log("  2. Protocol Safe: call Router.acceptOwnership()");
        console.log("  3. Protocol Safe: call Coordinator.acceptOwnership()");
        console.log("  4. Deploy VRF: make deploy-vrf-hpp-mainnet");
    }
}
