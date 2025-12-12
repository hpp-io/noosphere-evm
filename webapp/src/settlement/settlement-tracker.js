#!/usr/bin/env node

/**
 * Settlement Tracker for Noosphere EVM
 *
 * Tracks client and agent settlements through Router and Coordinator contracts
 * Exports settlement data to CSV format
 */

const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '.env-settlement.testnet') });

const ethers = require('ethers');
const fs = require('fs');

// --- Path Resolution ---
const projectRoot = path.resolve(__dirname, '../../..');

// Import contract artifacts
const RouterArtifact = require(path.join(projectRoot, 'out/Router.sol/Router.json'));
const CoordinatorArtifact = require(path.join(projectRoot, 'out/Coordinator.sol/Coordinator.json'));

// Request status enum
const RequestStatus = {
    PENDING: 'PENDING',
    DELIVERING: 'DELIVERING',
    VERIFYING: 'VERIFYING',
    COMPLETED: 'COMPLETED',
    CANCELLED: 'CANCELLED',
    TIMEOUT: 'TIMEOUT'
};

/**
 * Calculate requestId from subscriptionId and interval
 */
function calculateRequestId(subscriptionId, interval) {
    const packedData = ethers.solidityPacked(
        ['uint64', 'uint32'],
        [subscriptionId, interval]
    );
    return ethers.keccak256(packedData);
}

/**
 * Settlement data structure for each request
 */
class SettlementRecord {
    constructor(requestId) {
        this.requestId = requestId;
        this.subscriptionId = null;
        this.interval = null;
        this.containerId = null;
        this.redundancy = null;

        // Client data
        this.clientWallet = null;
        this.clientFeeAmount = null;
        this.clientGasFee = 0n;
        this.clientTxHash = null;

        // Agent data
        this.agentWallets = []; // Can have multiple agents with redundancy
        this.agentPayments = {};
        this.agentGasFees = {};
        this.agentTxHashes = {};

        // Fee breakdown
        this.protocolFee = 0n;
        this.verifierFee = 0n;
        this.totalPaid = 0n;

        // Verification data
        this.verificationLocked = 0n;
        this.verificationUnlocked = 0n;

        // Status
        this.status = RequestStatus.PENDING;
        this.timestamp = null;
        this.blockNumber = null;

        // Additional info
        this.feeToken = null;
        this.verifier = null;
        this.coordinator = null;
        this.deliveryCount = 0;

        // Subscription info
        this.maxExecutions = null;
    }
}

/**
 * Subscription status enum
 */
const SubscriptionStatus = {
    ACTIVE: 'ACTIVE',
    CANCELLED: 'CANCELLED',
    COMPLETED: 'COMPLETED'
};

/**
 * Subscription summary data structure
 */
class SubscriptionSummary {
    constructor(subscriptionId) {
        this.subscriptionId = subscriptionId;
        this.client = null;
        this.activeAt = null;
        this.intervalSeconds = null;
        this.maxExecutions = null;
        this.redundancy = null;
        this.containerId = null;
        this.feeAmount = null;
        this.feeToken = null;
        this.wallet = null;
        this.verifier = null;
        this.routeId = null;

        // Status tracking
        this.status = SubscriptionStatus.ACTIVE;
        this.createdAt = null;
        this.cancelledAt = null;

        // Execution tracking
        this.totalRequests = 0;
        this.completedRequests = 0;
        this.pendingRequests = 0;
        this.cancelledRequests = 0;
        this.currentInterval = 0;

        // Financial tracking
        this.totalFeesCharged = 0n;
        this.totalFeesPaid = 0n;
    }
}

/**
 * Main Settlement Tracker
 */
class SettlementTracker {
    constructor(provider, routerAddress, coordinatorAddress) {
        this.provider = provider;
        this.router = new ethers.Contract(routerAddress, RouterArtifact.abi, provider);
        this.coordinator = new ethers.Contract(coordinatorAddress, CoordinatorArtifact.abi, provider);
        this.settlements = new Map(); // requestId => SettlementRecord
        this.subscriptions = new Map(); // subscriptionId => SubscriptionSummary
    }

    /**
     * Get or create settlement record
     */
    getSettlement(requestId) {
        if (!this.settlements.has(requestId)) {
            this.settlements.set(requestId, new SettlementRecord(requestId));
        }
        return this.settlements.get(requestId);
    }

    /**
     * Get or create subscription summary
     */
    async getSubscription(subscriptionId) {
        const subIdStr = subscriptionId.toString();
        if (!this.subscriptions.has(subIdStr)) {
            const summary = new SubscriptionSummary(subIdStr);

            // Fetch subscription data from contract
            try {
                const subData = await this.router.getComputeSubscription(subscriptionId);
                summary.client = subData.client;
                summary.activeAt = Number(subData.activeAt);
                summary.intervalSeconds = Number(subData.intervalSeconds);
                summary.maxExecutions = Number(subData.maxExecutions);
                summary.redundancy = Number(subData.redundancy);
                summary.containerId = subData.containerId;
                summary.feeAmount = subData.feeAmount;
                summary.feeToken = subData.feeToken;
                summary.wallet = subData.wallet;
                summary.verifier = subData.verifier;
                summary.routeId = subData.routeId;
            } catch (e) {
                console.warn(`Could not fetch subscription ${subscriptionId}:`, e.message);
            }

            this.subscriptions.set(subIdStr, summary);
        }
        return this.subscriptions.get(subIdStr);
    }

    /**
     * Fetch transaction receipt to get gas fees
     */
    async getGasFee(txHash) {
        try {
            const receipt = await this.provider.getTransactionReceipt(txHash);
            if (receipt) {
                return receipt.gasUsed * receipt.gasPrice;
            }
        } catch (e) {
            console.warn(`Could not fetch gas fee for tx ${txHash}:`, e.message);
        }
        return 0n;
    }

    /**
     * Process Router RequestStart event
     */
    async processRequestStart(event) {
        const args = event.args;
        const requestId = args.requestId;
        const settlement = this.getSettlement(requestId);

        settlement.subscriptionId = args.subscriptionId.toString();
        settlement.interval = Number(args.interval);
        settlement.containerId = args.containerId;
        settlement.redundancy = Number(args.redundancy);
        settlement.clientFeeAmount = args.feeAmount;
        settlement.feeToken = args.feeToken;
        settlement.verifier = args.verifier;
        settlement.coordinator = args.coordinator;
        settlement.timestamp = Number((await event.getBlock()).timestamp);
        settlement.blockNumber = Number(event.blockNumber);
        settlement.clientTxHash = event.transactionHash;

        // Get gas fee for client transaction
        settlement.clientGasFee = await this.getGasFee(event.transactionHash);

        // Fetch and update subscription info
        const subscription = await this.getSubscription(args.subscriptionId);
        settlement.maxExecutions = Number(subscription.maxExecutions);

        // Update subscription tracking
        subscription.totalRequests++;
        subscription.pendingRequests++;
        subscription.currentInterval = Math.max(subscription.currentInterval, Number(args.interval));
        subscription.totalFeesCharged += args.feeAmount;

        if (!subscription.createdAt) {
            subscription.createdAt = settlement.timestamp;
        }

        settlement.status = RequestStatus.PENDING;

        console.log(`[RequestStart] requestId: ${requestId.slice(0, 10)}..., subscriptionId: ${settlement.subscriptionId}, interval: ${settlement.interval}`);
    }

    /**
     * Process Coordinator ComputeDelivered event
     */
    async processComputeDelivered(event) {
        const args = event.args;
        const requestId = args.requestId;
        const settlement = this.getSettlement(requestId);

        const nodeWallet = args.nodeWallet;
        settlement.deliveryCount = Number(args.numRedundantDeliveries);

        if (!settlement.agentWallets.includes(nodeWallet)) {
            settlement.agentWallets.push(nodeWallet);
        }

        // Store agent transaction hash
        settlement.agentTxHashes[nodeWallet] = event.transactionHash;

        // Get gas fee for agent delivery
        const gasFee = await this.getGasFee(event.transactionHash);
        settlement.agentGasFees[nodeWallet] = gasFee;

        settlement.status = RequestStatus.DELIVERING;

        console.log(`[ComputeDelivered] requestId: ${requestId.slice(0, 10)}..., agent: ${nodeWallet}, deliveryCount: ${settlement.deliveryCount}`);
    }

    /**
     * Process Router VerificationFundsLocked event
     */
    async processVerificationFundsLocked(event) {
        const args = event.args;
        const subscriptionId = args.subscriptionId.toString();
        const interval = args.interval;
        const requestId = calculateRequestId(subscriptionId, interval);
        const settlement = this.getSettlement(requestId);

        settlement.verificationLocked += args.amount;
        settlement.status = RequestStatus.VERIFYING;

        console.log(`[VerificationFundsLocked] requestId: ${requestId.slice(0, 10)}..., amount: ${ethers.formatEther(args.amount)}`);
    }

    /**
     * Process Router VerificationFundsUnlocked event
     */
    async processVerificationFundsUnlocked(event) {
        const args = event.args;
        const subscriptionId = args.subscriptionId.toString();
        const interval = args.interval;
        const requestId = calculateRequestId(subscriptionId, interval);
        const settlement = this.getSettlement(requestId);

        settlement.verificationUnlocked += args.amount;

        console.log(`[VerificationFundsUnlocked] requestId: ${requestId.slice(0, 10)}..., amount: ${ethers.formatEther(args.amount)}`);
    }

    /**
     * Process Router PaymentMade event
     */
    async processPaymentMade(event) {
        const args = event.args;
        const subscriptionId = args.subscriptionId.toString();

        // Find settlement record by subscriptionId (need to iterate)
        for (const [requestId, settlement] of this.settlements.entries()) {
            if (settlement.subscriptionId === subscriptionId) {
                const recipient = args.recipient;
                const amount = args.amount;

                // Track payments by recipient
                if (settlement.agentWallets.includes(recipient)) {
                    settlement.agentPayments[recipient] = (settlement.agentPayments[recipient] || 0n) + amount;
                } else if (recipient !== settlement.clientWallet) {
                    // Assume protocol or verifier fee
                    settlement.protocolFee += amount;
                }

                settlement.totalPaid += amount;

                console.log(`[PaymentMade] subscriptionId: ${subscriptionId}, recipient: ${recipient}, amount: ${ethers.formatEther(amount)}`);
                break;
            }
        }
    }

    /**
     * Process Router RequestProcessed event
     */
    async processRequestProcessed(event) {
        const args = event.args;
        const requestId = args.requestId;
        const settlement = this.getSettlement(requestId);

        settlement.clientWallet = args.nodeWallet; // This is actually from commitment
        settlement.status = RequestStatus.COMPLETED;

        // Update agent payment info if not already set
        const nodeWallet = args.nodeWallet;
        if (!settlement.agentWallets.includes(nodeWallet)) {
            settlement.agentWallets.push(nodeWallet);
        }

        // Update subscription tracking
        if (settlement.subscriptionId) {
            const subscription = await this.getSubscription(settlement.subscriptionId);
            subscription.completedRequests++;
            subscription.pendingRequests--;
        }

        console.log(`[RequestProcessed] requestId: ${requestId.slice(0, 10)}..., status: COMPLETED`);
    }

    /**
     * Process Coordinator RequestCancelled event
     */
    async processRequestCancelled(event) {
        const args = event.args;
        const requestId = args.requestId;
        const settlement = this.getSettlement(requestId);

        settlement.status = RequestStatus.CANCELLED;

        // Update subscription tracking
        if (settlement.subscriptionId) {
            const subscription = await this.getSubscription(settlement.subscriptionId);
            subscription.cancelledRequests++;
            subscription.pendingRequests--;
        }

        console.log(`[RequestCancelled] requestId: ${requestId.slice(0, 10)}...`);
    }

    /**
     * Process Router SubscriptionCreated event
     */
    async processSubscriptionCreated(event) {
        const args = event.args;
        const subscriptionId = args.subscriptionId.toString();
        const subscription = await this.getSubscription(subscriptionId);

        const block = await event.getBlock();
        subscription.createdAt = Number(block.timestamp);

        console.log(`[SubscriptionCreated] subscriptionId: ${subscriptionId}`);
    }

    /**
     * Process Router SubscriptionCancelled event
     */
    async processSubscriptionCancelled(event) {
        const args = event.args;
        const subscriptionId = args.subscriptionId.toString();
        const subscription = await this.getSubscription(subscriptionId);

        subscription.status = SubscriptionStatus.CANCELLED;

        const block = await event.getBlock();
        subscription.cancelledAt = Number(block.timestamp);

        console.log(`[SubscriptionCancelled] subscriptionId: ${subscriptionId}`);
    }

    /**
     * Scan blockchain for all settlement events
     */
    async scanEvents(startBlock, endBlock) {
        console.log(`\n=== Starting Event Scan ===`);
        console.log(`Block range: ${startBlock} to ${endBlock || 'latest'}`);
        console.log(`Router: ${await this.router.getAddress()}`);
        console.log(`Coordinator: ${await this.coordinator.getAddress()}\n`);

        // Define all event filters
        const routerFilters = {
            SubscriptionCreated: this.router.filters.SubscriptionCreated(),
            SubscriptionCancelled: this.router.filters.SubscriptionCancelled(),
            RequestStart: this.router.filters.RequestStart(),
            RequestProcessed: this.router.filters.RequestProcessed(),
            PaymentMade: this.router.filters.PaymentMade(),
            VerificationFundsLocked: this.router.filters.VerificationFundsLocked(),
            VerificationFundsUnlocked: this.router.filters.VerificationFundsUnlocked()
        };

        const coordinatorFilters = {
            ComputeDelivered: this.coordinator.filters.ComputeDelivered(),
            RequestCancelled: this.coordinator.filters.RequestCancelled()
        };

        // Fetch Router events
        console.log('Fetching Router events...');
        for (const [eventName, filter] of Object.entries(routerFilters)) {
            console.log(`  - ${eventName}...`);
            const events = await this.router.queryFilter(filter, startBlock, endBlock);
            console.log(`    Found ${events.length} events`);

            for (const event of events) {
                switch (eventName) {
                    case 'SubscriptionCreated':
                        await this.processSubscriptionCreated(event);
                        break;
                    case 'SubscriptionCancelled':
                        await this.processSubscriptionCancelled(event);
                        break;
                    case 'RequestStart':
                        await this.processRequestStart(event);
                        break;
                    case 'RequestProcessed':
                        await this.processRequestProcessed(event);
                        break;
                    case 'PaymentMade':
                        await this.processPaymentMade(event);
                        break;
                    case 'VerificationFundsLocked':
                        await this.processVerificationFundsLocked(event);
                        break;
                    case 'VerificationFundsUnlocked':
                        await this.processVerificationFundsUnlocked(event);
                        break;
                }
            }
        }

        // Fetch Coordinator events
        console.log('\nFetching Coordinator events...');
        for (const [eventName, filter] of Object.entries(coordinatorFilters)) {
            console.log(`  - ${eventName}...`);
            const events = await this.coordinator.queryFilter(filter, startBlock, endBlock);
            console.log(`    Found ${events.length} events`);

            for (const event of events) {
                switch (eventName) {
                    case 'ComputeDelivered':
                        await this.processComputeDelivered(event);
                        break;
                    case 'RequestCancelled':
                        await this.processRequestCancelled(event);
                        break;
                }
            }
        }

        console.log(`\n=== Event Scan Complete ===`);
        console.log(`Total settlement records: ${this.settlements.size}`);

        // Update subscription status based on completion
        console.log(`\nUpdating subscription status...`);
        for (const subscription of this.subscriptions.values()) {
            // Check if subscription is completed (reached maxExecutions)
            if (subscription.status !== SubscriptionStatus.CANCELLED) {
                if (subscription.maxExecutions > 0 && subscription.currentInterval >= subscription.maxExecutions - 1) {
                    // currentInterval is 0-indexed, maxExecutions is count
                    subscription.status = SubscriptionStatus.COMPLETED;
                }
            }
        }

        console.log(`Total subscription records: ${this.subscriptions.size}\n`);
    }

    /**
     * Export settlements to CSV
     */
    exportToCSV(outputPath) {
        const headers = [
            'RequestID',
            'SubscriptionID',
            'Interval',
            'MaxExecutions',
            'Status',
            'Timestamp',
            'BlockNumber',
            'ClientWallet',
            'ClientFeeAmount',
            'ClientGasFee (Gwei)',
            'ClientTxHash',
            'AgentWallets',
            'AgentPayments',
            'AgentGasFees (Gwei)',
            'ProtocolFee',
            'VerifierFee',
            'TotalPaid',
            'VerificationLocked',
            'VerificationUnlocked',
            'DeliveryCount',
            'Redundancy',
            'FeeToken',
            'Verifier',
            'Coordinator',
            'ContainerID'
        ];

        const rows = [headers];

        for (const [requestId, settlement] of this.settlements.entries()) {
            // Aggregate agent data
            const agentWalletsStr = settlement.agentWallets.join('; ');
            const agentPaymentsStr = settlement.agentWallets
                .map(wallet => `${wallet}: ${ethers.formatEther(settlement.agentPayments[wallet] || 0n)}`)
                .join('; ');
            const agentGasFeesStr = settlement.agentWallets
                .map(wallet => `${wallet}: ${ethers.formatUnits(settlement.agentGasFees[wallet] || 0n, 'gwei')}`)
                .join('; ');

            const row = [
                requestId,
                settlement.subscriptionId || '',
                settlement.interval || '',
                settlement.maxExecutions !== null ? settlement.maxExecutions.toString() : '',
                settlement.status,
                settlement.timestamp ? new Date(settlement.timestamp * 1000).toISOString() : '',
                settlement.blockNumber || '',
                settlement.clientWallet || '',
                settlement.clientFeeAmount ? ethers.formatEther(settlement.clientFeeAmount) : '0',
                ethers.formatUnits(settlement.clientGasFee, 'gwei'),
                settlement.clientTxHash || '',
                agentWalletsStr,
                agentPaymentsStr,
                agentGasFeesStr,
                ethers.formatEther(settlement.protocolFee),
                ethers.formatEther(settlement.verifierFee),
                ethers.formatEther(settlement.totalPaid),
                ethers.formatEther(settlement.verificationLocked),
                ethers.formatEther(settlement.verificationUnlocked),
                settlement.deliveryCount,
                settlement.redundancy || '',
                settlement.feeToken || '',
                settlement.verifier || '',
                settlement.coordinator || '',
                settlement.containerId || ''
            ];

            rows.push(row);
        }

        // Convert settlement rows to CSV format
        const settlementCsvContent = rows.map(row =>
            row.map(cell => {
                // Escape cells containing commas, quotes, or newlines
                const cellStr = String(cell);
                if (cellStr.includes(',') || cellStr.includes('"') || cellStr.includes('\n')) {
                    return `"${cellStr.replace(/"/g, '""')}"`;
                }
                return cellStr;
            }).join(',')
        ).join('\n');

        // Write settlement report to file
        const settlementPath = path.resolve(__dirname, outputPath);
        fs.writeFileSync(settlementPath, settlementCsvContent, 'utf8');

        // Create subscription status CSV
        const subscriptionHeaders = [
            'SubscriptionID',
            'Status',
            'Client',
            'Wallet',
            'ActiveAt',
            'IntervalSeconds',
            'MaxExecutions',
            'CurrentInterval',
            'Redundancy',
            'FeeAmount (ETH)',
            'FeeToken',
            'TotalRequests',
            'CompletedRequests',
            'PendingRequests',
            'CancelledRequests',
            'TotalFeesCharged (ETH)',
            'TotalFeesPaid (ETH)',
            'CreatedAt',
            'CancelledAt',
            'ContainerID',
            'Verifier',
            'RouteID'
        ];

        const subscriptionRows = [subscriptionHeaders];

        for (const subscription of this.subscriptions.values()) {
            const subscriptionRow = [
                subscription.subscriptionId,
                subscription.status,
                subscription.client || '',
                subscription.wallet || '',
                subscription.activeAt ? new Date(subscription.activeAt * 1000).toISOString() : '',
                subscription.intervalSeconds || '',
                subscription.maxExecutions || '',
                subscription.currentInterval,
                subscription.redundancy || '',
                ethers.formatEther(subscription.feeAmount || 0n),
                subscription.feeToken || '',
                subscription.totalRequests,
                subscription.completedRequests,
                subscription.pendingRequests,
                subscription.cancelledRequests,
                ethers.formatEther(subscription.totalFeesCharged),
                ethers.formatEther(subscription.totalFeesPaid),
                subscription.createdAt ? new Date(subscription.createdAt * 1000).toISOString() : '',
                subscription.cancelledAt ? new Date(subscription.cancelledAt * 1000).toISOString() : '',
                subscription.containerId || '',
                subscription.verifier || '',
                subscription.routeId || ''
            ];

            subscriptionRows.push(subscriptionRow);
        }

        // Convert subscription rows to CSV format
        const subscriptionCsvContent = subscriptionRows.map(row =>
            row.map(cell => {
                const cellStr = String(cell);
                if (cellStr.includes(',') || cellStr.includes('"') || cellStr.includes('\n')) {
                    return `"${cellStr.replace(/"/g, '""')}"`;
                }
                return cellStr;
            }).join(',')
        ).join('\n');

        // Write subscription status to separate file
        const subscriptionPath = path.resolve(__dirname, 'subscription-status.csv');
        fs.writeFileSync(subscriptionPath, subscriptionCsvContent, 'utf8');

        console.log(`\n=== CSV Export Complete ===`);
        console.log(`Settlement Report: ${settlementPath}`);
        console.log(`  - Records: ${this.settlements.size}`);
        console.log(`  - Size: ${(settlementCsvContent.length / 1024).toFixed(2)} KB`);
        console.log(`\nSubscription Status: ${subscriptionPath}`);
        console.log(`  - Records: ${this.subscriptions.size}`);
        console.log(`  - Size: ${(subscriptionCsvContent.length / 1024).toFixed(2)} KB\n`);

        return settlementPath;
    }

    /**
     * Print summary statistics
     */
    printSummary() {
        console.log(`\n=== Settlement Summary ===\n`);

        const statusCounts = {};
        let totalClientFees = 0n;
        let totalAgentPayments = 0n;
        let totalProtocolFees = 0n;
        let totalClientGas = 0n;
        let totalAgentGas = 0n;

        for (const settlement of this.settlements.values()) {
            statusCounts[settlement.status] = (statusCounts[settlement.status] || 0) + 1;

            totalClientFees += settlement.clientFeeAmount || 0n;
            totalProtocolFees += settlement.protocolFee;
            totalClientGas += settlement.clientGasFee;

            for (const agentWallet of settlement.agentWallets) {
                totalAgentPayments += settlement.agentPayments[agentWallet] || 0n;
                totalAgentGas += settlement.agentGasFees[agentWallet] || 0n;
            }
        }

        console.log(`Total Requests: ${this.settlements.size}`);
        console.log(`\nStatus Breakdown:`);
        for (const [status, count] of Object.entries(statusCounts)) {
            console.log(`  ${status}: ${count}`);
        }

        console.log(`\nFinancial Summary (in ETH):`);
        console.log(`  Total Client Fees: ${ethers.formatEther(totalClientFees)}`);
        console.log(`  Total Agent Payments: ${ethers.formatEther(totalAgentPayments)}`);
        console.log(`  Total Protocol Fees: ${ethers.formatEther(totalProtocolFees)}`);
        console.log(`\nGas Summary (in Gwei):`);
        console.log(`  Total Client Gas: ${ethers.formatUnits(totalClientGas, 'gwei')}`);
        console.log(`  Total Agent Gas: ${ethers.formatUnits(totalAgentGas, 'gwei')}`);
        console.log(`  Total Gas: ${ethers.formatUnits(totalClientGas + totalAgentGas, 'gwei')}\n`);

        // Subscription summary
        console.log(`=== Subscription Summary ===\n`);

        const subStatusCounts = {};
        let totalSubRequests = 0;
        let totalSubCompleted = 0;
        let totalSubPending = 0;
        let totalSubCancelled = 0;

        for (const subscription of this.subscriptions.values()) {
            subStatusCounts[subscription.status] = (subStatusCounts[subscription.status] || 0) + 1;
            totalSubRequests += subscription.totalRequests;
            totalSubCompleted += subscription.completedRequests;
            totalSubPending += subscription.pendingRequests;
            totalSubCancelled += subscription.cancelledRequests;
        }

        console.log(`Total Subscriptions: ${this.subscriptions.size}`);
        console.log(`\nSubscription Status Breakdown:`);
        for (const [status, count] of Object.entries(subStatusCounts)) {
            console.log(`  ${status}: ${count}`);
        }

        console.log(`\nRequest Statistics:`);
        console.log(`  Total Requests: ${totalSubRequests}`);
        console.log(`  Completed: ${totalSubCompleted}`);
        console.log(`  Pending: ${totalSubPending}`);
        console.log(`  Cancelled: ${totalSubCancelled}\n`);
    }
}

/**
 * Main execution
 */
async function main() {
    console.log('\n╔════════════════════════════════════════╗');
    console.log('║   Noosphere Settlement Tracker v1.0   ║');
    console.log('╚════════════════════════════════════════╝\n');

    // Load configuration
    const rpcUrl = process.env.RPC_URL;
    const routerAddress = process.env.ROUTER_ADDRESS;
    const coordinatorAddress = process.env.COORDINATOR_ADDRESS;
    const startBlock = process.env.START_BLOCK ? parseInt(process.env.START_BLOCK) : 0;
    const endBlock = process.env.END_BLOCK ? parseInt(process.env.END_BLOCK) : undefined;
    const outputCsv = process.env.OUTPUT_CSV || 'settlement-report.csv';

    // Validate configuration
    if (!rpcUrl) {
        console.error('❌ Error: RPC_URL not set in .env-settlement.testnet');
        process.exit(1);
    }
    if (!routerAddress) {
        console.error('❌ Error: ROUTER_ADDRESS not set in .env-settlement.testnet');
        process.exit(1);
    }
    if (!coordinatorAddress) {
        console.error('❌ Error: COORDINATOR_ADDRESS not set in .env-settlement.testnet');
        process.exit(1);
    }

    console.log('Configuration:');
    console.log(`  RPC: ${rpcUrl}`);
    console.log(`  Router: ${routerAddress}`);
    console.log(`  Coordinator: ${coordinatorAddress}`);
    console.log(`  Start Block: ${startBlock || 'Contract deployment'}`);
    console.log(`  End Block: ${endBlock || 'Latest'}`);
    console.log(`  Output: ${outputCsv}\n`);

    // Initialize provider
    const provider = new ethers.JsonRpcProvider(rpcUrl);

    // Verify connection
    try {
        const network = await provider.getNetwork();
        console.log(`✅ Connected to network: ${network.name} (chainId: ${network.chainId})\n`);
    } catch (e) {
        console.error('❌ Failed to connect to RPC:', e.message);
        process.exit(1);
    }

    // Initialize tracker
    const tracker = new SettlementTracker(provider, routerAddress, coordinatorAddress);

    // Scan events
    await tracker.scanEvents(startBlock, endBlock);

    // Print summary
    tracker.printSummary();

    // Export to CSV
    const csvPath = tracker.exportToCSV(outputCsv);

    console.log('✅ Settlement tracking complete!\n');
}

// Run main function
if (require.main === module) {
    main().catch((error) => {
        console.error('❌ Fatal error:', error);
        process.exit(1);
    });
}

module.exports = { SettlementTracker, calculateRequestId, RequestStatus };
