// tx-utils.js  (patched: include blockNumber & chainId, CSV_PATH from env)
const fs = require('fs');
const path = require('path');
const { computeCalldataInfo } = require('./calldata-info'); // 경로 맞추세요

// prefer env CSV_PATH, else default to legacy path
const CSV_PATH = process.env.CSV_PATH || path.resolve(__dirname, './logs/gas_log.csv');
const HEADER = 'timestamp,role,label,txHash,gasUsed,effectiveGasPrice,costWei,costEth,status,payloadSize,iteration,note,blockNumber,chainId,calldataBytes,calldataZeroBytes,calldataNonZeroBytes,calldataGasEstimate,baseFeePerGas,priorityFee\n';

// ensure csv header exists
if (!fs.existsSync(CSV_PATH)) {
    fs.mkdirSync(path.dirname(CSV_PATH), { recursive: true });
    fs.writeFileSync(CSV_PATH, HEADER, 'utf8');
}

function safeBigIntToString(x) {
    if (x === undefined || x === null || x === '') return '';
    try {
        if (typeof x === 'bigint') return x.toString();
        if (typeof x === 'number') return String(x);
        // ethers v6 sometimes returns hex string? handle that:
        if (typeof x === 'string' && /^0x[0-9a-f]+$/i.test(x)) {
            // convert hex to decimal string (BigInt)
            return BigInt(x).toString();
        }
        return String(x);
    } catch (e) {
        return String(x);
    }
}

async function summarizeReceipt(receipt, label, opts = {}) {
    // opts: { role, payloadSize, iteration, note, provider, calldataBytes,... or interface, method, args }
    opts = opts || {};
    const provider = opts.provider;
    try {
        // Defensive: if caller passed tx instead of receipt, try to fetch receipt
        if (!receipt || (!('gasUsed' in receipt) && provider && receipt && receipt.hash)) {
            // try to fetch receipt from provider
            try {
                receipt = await provider.getTransactionReceipt(receipt.hash || receipt.transactionHash);
            } catch (e) {
                // ignore, we'll continue with what's available
            }
        }

        // gasUsed might be BigInt (ethers v6) or number
        const gasUsed = receipt && receipt.gasUsed ? BigInt(receipt.gasUsed) : BigInt(0);

        // effectiveGasPrice may be missing for legacy txs
        let effectiveGasPrice = receipt && receipt.effectiveGasPrice ? receipt.effectiveGasPrice
            : receipt && receipt.gasPrice ? receipt.gasPrice
                : undefined;

        // fallback: try provider.getTransaction() to read gasPrice if still undefined and we have txHash
        if ((effectiveGasPrice === undefined || effectiveGasPrice === null) && provider && receipt && (receipt.transactionHash || receipt.hash)) {
            try {
                const tx = await provider.getTransaction(receipt.transactionHash || receipt.hash);
                if (tx) {
                    effectiveGasPrice = tx.gasPrice ?? tx.maxFeePerGas ?? tx.maxPriorityFeePerGas ?? undefined;
                }
            } catch (e) {
                // ignore
            }
        }

        // costWei = gasUsed * effectiveGasPrice (both BigInt)
        let costWei = BigInt(0);
        if (effectiveGasPrice !== undefined && effectiveGasPrice !== null) {
            costWei = BigInt(gasUsed) * BigInt(effectiveGasPrice);
        }

        // costEth as decimal string. Use Number for human readable (may lose precision for huge numbers)
        let costEth = '';
        try {
            if (costWei !== BigInt(0)) {
                // safe conversion: convert to string with decimal
                const costWeiStr = costWei.toString();
                // produce decimal ETH string with up to 18 decimals
                const whole = costWeiStr.slice(0, -18) || '0';
                const frac = costWeiStr.slice(-18).padStart(18, '0').replace(/0+$/,'') || '0';
                costEth = frac === '0' ? `${whole}` : `${whole}.${frac}`;
            }
        } catch (e) {
            costEth = '';
        }

        // baseFeePerGas (optional): if receipt.blockNumber and provider available
        let baseFeePerGas = '';
        if (provider && receipt && receipt.blockNumber) {
            try {
                const blk = await provider.getBlock(receipt.blockNumber);
                if (blk && blk.baseFeePerGas !== undefined && blk.baseFeePerGas !== null) {
                    baseFeePerGas = safeBigIntToString(blk.baseFeePerGas);
                }
            } catch (e) { /* ignore */ }
        }

        // priorityFee = effectiveGasPrice - baseFeePerGas (if both available)
        let priorityFee = '';
        try {
            if (effectiveGasPrice !== undefined && baseFeePerGas) {
                const ef = BigInt(effectiveGasPrice);
                const bf = BigInt(baseFeePerGas);
                const pf = ef >= bf ? ef - bf : BigInt(0);
                priorityFee = pf.toString();
            }
        } catch (e) { /* ignore */ }

        // blockNumber and chainId
        let blockNumber = '';
        let chainId = '';
        if (receipt && (receipt.blockNumber || receipt.blockNumber === 0)) {
            blockNumber = String(receipt.blockNumber);
        }
        if (provider) {
            try {
                const network = await provider.getNetwork();
                chainId = String(network.chainId);
            } catch (e) { /* ignore */ }
        }

        // calldata metrics: prefer opts fields; else attempt computeCalldataInfo if interface/method/args passed
        let calldataBytes = opts.calldataBytes ?? '';
        let calldataZeroBytes = opts.calldataZeroBytes ?? '';
        let calldataNonZeroBytes = opts.calldataNonZeroBytes ?? '';
        let calldataGasEstimate = opts.calldataGasEstimate ?? '';

        if ((!calldataBytes || calldataBytes === '') && opts.interface && opts.method && Array.isArray(opts.args) && typeof computeCalldataInfo === 'function') {
            try {
                const info = computeCalldataInfo(opts.interface, opts.method, opts.args);
                calldataBytes = info.calldataBytes;
                calldataZeroBytes = info.zeroBytes;
                calldataNonZeroBytes = info.nonZeroBytes;
                calldataGasEstimate = info.calldataGasEstimate;
            } catch (e) {
                // ignore
            }
        }

        // prepare CSV columns (stringify BigInts)
        const row = [
            new Date().toISOString(),
            opts.role || '',
            label || '',
            receipt && (receipt.transactionHash || receipt.hash) ? (receipt.transactionHash || receipt.hash) : '',
            safeBigIntToString(gasUsed),
            safeBigIntToString(effectiveGasPrice),
            safeBigIntToString(costWei),
            costEth,
            receipt && receipt.status !== undefined ? String(Number(receipt.status)) : '',
            opts.payloadSize ?? '',
            opts.iteration ?? '',
            opts.note ?? '',
            blockNumber,
            chainId,
            calldataBytes,
            calldataZeroBytes,
            calldataNonZeroBytes,
            calldataGasEstimate,
            baseFeePerGas,
            priorityFee
        ].map(v => String(v).replace(/\n/g,' ').replace(/,/g,'')); // remove commas/newlines to keep CSV simple

        fs.appendFileSync(CSV_PATH, row.join(',') + '\n', 'utf8');

        // Optional debug log when fields missing
        if (!effectiveGasPrice) {
            console.warn(`[summarizeReceipt] effectiveGasPrice missing for ${label} tx=${receipt && (receipt.transactionHash || receipt.hash)}`);
        }

    } catch (e) {
        console.error('summarizeReceipt error:', e);
    }
}

module.exports = { summarizeReceipt, CSV_PATH, HEADER };
