#!/usr/bin/env node
// summarize-gas-log.js (improved - explicit calldata/basefee handling + dynamic extras)
// Usage: node scripts/summarize-gas-log.js [path/to/gas_log.csv]

const fs = require('fs');
const path = require('path');

const argPath = process.argv[2];
const csvPath = argPath || process.env.CSV_PATH || path.resolve(__dirname, '../webapp/src/benchmark/logs/gas_log.csv');
const outDir = path.resolve(path.dirname(csvPath), '.'); // same folder by default
const summaryJsonPath = path.join(outDir, 'summary.json');
const summaryCsvPath = path.join(outDir, 'summary.csv');

if (!fs.existsSync(csvPath)) {
    console.error(`Error: CSV not found at ${csvPath}`);
    process.exit(2);
}

const raw = fs.readFileSync(csvPath, 'utf8');
const lines = raw.split(/\r?\n/).filter(l => l.trim() !== '');
if (lines.length <= 1) {
    console.error('No data rows found in CSV.');
    process.exit(3);
}

// parse header
const header = lines[0].split(',').map(h => h.trim());
const rows = lines.slice(1).map(line => {
    // naive split (CSV values in our log are simple, no embedded commas)
    const cols = line.split(',');
    const obj = { __rawCols: cols };
    for (let i = 0; i < header.length; i++) {
        obj[header[i]] = cols[i] !== undefined ? cols[i].trim() : '';
    }
    return obj;
});

// helper: detect numeric type (improved: handles hex ints like 0x...)
function detectNumericType(str) {
    if (str === '' || str === null || str === undefined) return null;
    const s = String(str).trim();
    // hex integer (0x...)
    if (/^-?0x[0-9a-f]+$/i.test(s)) return 'integer';
    // integer (no decimal)
    if (/^-?\d+$/.test(s)) return 'integer';
    // float-ish (digits with decimal) or scientific
    if (/^-?\d+\.\d+$/.test(s) || /^-?\d+(\.\d+)?e[+-]?\d+$/i.test(s)) return 'float';
    return null;
}

// Known base numeric keys (treat these specially)
const baseNumericKeys = new Set([
    'gasUsed',
    'effectiveGasPrice',
    'costWei',
    'costEth',
    'status',
    'payloadSize',
    'iteration',
    // calldata / metrics we added
    'calldataBytes',
    'calldataZeroBytes',
    'calldataNonZeroBytes',
    'calldataGasEstimate',
    // block fee metrics
    'baseFeePerGas',
    'priorityFee'
]);

// normalize rows: create typedNumeric map on each row for easy aggregation
for (const r of rows) {
    r.__nums = {}; // {key: {type: 'bigint'|'number', value: BigInt|Number}}
    for (const k of header) {
        if (!r.hasOwnProperty(k)) continue;
        const v = r[k];
        if (v === '' || v === undefined) continue;

        // if baseNumericKeys -> try to parse to bigint or number
        if (baseNumericKeys.has(k)) {
            // hex integer
            if (/^-?0x[0-9a-f]+$/i.test(v)) {
                try {
                    r.__nums[k] = { type: 'bigint', value: BigInt(v) };
                    continue;
                } catch (e) {
                    // fallthrough to other parsing
                }
            }
            // integer decimal
            if (/^-?\d+$/.test(v)) {
                try {
                    // costWei and big counters -> BigInt
                    if (k === 'costWei' || k === 'baseFeePerGas' || k === 'priorityFee' || k === 'effectiveGasPrice') {
                        r.__nums[k] = { type: 'bigint', value: BigInt(v) };
                    } else {
                        r.__nums[k] = { type: 'number', value: Number(v) };
                    }
                    continue;
                } catch (e) { /* ignore */ }
            }
            // float/decimal
            if (/^-?\d+(\.\d+)?(e[+-]?\d+)?$/i.test(v)) {
                const n = Number(v);
                if (!Number.isNaN(n)) {
                    r.__nums[k] = { type: 'number', value: n };
                    continue;
                }
            }
            // fallback: leave as string (non-numeric)
        } else {
            // non-base keys: detect numeric
            const t = detectNumericType(v);
            if (t === 'integer') {
                try {
                    // hex or decimal integer -> BigInt
                    r.__nums[k] = { type: 'bigint', value: BigInt(v) };
                } catch (e) {
                    const n = Number(v);
                    if (!Number.isNaN(n)) r.__nums[k] = { type: 'number', value: n };
                }
            } else if (t === 'float') {
                const n = Number(v);
                if (!Number.isNaN(n)) r.__nums[k] = { type: 'number', value: n };
            }
        }
    }
}

// group by label + payloadSize
const groups = {};
for (const r of rows) {
    const label = r.label || 'unknown';
    const payloadSize = r.payloadSize && r.__nums && r.__nums['payloadSize'] ? Number(r.__nums['payloadSize'].value) : (r.payloadSize ? Number(r.payloadSize) : 0);
    const key = `${label}|${payloadSize}`;
    if (!groups[key]) {
        groups[key] = {
            label,
            payloadSize,
            runs: 0,
            // base accumulators
            totalGas: 0,
            totalCostEth: 0,
            totalWei: BigInt(0),
            // dynamic accumulators (number/bigint)
            totalNumber: {}, // { colName: totalNumber }
            totalBigInt: {}  // { colName: totalBigInt (BigInt) }
        };
    }
    const g = groups[key];
    g.runs += 1;

    // accumulate known numeric fields (if present)
    if (r.__nums && r.__nums['gasUsed'] && r.__nums['gasUsed'].type === 'number') g.totalGas += Number(r.__nums['gasUsed'].value);
    if (r.__nums && r.__nums['gasUsed'] && r.__nums['gasUsed'].type === 'bigint') g.totalGas += Number(r.__nums['gasUsed'].value); // safe fallback

    if (r.__nums && r.__nums['costEth'] && r.__nums['costEth'].type === 'number') g.totalCostEth += Number(r.__nums['costEth'].value);
    if (r.__nums && r.__nums['costWei'] && r.__nums['costWei'].type === 'bigint') {
        try { g.totalWei += BigInt(r.__nums['costWei'].value); } catch (e) { /* ignore parse errors */ }
    }

    // accumulate all numeric keys found in row.__nums (except those already handled)
    if (r.__nums) {
        for (const [col, info] of Object.entries(r.__nums)) {
            if (col === 'gasUsed' || col === 'costEth' || col === 'costWei' || col === 'payloadSize') continue;
            if (info.type === 'number') {
                g.totalNumber[col] = (g.totalNumber[col] || 0) + Number(info.value);
            } else if (info.type === 'bigint') {
                g.totalBigInt[col] = (g.totalBigInt[col] || BigInt(0)) + BigInt(info.value);
            }
        }
    }
}

// produce summary array with averages, including extra numeric fields
const summary = Object.values(groups).map(g => {
    const avgGas = g.runs > 0 ? Math.round(g.totalGas / g.runs) : 0;
    const avgCostEth = g.runs > 0 ? (g.totalCostEth / g.runs) : 0;
    const avgWei = g.runs > 0 ? (g.totalWei / BigInt(g.runs)) : BigInt(0);

    // compute averages for extra numeric columns
    const extraAverages = {};
    for (const col of Object.keys(g.totalNumber)) {
        extraAverages[col] = g.runs > 0 ? (g.totalNumber[col] / g.runs) : 0;
    }
    for (const col of Object.keys(g.totalBigInt)) {
        extraAverages[col] = g.runs > 0 ? (g.totalBigInt[col] / BigInt(g.runs)).toString() : "0";
    }

    return {
        label: g.label,
        payloadSize: g.payloadSize,
        runs: g.runs,
        avgGas,
        avgCostEth,
        avgCostWei: avgWei.toString(),
        extras: extraAverages
    };
});

// Console output (human readable)
console.log('Summary (label | payloadSize -> runs, avgGas, avgCostEth):');
for (const s of summary) {
    let line = `${s.label}|${s.payloadSize} -> runs=${s.runs} avgGas=${s.avgGas} avgCostEth=${s.avgCostEth}`;
    const extraKeys = Object.keys(s.extras || {});
    if (extraKeys.length > 0) {
        const extrasStr = extraKeys.map(k => `${k}=${s.extras[k]}`).join(', ');
        line += ` | extras: ${extrasStr}`;
    }
    console.log(line);
}

// Write JSON summary
try {
    fs.writeFileSync(summaryJsonPath, JSON.stringify({ generatedAt: new Date().toISOString(), csvPath, summary }, null, 2), 'utf8');
    console.log(`Wrote JSON summary to ${summaryJsonPath}`);
} catch (e) {
    console.warn('Failed to write JSON summary:', e.message);
}

// Write CSV summary - dynamic columns: base + extras
try {
    const extraColsSet = new Set();
    for (const s of summary) {
        for (const k of Object.keys(s.extras || {})) extraColsSet.add(k);
    }
    const extraCols = Array.from(extraColsSet);
    const csvHeader = ['label','payloadSize','runs','avgGas','avgCostWei','avgCostEth', ...extraCols.map(c => `avg_${c}`)];
    const csvLines = [csvHeader.join(',')];
    for (const s of summary) {
        const base = [s.label, s.payloadSize, s.runs, s.avgGas, s.avgCostWei, s.avgCostEth];
        const extrasRow = extraCols.map(c => {
            const v = (s.extras && s.extras[c] !== undefined) ? s.extras[c] : '';
            return String(v);
        });
        csvLines.push([...base, ...extrasRow].join(','));
    }
    fs.writeFileSync(summaryCsvPath, csvLines.join('\n'), 'utf8');
    console.log(`Wrote CSV summary to ${summaryCsvPath}`);
} catch (e) {
    console.warn('Failed to write CSV summary:', e.message);
}

process.exit(0);
