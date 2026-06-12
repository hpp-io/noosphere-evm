# Use bash as the shell for enhanced scripting features
SHELL := /bin/bash

# -----------------------------------------------------------------------------
# Load environment variables (if a .env exists, include it so variables
# are available to the Makefile)
# -----------------------------------------------------------------------------
ifneq (,$(wildcard ./.env))
	include .env
	export
endif

# -----------------------------------------------------------------------------
# PHONY targets (force these to run even if a file with the same name exists)
# -----------------------------------------------------------------------------
.PHONY: all install clean build test format docs snapshot diff deploy deploy-anvil deploy-hpp-sepolia deploy-hpp-mainnet deploy-mainnet-test-sepolia deploy-mainnet-full deploy-vrf deploy-vrf-hpp-sepolia deploy-vrf-hpp-mainnet register-epoch register-epoch-mainnet verify-contracts verify-deployment fund-accounts

# -----------------------------------------------------------------------------
# Default target: run dependency install -> clean -> format -> build -> test
# -----------------------------------------------------------------------------
all: install clean format build test

# -----------------------------------------------------------------------------
# Install dependencies
# - Fetch forge dependencies (libraries, etc.)z
# -----------------------------------------------------------------------------
install:
	@echo "=> installing dependencies..."
	@forge install

# -----------------------------------------------------------------------------
# Clean build cache / artifacts
# - Use to get to a clean state before rebuilding
# -----------------------------------------------------------------------------
clean:
	@echo "=> cleaning build artifacts..."
	@forge clean

# -----------------------------------------------------------------------------
# Compile / build
# -----------------------------------------------------------------------------
build:
	@echo "=> building contracts and artifacts..."
	@forge build

# -----------------------------------------------------------------------------
# Run all tests (verbose)
# -----------------------------------------------------------------------------
test:
	@echo "=> running tests..."
	@forge test -vvv

# -----------------------------------------------------------------------------
# Scripts / deploy target
# - Requires RPC_URL environment variable
# - PRIVATE_KEY should be provided for the Forge script to read
# - Adjust --skip-simulation and optimizer flags according to deployment policy
# -----------------------------------------------------------------------------
deploy:
	@if [ -z "$(RPC_URL)" ]; then \
		echo "ERROR: RPC_URL environment variable is required for deploy"; \
		exit 1; \
	fi
	@echo "=> running deploy script (broadcasting) to $(RPC_URL)..."
	@forge script scripts/Deploy.sol:Deploy \
		--broadcast \
		--skip-simulation \
		--gas-estimate-multiplier 130 \
		--optimize \
		--optimizer-runs 1000000 \
		--extra-output-files abi \
		--rpc-url $(RPC_URL)

deploy-anvil:
	@if [ -z "$(RPC_URL)" ] || [ -z "$(PRIVATE_KEY)" ] || [ -z "$(PRODUCTION_OWNER_ADDR)" ] || [ -z "$(CHAIN_ID)" ] || [ -z "$(INITIAL_FEE_RECIPIENT_ADDR)" ]; then \
		echo "ERROR: RPC_URL, PRIVATE_KEY, PRODUCTION_OWNER, CHAIN_ID, and INITIAL_FEE_RECIPIENT environment variables are required."; \
		exit 1; \
	fi
	@echo "=> Running production deployment to $(RPC_URL)..."
	@echo "  Chain ID:         $(CHAIN_ID)"
	@echo "  Deployer:         (address derived from PRIVATE_KEY)"
	@echo "  Production Owner:   $(PRODUCTION_OWNER)"
	@echo "  Initial Fee Recipient: $(INITIAL_FEE_RECIPIENT)"
	@forge script scripts/DeployTest.sol:DeployTest \
		--skip-simulation \
		--gas-estimate-multiplier 130 \
		--optimize \
		--optimizer-runs 1000000 \
		--extra-output-files abi \
		--rpc-url ${RPC_URL} \
		--chain-id $(CHAIN_ID) \
		--private-key $(PRIVATE_KEY) \
		--broadcast \
		--sig "run(address,address)" $(PRODUCTION_OWNER_ADDR) $(INITIAL_FEE_RECIPIENT_ADDR)

# -----------------------------------------------------------------------------
# Deploy to HPP Sepolia testnet with contract verification
# - Requires: RPC_URL, PRIVATE_KEY, PRODUCTION_OWNER_ADDR, CHAIN_ID, INITIAL_FEE_RECIPIENT_ADDR
# - Uses Blockscout explorer at https://sepolia-explorer.hpp.io/
# -----------------------------------------------------------------------------
deploy-hpp-sepolia:
	@if [ -z "$(RPC_URL)" ] || [ -z "$(PRIVATE_KEY)" ] || [ -z "$(PRODUCTION_OWNER_ADDR)" ] || [ -z "$(CHAIN_ID)" ] || [ -z "$(INITIAL_FEE_RECIPIENT_ADDR)" ]; then \
		echo "ERROR: RPC_URL, PRIVATE_KEY, PRODUCTION_OWNER_ADDR, CHAIN_ID, and INITIAL_FEE_RECIPIENT_ADDR environment variables are required."; \
		exit 1; \
	fi
	@echo "=> Running deployment to HPP Sepolia with verification..."
	@echo "  Chain ID:              $(CHAIN_ID)"
	@echo "  Deployer:              (address derived from PRIVATE_KEY)"
	@echo "  Production Owner:      $(PRODUCTION_OWNER_ADDR)"
	@echo "  Initial Fee Recipient: $(INITIAL_FEE_RECIPIENT_ADDR)"
	@echo "  Verifier:              https://sepolia-explorer.hpp.io/api"
	@forge script scripts/DeployTest.sol:DeployTest \
		--skip-simulation \
		--gas-estimate-multiplier 130 \
		--optimize \
		--optimizer-runs 1000000 \
		--extra-output-files abi \
		--rpc-url $(RPC_URL) \
		--chain-id $(CHAIN_ID) \
		--private-key $(PRIVATE_KEY) \
		--broadcast \
		--verify \
		--verifier blockscout \
		--verifier-url https://sepolia-explorer.hpp.io/api/ \
		--sig "run(address,address)" $(PRODUCTION_OWNER_ADDR) $(INITIAL_FEE_RECIPIENT_ADDR)

# -----------------------------------------------------------------------------
# Test DeployMainnet.sol on HPP Sepolia (pre-mainnet dry run)
# - Uses DeployMainnet.sol script with Sepolia explorer for verification
# - All owner roles should be set to a single test address in .env
# - Requires: RPC_URL, PRIVATE_KEY, PRODUCTION_OWNER_ADDR, CHAIN_ID,
#             INITIAL_FEE_RECIPIENT_ADDR, IMMEDIATE_FINALIZE_VERIFIER_OWNER_ADDR
# -----------------------------------------------------------------------------
deploy-mainnet-test-sepolia:
	@if [ -z "$(RPC_URL)" ] || [ -z "$(PRIVATE_KEY)" ] || [ -z "$(PRODUCTION_OWNER_ADDR)" ] \
		|| [ -z "$(CHAIN_ID)" ] || [ -z "$(INITIAL_FEE_RECIPIENT_ADDR)" ] \
		|| [ -z "$(IMMEDIATE_FINALIZE_VERIFIER_OWNER_ADDR)" ]; then \
		echo "ERROR: RPC_URL, PRIVATE_KEY, PRODUCTION_OWNER_ADDR, CHAIN_ID, INITIAL_FEE_RECIPIENT_ADDR, and IMMEDIATE_FINALIZE_VERIFIER_OWNER_ADDR are required."; \
		exit 1; \
	fi
	@echo "=> Testing DeployMainnet.sol on HPP Sepolia..."
	@echo "  Chain ID:              $(CHAIN_ID)"
	@echo "  Deployer:              (address derived from PRIVATE_KEY)"
	@echo "  Protocol Safe:         $(PRODUCTION_OWNER_ADDR)"
	@echo "  Verifier Safe:         $(IMMEDIATE_FINALIZE_VERIFIER_OWNER_ADDR)"
	@echo "  Initial Fee Recipient: $(INITIAL_FEE_RECIPIENT_ADDR)"
	@echo "  Explorer:              https://sepolia-explorer.hpp.io/api"
	@forge script scripts/DeployMainnet.sol:DeployMainnet \
		--skip-simulation \
		--gas-estimate-multiplier 130 \
		--optimize \
		--optimizer-runs 1000000 \
		--extra-output-files abi \
		--rpc-url $(RPC_URL) \
		--chain-id $(CHAIN_ID) \
		--private-key $(PRIVATE_KEY) \
		--broadcast \
		--verify \
		--verifier blockscout \
		--verifier-url https://sepolia-explorer.hpp.io/api/ \
		--sig "run(address,address)" $(PRODUCTION_OWNER_ADDR) $(INITIAL_FEE_RECIPIENT_ADDR)

# =============================================================================
# MAINNET DEPLOYMENT ORCHESTRATOR
# =============================================================================
# Full mainnet deployment flow with confirmation prompts between steps.
#
# Prerequisites:
#   1. .env loaded with mainnet config (see .env.mainnet.example)
#   2. Safe multisigs created (Protocol, Verifier, VRF)
#   3. Deployer EOA funded with ~0.2 ETH for gas
#
# Flow:
#   Step 1: Pre-flight checks (build + test)
#   Step 2: Core contract deployment (Router, Coordinator, Verifier, etc.)
#   Step 3: VRF deployment
#   Step 4: Source code verification on explorer
#   Step 5: Post-deployment state verification
#
# After completion:
#   - Fund Safe wallets via Ops dashboard
#   - Protocol Safe: call Router.acceptOwnership() + Coordinator.acceptOwnership()
#   - VRF Safe: call NoosphereVRF.registerEpoch()
# =============================================================================
deploy-mainnet-full:
	@echo ""
	@echo "╔══════════════════════════════════════════════════╗"
	@echo "║        HPP Mainnet Deployment Orchestrator       ║"
	@echo "╚══════════════════════════════════════════════════╝"
	@echo ""
	@echo "  Chain ID:              $(CHAIN_ID)"
	@echo "  RPC:                   $(RPC_URL)"
	@echo "  Protocol Safe:         $(PRODUCTION_OWNER_ADDR)"
	@echo "  Verifier Safe:         $(IMMEDIATE_FINALIZE_VERIFIER_OWNER_ADDR)"
	@echo "  VRF Owner:             $(VRF_OWNER)"
	@echo "  Fee Recipient:         $(INITIAL_FEE_RECIPIENT_ADDR)"
	@echo ""
	@echo "─── Step 1/5: Pre-flight checks ───"
	@read -p "Run build + tests? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	@$(MAKE) build
	@$(MAKE) test
	@echo ""
	@echo "✓ Step 1 complete: build + tests passed"
	@echo ""
	@echo "─── Step 2/5: Core contract deployment ───"
	@echo "  This will deploy Router, Coordinator, WalletFactory, Verifier, Reader"
	@echo "  and transfer ownership to Safe addresses."
	@read -p "Deploy core contracts to mainnet? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	@$(MAKE) deploy-hpp-mainnet
	@echo ""
	@echo "✓ Step 2 complete: core contracts deployed"
	@echo "  Save the contract addresses from the output above."
	@echo ""
	@echo "─── Step 3/5: VRF deployment ───"
	@read -p "Deploy NoosphereVRF to mainnet? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	@$(MAKE) deploy-vrf-hpp-mainnet
	@echo ""
	@echo "✓ Step 3 complete: VRF deployed"
	@echo ""
	@echo "─── Step 4/5: Source code verification ───"
	@echo "  Wait ~30s for explorer to index contracts before verifying."
	@read -p "Verify contract source code on explorer? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	@$(MAKE) verify-contracts
	@echo ""
	@echo "✓ Step 4 complete: source code verified"
	@echo ""
	@echo "─── Step 5/5: Post-deployment state verification ───"
	@echo "  Set ROUTER_ADDR, COORDINATOR_ADDR, VRF_ADDR in .env first."
	@read -p "Run state verification? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	@$(MAKE) verify-deployment
	@echo ""
	@echo "╔══════════════════════════════════════════════════╗"
	@echo "║              Deployment Complete                 ║"
	@echo "╠══════════════════════════════════════════════════╣"
	@echo "║  Next steps:                                     ║"
	@echo "║  1. Fund Safe wallets via Ops dashboard          ║"
	@echo "║  2. Protocol Safe: acceptOwnership() on Router   ║"
	@echo "║  3. Protocol Safe: acceptOwnership() on Coord.   ║"
	@echo "║  4. VRF Safe: registerEpoch(0, merkleRoot)       ║"
	@echo "╚══════════════════════════════════════════════════╝"

# -----------------------------------------------------------------------------
# Deploy to HPP Mainnet with contract verification
# - Deployer acts as temporary Owner (no PRODUCTION_OWNER_PRIVATE_KEY needed)
# - Phase 1: contract deployment, Phase 2: configuration, Phase 3: ownership transfer
# - Requires: RPC_URL, PRIVATE_KEY, PRODUCTION_OWNER_ADDR, CHAIN_ID,
#             INITIAL_FEE_RECIPIENT_ADDR, IMMEDIATE_FINALIZE_VERIFIER_OWNER_ADDR
# -----------------------------------------------------------------------------
deploy-hpp-mainnet:
	@if [ -z "$(RPC_URL)" ] || [ -z "$(PRIVATE_KEY)" ] || [ -z "$(PRODUCTION_OWNER_ADDR)" ] \
		|| [ -z "$(CHAIN_ID)" ] || [ -z "$(INITIAL_FEE_RECIPIENT_ADDR)" ] \
		|| [ -z "$(IMMEDIATE_FINALIZE_VERIFIER_OWNER_ADDR)" ]; then \
		echo "ERROR: RPC_URL, PRIVATE_KEY, PRODUCTION_OWNER_ADDR, CHAIN_ID, INITIAL_FEE_RECIPIENT_ADDR, and IMMEDIATE_FINALIZE_VERIFIER_OWNER_ADDR are required."; \
		exit 1; \
	fi
	@echo "=> Running deployment to HPP Mainnet with verification..."
	@echo "  Chain ID:              $(CHAIN_ID)"
	@echo "  Deployer:              (address derived from PRIVATE_KEY)"
	@echo "  Protocol Safe:         $(PRODUCTION_OWNER_ADDR)"
	@echo "  Verifier Safe:         $(IMMEDIATE_FINALIZE_VERIFIER_OWNER_ADDR)"
	@echo "  Initial Fee Recipient: $(INITIAL_FEE_RECIPIENT_ADDR)"
	@echo "  Explorer:              https://explorer.hpp.io/api"
	@forge script scripts/DeployMainnet.sol:DeployMainnet \
		--skip-simulation \
		--gas-estimate-multiplier 130 \
		--optimize \
		--optimizer-runs 1000000 \
		--extra-output-files abi \
		--rpc-url $(RPC_URL) \
		--chain-id $(CHAIN_ID) \
		--private-key $(PRIVATE_KEY) \
		--broadcast \
		--sig "run(address,address)" $(PRODUCTION_OWNER_ADDR) $(INITIAL_FEE_RECIPIENT_ADDR)
	@echo ""
	@echo "NOTE: Run 'make verify-contracts' after explorer indexes the contracts."

# -----------------------------------------------------------------------------
# Deploy NoosphereVRF singleton
# - Requires: RPC_URL, PRIVATE_KEY
# - Optional: VRF_OWNER (defaults to deployer address)
# -----------------------------------------------------------------------------
deploy-vrf:
	@if [ -z "$(RPC_URL)" ] || [ -z "$(PRIVATE_KEY)" ]; then \
		echo "ERROR: RPC_URL and PRIVATE_KEY environment variables are required."; \
		exit 1; \
	fi
	@echo "=> Deploying NoosphereVRF singleton to $(RPC_URL)..."
	@forge script scripts/DeployVRF.sol:DeployVRF \
		--broadcast \
		--skip-simulation \
		--gas-estimate-multiplier 130 \
		--optimize \
		--optimizer-runs 1000000 \
		--extra-output-files abi \
		--rpc-url $(RPC_URL) \
		--chain-id $(CHAIN_ID) \
		--private-key $(PRIVATE_KEY)

deploy-vrf-hpp-sepolia:
	@if [ -z "$(RPC_URL)" ] || [ -z "$(PRIVATE_KEY)" ]; then \
		echo "ERROR: RPC_URL and PRIVATE_KEY environment variables are required."; \
		exit 1; \
	fi
	@echo "=> Deploying NoosphereVRF to HPP Sepolia with verification..."
	@forge script scripts/DeployVRF.sol:DeployVRF \
		--broadcast \
		--skip-simulation \
		--gas-estimate-multiplier 130 \
		--optimize \
		--optimizer-runs 1000000 \
		--extra-output-files abi \
		--rpc-url $(RPC_URL) \
		--chain-id $(CHAIN_ID) \
		--private-key $(PRIVATE_KEY) \
		--verify \
		--verifier blockscout \
		--verifier-url https://sepolia-explorer.hpp.io/api/

# -----------------------------------------------------------------------------
# Register epoch on NoosphereVRF
# - Requires: RPC_URL, PRIVATE_KEY, VRF_ADDRESS, EPOCH, MERKLE_ROOT
# -----------------------------------------------------------------------------
register-epoch:
	@if [ -z "$(RPC_URL)" ] || [ -z "$(PRIVATE_KEY)" ] || [ -z "$(VRF_ADDRESS)" ] || [ -z "$(EPOCH)" ] || [ -z "$(MERKLE_ROOT)" ]; then \
		echo "ERROR: RPC_URL, PRIVATE_KEY, VRF_ADDRESS, EPOCH, MERKLE_ROOT are required."; \
		exit 1; \
	fi
	@echo "=> Registering epoch $(EPOCH) on NoosphereVRF $(VRF_ADDRESS)..."
	@NOOSPHERE_VRF_ADDRESS=$(VRF_ADDRESS) forge script scripts/RegisterEpoch.sol:RegisterEpoch \
		--broadcast \
		--rpc-url $(RPC_URL) \
		--chain-id $(CHAIN_ID) \
		--private-key $(PRIVATE_KEY)

# -----------------------------------------------------------------------------
# Deploy NoosphereVRF to HPP Mainnet with verification
# - Requires: RPC_URL, PRIVATE_KEY, CHAIN_ID
# - Optional: VRF_OWNER (defaults to deployer address)
# -----------------------------------------------------------------------------
deploy-vrf-hpp-mainnet:
	@if [ -z "$(RPC_URL)" ] || [ -z "$(PRIVATE_KEY)" ]; then \
		echo "ERROR: RPC_URL and PRIVATE_KEY environment variables are required."; \
		exit 1; \
	fi
	@echo "=> Deploying NoosphereVRF to HPP Mainnet..."
	@forge script scripts/DeployVRF.sol:DeployVRF \
		--broadcast \
		--skip-simulation \
		--gas-estimate-multiplier 130 \
		--optimize \
		--optimizer-runs 1000000 \
		--extra-output-files abi \
		--rpc-url $(RPC_URL) \
		--chain-id $(CHAIN_ID) \
		--private-key $(PRIVATE_KEY)
	@echo ""
	@echo "NOTE: Run 'make verify-contracts' after explorer indexes the contract."

# -----------------------------------------------------------------------------
# Register epoch on NoosphereVRF (HPP Mainnet)
# - Requires: RPC_URL, PRIVATE_KEY, VRF_ADDRESS, EPOCH, MERKLE_ROOT
# -----------------------------------------------------------------------------
register-epoch-mainnet:
	@if [ -z "$(RPC_URL)" ] || [ -z "$(PRIVATE_KEY)" ] || [ -z "$(VRF_ADDRESS)" ] \
		|| [ -z "$(EPOCH)" ] || [ -z "$(MERKLE_ROOT)" ]; then \
		echo "ERROR: RPC_URL, PRIVATE_KEY, VRF_ADDRESS, EPOCH, MERKLE_ROOT are required."; \
		exit 1; \
	fi
	@echo "=> Registering epoch $(EPOCH) on NoosphereVRF $(VRF_ADDRESS)..."
	@NOOSPHERE_VRF_ADDRESS=$(VRF_ADDRESS) forge script scripts/RegisterEpoch.sol:RegisterEpoch \
		--broadcast \
		--rpc-url $(RPC_URL) \
		--chain-id $(CHAIN_ID) \
		--private-key $(PRIVATE_KEY)

# -----------------------------------------------------------------------------
# Verify contract source code on Blockscout explorer
# - Re-reads broadcast artifacts and submits verification for all contracts
# - Run after deploy-hpp-mainnet / deploy-vrf-hpp-mainnet (wait ~30s for indexing)
# - Requires: RPC_URL, CHAIN_ID, EXPLORER_API_URL
# - EXPLORER_API_URL defaults to mainnet; override for testnet
# -----------------------------------------------------------------------------
EXPLORER_API_URL ?= https://explorer.hpp.io/api/

verify-contracts:
	@if [ -z "$(RPC_URL)" ] || [ -z "$(CHAIN_ID)" ] || [ -z "$(PRIVATE_KEY)" ]; then \
		echo "ERROR: RPC_URL, CHAIN_ID, and PRIVATE_KEY are required."; \
		exit 1; \
	fi
	@echo "=> Verifying contract source code on $(EXPLORER_API_URL)..."
	@echo ""
	@echo "--- Core contracts (DeployMainnet.sol) ---"
	@forge script scripts/DeployMainnet.sol:DeployMainnet \
		--rpc-url $(RPC_URL) \
		--chain-id $(CHAIN_ID) \
		--private-key $(PRIVATE_KEY) \
		--optimize --optimizer-runs 1000000 \
		--verify \
		--verifier blockscout \
		--verifier-url $(EXPLORER_API_URL) \
		--resume \
		--sig "run(address,address)" $(PRODUCTION_OWNER_ADDR) $(INITIAL_FEE_RECIPIENT_ADDR) || true
	@echo ""
	@echo "--- VRF contract (DeployVRF.sol) ---"
	@forge script scripts/DeployVRF.sol:DeployVRF \
		--rpc-url $(RPC_URL) \
		--chain-id $(CHAIN_ID) \
		--private-key $(PRIVATE_KEY) \
		--optimize --optimizer-runs 1000000 \
		--verify \
		--verifier blockscout \
		--verifier-url $(EXPLORER_API_URL) \
		--resume || true
	@echo ""
	@echo "=> Source verification complete."

# -----------------------------------------------------------------------------
# Verify deployment — post-deployment state checks via cast call
# - Requires: RPC_URL, ROUTER_ADDR, COORDINATOR_ADDR
# - Optional: VRF_ADDR, PRODUCTION_OWNER_ADDR
# -----------------------------------------------------------------------------
verify-deployment:
	@if [ -z "$(RPC_URL)" ] || [ -z "$(ROUTER_ADDR)" ] || [ -z "$(COORDINATOR_ADDR)" ]; then \
		echo "ERROR: RPC_URL, ROUTER_ADDR, and COORDINATOR_ADDR are required."; \
		exit 1; \
	fi
	@echo "=> Verifying on-chain state..."
	@echo ""
	@echo "--- Ownership ---"
	@echo -n "  Router owner:        "; cast call $(ROUTER_ADDR) "client()(address)" --rpc-url $(RPC_URL)
	@echo -n "  Coordinator owner:   "; cast call $(COORDINATOR_ADDR) "client()(address)" --rpc-url $(RPC_URL)
	@if [ -n "$(VRF_ADDR)" ]; then \
		echo -n "  VRF owner:           "; cast call $(VRF_ADDR) "owner()(address)" --rpc-url $(RPC_URL); \
	fi
	@echo ""
	@echo "--- Configuration ---"
	@echo -n "  WalletFactory:       "; cast call $(ROUTER_ADDR) "getWalletFactory()(address)" --rpc-url $(RPC_URL)
	@echo -n "  Router paused:       "; cast call $(ROUTER_ADDR) "paused()(bool)" --rpc-url $(RPC_URL)
	@echo -n "  Coordinator init:    "; cast call $(COORDINATOR_ADDR) "getProtocolFee()(uint96)" --rpc-url $(RPC_URL) 2>/dev/null && echo "" || echo "  (check manually)"
	@if [ -n "$(VRF_ADDR)" ]; then \
		echo -n "  VRF EPOCH_SIZE:      "; cast call $(VRF_ADDR) "EPOCH_SIZE()(uint256)" --rpc-url $(RPC_URL); \
	fi
	@echo ""
	@if [ -n "$(PRODUCTION_OWNER_ADDR)" ]; then \
		echo "--- Expected owner: $(PRODUCTION_OWNER_ADDR) ---"; \
	fi
	@echo "=> State verification complete."

# -----------------------------------------------------------------------------
# Fund accounts — optional CLI backup for Safe funding (Ops EOA only)
# - Requires: RPC_URL, OPS_PRIVATE_KEY
# - Amounts from FUND_* environment variables
# -----------------------------------------------------------------------------
fund-accounts:
	@if [ -z "$(RPC_URL)" ] || [ -z "$(OPS_PRIVATE_KEY)" ]; then \
		echo "ERROR: RPC_URL and OPS_PRIVATE_KEY are required."; \
		exit 1; \
	fi
	@echo "=> Funding accounts (Source: Ops EOA)..."
	@if [ -n "$(FUND_PROTOCOL_SAFE)" ] && [ -n "$(PRODUCTION_OWNER_ADDR)" ]; then \
		echo "  Funding Protocol Safe ($(PRODUCTION_OWNER_ADDR)) with $(FUND_PROTOCOL_SAFE) ETH"; \
		cast send $(PRODUCTION_OWNER_ADDR) --value $(FUND_PROTOCOL_SAFE)ether \
			--rpc-url $(RPC_URL) --private-key $(OPS_PRIVATE_KEY); \
	fi
	@if [ -n "$(FUND_VERIFIER_SAFE)" ] && [ -n "$(IMMEDIATE_FINALIZE_VERIFIER_OWNER_ADDR)" ]; then \
		echo "  Funding Verifier Safe ($(IMMEDIATE_FINALIZE_VERIFIER_OWNER_ADDR)) with $(FUND_VERIFIER_SAFE) ETH"; \
		cast send $(IMMEDIATE_FINALIZE_VERIFIER_OWNER_ADDR) --value $(FUND_VERIFIER_SAFE)ether \
			--rpc-url $(RPC_URL) --private-key $(OPS_PRIVATE_KEY); \
	fi
	@if [ -n "$(FUND_VRF_SAFE)" ] && [ -n "$(VRF_OWNER)" ]; then \
		echo "  Funding VRF Safe ($(VRF_OWNER)) with $(FUND_VRF_SAFE) ETH"; \
		cast send $(VRF_OWNER) --value $(FUND_VRF_SAFE)ether \
			--rpc-url $(RPC_URL) --private-key $(OPS_PRIVATE_KEY); \
	fi
	@echo "=> Funding complete."

# -----------------------------------------------------------------------------
# Save gas snapshot (using forge snapshot)
# -----------------------------------------------------------------------------
snapshot:
	@echo "=> saving current gas profile snapshot..."
	@forge snapshot

# -----------------------------------------------------------------------------
# Show difference between saved snapshot and current profile
# -----------------------------------------------------------------------------
diff:
	@echo "=> comparing gas snapshot (diff)..."
	@forge snapshot --diff

# -----------------------------------------------------------------------------
# Code formatting
# -----------------------------------------------------------------------------
format:
	@echo "=> formatting solidity files..."
	@forge fmt

# -----------------------------------------------------------------------------
# Build documentation and serve locally (auto-open browser)
# - If system does not have `open`, comment out that step (e.g., headless Linux)
# -----------------------------------------------------------------------------
docs:
	@echo "=> building docs..."
	@forge doc --build
	@echo "=> serving docs at http://localhost:4000"
	@forge doc --serve --port 4000
