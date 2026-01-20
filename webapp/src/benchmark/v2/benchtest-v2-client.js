// webapp/src/benchmark/v2/benchtest-v2-client.js
// V2 Benchmark Client: Production scenario with off-chain storage simulation
//
// Design spec (from URI_SCHEME_PAYLOAD_DESIGN.md):
// - < 1KB: RAW_DATA (inline on-chain)
// - >= 1KB: PAYLOAD_DATA with URI reference (off-chain storage)
//
// This measures real gas costs for production scenarios where large data
// is stored off-chain (IPFS/R2) and only the URI reference is on-chain.

const path = require('path');
const fs = require('fs');
const ethers = require('ethers');
const crypto = require('crypto');

// tx utils
const { summarizeReceipt } = require('../tx-utils');
const { computeCalldataInfo } = require('../calldata-info');

const projectRoot = path.resolve(__dirname, '../../../..'); // repo root

const TransientClientArtifact = require(path.join(projectRoot, 'out/MyTransientClient.sol/MyTransientClient.json'));
const RouterArtifact = require(path.join(projectRoot, 'out/Router.sol/Router.json'));
const WalletFactoryArtifact = require(path.join(projectRoot, 'out/WalletFactory.sol/WalletFactory.json'));
const WalletArtifact = require(path.join(projectRoot, 'out/Wallet.sol/Wallet.json'));

console.log('ENV CSV_PATH=', process.env.CSV_PATH, '  cwd=', process.cwd());

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
        const broadcastPath = path.join(projectRoot, `broadcast/DeployTest.sol/${network.chainId}/run-latest.json`);
        const broadcast = require(broadcastPath);
        const deployment = broadcast.transactions.find(
            (tx) => tx.transactionType === 'CREATE' && tx.contractName === contractName
        );
        return deployment?.contractAddress;
    } catch (e) {
        return undefined;
    }
}

// InputType enum (matches Solidity)
const InputType = {
    RAW_DATA: 0,
    URI_STRING: 1,
    PAYLOAD_DATA: 2
};

/**
 * Simulate off-chain storage by generating a mock IPFS CID
 * In production, this would upload to actual IPFS/R2/Arweave
 *
 * @param {Uint8Array} data - The data to "upload"
 * @returns {string} Mock IPFS URI (ipfs://Qm...)
 */
function simulateOffchainUpload(data) {
    // Generate a realistic IPFS CIDv0 (46 chars starting with Qm)
    // In production, this would be actual IPFS upload
    const hash = crypto.createHash('sha256').update(data).digest('hex');
    // CIDv0 format: Qm + base58(multihash)
    const mockCid = 'Qm' + Buffer.from(hash, 'hex').toString('base64').replace(/[+/=]/g, 'x').slice(0, 44);
    return `ipfs://${mockCid}`;
}

/**
 * Create PayloadData for off-chain reference
 * Only contentHash (32 bytes) + URI (~50 bytes) goes on-chain
 *
 * @param {Uint8Array} data - Original data (stored off-chain)
 * @returns {Object} PayloadData struct for on-chain storage
 */
function createOffchainPayloadData(data) {
    const contentHash = ethers.keccak256(data);
    const uri = simulateOffchainUpload(data);
    return {
        contentHash: contentHash,
        uri: ethers.toUtf8Bytes(uri)
    };
}

/**
 * Encode PayloadData for on-chain transmission
 */
function encodePayloadData(payloadData) {
    return ethers.AbiCoder.defaultAbiCoder().encode(
        ['tuple(bytes32 contentHash, bytes uri)'],
        [[payloadData.contentHash, payloadData.uri]]
    );
}

/**
 * Format bytes to human readable
 */
function formatBytes(bytes) {
    if (bytes < 1024) return `${bytes}B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}KB`;
    return `${(bytes / (1024 * 1024)).toFixed(2)}MB`;
}

async function main() {
    const rpcUrl = process.env.RPC_URL;
    if (!rpcUrl) {
        console.error('Error: RPC_URL is not set in the .env file.');
        process.exit(1);
    }
    console.log('[v2-client] rpcUrl=', rpcUrl);
    const provider = new ethers.JsonRpcProvider(rpcUrl);

    const CLIENT_ADDRESS = await getContractAddress('MyTransientClient', provider);
    const ROUTER_ADDRESS = await getContractAddress('Router', provider);

    if (!CLIENT_ADDRESS || !ROUTER_ADDRESS) {
        const network = await provider.getNetwork();
        console.error(`Error: Could not find contract addresses for chain ${network.chainId}. Please deploy contracts first.`);
        process.exit(1);
    }

    const clientCode = await provider.getCode(CLIENT_ADDRESS);
    if (clientCode === '0x') {
        console.error(`\nError: No contract code found at MyTransientClient address (${CLIENT_ADDRESS}).`);
        process.exit(1);
    }

    const clientPrivateKey = process.env.CLIENT_PRIVATE_KEY;
    if (!clientPrivateKey) {
        console.error('Error: CLIENT_PRIVATE_KEY is not set in the .env file.');
        process.exit(1);
    }
    const signer = new ethers.Wallet(clientPrivateKey, provider);
    console.log(`Using signer address: ${signer.address}`);

    let clientContract = new ethers.Contract(CLIENT_ADDRESS, TransientClientArtifact.abi, signer);
    let routerContract = new ethers.Contract(ROUTER_ADDRESS, RouterArtifact.abi, signer);

    try {
        let version = await clientContract.typeAndVersion();
        console.log(`\nSuccessfully connected to client contract: ${version}`);
        version = await routerContract.typeAndVersion();
        console.log(`Successfully connected to router contract: ${version}`);

    } catch (e) {
        console.error('\nCould not connect to the Client/Router contract.');
        console.error(e);
        process.exit(1);
    }

    try {
        let nonce = await provider.getTransactionCount(signer.address, 'pending');
        console.log(`Starting nonce (pending): ${nonce}`);

        // --- 0. Create a new Wallet via the WalletFactory ---
        console.log('\n[Step 0] Creating a new wallet for the subscription...');
        const walletFactoryAddress = await routerContract.getWalletFactory();
        if (walletFactoryAddress === ethers.ZeroAddress) {
            throw new Error('WalletFactory address is not set on the Router.');
        }
        const walletFactoryContract = new ethers.Contract(walletFactoryAddress, WalletFactoryArtifact.abi, signer);
        console.log(`   WalletFactory found at: ${walletFactoryAddress}`);

        const createWalletTx = await walletFactoryContract.createWallet(signer.address, { nonce });
        nonce++;
        const createWalletReceipt = await createWalletTx.wait(1);

        try {
            const calldataInfo = computeCalldataInfo(walletFactoryContract.interface, 'createWallet', [signer.address]);
            summarizeReceipt(createWalletReceipt, 'v2.walletFactory.createWallet', {
                role: 'client',
                calldataBytes: calldataInfo.calldataBytes,
                calldataZeroBytes: calldataInfo.zeroBytes,
                calldataNonZeroBytes: calldataInfo.nonZeroBytes,
                calldataGasEstimate: calldataInfo.calldataGasEstimate
            });
        } catch (e) {
            summarizeReceipt(createWalletReceipt, 'v2.walletFactory.createWallet', { role: 'client' });
        }

        // Find wallet address in created event
        const walletCreatedEvents = await walletFactoryContract.queryFilter(walletFactoryContract.filters.WalletCreated(), createWalletReceipt.blockNumber, createWalletReceipt.blockNumber);
        const ourWalletEvent = walletCreatedEvents.find(e => e.transactionHash === createWalletTx.hash);
        if (!ourWalletEvent) {
            throw new Error("Could not find 'WalletCreated' event.");
        }
        const newWalletAddress = ourWalletEvent.args.walletAddress;
        console.log(`   New Wallet Created! Address: ${newWalletAddress}`);

        // Fund the newly created wallet
        console.log('   Funding the new wallet with wei...');
        const oneWei = ethers.parseUnits('1', 'wei');
        const fundTx = await signer.sendTransaction({ to: newWalletAddress, value: oneWei, nonce });
        nonce++;
        const fundReceipt = await fundTx.wait(1);
        summarizeReceipt(fundReceipt, 'v2.fundWallet', { role: 'client' });

        // Approve the Client contract
        console.log('   Approving the Client contract...');
        const walletContract = new ethers.Contract(newWalletAddress, WalletArtifact.abi, signer);
        const approveTx = await walletContract.approve(CLIENT_ADDRESS, ethers.ZeroAddress, ethers.MaxUint256, { nonce });
        nonce++;
        const approveReceipt = await approveTx.wait(1);

        try {
            const calldataInfoApprove = computeCalldataInfo(walletContract.interface, 'approve', [CLIENT_ADDRESS, ethers.ZeroAddress, ethers.MaxUint256]);
            summarizeReceipt(approveReceipt, 'v2.wallet.approve', {
                role: 'client',
                calldataBytes: calldataInfoApprove.calldataBytes,
                calldataZeroBytes: calldataInfoApprove.zeroBytes,
                calldataNonZeroBytes: calldataInfoApprove.nonZeroBytes,
                calldataGasEstimate: calldataInfoApprove.calldataGasEstimate
            });
        } catch (e) {
            summarizeReceipt(approveReceipt, 'v2.wallet.approve', { role: 'client' });
        }

        // --- 1. Create a new compute subscription ---
        const coordinatorId = ethers.encodeBytes32String('Coordinator_v1.0.0');
        const coordinatorAddress = await routerContract.getContractById(coordinatorId);
        console.log(`Coordinator Address: ${coordinatorAddress}`);

        console.log('\n[Step 1] Creating compute subscription...');
        const subscriptionParams = {
            containerId: 'v2-bench-container',
            redundancy: 1,
            useDeliveryInbox: false,
            feeToken: ethers.ZeroAddress,
            feeAmount: ethers.parseUnits('1', 'wei'),
            wallet: newWalletAddress,
            verifier: ethers.ZeroAddress,
            routeId: coordinatorId
        };

        const createSubTx = await clientContract.createSubscription(
            subscriptionParams.containerId,
            subscriptionParams.redundancy,
            subscriptionParams.useDeliveryInbox,
            subscriptionParams.feeToken,
            subscriptionParams.feeAmount,
            subscriptionParams.wallet,
            subscriptionParams.verifier,
            subscriptionParams.routeId,
            { nonce }
        );
        nonce++;
        const createSubReceipt = await createSubTx.wait(1);

        try {
            const calldataInfoCreateSub = computeCalldataInfo(clientContract.interface, 'createSubscription', [
                subscriptionParams.containerId,
                subscriptionParams.redundancy,
                subscriptionParams.useDeliveryInbox,
                subscriptionParams.feeToken,
                subscriptionParams.feeAmount,
                subscriptionParams.wallet,
                subscriptionParams.verifier,
                subscriptionParams.routeId
            ]);
            summarizeReceipt(createSubReceipt, 'v2.client.createSubscription', {
                role: 'client',
                calldataBytes: calldataInfoCreateSub.calldataBytes,
                calldataZeroBytes: calldataInfoCreateSub.zeroBytes,
                calldataNonZeroBytes: calldataInfoCreateSub.nonZeroBytes,
                calldataGasEstimate: calldataInfoCreateSub.calldataGasEstimate
            });
        } catch (e) {
            summarizeReceipt(createSubReceipt, 'v2.client.createSubscription', { role: 'client' });
        }

        // Find subscriptionId
        const events = await routerContract.queryFilter(routerContract.filters.SubscriptionCreated(), createSubReceipt.blockNumber, createSubReceipt.blockNumber);
        const subCreatedEvent = events.find(e => e.transactionHash === createSubTx.hash);
        if (!subCreatedEvent) throw new Error("Could not find 'SubscriptionCreated' event.");
        const { subscriptionId } = subCreatedEvent.args;
        console.log(`   Subscription Created! ID: ${subscriptionId.toString()}`);

        // --- 2. Request compute with production-realistic input type ---
        console.log('\n[Step 2] Requesting compute job...');

        // Get configuration from environment
        const size = parseInt(process.env.TEST_PAYLOAD_SIZE ?? '1024', 10);
        const iteration = parseInt(process.env.TEST_ITERATION ?? '0', 10);
        const inputType = process.env.TEST_INPUT_TYPE ?? 'RAW_DATA';
        const inlineThreshold = parseInt(process.env.TEST_INLINE_THRESHOLD ?? '1024', 10);

        // Generate test data of specified size
        const testData = new Uint8Array(size);
        for (let i = 0; i < size; i++) {
            testData[i] = 0xaa; // Fill with 0xaa pattern
        }

        let computeInputs;
        let actualInputType = inputType;
        let onchainBytes = 0;
        let offchainBytes = 0;

        if (inputType === 'RAW_DATA') {
            // Inline on-chain storage (v1 compatible)
            // All data goes on-chain as calldata
            computeInputs = size > 0 ? '0x' + Buffer.from(testData).toString('hex') : '0x';
            onchainBytes = size;
            offchainBytes = 0;
            console.log(`   [RAW_DATA] Storing ${formatBytes(size)} directly on-chain`);
            console.log(`   -> On-chain calldata: ${formatBytes(size)}`);
        } else if (inputType === 'PAYLOAD_DATA') {
            // Off-chain storage with URI reference
            // Only hash (32 bytes) + URI (~50 bytes) goes on-chain
            const payloadData = createOffchainPayloadData(testData);
            computeInputs = encodePayloadData(payloadData);

            // Calculate actual on-chain size
            const uriLength = payloadData.uri.length;
            onchainBytes = 32 + uriLength + 64; // hash + uri + ABI encoding overhead
            offchainBytes = size;

            console.log(`   [PAYLOAD_DATA] Data: ${formatBytes(size)} -> off-chain`);
            console.log(`   -> On-chain: ~${formatBytes(onchainBytes)} (hash + URI)`);
            console.log(`   -> Off-chain: ${formatBytes(offchainBytes)} (IPFS/R2)`);
            console.log(`   -> Gas savings: ~${((1 - onchainBytes / size) * 100).toFixed(1)}%`);
        }

        console.log(`   Using nonce: ${nonce}, payloadSize=${formatBytes(size)}, iteration=${iteration}`);

        const requestTx = await clientContract.requestCompute(subscriptionId, computeInputs, { nonce });
        nonce++;
        const requestReceipt = await requestTx.wait(1);

        // Compute calldata info for requestCompute
        try {
            const calldataInfoRequest = computeCalldataInfo(clientContract.interface, 'requestCompute', [subscriptionId, computeInputs]);
            summarizeReceipt(requestReceipt, 'v2.client.requestCompute', {
                role: 'client',
                payloadSize: size,
                iteration,
                note: `inputType=${inputType},onchain=${onchainBytes},offchain=${offchainBytes}`,
                calldataBytes: calldataInfoRequest.calldataBytes,
                calldataZeroBytes: calldataInfoRequest.zeroBytes,
                calldataNonZeroBytes: calldataInfoRequest.nonZeroBytes,
                calldataGasEstimate: calldataInfoRequest.calldataGasEstimate
            });
        } catch (e) {
            console.warn('   computeCalldataInfo failed:', e.message || e);
            summarizeReceipt(requestReceipt, 'v2.client.requestCompute', {
                role: 'client',
                payloadSize: size,
                iteration,
                note: `inputType=${inputType},onchain=${onchainBytes},offchain=${offchainBytes}`
            });
        }

        // Get requestId
        const requestStartEvents = await routerContract.queryFilter(routerContract.filters.RequestStart(), requestReceipt.blockNumber, requestReceipt.blockNumber);
        const ourRequestEvent = requestStartEvents.find(e => e.transactionHash === requestTx.hash);
        if (ourRequestEvent) {
            console.log(`   Request ID: ${ourRequestEvent.args.requestId}`);
        }

        // --- 3. Poll for result ---
        console.log('\n[Step 3] Waiting for result...');
        const clientWalletBalanceBefore = await provider.getBalance(newWalletAddress);
        let lastOutput = null;
        const pollInterval = 2000;
        const maxAttempts = 30;
        for (let i = 0; i < maxAttempts; i++) {
            try {
                lastOutput = await clientContract.lastReceivedOutput();
                if (lastOutput && lastOutput.contentHash && lastOutput.contentHash !== ethers.ZeroHash) {
                    console.log('   Result received!');
                    break;
                }
            } catch (e) { }
            console.log(`   ...waiting (${i + 1}/${maxAttempts})`);
            await new Promise(resolve => setTimeout(resolve, pollInterval));
        }

        if (!lastOutput || lastOutput.contentHash === ethers.ZeroHash) {
            console.warn('   Timeout waiting for result.');
        } else {
            console.log(`   Result contentHash: ${lastOutput.contentHash}`);
            try {
                console.log(`   Result uri: ${ethers.toUtf8String(lastOutput.uri)}`);
            } catch (e) { }
        }

        // --- 4. Verify settlement ---
        await new Promise(resolve => setTimeout(resolve, 3000));
        const clientWalletBalanceAfter = await provider.getBalance(newWalletAddress);
        console.log(`   Client Wallet Balance: ${ethers.formatEther(clientWalletBalanceBefore)} -> ${ethers.formatEther(clientWalletBalanceAfter)} ETH`);

        if (clientWalletBalanceAfter < clientWalletBalanceBefore) {
            console.log('   Payment sent successfully!');
        } else {
            console.warn('   Settlement inconclusive.');
        }

        console.log('\nV2 Client test finished.');
        console.log(`   Data size: ${formatBytes(size)}`);
        console.log(`   Input type: ${inputType}`);
        console.log(`   On-chain bytes: ${formatBytes(onchainBytes)}`);
        console.log(`   Off-chain bytes: ${formatBytes(offchainBytes)}`);
        process.exit(0);

    } catch (error) {
        console.error('\nAn error occurred:');
        console.error(error);
        process.exit(1);
    }
}

main();
