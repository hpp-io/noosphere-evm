// webapp/src/client.js
const path = require('path');
// require('dotenv').config({ path: path.resolve(__dirname, '.env-bench.mainnet') });
const fs = require('fs');
const ethers = require('ethers');

// tx utils
const { summarizeReceipt } = require('./tx-utils');
const { computeCalldataInfo } = require('./calldata-info');

const projectRoot = path.resolve(__dirname, '../../..'); // repo root

const TransientClientArtifact = require(path.join(projectRoot, 'out/MyTransientClient.sol/MyTransientClient.json'));
const RouterArtifact = require(path.join(projectRoot, 'out/Router.sol/Router.json'));
const WalletFactoryArtifact = require(path.join(projectRoot, 'out/WalletFactory.sol/WalletFactory.json'));
const WalletArtifact = require(path.join(projectRoot, 'out/Wallet.sol/Wallet.json'));

console.log('ENV CSV_PATH=', process.env.CSV_PATH, '  cwd=', process.cwd());

// Dynamically load a contract address from the latest deployment.
async function getLatestDeploymentAddress(contractName, provider) {
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

function requestIdPacked(subscriptionId, interval) {
    // Note: ethers.solidityPacked and keccak256 require ethers v6 style
    const packedData = ethers.solidityPacked(['uint64', 'uint32'], [subscriptionId, interval]);
    const rid = ethers.keccak256(packedData);
    return rid;
}

async function main() {
    const rpcUrl = process.env.RPC_URL;
    if (!rpcUrl) {
        console.error('Error: RPC_URL is not set in the .env file.');
        process.exit(1);
    }
    console.log('[client] rpcUrl=', rpcUrl);
    const provider = new ethers.JsonRpcProvider(rpcUrl);

    const CLIENT_ADDRESS = await getLatestDeploymentAddress('MyTransientClient', provider);
    const ROUTER_ADDRESS = await getLatestDeploymentAddress('Router', provider);

    if (!CLIENT_ADDRESS || !ROUTER_ADDRESS) {
        const network = await provider.getNetwork();
        console.error(`Error: Could not find contract addresses for chain ${network.chainId}. Please deploy contracts first.`);
        process.exit(1);
    }

    const clientCode = await provider.getCode(CLIENT_ADDRESS);
    if (clientCode === '0x') {
        console.error(`\n❌ Error: No contract code found at MyTransientClient address (${CLIENT_ADDRESS}).`);
        process.exit(1);
    }

    const clientPrivateKey = process.env.CLIENT_PRIVATE_KEY;
    if (!clientPrivateKey) {
        console.error('Error: CLIENT_PRIVATE_KEY (CLIENT_PRIVATE_KEY) is not set in the .env file.');
        process.exit(1);
    }
    const signer = new ethers.Wallet(clientPrivateKey, provider);
    console.log(`Using signer address: ${signer.address}`);

    let clientContract = new ethers.Contract(CLIENT_ADDRESS, TransientClientArtifact.abi, signer);
    let routerContract = new ethers.Contract(ROUTER_ADDRESS, RouterArtifact.abi, signer);

    try {
        let version = await clientContract.typeAndVersion();
        console.log(`\n✅ Successfully connected to client contract: ${version}`);
        version = await routerContract.typeAndVersion();
        console.log(`\n✅ Successfully connected to router contract: ${version}`);
        const routerAddress = await routerContract.getAddress();
        console.log(`\n✅ Client contract is configured to use Router at: ${routerAddress}`);

    } catch (e) {
        console.error('\n❌ Could not connect to the Client/Router contract. Please check the address, ABI, and network.');
        console.error(e);
        process.exit(1);
    }

    try {
        let nonce = await provider.getTransactionCount(signer.address, 'pending');
        console.log(`Starting nonce (pending): ${nonce}`);

        // --- 0. Create a new Wallet via the WalletFactory ---
        console.log('\n0️⃣  Creating a new wallet for the subscription...');
        const walletFactoryAddress = await routerContract.getWalletFactory();
        if (walletFactoryAddress === ethers.ZeroAddress) {
            throw new Error('WalletFactory address is not set on the Router.');
        }
        const walletFactoryContract = new ethers.Contract(walletFactoryAddress, WalletFactoryArtifact.abi, signer);
        console.log(`   WalletFactory found at: ${walletFactoryAddress}`);

        const createWalletTx = await walletFactoryContract.createWallet(signer.address, { nonce });
        nonce++;
        const createWalletReceipt = await createWalletTx.wait(1);

        // compute calldata info for createWallet and pass into summarizeReceipt
        try {
            const calldataInfo = computeCalldataInfo(walletFactoryContract.interface, 'createWallet', [signer.address]);
            summarizeReceipt(createWalletReceipt, 'walletFactory.createWallet', {
                role: 'client',
                calldataBytes: calldataInfo.calldataBytes,
                calldataZeroBytes: calldataInfo.zeroBytes,
                calldataNonZeroBytes: calldataInfo.nonZeroBytes,
                calldataGasEstimate: calldataInfo.calldataGasEstimate
            });
        } catch (e) {
            // fallback to previous behavior
            console.warn('   ⚠️ computeCalldataInfo failed for createWallet:', e.message || e);
            summarizeReceipt(createWalletReceipt, 'walletFactory.createWallet', { role: 'client' });
        }

        // Find wallet address in created event
        const walletCreatedEvents = await walletFactoryContract.queryFilter(walletFactoryContract.filters.WalletCreated(), createWalletReceipt.blockNumber, createWalletReceipt.blockNumber);
        const ourWalletEvent = walletCreatedEvents.find(e => e.transactionHash === createWalletTx.hash);
        if (!ourWalletEvent) {
            throw new Error("Could not find 'WalletCreated' event.");
        }
        const newWalletAddress = ourWalletEvent.args.walletAddress;
        console.log(`   ✅ New Wallet Created! Address: ${newWalletAddress}`);

        // Fund the newly created wallet with ETH for fees (small amount)
        console.log('   Funding the new wallet with wei...');
        const oneWei = ethers.parseUnits('1', 'wei');
        const fundTx = await signer.sendTransaction({ to: newWalletAddress,  value: oneWei, nonce });
        nonce++;
        const fundReceipt = await fundTx.wait(1);
        // fundTx is a plain ETH transfer — keep existing summarize call (no calldata)
        summarizeReceipt(fundReceipt, 'fundWallet', { role: 'client' });

        // Approve the Client contract to spend funds from the new wallet
        console.log('   Approving the Client contract to spend from the new wallet...');
        const walletContract = new ethers.Contract(newWalletAddress, WalletArtifact.abi, signer);
        const approveTx = await walletContract.approve(CLIENT_ADDRESS, ethers.ZeroAddress, ethers.MaxUint256, { nonce });
        nonce++;
        const approveReceipt = await approveTx.wait(1);

        // compute calldata info for wallet.approve and pass into summarizeReceipt
        try {
            const calldataInfoApprove = computeCalldataInfo(walletContract.interface, 'approve', [CLIENT_ADDRESS, ethers.ZeroAddress, ethers.MaxUint256]);
            summarizeReceipt(approveReceipt, 'wallet.approve', {
                role: 'client',
                calldataBytes: calldataInfoApprove.calldataBytes,
                calldataZeroBytes: calldataInfoApprove.zeroBytes,
                calldataNonZeroBytes: calldataInfoApprove.nonZeroBytes,
                calldataGasEstimate: calldataInfoApprove.calldataGasEstimate
            });
        } catch (e) {
            console.warn('   ⚠️ computeCalldataInfo failed for wallet.approve:', e.message || e);
            summarizeReceipt(approveReceipt, 'wallet.approve', { role: 'client' });
        }

        // --- 1. Create a new compute subscription ---
        const coordinatorId = ethers.encodeBytes32String('Coordinator_v1.0.0');
        const coordinatorAddress = await routerContract.getContractById(coordinatorId);
        console.log(`Coordinator Address for routeId "Coordinator_v1.0.0" : ${coordinatorAddress}`);

        console.log('\n1️⃣  Sending transaction to create a new compute subscription...');
        const subscriptionParams = {
            containerId: 'my-container-id',
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
        console.log(`   Transaction sent! Hash: ${createSubTx.hash}`);
        nonce++;
        const createSubReceipt = await createSubTx.wait(1);

        // compute calldata info for createSubscription
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
            summarizeReceipt(createSubReceipt, 'client.createSubscription', {
                role: 'client',
                calldataBytes: calldataInfoCreateSub.calldataBytes,
                calldataZeroBytes: calldataInfoCreateSub.zeroBytes,
                calldataNonZeroBytes: calldataInfoCreateSub.nonZeroBytes,
                calldataGasEstimate: calldataInfoCreateSub.calldataGasEstimate
            });
        } catch (e) {
            console.warn('   ⚠️ computeCalldataInfo failed for createSubscription:', e.message || e);
            summarizeReceipt(createSubReceipt, 'client.createSubscription', { role: 'client' });
        }

        // Find subscriptionId from SubscriptionCreated event
        const events = await routerContract.queryFilter(routerContract.filters.SubscriptionCreated(), createSubReceipt.blockNumber, createSubReceipt.blockNumber);
        const subCreatedEvent = events.find(e => e.transactionHash === createSubTx.hash);
        if (!subCreatedEvent) throw new Error("Could not find 'SubscriptionCreated' event.");
        const { subscriptionId } = subCreatedEvent.args;
        console.log(`   ✅ New Subscription Created! ID: ${subscriptionId.toString()}`);

        // --- 2. Request a compute job for the new subscription ---
        console.log('\n2️⃣  Sending transaction to request a compute job...');

        // payload size controlled via env var TEST_PAYLOAD_SIZE (number of bytes)
        const size = parseInt(process.env.TEST_PAYLOAD_SIZE ?? '16', 10);
        const iteration = parseInt(process.env.TEST_ITERATION ?? '0', 10);
        const computeInputs = '0x' + 'aa'.repeat(size); // size bytes

        console.log(`   Using nonce for requestCompute: ${nonce} payloadSize=${size} iteration=${iteration}`);
        const requestTx = await clientContract.requestCompute(subscriptionId, computeInputs, { nonce });
        nonce++;
        const requestReceipt = await requestTx.wait(1);

        // compute calldata info for requestCompute
        try {
            const calldataInfoRequest = computeCalldataInfo(clientContract.interface, 'requestCompute', [subscriptionId, computeInputs]);
            summarizeReceipt(requestReceipt, 'client.requestCompute', {
                role: 'client',
                payloadSize: size,
                iteration,
                calldataBytes: calldataInfoRequest.calldataBytes,
                calldataZeroBytes: calldataInfoRequest.zeroBytes,
                calldataNonZeroBytes: calldataInfoRequest.nonZeroBytes,
                calldataGasEstimate: calldataInfoRequest.calldataGasEstimate
            });
        } catch (e) {
            console.warn('   ⚠️ computeCalldataInfo failed for requestCompute:', e.message || e);
            summarizeReceipt(requestReceipt, 'client.requestCompute', { role: 'client', payloadSize: size, iteration });
        }

        // Get requestId from Router RequestStart event
        const requestStartEvents = await routerContract.queryFilter(routerContract.filters.RequestStart(), requestReceipt.blockNumber, requestReceipt.blockNumber);
        const ourRequestEvent = requestStartEvents.find(e => e.transactionHash === requestTx.hash);
        if (!ourRequestEvent) {
            console.warn("Could not find 'RequestStart' event from Router for this tx.");
        } else {
            const { requestId } = ourRequestEvent.args;
            console.log(`   Request ID: ${requestId}`);
        }

        // --- 3. Poll for result (lastReceivedOutput on client contract) ---
        console.log('\n3️⃣  Waiting for the node to fulfill the request and receive the result...');
        const clientWalletBalanceBefore = await provider.getBalance(newWalletAddress);
        let lastOutput = '0x';
        const pollInterval = 2000;
        const maxAttempts = 30;
        for (let i = 0; i < maxAttempts; i++) {
            lastOutput = await clientContract.lastReceivedOutput();
            if (lastOutput && lastOutput !== '0x') {
                console.log('   ✅ Result received in client contract!');
                break;
            }
            console.log(`   ...waiting (${i + 1}/${maxAttempts})`);
            await new Promise(resolve => setTimeout(resolve, pollInterval));
        }

        if (lastOutput === '0x' || lastOutput === null) {
            console.warn('   Timeout waiting for result. You may need to run agent separately.');
        } else {
            console.log(`   Result: ${lastOutput}`);
        }

        // --- 4. Verify settlement by checking the client's wallet balance ---
        await new Promise(resolve => setTimeout(resolve, 3000));
        const clientWalletBalanceAfter = await provider.getBalance(newWalletAddress);
        console.log(`   Client Wallet Balance: ${ethers.formatEther(clientWalletBalanceBefore)} -> ${ethers.formatEther(clientWalletBalanceAfter)} ETH`);

        if (clientWalletBalanceAfter < clientWalletBalanceBefore) {
            console.log('   ✅ Payment sent successfully! Client balance decreased.');
        } else {
            console.warn('   ⚠️ Settlement inconclusive. Balance did not decrease.');
        }

        console.log('\n🎉 Client-side test finished.');
        process.exit(0);

    } catch (error) {
        console.error('\nAn error occurred during the client test script:');
        console.error(error);
        process.exit(1);
    }
}

main();
