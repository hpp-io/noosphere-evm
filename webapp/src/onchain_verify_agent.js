const path = require('path');
const {Commitment} = require("./commitment");
require('dotenv').config({path: path.resolve(__dirname, '../../.env')});

const ethers = require('ethers');

// --- Path Resolution ---
const projectRoot = path.resolve(__dirname, '../..');

// --- Artifacts ---
const CoordinatorArtifact = require(path.join(projectRoot, 'out/DelegateeCoordinator.sol/DelegateeCoordinator.json'));
const ClientArtifact = require(path.join(projectRoot, 'out/MyTransientClient.sol/MyTransientClient.json'));
const RouterArtifact = require(path.join(projectRoot, 'out/Router.sol/Router.json'));
const WalletFactoryArtifact = require(path.join(projectRoot, 'out/WalletFactory.sol/WalletFactory.json'));
const WalletArtifact = require(path.join(projectRoot, 'out/Wallet.sol/Wallet.json'));
const ImmediateFinalizeVerifierArtifact = require(path.join(projectRoot, 'out/ImmediateFinalizeVerifier.sol/ImmediateFinalizeVerifier.json'));

// Dynamically load a contract address from the latest deployment.
function getLatestDeploymentAddress(contractName) {
    try {
        const broadcast = require(path.join(projectRoot, 'broadcast/Deploy.sol/31337/run-latest.json'));
        const deployment = broadcast.transactions.find(
            (tx) => tx.transactionType === 'CREATE' && (tx.contractName === contractName || (contractName === 'Coordinator' && tx.contractName === 'DelegateeCoordinator'))
        );
        return deployment?.contractAddress;
    } catch (e) {
        console.error(`Could not find or parse broadcast file for chain 31337.`, e);
        return undefined;
    }
}

// Returns the current timestamp in seconds.
const now = () => Math.floor(Date.now() / 1000);

// --- Constants ---
const MIN_FUNDS = ethers.parseEther("0.1"); // Minimum funds for bond + gas

// Global map to store initial balances for requests
const initialBalances = new Map();

async function main() {
    console.log("🤖 Onchain-Verify Agent (ImmediateFinalize) starting up...");
    const rpcUrl = process.env.RPC_URL;
    const COORDINATOR_ADDRESS = getLatestDeploymentAddress('Coordinator');
    const CLIENT_ADDRESS = getLatestDeploymentAddress('MyTransientClient');
    const ROUTER_ADDRESS = getLatestDeploymentAddress('Router');
    const IMMEDIATE_FINALIZE_VERIFIER_ADDRESS = getLatestDeploymentAddress('ImmediateFinalizeVerifier');

    if (!COORDINATOR_ADDRESS || !CLIENT_ADDRESS || !ROUTER_ADDRESS || !IMMEDIATE_FINALIZE_VERIFIER_ADDRESS) {
        console.error(
            "Error: Could not find Coordinator, MyTransientClient, Router, or ImmediateFinalizeVerifier address. Please deploy contracts first."
        );
        process.exit(1);
    }

    const provider = new ethers.JsonRpcProvider(rpcUrl);

    if (!rpcUrl) {
        console.error("Error: RPC_URL is not set in the .env file.");
        process.exit(1);
    }
    // For E2E tests, we dynamically get the second signer provided by the Anvil node.
    const nodeSigner = await provider.getSigner(6); // Changed to match the actual signing account (0x4C6ee0b119D9e17B7EF65Ca74C2EFe4C40E56710)
    console.log(`   Node Signer (EOA): ${nodeSigner.address}`);

    const coordinatorContract = new ethers.Contract(COORDINATOR_ADDRESS, CoordinatorArtifact.abi, nodeSigner);
    const clientContract = new ethers.Contract(CLIENT_ADDRESS, ClientArtifact.abi, provider); // Read-only is fine
    const routerContract = new ethers.Contract(ROUTER_ADDRESS, RouterArtifact.abi, provider);
    const verifierContract = new ethers.Contract(IMMEDIATE_FINALIZE_VERIFIER_ADDRESS, ImmediateFinalizeVerifierArtifact.abi, provider);

    // --- Create a dedicated Wallet for the Node to receive payments ---
    console.log("\n🤖 Ensuring node has a payment wallet...");
    const walletFactoryAddress = await routerContract.getWalletFactory();
    if (walletFactoryAddress === ethers.ZeroAddress) {
        throw new Error("WalletFactory address is not set on the Router.");
    }
    const walletFactoryContract = new ethers.Contract(walletFactoryAddress, WalletFactoryArtifact.abi, nodeSigner);

    console.log("   Creating a new wallet for the node...");
    const createWalletTx = await walletFactoryContract.createWallet(nodeSigner.address);
    const createWalletReceipt = await createWalletTx.wait(1);

    const walletCreatedEvents = await walletFactoryContract.queryFilter("WalletCreated", createWalletReceipt.blockNumber, createWalletReceipt.blockNumber);
    const ourWalletEvent = walletCreatedEvents.find(e => e.transactionHash === createWalletTx.hash);
    if (!ourWalletEvent) {
        throw new Error("Could not find 'WalletCreated' event for the node's wallet.");
    }
    const nodePaymentWalletAddress = ourWalletEvent.args.walletAddress;
    console.log(`   ✅ Node Payment Wallet created! Address: ${nodePaymentWalletAddress}`);

    // --- Ensure node payment wallet has sufficient funds and is approved for the node signer ---
    console.log("\n💰 Ensuring node payment wallet has sufficient funds and approval for the Node Signer...");
    const nodePaymentWalletContract = new ethers.Contract(nodePaymentWalletAddress, WalletArtifact.abi, nodeSigner);

    let currentWalletBalance = await provider.getBalance(nodePaymentWalletAddress);
    console.log(`   Current Node Payment Wallet balance: ${ethers.formatEther(currentWalletBalance)} ETH`);

    if (currentWalletBalance < MIN_FUNDS) {
        console.log(`   Insufficient funds. Transferring ETH from Node Signer to meet minimum requirement...`);
        const transferTx = await nodeSigner.sendTransaction({
            to: nodePaymentWalletAddress,
            value: MIN_FUNDS - currentWalletBalance
        });
        await transferTx.wait(1);
        currentWalletBalance = await provider.getBalance(nodePaymentWalletAddress); // Update balance
        console.log(`   ✅ Funds transferred. New balance: ${ethers.formatEther(currentWalletBalance)} ETH`);
    } else {
        console.log("   ✅ Node Payment Wallet has sufficient funds.");
    }

    // Approve the Node's EOA (nodeSigner) to spend from the wallet, as it will be the one initiating the reportComputeResult transaction.
    // The Coordinator will then use this allowance.
    console.log(`   Approving Node Signer (${nodeSigner.address}) to spend from the payment wallet...`);
    const approveTx = await nodePaymentWalletContract.approve(nodeSigner.address, ethers.ZeroAddress, ethers.MaxUint256);
    await approveTx.wait(1);
    console.log("   ✅ Node Signer approved for ETH.");

    // --- 🔍 START DEBUGGING: Add a catch-all event listener for the Verifier ---
    console.log("\n[DEBUG] Attaching a catch-all event listener to the routerContract...");
    routerContract.on("*", (event) => {
        console.log(`\n[DEBUG] <<-- 🔬 Router Event Received: ${event.log.eventName} -->>`);
        const argNames = event.log.fragment.inputs.map(input => input.name);
        event.log.args.forEach((arg, i) => {
            console.log(`       - ${argNames[i]} (${event.log.fragment.inputs[i].type}): ${arg.toString()}`);
        });
        console.log(`       (Raw Event: ${JSON.stringify(event, null, 2)})`);
        console.log(`[DEBUG] <<------------------------------------>>`);
    });
    // --- 🔍 END DEBUGGING ---

    // --- 🔍 START DEBUGGING: Add a catch-all event listener for the Verifier ---
    console.log("\n[DEBUG] Attaching a catch-all event listener to the Verifier contract...");
    verifierContract.on("*", (event) => {
        console.log(`\n[DEBUG] <<-- 🔬 Verifier Event Received: ${event.log.eventName} -->>`);
        const argNames = event.log.fragment.inputs.map(input => input.name);
        event.log.args.forEach((arg, i) => {
            console.log(`       - ${argNames[i]} (${event.log.fragment.inputs[i].type}): ${arg.toString()}`);
        });
        console.log(`       (Raw Event: ${JSON.stringify(event, null, 2)})`);
        console.log(`[DEBUG] <<------------------------------------>>`);
    });
    // --- 🔍 END DEBUGGING ---

    // --- 🔍 START DEBUGGING: Add a catch-all event listener ---
    console.log("\n[DEBUG] Attaching a catch-all event listener to the Coordinator contract...");
    coordinatorContract.on("*", (event) => {
        // The event object has a `log` property which is the raw log,
        // and an `args` property with the decoded arguments.
        console.log(`\n[DEBUG] <<-- 📬 Coordinator Event Received: ${event.log.eventName} -->>`);
        const argNames = event.log.fragment.inputs.map(input => input.name);
        event.log.args.forEach((arg, i) => {
            console.log(`       - ${argNames[i]} (${event.log.fragment.inputs[i].type}): ${arg.toString()}`);
        });
        console.log(`       (Raw Event: ${JSON.stringify(event, null, 2)})`);
        console.log(`[DEBUG] <<------------------------------------>>`);
    });


    console.log(`   Listening for 'RequestStarted' events on Coordinator at ${COORDINATOR_ADDRESS}...`);

    // --- Event Listener for Payment Verification ---
    // This listener waits for the final `ProofVerified` event to check the balance.
    coordinatorContract.on("ProofVerified", async (eventSubscriptionId, interval, eventNode, valid) => {
        // The `node` in ProofVerified is the msg.sender to reportVerificationResult, which is the Coordinator.
        // The logic inside the coordinator then uses the submitter address. Let's check against our node's signer address.
        if (valid && eventNode.toLowerCase() === nodeSigner.address.toLowerCase()) { // This condition is for the submitter of the proof
            console.log("\n✅ Proof verified successfully! Checking for payment...");
        } else {
            console.log("\n✅ Proof verified Failed! Checking for payment...");
        }

        // Reconstruct the requestId to look up the initial balance.
        const requestId = ethers.solidityPackedKeccak256(['uint64', 'uint32'], [eventSubscriptionId, interval]);
        const balanceBefore = initialBalances.get(requestId);

        if (balanceBefore === undefined) {
            console.warn(`   ⚠️ Could not retrieve initial balance for requestId ${requestId}. Skipping payment verification.`);
            return;
        }
        initialBalances.delete(requestId); // Clean up the map

        let balanceAfter = balanceBefore; // Initialize with the balance before payment

        // Poll for balance change
        const pollInterval = 2000; // 2 seconds
        const maxAttempts = 15; // 30 seconds timeout
        for (let i = 0; i < maxAttempts; i++) {
            await new Promise(resolve => setTimeout(resolve, pollInterval));
            balanceAfter = await provider.getBalance(nodePaymentWalletAddress);
            if (balanceAfter > balanceBefore) {
                console.log(`   🎉 Payment confirmed after ~${(i + 1) * 2} seconds!`);
                break;
            }
            console.log(`   ...waiting for payment confirmation (${i + 1}/${maxAttempts})`);
        }

        const balanceChange = balanceAfter - balanceBefore;
        console.log("\n      --- 💰 Balance Snapshot ---");
        console.log(`      - Balance Before: ${ethers.formatEther(balanceBefore)} ETH`);
        console.log(`      - Balance After:  ${ethers.formatEther(balanceAfter)} ETH`);
        console.log(`      - Change:         ${ethers.formatEther(balanceChange)} ETH`);
        console.log("      --------------------------");

        if (balanceAfter > balanceBefore) {
            console.log("      ✅ Payment confirmed successfully!");
        } else {
            console.warn("      🤔 Payment not reflected in balance. This is expected if the fee was 0 or the Coordinator does not implement settlement.");
        }
    });

    // Listen for the RequestStarted event from the Coordinator
    coordinatorContract.on("RequestStarted", async (requestId, subscriptionId, containerId, commitmentDataFromEvent) => {
        // Only process requests that use our ImmediateFinalizeVerifier
        if (commitmentDataFromEvent.verifier.toLowerCase() !== IMMEDIATE_FINALIZE_VERIFIER_ADDRESS.toLowerCase()) {
            return;
        }

        console.log("\n⚡️ New Onchain-Verify Request Detected!");
        console.log(`   Request ID: ${requestId}`);
        console.log(`   Subscription ID: ${subscriptionId}`);

        const clientWalletAddress = commitmentDataFromEvent.walletAddress;
        const clientWalletContract = new ethers.Contract(clientWalletAddress, WalletArtifact.abi, provider);

        try {
            // 1. Get the inputs for the computation from the client contract
            console.log("   1. Fetching compute inputs...");
            const inputs = await clientContract.getComputeInputs(subscriptionId, 1, now(), nodePaymentWalletAddress);
            console.log(`      Inputs received: ${inputs}`);

            // 2. "Perform" the computation
            const output = "0x5678"; // Our "computed" result
            console.log(`   2. Computation finished. Output: ${output}`);

            const balanceBeforeReport = await provider.getBalance(nodePaymentWalletAddress);
            console.log(`   Node Payment Wallet balance before report: ${ethers.formatEther(balanceBeforeReport)} ETH`);
            initialBalances.set(requestId, balanceBeforeReport); // Store initial balance for later payment verification

            // 3. Generate an EIP-712 proof
            console.log("   3. Generating EIP-712 proof...");

            // // Use the commitment data directly from the event to ensure hash consistency.
            const commitmentInstance = new Commitment(commitmentDataFromEvent);
            const encodedCommitmentData = commitmentInstance.encode();

            const proofServiceUrl = 'http://localhost:3000/api/service_output';
            const requestBody = {
                // type: 'on-chain',
                data: {
                    requestId: requestId,
                    commitment: {type: 'inline', value: encodedCommitmentData},
                    // Ensure inputs and outputs are consistently hexlified to prevent hash mismatches.
                    input: {type: 'inline', value: ethers.hexlify(ethers.toUtf8Bytes(inputs))},
                    output: {type: 'inline', value: ethers.hexlify(ethers.toUtf8Bytes(output))},
                    timestamp: now()
                }
            };

            let proof;
            try {
                const response = await fetch(proofServiceUrl, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify(requestBody),
                });

                if (!response.ok) {
                    throw new Error(`Proof service returned an error: ${response.status} ${response.statusText}`);
                }

                const responseData = await response.json();
                proof = responseData.proof;
                console.log(`      ✅ Proof received successfully from service.`);

                // The local proof generation block has been removed for clarity.
                // The proof service is the single source of truth for the proof.

            } catch (e) {
                console.error("   ❌ Error getting proof from service:", e);
                throw e; // Stop processing this request if proof generation fails
            }

            // 4. Report the result back to the Coordinator
            console.log("   4. Reporting compute result to Coordinator...");
            const reportTx = await coordinatorContract.reportComputeResult(
                commitmentDataFromEvent.interval,
                ethers.hexlify(ethers.toUtf8Bytes(inputs)),
                ethers.hexlify(ethers.toUtf8Bytes(output)),
                proof,
                encodedCommitmentData,
                nodePaymentWalletAddress
            );

            console.log(`      Transaction sent! Hash: ${reportTx.hash}`);

        } catch (error) {
            console.error("\n   ❌ Error processing request:", error);
        }
    });
}

main().catch((error) => {
    console.error("Node failed to start:", error);
    process.exit(1);
});