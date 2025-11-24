// /Users/nol/work/noosphere/noosphere-evm/webapp/src/node.js

const path = require('path');
const {Commitment} = require("./commitment");
require('dotenv').config({ path: path.resolve(__dirname, '../../.env') });

const ethers = require('ethers');

// --- Path Resolution ---
const projectRoot = path.resolve(__dirname, '../..');

// --- Artifacts ---
const CoordinatorArtifact = require(path.join(projectRoot, 'out/DelegateeCoordinator.sol/DelegateeCoordinator.json'));
const ClientArtifact = require(path.join(projectRoot, 'out/MyTransientClient.sol/MyTransientClient.json'));
const RouterArtifact = require(path.join(projectRoot, 'out/Router.sol/Router.json'));
const WalletFactoryArtifact = require(path.join(projectRoot, 'out/WalletFactory.sol/WalletFactory.json'));
const WalletArtifact = require(path.join(projectRoot, 'out/Wallet.sol/Wallet.json'));

// Define a timeout for how long the agent will listen for events.
const LISTEN_TIMEOUT_MS = 15 * 1000; // 30 seconds

// Dynamically load a contract address from the latest deployment.
function getLatestDeploymentAddress(contractName) {
    try {
        const broadcast = require(path.join(projectRoot, 'broadcast/DeployTest.sol/31337/run-latest.json'));
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

/**
 * Replicates the logic of RequestIdUtils.requestIdPacked in Solidity.
 * keccak256(abi.encodePacked(uint64, uint32))
 * @param {bigint | number | string} subscriptionId - The subscription ID (uint64).
 * @param {number} interval - The interval (uint32).
 * @returns {string} The calculated request ID (bytes32).
 */
function calculateRequestIdPacked(subscriptionId, interval) {
    return ethers.solidityPackedKeccak256(
        ['uint64', 'uint32'],
        [subscriptionId, interval]
    );
}

/**
 * Replicates the logic of CommitmentUtils.build in Solidity.
 * Creates a Commitment instance from subscription data and other parameters.
 * @param {object} sub - The compute subscription object from the contract.
 * @param {bigint | number | string} subscriptionId - The subscription ID (uint64).
 * @param {number} interval - The interval for which the commitment is being created (uint32).
 * @param {string} coordinator - The address of the coordinator.
 * @returns {Commitment} A new Commitment instance.
 */
function buildCommitment(sub, subscriptionId, interval, coordinator) {
    const requestId = calculateRequestIdPacked(subscriptionId, interval);

    // Note: The field names in the `sub` object from ethers.js match the Solidity struct.
    // The Commitment class constructor expects `walletAddress`, so we map `sub.wallet` to it.
    const commitmentParams = {
        requestId: requestId,
        subscriptionId: subscriptionId,
        containerId: sub.containerId,
        interval: interval,
        useDeliveryInbox: sub.useDeliveryInbox,
        redundancy: sub.redundancy,
        walletAddress: sub.wallet, // Map sub.wallet to walletAddress
        feeAmount: sub.feeAmount,
        feeToken: sub.feeToken,
        verifier: sub.verifier,
        coordinator: coordinator
    };
    return new Commitment(commitmentParams);
}

// --- Graceful Shutdown ---

// Store references for cleanup
let provider;
let coordinatorContract;
let shutdownTimer;

function shutdown(reason) {
    console.log(`\n🤖 Node shutting down... (Reason: ${reason})`);
    clearTimeout(shutdownTimer); // Prevent multiple shutdowns
    if (coordinatorContract) {
        console.log("   Removing all event listeners...");
        coordinatorContract.removeAllListeners();
    }
    if (provider) {
        console.log("   Destroying provider connection...");
        provider.destroy();
    }
}

async function main() {
    console.log("🤖 Node starting up...");

    const rpcUrl = process.env.RPC_URL;

    const COORDINATOR_ADDRESS = getLatestDeploymentAddress('Coordinator');
    const CLIENT_ADDRESS = getLatestDeploymentAddress('MyTransientClient');
    const ROUTER_ADDRESS = getLatestDeploymentAddress('Router');

    if (!COORDINATOR_ADDRESS || !CLIENT_ADDRESS || !ROUTER_ADDRESS) {
        console.error("Error: Could not find Coordinator, MyTransientClient, or Router address. Please deploy contracts first.");
        process.exit(1);
    }

    provider = new ethers.JsonRpcProvider(rpcUrl);

    if (!rpcUrl) {
        console.error("Error: RPC_URL is not set in the .env file.");
        process.exit(1);
    }
    // For E2E tests, we dynamically get the second signer provided by the Anvil node.
    const nodeSigner = await provider.getSigner(1);
    console.log(`   Node Signer (EOA): ${nodeSigner.address}`);

    coordinatorContract = new ethers.Contract(COORDINATOR_ADDRESS, CoordinatorArtifact.abi, nodeSigner);
    const routerContract = new ethers.Contract(ROUTER_ADDRESS, RouterArtifact.abi, provider);

    console.log(`   Router Address: ${ROUTER_ADDRESS}`);
    const coordinatorId = ethers.encodeBytes32String("Coordinator_v1.0.0");
    const coordinatorAddress = await routerContract.getContractById(coordinatorId);
    console.log(`   Coordinator Address for routeId "Coordinator_v1.0.0" : ${coordinatorAddress}`);



    // --- Create a dedicated Wallet for the Node to receive payments ---
    console.log("\n🤖 Ensuring node has a payment wallet...");
    const walletFactoryAddress = await routerContract.getWalletFactory();
    if (walletFactoryAddress === ethers.ZeroAddress) {
        throw new Error("WalletFactory address is not set on the Router.");
    }
    const walletFactoryContract = new ethers.Contract(walletFactoryAddress, WalletFactoryArtifact.abi, nodeSigner);

    // Check if a wallet already exists for this node's EOA. For this script, we'll just create a new one each time for simplicity.
    // A real-world agent would persist this address.
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

    // Set a timer to automatically shut down the agent after a certain period.
    shutdownTimer = setTimeout(() => shutdown('timeout'), LISTEN_TIMEOUT_MS);
    console.log(`   Agent will automatically shut down in ${LISTEN_TIMEOUT_MS / 1000} seconds.`);

    console.log(`   Listening for 'RequestStarted' events on Coordinator at ${COORDINATOR_ADDRESS}...`);



    // Listen for the RequestStarted event from the Coordinator
    coordinatorContract.on("RequestStarted", async (requestId, subscriptionId, containerId, commitment) => {
        console.log("\n⚡️ New Request Detected!");
        console.log(`   Request ID: ${requestId}`);
        console.log(`   Subscription ID: ${subscriptionId}`);

        // The commitment contains the client's wallet address, which emits the 'RequestDisbursed' event.
        const clientWalletAddress = commitment.walletAddress;
        const clientWalletContract = new ethers.Contract(clientWalletAddress, WalletArtifact.abi, provider);

        // Get balance BEFORE reporting
        const balanceBefore = await provider.getBalance(nodePaymentWalletAddress);
        console.log(`   Node Payment Wallet balance before report: ${ethers.formatEther(balanceBefore)} ETH`);

        try {
            // 1. Get the inputs for the computation from the client contract
            console.log("   1. Fetching compute inputs...");
            const subscription = await routerContract.getComputeSubscription(commitment.subscriptionId);
            const clientContract = new ethers.Contract(subscription.client, ClientArtifact.abi, provider); // Read-only is fine
            const inputs = await clientContract.getComputeInputs(subscriptionId, commitment.interval, now(), nodePaymentWalletAddress);
            console.log(`      Inputs received: ${inputs}`);

            // [EXAMPLE] Get the delegated signer from the client contract
            console.log("   -> Fetching delegated signer from client contract...");
            const delegatedSigner = await clientContract.getSigner();
            console.log(`      Delegated Signer for client ${await clientContract.getAddress()}: ${delegatedSigner}`);
            // This delegatedSigner address is the one that would be used to sign off-chain messages for `createSubscriptionDelegatee`.

            // 2. "Perform" the computation and convert output to hex
            const timestamp = new Date().toISOString();
            // Generate a long string for testing purposes (approx. 1000 chars)
            const longText = "This is a long string for testing data transmission. It repeats multiple times to increase its length and simulate a more realistic payload that a compute job might return. This helps in verifying that the system can handle larger data sizes without issues. 1. ".repeat(5);
            const rawOutput = `I am GPT. Processed at: ${timestamp}. Inputs: ${ethers.toUtf8String(inputs)}. Payload: ${longText}`;
            const outputBytes = ethers.hexlify(ethers.toUtf8Bytes(rawOutput));

            console.log(`   2. Computation finished. Output: "${rawOutput}" (bytes: ${outputBytes})`);

            // 3. Verify commitment data from multiple sources and prepare for reporting
            console.log("   3. Verifying commitment data and preparing report...");
            // const subscription = await routerContract.getComputeSubscription(subscriptionId);

            // Source 1: From the event itself
            const eventCommitment = new Commitment(commitment);

            // Source 3: Fetched directly from the Coordinator contract
            const onchainCommitmentResult = await coordinatorContract.getCommitment(subscriptionId, commitment.interval);
            const onchainCommitment = new Commitment(onchainCommitmentResult);

            // Compare all three sources. We'll use the encoded hash for a definitive check.
            const eventHash = ethers.keccak256(eventCommitment.encode());
            const onchainHash = ethers.keccak256(onchainCommitment.encode());


            if (eventHash !== onchainHash) {
                console.warn("   ⚠️ CRITICAL: Commitment data mismatch between sources!");
                console.warn(`      - Event Hash:         ${eventHash}`);
                console.warn(`      - On-chain Hash:      ${onchainHash}`);
                // In a real-world scenario, you might want to halt processing here.
            } else {
                console.log("   ✅ Commitment data verified across all sources (event, on-chain).");
            }


            // 4. Report the result back to the Coordinator
            console.log("   4. Reporting compute result to Coordinator...");
            console.log(`      Commitment Details:`);
            console.log(`         Request ID: ${eventCommitment.data.requestId}`);
            console.log(`         Subscription ID: ${eventCommitment.data.subscriptionId}`);
            console.log(`         Container ID: ${eventCommitment.data.containerId}`);
            console.log(`         Interval: ${eventCommitment.data.interval}`);
            console.log(`         Use Delivery Inbox: ${eventCommitment.data.useDeliveryInbox}`);
            console.log(`         Redundancy: ${eventCommitment.data.redundancy}`);
            console.log(`         Wallet Address: ${eventCommitment.data.walletAddress}`);
            console.log(`         Fee Amount: ${eventCommitment.data.feeAmount}`);
            console.log(`         Fee Token: ${eventCommitment.data.feeToken}`);
            console.log(`         Verifier: ${eventCommitment.data.verifier}`);
            console.log(`         Coordinator: ${eventCommitment.data.coordinator}`);


            const reportTx = await coordinatorContract.reportComputeResult(
                commitment.interval,
                inputs,
                outputBytes,
                "0x", // proof (placeholder)
                eventCommitment.encode(), // Use the reconstructed data for the report
                nodePaymentWalletAddress // The node's dedicated Wallet contract that will receive payment
            );

            console.log(`      Transaction sent! Hash: ${reportTx.hash}`);
            const reportReceipt = await reportTx.wait(1);
            console.log("   ✅ Result reported to Coordinator successfully!");

            // 5. Find the settlement event in the receipt and verify payment
            console.log("   5. Finding settlement event (RequestProcessed) in transaction receipt...");

            let requestProcessedEvent;
            for (const log of reportReceipt.logs) {
                // Only try to parse logs from the Router contract
                if (log.address.toLowerCase() !== ROUTER_ADDRESS.toLowerCase()) continue;

                const parsedLog = routerContract.interface.parseLog(log);
                if (parsedLog && parsedLog.name === "RequestProcessed" && parsedLog.args.requestId === requestId) {
                    requestProcessedEvent = parsedLog;
                    break; // Found our event, no need to look further
                }
            }

            if (requestProcessedEvent) {
                console.log("   ✅ Settlement event (RequesProcessed) detected!");
                const eventBlockNumber = requestProcessedEvent.blockNumber;
                console.log(`      Block: ${eventBlockNumber}, Tx: ${reportReceipt.hash}`);

                // --- DEBUG: Check for the RequestDisbursed event in the same block ---
                console.log("   🔍 Verifying actual disbursement by checking for RequestDisbursed event...");
                const disbursedEvents = await clientWalletContract.queryFilter(
                    clientWalletContract.filters.RequestDisbursed(requestId),
                    eventBlockNumber,
                    eventBlockNumber
                );
                // Find the specific disbursement event that paid our node's wallet for this request
                const ourDisbursedEvent = disbursedEvents.find(e => e.args.to === nodePaymentWalletAddress);

                if (ourDisbursedEvent) {
                    console.log(`      -> Found RequestDisbursed event for our wallet: ${ourDisbursedEvent.args.to} of ${ethers.formatEther(ourDisbursedEvent.args.amount)} ETH`);
                } else {
                    console.log(`      -> CRITICAL: RequestDisbursed event for our wallet (${nodePaymentWalletAddress}) was NOT found.`);
                }
                await new Promise(resolve => setTimeout(resolve, 2000));
                const balanceAfter = await provider.getBalance(nodePaymentWalletAddress);
                console.log(`   Node Payment Wallet balance after report:  ${ethers.formatEther(balanceAfter)} ETH`);
                if (balanceAfter > balanceBefore) {
                    console.log("   🎉 Payment received successfully!");
                } else {
                    console.warn("   🤔 Payment not reflected in balance.");
                }
            } else {
                console.error("   ❌ CRITICAL: RequestProcessed event was not found in the transaction receipt!");
            }

        } catch (error) {
            console.error("   ❌ Error processing request:", error);
        }
    });
}
main().catch((error) => {
    console.error("Node failed to start:", error);
    process.exit(1);
});

// Handle external shutdown signals (e.g., Ctrl+C or from concurrently)
process.on('SIGTERM', () => shutdown('signal'));
process.on('SIGINT', () => shutdown('signal'));