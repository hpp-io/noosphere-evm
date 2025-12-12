#!/bin/bash

###############################################################################
# Noosphere Settlement Tracker Runner
#
# Usage:
#   ./run-settlement.sh                    # Run with default config
#   ./run-settlement.sh --help             # Show help
#
# Description:
#   This script runs the settlement tracker to analyze client/agent fees
#   from Router and Coordinator contract events on the testnet.
###############################################################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Help message
show_help() {
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     Noosphere Settlement Tracker Runner v1.0         ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --help              Show this help message"
    echo "  --env FILE          Use custom env file (default: .env-settlement.testnet)"
    echo "  --check-deps        Check if required dependencies are installed"
    echo ""
    echo "Description:"
    echo "  Tracks settlement data from Router and Coordinator contracts"
    echo "  Exports client and agent fee information to CSV format"
    echo ""
    echo "Configuration:"
    echo "  Edit .env-settlement.testnet to configure:"
    echo "    - RPC_URL: Testnet RPC endpoint"
    echo "    - ROUTER_ADDRESS: Router contract address"
    echo "    - COORDINATOR_ADDRESS: Coordinator contract address"
    echo "    - START_BLOCK: Start block for event scanning (optional)"
    echo "    - END_BLOCK: End block for event scanning (optional)"
    echo "    - OUTPUT_CSV: Output CSV filename"
    echo ""
    exit 0
}

# Check dependencies
check_dependencies() {
    echo -e "${YELLOW}Checking dependencies...${NC}"

    # Check Node.js
    if ! command -v node &> /dev/null; then
        echo -e "${RED}❌ Node.js is not installed${NC}"
        echo -e "   Please install Node.js from https://nodejs.org/"
        exit 1
    fi
    NODE_VERSION=$(node --version)
    echo -e "${GREEN}✅ Node.js: $NODE_VERSION${NC}"

    # Check npm
    if ! command -v npm &> /dev/null; then
        echo -e "${RED}❌ npm is not installed${NC}"
        exit 1
    fi
    NPM_VERSION=$(npm --version)
    echo -e "${GREEN}✅ npm: $NPM_VERSION${NC}"

    # Check required Node.js packages
    REQUIRED_PACKAGES=("ethers" "dotenv")
    MISSING_PACKAGES=()

    for package in "${REQUIRED_PACKAGES[@]}"; do
        if ! node -e "require('$package')" 2>/dev/null; then
            MISSING_PACKAGES+=("$package")
        fi
    done

    if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
        echo -e "${YELLOW}⚠️  Missing packages: ${MISSING_PACKAGES[*]}${NC}"
        echo -e "${YELLOW}   Installing missing packages...${NC}"

        cd "$SCRIPT_DIR/../../.." || exit 1

        for package in "${MISSING_PACKAGES[@]}"; do
            npm install "$package"
        done

        echo -e "${GREEN}✅ All dependencies installed${NC}"
    else
        echo -e "${GREEN}✅ All required packages are installed${NC}"
    fi

    echo ""
}

# Parse arguments
ENV_FILE=".env-settlement.testnet"
CHECK_DEPS_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --help)
            show_help
            ;;
        --env)
            ENV_FILE="$2"
            shift 2
            ;;
        --check-deps)
            CHECK_DEPS_ONLY=true
            shift
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Check dependencies
check_dependencies

if [ "$CHECK_DEPS_ONLY" = true ]; then
    exit 0
fi

# Verify env file exists
ENV_PATH="$SCRIPT_DIR/$ENV_FILE"
if [ ! -f "$ENV_PATH" ]; then
    echo -e "${RED}❌ Environment file not found: $ENV_PATH${NC}"
    echo -e "${YELLOW}   Please create the file and configure it with:${NC}"
    echo -e "   - RPC_URL"
    echo -e "   - ROUTER_ADDRESS"
    echo -e "   - COORDINATOR_ADDRESS"
    exit 1
fi

echo -e "${GREEN}✅ Using environment file: $ENV_FILE${NC}\n"

# Run the settlement tracker
cd "$SCRIPT_DIR" || exit 1

echo -e "${BLUE}Starting settlement tracker...${NC}\n"
node settlement-tracker.js

# Check if CSV files were generated
CSV_FILE=$(grep "^OUTPUT_CSV=" "$ENV_PATH" | cut -d'=' -f2)
CSV_FILE=${CSV_FILE:-"settlement-report.csv"}
SETTLEMENT_PATH="$SCRIPT_DIR/$CSV_FILE"
SUBSCRIPTION_PATH="$SCRIPT_DIR/subscription-status.csv"

if [ -f "$SETTLEMENT_PATH" ] && [ -f "$SUBSCRIPTION_PATH" ]; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✅ Reports generated successfully!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${BLUE}📊 Settlement Report:${NC} $SETTLEMENT_PATH"
    echo -e "${BLUE}   📏 Size:${NC} $(du -h "$SETTLEMENT_PATH" | cut -f1)"
    echo -e "${BLUE}   📝 Lines:${NC} $(wc -l < "$SETTLEMENT_PATH")"
    echo ""
    echo -e "${BLUE}📊 Subscription Status:${NC} $SUBSCRIPTION_PATH"
    echo -e "${BLUE}   📏 Size:${NC} $(du -h "$SUBSCRIPTION_PATH" | cut -f1)"
    echo -e "${BLUE}   📝 Lines:${NC} $(wc -l < "$SUBSCRIPTION_PATH")"
    echo ""
    echo -e "${YELLOW}💡 Tip: Open the CSV files in Excel, Google Sheets, or any CSV viewer${NC}"
    echo ""
else
    echo -e "${RED}❌ CSV files not generated${NC}"
    exit 1
fi
