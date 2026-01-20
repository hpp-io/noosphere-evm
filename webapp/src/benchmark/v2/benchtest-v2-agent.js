#!/usr/bin/env node
// webapp/src/benchmark/v2/benchtest-v2-agent.js
// V2 Benchmark Agent: Production scenario with PayloadData support
//
// Handles both:
// - RAW_DATA: inline bytes (small data < 1KB)
// - PAYLOAD_DATA: off-chain URI reference (large data >= 1KB)
//
// Agent creates output as PayloadData (simulating off-chain storage)
// to measure real gas costs for reportComputeResult

const path = require('path');
const ethers = require('ethers');
const crypto = require('crypto');

// tx utils
const { summarizeReceipt } = require('../tx-utils');
const { Commitment } = require('../../commitment');
const { computeCalldataInfo } = require('../calldata-info');

// --- Path Resolution ---
const projectRoot = path.resolve(__dirname, '../../../..');

// Artifacts
const CoordinatorArtifact = require(path.join(projectRoot, 'out/DelegateeCoordinator.sol/DelegateeCoordinator.json'));
const ClientArtifact = require(path.join(projectRoot, 'out/MyTransientClient.sol/MyTransientClient.json'));
const RouterArtifact = require(path.join(projectRoot, 'out/Router.sol/Router.json'));
const WalletFactoryArtifact = require(path.join(projectRoot, 'out/WalletFactory.sol/WalletFactory.json'));
const WalletArtifact = require(path.join(projectRoot, 'out/Wallet.sol/Wallet.json'));

// InputType enum (matches Solidity)
const InputType = {
    RAW_DATA: 0,
    URI_STRING: 1,
    PAYLOAD_DATA: 2
};

const InputTypeName = ['RAW_DATA', 'URI_STRING', 'PAYLOAD_DATA'];

/**
 * Simulate off-chain storage (IPFS/R2)
 */
function simulateOffchainUpload(data) {
    const hash = crypto.createHash('sha256').update(data).digest('hex');
    const mockCid = 'Qm' + Buffer.from(hash, 'hex').toString('base64').replace(/[+/=]/g, 'x').slice(0, 44);
    return `ipfs://${mockCid}`;
}

/**
 * Create PayloadData for off-chain reference
 */
function createPayloadData(contentHashOrData, uri) {
    let contentHash;
    if (typeof contentHashOrData === 'string' && contentHashOrData.startsWith('0x') && contentHashOrData.length === 66) {
        // Already a hash
        contentHash = contentHashOrData;
    } else {
        // It's data, compute hash
        contentHash = ethers.keccak256(contentHashOrData);
    }

    // Handle URI conversion:
    // - hex string (0x...): raw bytes
    // - regular string (ipfs://...): UTF-8 encode
    // - already bytes: use as-is
    let uriBytes;
    if (typeof uri === 'string') {
        if (uri.startsWith('0x')) {
            // Raw bytes as hex string
            uriBytes = ethers.getBytes(uri);
        } else {
            // Regular string (e.g., "ipfs://...")
            uriBytes = ethers.toUtf8Bytes(uri);
        }
    } else {
        uriBytes = uri;
    }

    return {
        contentHash: contentHash,
        uri: uriBytes
    };
}

/**
 * Create empty PayloadData (for proof when not needed)
 */
function emptyPayloadData() {
    return {
        contentHash: ethers.ZeroHash,
        uri: '0x'
    };
}

/**
 * Format bytes to human readable
 */
function formatBytes(bytes) {
    if (bytes < 1024) return `${bytes}B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}KB`;
    return `${(bytes / (1024 * 1024)).toFixed(2)}MB`;
}

// Get contract address from env or deployment broadcast
async function getContractAddress(contractName, provider) {
    // Priority 1: Environment variable
    const envMapping = {
        'MyTransientClient': process.env.CLIENT_ADDRESS,
        'Router': process.env.ROUTER_ADDRESS,
        'Coordinator': process.env.COORDINATOR_ADDRESS,
        'DelegateeCoordinator': process.env.COORDINATOR_ADDRESS,
    };
    if (envMapping[contractName]) {
        console.log(`   Using ${contractName} from env: ${envMapping[contractName]}`);
        return envMapping[contractName];
    }

    // Priority 2: Deployment broadcast
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
    console.log('V2 benchtest-agent starting...');

    const rpcUrl = process.env.RPC_URL;
    const nodePrivateKey = process.env.NODE_PRIVATE_KEY;
    if (!rpcUrl) {
        console.error('Error: RPC_URL not set');
        process.exit(1);
    }

    console.log('[v2-agent] rpcUrl=', rpcUrl);
    if (!nodePrivateKey) {
        console.error('Error: NODE_PRIVATE_KEY not set');
        process.exit(1);
    }

    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const nodeSigner = new ethers.Wallet(nodePrivateKey, provider);
    console.log(`   Node Signer (EOA): ${nodeSigner.address}`);

    const COORDINATOR_ADDRESS = await getContractAddress('Coordinator', provider);
    const CLIENT_ADDRESS = await getContractAddress('MyTransientClient', provider);
    const ROUTER_ADDRESS = await getContractAddress('Router', provider);

    if (!COORDINATOR_ADDRESS || !CLIENT_ADDRESS || !ROUTER_ADDRESS) {
        const network = await provider.getNetwork();
        console.error(`Error: Could not find contract addresses for chain ${network.chainId}. Deploy first.`);
        process.exit(1);
    }

    const coordinatorContract = new ethers.Contract(COORDINATOR_ADDRESS, CoordinatorArtifact.abi, nodeSigner);
    const routerContract = new ethers.Contract(ROUTER_ADDRESS, RouterArtifact.abi, provider);
    const walletFactoryContract = new ethers.Contract(await routerContract.getWalletFactory(), WalletFactoryArtifact.abi, nodeSigner);

    // Create node payment wallet
    console.log('\nCreating node payment wallet...');
    const createWalletTx = await walletFactoryContract.createWallet(nodeSigner.address);
    const createWalletReceipt = await createWalletTx.wait(1);
    summarizeReceipt(createWalletReceipt, 'v2.walletFactory.createWallet', { role: 'agent' });

    const walletCreatedEvents = await walletFactoryContract.queryFilter(walletFactoryContract.filters.WalletCreated(), createWalletReceipt.blockNumber, createWalletReceipt.blockNumber);
    const ourWalletEvent = walletCreatedEvents.find(e => e.transactionHash === createWalletTx.hash && e.args.owner.toLowerCase() === nodeSigner.address.toLowerCase());
    if (!ourWalletEvent) throw new Error("Could not find 'WalletCreated' event for node wallet.");
    const nodePaymentWalletAddress = ourWalletEvent.args.walletAddress;
    console.log(`   Node Payment Wallet: ${nodePaymentWalletAddress}`);

    console.log(`   Listening for 'RequestStarted' on Coordinator ${COORDINATOR_ADDRESS}...`);

    coordinatorContract.on('RequestStarted', async (requestId, subscriptionId, containerId, commitment) => {
        console.log('\nNew Request Detected!');
        console.log(`   Request ID: ${requestId}`);
        console.log(`   Subscription ID: ${subscriptionId}`);

        const clientWalletAddress = commitment.walletAddress;
        const clientWalletContract = new ethers.Contract(clientWalletAddress, WalletArtifact.abi, provider);

        const balanceBefore = await provider.getBalance(nodePaymentWalletAddress);
        console.log(`   Node Payment Wallet balance before: ${ethers.formatEther(balanceBefore)} ETH`);

        try {
            // 1) Fetch inputs (V2: returns tuple (bytes data, InputType inputType))
            console.log('   1. Fetching compute inputs...');
            const subscription = await routerContract.getComputeSubscription(commitment.subscriptionId);
            const clientContract = new ethers.Contract(subscription.client, ClientArtifact.abi, provider);

            // V2: getComputeInputs returns (bytes data, InputType inputType)
            const [inputData, inputType] = await clientContract.getComputeInputs(subscriptionId, commitment.interval, now(), nodePaymentWalletAddress);

            const inputTypeName = InputTypeName[inputType] || 'UNKNOWN';
            const inputLen = (typeof inputData === 'string') ? (inputData.length - 2) / 2 : 0;
            console.log(`      InputType: ${inputType} (${inputTypeName})`);
            console.log(`      Input data length: ${formatBytes(inputLen)}`);

            // 2) Process input based on type and compute output
            console.log('   2. Processing input and computing output...');

            let inputPayloadData;
            let outputPayloadData;
            let rawDataSize = 0;

            // Note: ethers v6 returns enum as BigInt, so use Number() for comparison
            // Hybrid approach threshold (1KB)
            // < 1KB: raw bytes directly in URI (no encoding overhead)
            // >= 1KB: off-chain URI (IPFS, constant ~53 bytes)
            const INLINE_THRESHOLD = 1024;

            if (Number(inputType) === InputType.RAW_DATA) {
                // RAW_DATA: input is raw bytes stored on-chain
                rawDataSize = inputLen;
                const contentHash = inputData !== '0x' ? ethers.keccak256(inputData) : ethers.ZeroHash;

                if (rawDataSize < INLINE_THRESHOLD) {
                    // Small data: raw bytes directly in URI (no encoding)
                    // This is the most gas-efficient for small data
                    const rawUri = inputData;  // Use raw bytes directly
                    inputPayloadData = createPayloadData(contentHash, rawUri);
                    outputPayloadData = createPayloadData(contentHash, rawUri);
                    console.log(`      [HYBRID < 1KB] Raw bytes in URI: ${rawDataSize}B`);
                } else {
                    // Large data: use off-chain URI (simulated IPFS, ~53 bytes)
                    const offchainUri = simulateOffchainUpload(Buffer.from(inputData.slice(2), 'hex'));
                    inputPayloadData = createPayloadData(contentHash, offchainUri);
                    outputPayloadData = createPayloadData(contentHash, offchainUri);
                    console.log(`      [HYBRID >= 1KB] Off-chain URI: ${offchainUri}`);
                }
            } else if (Number(inputType) === InputType.PAYLOAD_DATA) {
                // PAYLOAD_DATA: input is ABI-encoded PayloadData (hash + URI)
                // The actual data is off-chain, we only have the reference
                try {
                    const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
                        ['tuple(bytes32 contentHash, bytes uri)'],
                        inputData
                    );
                    inputPayloadData = {
                        contentHash: decoded[0].contentHash,
                        uri: decoded[0].uri
                    };

                    // In production, agent would fetch from URI and process
                    // For benchmark, we simulate processing and create output PayloadData
                    const outputUri = simulateOffchainUpload(Buffer.from(decoded[0].contentHash.slice(2), 'hex'));
                    outputPayloadData = createPayloadData(decoded[0].contentHash, outputUri);

                    const uriStr = ethers.toUtf8String(decoded[0].uri);
                    console.log(`      [PAYLOAD_DATA] Off-chain reference: ${uriStr}`);
                    console.log(`      [PAYLOAD_DATA] On-chain: ~${formatBytes(32 + decoded[0].uri.length)} (hash + URI)`);
                } catch (e) {
                    console.warn('      Failed to decode PayloadData:', e.message);
                    inputPayloadData = createPayloadData(ethers.keccak256(inputData), 'data:raw');
                    outputPayloadData = createPayloadData(ethers.keccak256(inputData), 'data:result');
                }
            } else if (Number(inputType) === InputType.URI_STRING) {
                // URI_STRING: input is a URI string
                const uri = ethers.toUtf8String(inputData);
                const contentHash = ethers.keccak256(inputData);
                inputPayloadData = createPayloadData(contentHash, uri);
                outputPayloadData = createPayloadData(contentHash, simulateOffchainUpload(Buffer.from(inputData.slice(2), 'hex')));
                console.log(`      [URI_STRING] URI: ${uri}`);
            } else {
                // Unknown, treat as raw
                inputPayloadData = createPayloadData(ethers.keccak256(inputData), 'data:unknown');
                outputPayloadData = createPayloadData(ethers.keccak256(inputData), 'data:result');
            }

            // Empty proof
            const proofPayloadData = emptyPayloadData();

            console.log('      Output PayloadData created (simulated off-chain storage)');

            // 3) Verify commitment
            console.log('   3. Verifying commitment...');
            const eventCommitment = new Commitment(commitment);
            const onchainCommitmentResult = await coordinatorContract.getCommitment(subscriptionId, commitment.interval);
            const onchainCommitment = new Commitment(onchainCommitmentResult);
            const eventHash = ethers.keccak256(eventCommitment.encode());
            const onchainHash = ethers.keccak256(onchainCommitment.encode());
            if (eventHash !== onchainHash) {
                console.warn('      Commitment hash mismatch');
            } else {
                console.log('      Commitment verified');
            }

            // 4) Report result to coordinator with PayloadData
            console.log('   4. Reporting result to Coordinator (PayloadData)...');

            // V2 reportComputeResult signature uses PayloadData structs
            const reportTx = await coordinatorContract.reportComputeResult(
                commitment.interval,
                inputPayloadData,      // PayloadData
                outputPayloadData,     // PayloadData
                proofPayloadData,      // PayloadData (empty)
                eventCommitment.encode(),
                nodePaymentWalletAddress
            );
            const reportReceipt = await reportTx.wait(1);

            // Compute calldata metrics
            try {
                const argsForCalldata = [
                    commitment.interval,
                    inputPayloadData,
                    outputPayloadData,
                    proofPayloadData,
                    eventCommitment.encode(),
                    nodePaymentWalletAddress
                ];
                const calldataInfo = computeCalldataInfo(coordinatorContract.interface, 'reportComputeResult', argsForCalldata);

                // Calculate output size for logging
                const outputUriLen = typeof outputPayloadData.uri === 'string'
                    ? (outputPayloadData.uri.length - 2) / 2
                    : outputPayloadData.uri.length;

                summarizeReceipt(reportReceipt, 'v2.coordinator.reportComputeResult', {
                    role: 'agent',
                    payloadSize: rawDataSize || inputLen,
                    note: `inputType=${inputTypeName},outputUriLen=${outputUriLen}`,
                    calldataBytes: calldataInfo.calldataBytes,
                    calldataZeroBytes: calldataInfo.zeroBytes,
                    calldataNonZeroBytes: calldataInfo.nonZeroBytes,
                    calldataGasEstimate: calldataInfo.calldataGasEstimate
                });

                console.log(`      Calldata: ${formatBytes(calldataInfo.calldataBytes)}`);
                console.log(`      Calldata gas: ~${calldataInfo.calldataGasEstimate}`);
            } catch (e) {
                console.warn('      computeCalldataInfo failed:', e.message || e);
                summarizeReceipt(reportReceipt, 'v2.coordinator.reportComputeResult', {
                    role: 'agent',
                    payloadSize: rawDataSize || inputLen,
                    note: `inputType=${inputTypeName}`
                });
            }

            console.log('      Reported result to Coordinator.');

            // 5) Detect settlement
            let requestProcessedFound = false;
            for (const log of reportReceipt.logs) {
                try {
                    const parsed = routerContract.interface.parseLog(log);
                    if (parsed && parsed.name === 'RequestProcessed' && parsed.args && parsed.args.requestId === requestId) {
                        requestProcessedFound = true;
                        break;
                    }
                } catch (e) { }
            }

            if (requestProcessedFound) {
                console.log('      RequestProcessed found. Checking disbursement...');
                const block = reportReceipt.blockNumber;
                const disbursedEvents = await clientWalletContract.queryFilter(clientWalletContract.filters.RequestDisbursed(requestId), block, block);
                const ourDisbursedEvent = disbursedEvents.find(e => e.args.to.toLowerCase() === nodePaymentWalletAddress.toLowerCase());
                if (ourDisbursedEvent) {
                    console.log(`      RequestDisbursed: ${ethers.formatEther(ourDisbursedEvent.args.amount)} ETH`);
                }
                const balanceAfter = await waitForBalanceChange(provider, nodePaymentWalletAddress, balanceBefore, 15000, 1000);
                console.log(`      Node balance after: ${ethers.formatEther(balanceAfter)} ETH`);
                if (balanceAfter > balanceBefore) {
                    console.log('      Payment received!');
                }
            } else {
                console.error('      RequestProcessed not found.');
            }

        } catch (err) {
            console.error('      Error processing request:', err);
        }
    });

    console.log('   V2 Agent is running and listening for events (CTRL+C to stop).');
}

main().catch(err => {
    console.error('V2 Agent failed to start:', err);
    process.exit(1);
});
