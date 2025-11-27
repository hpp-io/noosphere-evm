#!/usr/bin/env node
// benchtest-agent.js
// Bench agent: listens for RequestStarted, performs dummy compute, and reports result.
// Nonce management removed (ethers handles it).

const path = require('path');
// require('dotenv').config({ path: path.resolve(__dirname, '.env-bench.mainnet') });

// tx utils
const { summarizeReceipt } = require('./tx-utils');
const {Commitment} = require("../commitment");
const { computeCalldataInfo } = require('./calldata-info');

// --- Path Resolution ---
const projectRoot = path.resolve(__dirname, '../../..');

const ethers = require('ethers');

// Artifacts (load from repo_root/out/...)
const CoordinatorArtifact = require(path.join(projectRoot, 'out/DelegateeCoordinator.sol/DelegateeCoordinator.json'));
const ClientArtifact = require(path.join(projectRoot, 'out/MyTransientClient.sol/MyTransientClient.json'));
const RouterArtifact = require(path.join(projectRoot, 'out/Router.sol/Router.json'));
const WalletFactoryArtifact = require(path.join(projectRoot, 'out/WalletFactory.sol/WalletFactory.json'));
const WalletArtifact = require(path.join(projectRoot, 'out/Wallet.sol/Wallet.json'));

async function getLatestDeploymentAddress(contractName, provider) {
    try {
        const network = await provider.getNetwork();
        const broadcast = require(path.join(projectRoot, `broadcast/DeployTest.sol/${network.chainId}/run-latest.json`));
        const deployment = broadcast.transactions.find(
            (tx) => tx.transactionType === 'CREATE' && (tx.contractName === contractName || (contractName === 'Coordinator' && tx.contractName === 'DelegateeCoordinator'))
        );
        return deployment?.contractAddress;
    } catch (e) {
        return undefined;
    }
}

const now = () => Math.floor(Date.now() / 1000);

async function waitForBalanceChange(provider, address, initialBalance, timeout = 15000, pollInterval = 1000) {
    const endTime = Date.now() + timeout;
    while (Date.now() < endTime) {
        const currentBalance = await provider.getBalance(address);
        if (currentBalance > initialBalance) return currentBalance;
        await new Promise(resolve => setTimeout(resolve, pollInterval));
    }
    return provider.getBalance(address);
}

async function main() {
    console.log('🤖 benchtest-agent starting...');

    const rpcUrl = process.env.RPC_URL;
    const nodePrivateKey = process.env.NODE_PRIVATE_KEY;
    if (!rpcUrl) {
        console.error('Error: RPC_URL not set in .env-bench.fork-testnet');
        process.exit(1);
    }

    console.log('[agent] rpcUrl=', rpcUrl);
    if (!nodePrivateKey) {
        console.error('Error: NODE_PRIVATE_KEY or PRIVATE_KEY not set for agent in .env-bench.fork-testnet');
        process.exit(1);
    }

    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const nodeSigner = new ethers.Wallet(nodePrivateKey, provider);
    console.log(`   Node Signer (EOA): ${nodeSigner.address}`);

    const COORDINATOR_ADDRESS = await getLatestDeploymentAddress('Coordinator', provider);
    const CLIENT_ADDRESS = await getLatestDeploymentAddress('MyTransientClient', provider);
    const ROUTER_ADDRESS = await getLatestDeploymentAddress('Router', provider);

    if (!COORDINATOR_ADDRESS || !CLIENT_ADDRESS || !ROUTER_ADDRESS) {
        const network = await provider.getNetwork();
        console.error(`Error: Could not find contract addresses for chain ${network.chainId}. Deploy first.`);
        process.exit(1);
    }

    const coordinatorContract = new ethers.Contract(COORDINATOR_ADDRESS, CoordinatorArtifact.abi, nodeSigner);
    const routerContract = new ethers.Contract(ROUTER_ADDRESS, RouterArtifact.abi, provider);
    const walletFactoryContract = new ethers.Contract(await routerContract.getWalletFactory(), WalletFactoryArtifact.abi, nodeSigner);

    // Create node payment wallet (no manual nonce)
    console.log('\n🤖 Creating node payment wallet...');
    const createWalletTx = await walletFactoryContract.createWallet(nodeSigner.address);
    const createWalletReceipt = await createWalletTx.wait(1);
    summarizeReceipt(createWalletReceipt, 'walletFactory.createWallet', { role: 'agent' });

    const walletCreatedEvents = await walletFactoryContract.queryFilter(walletFactoryContract.filters.WalletCreated(), createWalletReceipt.blockNumber, createWalletReceipt.blockNumber);
    const ourWalletEvent = walletCreatedEvents.find(e => e.transactionHash === createWalletTx.hash && e.args.owner.toLowerCase() === nodeSigner.address.toLowerCase());
    if (!ourWalletEvent) throw new Error("Could not find 'WalletCreated' event for node wallet.");
    const nodePaymentWalletAddress = ourWalletEvent.args.walletAddress;
    console.log(`   ✅ Node Payment Wallet: ${nodePaymentWalletAddress}`);

    console.log(`   Listening for 'RequestStarted' on Coordinator ${COORDINATOR_ADDRESS}...`);

    coordinatorContract.on('RequestStarted', async (requestId, subscriptionId, containerId, commitment) => {
        console.log('\n⚡️ New Request Detected!');
        console.log(`   Request ID: ${requestId}`);
        console.log(`   Subscription ID: ${subscriptionId}`);

        const clientWalletAddress = commitment.walletAddress;
        const clientWalletContract = new ethers.Contract(clientWalletAddress, WalletArtifact.abi, provider);

        const balanceBefore = await provider.getBalance(nodePaymentWalletAddress);
        console.log(`   Node Payment Wallet balance before: ${ethers.formatEther(balanceBefore)} ETH`);

        try {
            // 1) fetch inputs
            console.log('   1. Fetching compute inputs...');
            const subscription = await routerContract.getComputeSubscription(commitment.subscriptionId);
            const clientContract = new ethers.Contract(subscription.client, ClientArtifact.abi, provider); // read-only
            const inputs = await clientContract.getComputeInputs(subscriptionId, commitment.interval, now(), nodePaymentWalletAddress);

            // log short
            const hexLen = (typeof inputs === 'string') ? (inputs.length - 2) / 2 : 0;
            console.log(`      Inputs received (hex len=${hexLen}): ${String(inputs).slice(0, 200)}${String(inputs).length > 200 ? '...' : ''}`);

            // optional delegated signer (try/catch in case function not present)
            let delegatedSigner = null;
            try {
                delegatedSigner = await clientContract.getSigner();
                console.log(`   -> Delegated Signer: ${delegatedSigner}`);
            } catch (e) {
                console.warn('   -> clientContract.getSigner() not available or failed:', e.message || e);
            }

            // 2) Perform dummy computation: echo inputs + append timestamp
            console.log('   2. Performing dummy computation (echo input + timestamp)...');

            const timestamp = new Date().toISOString();
            const tsSuffix = `|ts:${timestamp}`; // 구분자 포함해서 붙임 (parsing 용이)

            // Normalize inputs into a hex string (0x...)
            let inputsHex = '0x';
            try {
                if (typeof inputs === 'string') {
                    if (inputs.startsWith('0x')) {
                        inputsHex = inputs;
                    } else {
                        // treat as UTF-8 string
                        inputsHex = ethers.hexlify(ethers.toUtf8Bytes(inputs));
                    }
                } else if (inputs instanceof Uint8Array || Buffer.isBuffer(inputs)) {
                    inputsHex = ethers.hexlify(inputs);
                } else if (typeof inputs === 'object' && inputs !== null && inputs._isResult) {
                    // ethers Result (tuple) — try to convert to bytes if possible
                    // fallback: stringify
                    inputsHex = ethers.hexlify(ethers.toUtf8Bytes(JSON.stringify(inputs)));
                } else {
                    // other fallback: stringify
                    inputsHex = ethers.hexlify(ethers.toUtf8Bytes(String(inputs)));
                }
            } catch (e) {
                console.warn('   ⚠️ Warning: could not normalize inputs to hex, falling back to string:', e.message);
                inputsHex = ethers.hexlify(ethers.toUtf8Bytes(String(inputs)));
            }

            let outputBytes = '0x';
            if (inputsHex === '0x' || inputsHex === '0x0') {
                outputBytes = '0x';
            } else {
                outputBytes = inputsHex;
            }

            // Logging lengths for debugging
            const inputLen = inputsHex === '0x' ? 0 : (inputsHex.length - 2) / 2;
            const outputLen = (outputBytes.length - 2) / 2;
            let inputsPreview = '';
            try {
                inputsPreview = inputsHex.length > 2 ? ethers.toUtf8String(inputsHex) : '';
                // keep preview short
                if (inputsPreview.length > 200) inputsPreview = inputsPreview.slice(0, 200) + '...';
            } catch (e) {
                inputsPreview = inputsHex.slice(0, Math.min(66, inputsHex.length)) + (inputsHex.length > 66 ? '...' : '');
            }

            console.log(`   Computation done: input bytes=${inputLen}, output bytes=${outputLen}, ts="${timestamp}"`);


            // 3) verify commitment vs on-chain (best-effort)
            console.log('   3. Verifying commitment vs on-chain (best-effort)');
            const eventCommitment = new Commitment(commitment);
            const onchainCommitmentResult = await coordinatorContract.getCommitment(subscriptionId, commitment.interval);
            const onchainCommitment = new Commitment(onchainCommitmentResult);
            const eventHash = ethers.keccak256(eventCommitment.encode());
            const onchainHash = ethers.keccak256(onchainCommitment.encode());
            if (eventHash !== onchainHash) {
                console.warn('   ⚠️ Commitment hash mismatch (event vs on-chain)');
            } else {
                console.log('   ✅ Commitment verified (hash match)');
            }

            // 4) report result to coordinator (connected with nodeSigner)
            console.log('   4. Reporting result to Coordinator...');
            const reportTx = await coordinatorContract.reportComputeResult(
                commitment.interval,
                inputs,
                outputBytes,
                '0x',
                eventCommitment.encode(),
                nodePaymentWalletAddress
            );
            const reportReceipt = await reportTx.wait(1);

            // --- NEW: compute calldata metrics and pass into summarizeReceipt ---
            try {
                const argsForCalldata = [
                    commitment.interval,
                    inputs,
                    outputBytes,
                    '0x',
                    eventCommitment.encode(),
                    nodePaymentWalletAddress
                ];
                const calldataInfo = computeCalldataInfo(coordinatorContract.interface, 'reportComputeResult', argsForCalldata);
                summarizeReceipt(reportReceipt, 'coordinator.reportComputeResult', {
                    role: 'agent',
                    payloadSize: outputLen,
                    calldataBytes: calldataInfo.calldataBytes,
                    calldataZeroBytes: calldataInfo.zeroBytes,
                    calldataNonZeroBytes: calldataInfo.nonZeroBytes,
                    calldataGasEstimate: calldataInfo.calldataGasEstimate
                });
            } catch (e) {
                // If computeCalldataInfo fails for any reason, fallback to existing behavior
                console.warn('   ⚠️ computeCalldataInfo failed, falling back to payload-only summarize:', e.message || e);
                summarizeReceipt(reportReceipt, 'coordinator.reportComputeResult', { role: 'agent', payloadSize: outputLen });
            }

            console.log('   ✅ Reported result to Coordinator.');

            // 5) detect settlement (RequestProcessed / RequestDisbursed)
            let requestProcessedFound = false;
            for (const log of reportReceipt.logs) {
                try {
                    const parsed = routerContract.interface.parseLog(log);
                    if (parsed && parsed.name === 'RequestProcessed' && parsed.args && parsed.args.requestId === requestId) {
                        requestProcessedFound = true;
                        break;
                    }
                } catch (e) { /* ignore non-router logs */ }
            }

            if (requestProcessedFound) {
                console.log('   ✅ RequestProcessed found in receipt logs. Checking disbursement...');
                const block = reportReceipt.blockNumber;
                const disbursedEvents = await clientWalletContract.queryFilter(clientWalletContract.filters.RequestDisbursed(requestId), block, block);
                const ourDisbursedEvent = disbursedEvents.find(e => e.args.to.toLowerCase() === nodePaymentWalletAddress.toLowerCase());
                if (ourDisbursedEvent) {
                    console.log(`   -> Found RequestDisbursed to our wallet: ${ethers.formatEther(ourDisbursedEvent.args.amount)}`);
                } else {
                    console.warn('   -> RequestDisbursed for our wallet not found in that block.');
                }
                const balanceAfter = await waitForBalanceChange(provider, nodePaymentWalletAddress, balanceBefore, 15000, 1000);
                console.log(`   Node Payment Wallet balance after: ${ethers.formatEther(balanceAfter)} ETH`);
                if (balanceAfter > balanceBefore) {
                    console.log('   🎉 Payment received!');
                } else {
                    console.warn('   🤔 No payment reflected yet.');
                }
            } else {
                console.error('   ❌ RequestProcessed not found in receipt logs.');
            }

        } catch (err) {
            console.error('   ❌ Error processing request:', err);
        }
    });

    // keep process alive (agent)
    console.log('   Agent is running and listening for events (CTRL+C to stop).');
}

main().catch(err => {
    console.error('Agent failed to start:', err);
    process.exit(1);
});
