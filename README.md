# noosphere-evm

Noosphere smart contract suite — an on-chain framework for requesting off-chain compute workloads, receiving results, and managing subscription lifecycle and billing on EVM chains. This repository provides the protocol primitives, developer-facing client base contracts, and tooling to integrate periodic or one-shot off-chain compute into your smart contracts.

---

## Table of contents

- [Highlights](#highlights)
- [Foundry](#foundry)
- [Quick start](#quick-start)
- [Usage](#usage)
- [Contracts & architecture](#contracts--architecture)
- [Developer guide — client interfaces](#developer-guide---client-interfaces)
- [Project structure (typical)](#project-structure-typical)
- [Tests & CI](#tests--ci)
- [Deployment](#deployment---make-deploy)
- [Contributing](#contributing)
- [License](#license)
- [Acknowledgements (brief)](#acknowledgements-brief)

---

## Highlights

- Support for **one-shot (transient)** and **recurring (scheduled)** off-chain compute requests.
- Commitment-based request lifecycle: create request → off-chain fulfill → on-chain delivery.
- Billing and escrow primitives for payment/settlement management.
- Developer-facing base contracts:
    - `ScheduledComputeClient` — for recurring subscriptions (formerly `SubscriptionConsumer`)
    - `TransientComputeClient` — for one-shot callback jobs (formerly `CallbackConsumer`)
    - `ComputeClient` — shared base utilities (formerly `BaseConsumer`)

---

## Foundry

This project uses **Foundry** for development and testing.

Components used:

- **Forge**: testing & building.
- **Cast**: CLI for interacting with contracts & nodes.
- **Anvil**: local development node.
- **Chisel**: Solidity REPL.

Documentation: https://book.getfoundry.sh/

---

## Quick start

Clone and install dependencies (if you use git submodules for libs):

```bash
git clone https://github.com/hpp-io/noosphere-evm.git
cd noosphere-evm
# initialize submodules if any
git submodule update --init --recursive
```

Build and test:

```bash
forge build
forge test
```

Format:

```bash
forge fmt
```

Run a local node:

```bash
anvil
```

Interact with contracts:

```bash
cast <subcommand>
```

---

## Usage

### Build

```bash
forge build
```

### Test

```bash
forge test
```

### Format

```bash
forge fmt
```

### Gas snapshots

```bash
forge snapshot
```

### Local node

```bash
anvil
```

---

## Contracts & architecture (overview)

Key components and responsibilities:

- **Router** — contract registry/resolver and main entry point for protocol discovery and routing.
- **Coordinator** — orchestrates commitment lifecycle and validates deliveries.
- **Billing** — fee calculation, commitment mapping, and settlement helpers.
- **SubscriptionsManager** — create and manage subscriptions (period, frequency, redundancy).
- **Wallet / WalletFactory** — escrow/payment wallet management.
- **ScheduledComputeClient / TransientComputeClient / ComputeClient** — developer-facing client base contracts for receiving compute outputs.
- **Verifier** (optional) — hook to perform proof verification when using a proofing layer.

Design aims:
- Single responsibility per contract to reduce audit surface.
- Clear access control for callback/delivery entrypoints (e.g., `onlyCoordinator`).
- Minimal and reusable client base classes so application contracts implement only business logic.

Implementation files are under `src/v1_0_0/`.

---

## Developer guide — client interfaces

Integrate by inheriting one of the client base contracts depending on your use case.

### Scheduled (recurring) example

```solidity
// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {ScheduledComputeClient} from "src/v1_0_0/ScheduledComputeClient.sol";

contract MyScheduler is ScheduledComputeClient {
    constructor(address router) ScheduledComputeClient(router) {}
}
```

### Transient (one-shot) example

```solidity
import {TransientComputeClient} from "src/v1_0_0/TransientComputeClient.sol";

contract MyOneShotClient is TransientComputeClient {
    constructor(address router) TransientComputeClient(router) {}
}
```

### Notes & best practices

- Use access modifiers like `onlyCoordinator` to restrict callback endpoints.
- Keep decode/processing logic concise; use events to signal off-chain or indexable state.
- Prefer idempotent handlers where possible (e.g., ignore duplicate deliveries by requestId).
- The `ComputeClient` base provides helpers for registry lookups, request creation helpers, and common events.

---

## Project structure (typical)

```
.
├─ src/v1_0_0/            # Contracts (Router, Coordinator, ScheduledComputeClient, TransientComputeClient, Wallet, Billing, etc.)
├─ test/                  # Foundry tests
├─ scripts/               # Helper scripts (optional)
├─ Makefile               # build / test / deploy helpers (make deploy)
├─ lib/                   # Third-party deps (openzeppelin, solady, etc.)
├─ foundry.toml
└─ README.md
```

---

## Tests & CI

- Run tests locally: `forge test`.
- CI pipeline should at minimum run:
    - `forge build`
    - `forge test`
    - `forge fmt --check`

Example GitHub Actions job (conceptual):

```yaml
# .github/workflows/ci.yml (conceptual)
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Setup Foundry
        run: curl -L https://foundry.paradigm.xyz | bash && foundryup
      - name: Install deps
        run: forge install || true
      - name: Build & test
        run: forge build && forge test
      - name: Check format
        run: forge fmt --check
```

---

## Deployment

This repo uses a `Makefile` helper to standardize deployment. `make deploy` wraps `forge script` with environment variables for the private key and RPC endpoint.

### Example usage

```bash
export PRIVATE_KEY="0xYOUR_PRIVATE_KEY"   # use CI secrets or hardware signer in production
export RPC_URL="https://sepolia.hpp.io"
```

```bash
make deploy
```

### Suggested Makefile snippet

Add this snippet (or similar) to your `Makefile`:


### Best practices

- **Never** commit private keys to the repository. Use environment variables or CI secret stores.
- Prefer hardware signers or secure key management for production deployments.
- Add `dry-run`/simulation options to your Makefile for preflight checks (e.g., `--skip-simulation` or local fork simulation).
- In CI, set `PRIVATE_KEY` and `RPC_URL` as encrypted secrets and use a gated workflow for production deployments.

---

## Contributing

We welcome contributions.

- Fork the repo and open PRs with clear, focused changes.
- Run `forge fmt` and `forge test` locally before opening PRs.
- Keep API changes backwards-compatible where possible; if not, include a migration note.
- Add tests for new behavior and document new public functions in the README.

When referencing design ideas or architecture that were inspired by other public projects, a short mention in your PR description is appreciated.

---

## License

This repository is licensed under the **BSD 3-Clause Clear License**.

Include SPDX header in Solidity files:

```solidity
// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;
```

If you have questions about license compatibility with other projects you consulted, consider legal review.

---

## Acknowledgements

Design ideas and high-level patterns were referenced from other public projects. 
For attribution we note: Ritual / Infernet SDK. This mention is informational only.
