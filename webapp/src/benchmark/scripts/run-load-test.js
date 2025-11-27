// webapp/src/benchmark/scripts/run-load-test.js
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const BENCH_DIR = path.resolve(__dirname, '..'); // webapp/src/benchmark
const REPO_ROOT = path.resolve(BENCH_DIR, '../../..'); // repo root if needed

// Path to client script (absolute, adjust if your client is elsewhere)
const CLIENT_SCRIPT = path.resolve(BENCH_DIR, 'benchtest-client.js');

const LOG_DIR = path.join(BENCH_DIR, 'logs');
if (!fs.existsSync(LOG_DIR)) fs.mkdirSync(LOG_DIR, { recursive: true });

// --- IMPORTANT: use absolute CSV_PATH so child processes write to same file ---
const CSV_PATH = path.join(LOG_DIR, 'gas_log.csv');

// Config
// const sizes = [0, 16, 64, 256, 1024, 4096];
const sizes = [0, 16];
const iterations = 1;
const failFast = process.argv.includes('--fail-fast'); // optional

console.log(`Starting load test — output will be written to ${CSV_PATH}`);
console.log(`Client script: ${CLIENT_SCRIPT}`);
console.log(`Sizes: ${sizes.join(', ')}  iterations: ${iterations}`);
console.log(`Fail-fast: ${failFast}`);

for (const s of sizes) {
    for (let iter = 1; iter <= iterations; iter++) {
        console.log(`\n=== Running size=${s} bytes (iteration ${iter}/${iterations}) ===`);

        // Build child env: inherit current env + our test vars + CSV_PATH
        const childEnv = {
            ...process.env,
            TEST_PAYLOAD_SIZE: String(s),
            TEST_ITERATION: String(iter),
            CSV_PATH: CSV_PATH, // <-- pass absolute CSV path to child
        };

        // spawn the client script by absolute path with cwd set to BENCH_DIR
        // stdio: inherit so child logs appear in current console (or file if redirected)
        const r = spawnSync('node', [CLIENT_SCRIPT], { env: childEnv, cwd: BENCH_DIR, stdio: 'inherit' });

        if (r.error) {
            console.error('Spawn error:', r.error);
            if (failFast) process.exit(1);
            continue;
        }
        if (r.status !== 0) {
            console.warn(`Client process exited with code=${r.status}.`);
            if (failFast) process.exit(r.status);
        } else {
            console.log(`Completed size=${s} iteration=${iter}`);
        }

        // short sleep
        const waitMs = 800;
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, waitMs);
    }
}

console.log(`\nAll runs finished. See ${CSV_PATH} for aggregated transaction summaries.`);
