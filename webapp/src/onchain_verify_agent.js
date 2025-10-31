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

    console.log(`   Listening for 'RequestStarted' events on Coordinator at ${COORDINATOR_ADDRESS}...`);

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

        const balanceBefore = await provider.getBalance(nodePaymentWalletAddress);
        console.log(`   Node Payment Wallet balance before report: ${ethers.formatEther(balanceBefore)} ETH`);

        try {
            // 1. Get the inputs for the computation from the client contract
            console.log("   1. Fetching compute inputs...");
            const inputs = await clientContract.getComputeInputs(subscriptionId, 1, now(), nodePaymentWalletAddress);
            console.log(`      Inputs received: ${inputs}`);

            // 2. "Perform" the computation
            const output = "0x5678"; // Our "computed" result
            console.log(`   2. Computation finished. Output: ${output}`);

            // 3. Generate an EIP-712 proof
            console.log("   3. Generating EIP-712 proof...");

            // Use the commitment data directly from the event to ensure hash consistency.
            const commitmentInstance = new Commitment(commitmentDataFromEvent);
            const encodedCommitmentData = commitmentInstance.encode();

            // 1. Define the EIP-712 domain and types, which must match the Verifier contract.

            const domain = {
                name: 'Noosphere Onchain Verifier',
                version: '1',
                chainId: (await provider.getNetwork()).chainId,
                verifyingContract: IMMEDIATE_FINALIZE_VERIFIER_ADDRESS
            };

            const types = {
                ComputeSubmission: [
                    { name: 'requestId', type: 'bytes32' },
                    { name: 'commitmentHash', type: 'bytes32' },
                    { name: 'inputHash', type: 'bytes32' },
                    { name: 'resultHash', type: 'bytes32' },
                    { name: 'nodeAddress', type: 'address' },
                    { name: 'timestamp', type: 'uint256' }
                ]
            };
            //
            // // 2. Prepare the data structure (value) to be signed.
            const timestamp = now();
            const commitmentHash = ethers.keccak256(encodedCommitmentData);
            const inputHash = ethers.keccak256(inputs);
            const resultHash = ethers.keccak256(ethers.toUtf8Bytes(output));

            const proofValue = {
                requestId: requestId,
                commitmentHash: commitmentHash,
                inputHash: inputHash,
                resultHash: resultHash,
                nodeAddress: nodeSigner.address,
                timestamp: timestamp
            };
            //
            // // 3. Sign the typed data. `ethers` handles the digest creation internally.
            const signature = await nodeSigner.signTypedData(domain, types, proofValue);
            //
            const proof1 = ethers.AbiCoder.defaultAbiCoder().encode(
                ['bytes32', 'bytes32', 'bytes32', 'bytes32', 'address', 'uint256', 'bytes'],
                [proofValue.requestId, proofValue.commitmentHash, proofValue.inputHash, proofValue.resultHash, proofValue.nodeAddress, proofValue.timestamp, signature]
            );
            console.log(`      ✅ Proof generated successfully.`);

            const proofServiceUrl = 'http://localhost:3000/api/service_output';
            const requestBody = {
                type: 'on-chain',
                data: {
                    requestId: requestId.toString(),
                    commitment: { type: 'inline', value: encodedCommitmentData},
                    input: { type: 'inline', value: inputs },
                    output: { type: 'inline', value: ethers.hexlify(ethers.toUtf8Bytes(output)) },
                    timestamp: now(),
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

                // --- 🐛 START DEBUGGING: Compare local proof with API proof ---
                console.log("\n   --- 🔍 DEBUG: Comparing Local vs. API Proof Data ---");

                // 1. Generate proof locally for comparison
                const localTimestamp = requestBody.data.timestamp; // Use the same timestamp sent to the API
                const localCommitmentHash = ethers.keccak256(encodedCommitmentData);
                const localInputHash = ethers.keccak256(inputs);
                // Use the same hexlified output for hashing
                const localResultHash = ethers.keccak256(ethers.hexlify(ethers.toUtf8Bytes(output)));

                const localProofValue = {
                    requestId: requestId,
                    commitmentHash: localCommitmentHash,
                    inputHash: localInputHash,
                    resultHash: localResultHash,
                    nodeAddress: nodeSigner.address,
                    timestamp: localTimestamp
                };

                const localSignature = await nodeSigner.signTypedData(domain, types, localProofValue);
                const localProof = ethers.AbiCoder.defaultAbiCoder().encode(
                    ['bytes32', 'bytes32', 'bytes32', 'bytes32', 'address', 'uint256', 'bytes'],
                    [localProofValue.requestId, localProofValue.commitmentHash, localProofValue.inputHash, localProofValue.resultHash, localProofValue.nodeAddress, localProofValue.timestamp, localSignature]
                );

                // 2. Log both sets of data
                console.log("   [Local Generation]:");
                console.log(`     - Timestamp:      ${localTimestamp}`);
                console.log(`     - Commitment Hash: ${localCommitmentHash}`);
                console.log(`     - Input Hash:      ${localInputHash}`);
                console.log(`     - Result Hash:     ${localResultHash}`);
                console.log(`     - Signature:       ${localSignature}`);
                console.log(`     - Final Proof:     ${localProof}`);

                console.log("\n   [API Response]:");
                console.log(`     - Timestamp:      ${responseData.timestamp}`);
                console.log(`     - Commitment Hash: ${responseData.commitmentHash}`);
                console.log(`     - Input Hash:      ${responseData.inputHash}`);
                console.log(`     - Result Hash:     ${responseData.resultHash}`);
                console.log(`     - Signature:       ${responseData.signature}`);
                console.log(`     - Final Proof:     ${responseData.proof}`);
                // --- 🐛 END DEBUGGING ---

            } catch (e) {
                console.error("   ❌ Error getting proof from service:", e);
                throw e; // Stop processing this request if proof generation fails
            }

            // 4. Report the result back to the Coordinator
            console.log("   4. Reporting compute result to Coordinator...");
            const reportTx = await coordinatorContract.reportComputeResult(
                commitmentDataFromEvent.interval,
                inputs,
                ethers.hexlify(ethers.toUtf8Bytes(output)),
                proof,
                // proof, // Use the generated proof
                encodedCommitmentData,
                nodePaymentWalletAddress
            );

            console.log(`      Transaction sent! Hash: ${reportTx.hash}`);
            const reportReceipt = await reportTx.wait(1);
            console.log("   ✅ Result reported to Coordinator successfully!");

            // 5. Verify payment
            // With ImmediateFinalizeVerifier, the payment is processed in the same transaction.
            // We can check the balance immediately after the transaction is mined.
            console.log("   5. Verifying payment...");
            // A small delay might be needed for the node to update its state.
            await new Promise(resolve => setTimeout(resolve, 2000));
            const balanceAfter = await provider.getBalance(nodePaymentWalletAddress);
            console.log(`   Node Payment Wallet balance after report:  ${ethers.formatEther(balanceAfter)} ETH`);
            if (balanceAfter > balanceBefore) {
                console.log("   🎉 Payment received successfully!");
            } else {
                console.warn("   🤔 Payment not reflected in balance. This might happen if the fee was 0 or due to network delays.");
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