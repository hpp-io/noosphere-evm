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

    const provider = new ethers.JsonRpcProvider(rpcUrl);

    if (!rpcUrl) {
        console.error("Error: RPC_URL is not set in the .env file.");
        process.exit(1);
    }
    // For E2E tests, we dynamically get the second signer provided by the Anvil node.
    const nodeSigner = await provider.getSigner(1);
    console.log(`   Node Signer (EOA): ${nodeSigner.address}`);

    const coordinatorContract = new ethers.Contract(COORDINATOR_ADDRESS, CoordinatorArtifact.abi, nodeSigner);
    const clientContract = new ethers.Contract(CLIENT_ADDRESS, ClientArtifact.abi, provider); // Read-only is fine
    const routerContract = new ethers.Contract(ROUTER_ADDRESS, RouterArtifact.abi, provider);

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
            const inputs = await clientContract.getComputeInputs(subscriptionId, 1, now(), nodePaymentWalletAddress);
            console.log(`      Inputs received: ${inputs}`);

            // 2. "Perform" the computation (we'll just return a dummy value)
            const output = "0x5678"; // Our "computed" result
            console.log(`   2. Computation finished. Output: ${output}`);

            // 3. Prepare the data to report back to the coordinator
            const commitmentInstance = new Commitment(commitment);
            const commitmentData = commitmentInstance.encode();

            // 4. Report the result back to the Coordinator
            console.log("   3. Reporting compute result to Coordinator...");
            const reportTx = await coordinatorContract.reportComputeResult(
                commitment.interval,
                inputs,
                output,
                "0x", // proof
                commitmentData,
                nodePaymentWalletAddress // The node's dedicated Wallet contract that will receive payment
            );

            console.log(`      Transaction sent! Hash: ${reportTx.hash}`);
            const reportReceipt = await reportTx.wait(1);
            console.log("   ✅ Result reported to Coordinator successfully!");

            // 5. Find the settlement event in the receipt and verify payment
            console.log("   4. Finding settlement event (RequestProcessed) in transaction receipt...");

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
                console.log("   ✅ Settlement event (RequestProcessed) detected!");
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