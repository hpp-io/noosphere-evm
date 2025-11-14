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
.PHONY: all install clean build test format docs snapshot diff deploy

# -----------------------------------------------------------------------------
# Default target: run dependency install -> clean -> format -> build -> test
# -----------------------------------------------------------------------------
all: install clean format build test

# -----------------------------------------------------------------------------
# Install dependencies
# - Fetch forge dependencies (libraries, etc.)
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
