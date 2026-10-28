#!/bin/bash

# 3Jane Morpho Blue - Contract Verification Script
# Verifies all deployed contracts on Etherscan

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NETWORK="${NETWORK:-sepolia}"
RPC_URL="${RPC_URL:-$SEPOLIA_RPC_URL}"
DEPLOYMENT_DIR="deployments"

# Function to print colored output
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites..."
    
    if [ -z "$ETHERSCAN_API_KEY" ]; then
        print_error "ETHERSCAN_API_KEY not set"
        exit 1
    fi
    
    if [ -z "$RPC_URL" ]; then
        print_error "RPC_URL not set"
        exit 1
    fi
    
    # Get chain ID
    CHAIN_ID=$(cast chain-id --rpc-url $RPC_URL)
    print_info "Chain ID: $CHAIN_ID"
    
    # Check deployment file exists
    DEPLOYMENT_FILE="$DEPLOYMENT_DIR/$CHAIN_ID/latest.json"
    if [ ! -f "$DEPLOYMENT_FILE" ]; then
        print_error "Deployment file not found: $DEPLOYMENT_FILE"
        print_error "Please deploy contracts first using ./deploy.sh"
        exit 1
    fi
    
    print_success "Prerequisites check passed"
}

# Verify a single contract
verify_contract() {
    local name=$1
    local address=$2
    local contract_path=$3
    local constructor_args=$4
    
    print_info "Verifying $name at $address..."
    
    # Skip if already verified
    IS_VERIFIED=$(cast etherscan-source $address --chain-id $CHAIN_ID 2>/dev/null | grep -c "Contract source code verified" || true)
    if [ "$IS_VERIFIED" -gt 0 ]; then
        print_success "$name already verified"
        return 0
    fi
    
    # Build verification command
    VERIFY_CMD="forge verify-contract $address $contract_path"
    VERIFY_CMD="$VERIFY_CMD --chain-id $CHAIN_ID"
    VERIFY_CMD="$VERIFY_CMD --num-of-optimizations 999999"
    VERIFY_CMD="$VERIFY_CMD --compiler-version 0.8.22"
    VERIFY_CMD="$VERIFY_CMD --etherscan-api-key $ETHERSCAN_API_KEY"
    
    # Add constructor args if provided
    if [ ! -z "$constructor_args" ]; then
        VERIFY_CMD="$VERIFY_CMD --constructor-args $constructor_args"
    fi
    
    # Add watch flag to wait for verification
    VERIFY_CMD="$VERIFY_CMD --watch"
    
    # Execute verification
    eval $VERIFY_CMD || {
        print_warning "Failed to verify $name"
        return 1
    }
    
    print_success "$name verified successfully"
}

# Load deployment addresses
load_addresses() {
    print_info "Loading deployment addresses..."
    
    CHAIN_ID=$(cast chain-id --rpc-url $RPC_URL)
    DEPLOYMENT_FILE="$DEPLOYMENT_DIR/$CHAIN_ID/latest.json"
    
    # Load addresses from JSON
    TIMELOCK=$(jq -r '.timelock // empty' "$DEPLOYMENT_FILE")
    PROTOCOL_CONFIG=$(jq -r '.protocolConfig // empty' "$DEPLOYMENT_FILE")
    PROTOCOL_CONFIG_IMPL=$(jq -r '.protocolConfigImpl // empty' "$DEPLOYMENT_FILE")
    MORPHO_CREDIT=$(jq -r '.morphoCredit // empty' "$DEPLOYMENT_FILE")
    MORPHO_CREDIT_IMPL=$(jq -r '.morphoCreditImpl // empty' "$DEPLOYMENT_FILE")
    ADAPTIVE_CURVE_IRM=$(jq -r '.adaptiveCurveIrm // empty' "$DEPLOYMENT_FILE")
    ADAPTIVE_CURVE_IRM_IMPL=$(jq -r '.adaptiveCurveIrmImpl // empty' "$DEPLOYMENT_FILE")
    HELPER=$(jq -r '.helper // empty' "$DEPLOYMENT_FILE")
    CREDIT_LINE=$(jq -r '.creditLine // empty' "$DEPLOYMENT_FILE")
    INSURANCE_FUND=$(jq -r '.insuranceFund // empty' "$DEPLOYMENT_FILE")
    MARKDOWN_MANAGER=$(jq -r '.markdownManager // empty' "$DEPLOYMENT_FILE")
    
    print_success "Addresses loaded"
}

# Verify TimelockController
verify_timelock() {
    if [ ! -z "$TIMELOCK" ] && [ "$TIMELOCK" != "null" ]; then
        # Get constructor args from deployment
        MULTISIG="${MULTISIG_ADDRESS:-$DEPLOYER}"
        MIN_DELAY="${TIMELOCK_DELAY:-300}"
        
        # Encode constructor args: minDelay, proposers[], executors[], admin
        CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(uint256,address[],address[],address)" \
            "$MIN_DELAY" \
            "[$MULTISIG]" \
            "[0x0000000000000000000000000000000000000000]" \
            "$MULTISIG")
        
        verify_contract "TimelockController" "$TIMELOCK" \
            "@openzeppelin/contracts/governance/TimelockController.sol:TimelockController" \
            "$CONSTRUCTOR_ARGS"
    fi
}

# Verify ProtocolConfig
verify_protocol_config() {
    if [ ! -z "$PROTOCOL_CONFIG_IMPL" ] && [ "$PROTOCOL_CONFIG_IMPL" != "null" ]; then
        verify_contract "ProtocolConfig Implementation" "$PROTOCOL_CONFIG_IMPL" \
            "src/ProtocolConfig.sol:ProtocolConfig" ""
    fi
}

# Verify MorphoCredit
verify_morpho_credit() {
    if [ ! -z "$MORPHO_CREDIT_IMPL" ] && [ "$MORPHO_CREDIT_IMPL" != "null" ]; then
        # MorphoCredit constructor takes protocolConfig address
        CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address)" "$PROTOCOL_CONFIG")
        
        verify_contract "MorphoCredit Implementation" "$MORPHO_CREDIT_IMPL" \
            "src/MorphoCredit.sol:MorphoCredit" \
            "$CONSTRUCTOR_ARGS"
    fi
}

# Verify AdaptiveCurveIrm
verify_adaptive_curve_irm() {
    if [ ! -z "$ADAPTIVE_CURVE_IRM_IMPL" ] && [ "$ADAPTIVE_CURVE_IRM_IMPL" != "null" ]; then
        # AdaptiveCurveIrm constructor takes morpho address
        CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address)" "$MORPHO_CREDIT")
        
        verify_contract "AdaptiveCurveIrm Implementation" "$ADAPTIVE_CURVE_IRM_IMPL" \
            "src/irm/adaptive-curve-irm/AdaptiveCurveIrm.sol:AdaptiveCurveIrm" \
            "$CONSTRUCTOR_ARGS"
    fi
}

# Verify Helper
verify_helper() {
    if [ ! -z "$HELPER" ] && [ "$HELPER" != "null" ]; then
        # Helper constructor takes: morpho, usd3, susd3, usdc, wausdc
        # Load token addresses from environment
        USD3="${USD3_ADDRESS:-0x0000000000000000000000000000000000000000}"
        SUSD3="${SUSD3_ADDRESS:-0x0000000000000000000000000000000000000000}"
        USDC="${USDC_ADDRESS:-0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8}"
        WAUSDC="${WAUSDC_ADDRESS:-0x0000000000000000000000000000000000000000}"
        
        CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address,address,address,address)" \
            "$MORPHO_CREDIT" "$USD3" "$SUSD3" "$USDC" "$WAUSDC")
        
        verify_contract "Helper" "$HELPER" \
            "src/Helper.sol:Helper" \
            "$CONSTRUCTOR_ARGS"
    fi
}

# Verify CreditLine
verify_credit_line() {
    if [ ! -z "$CREDIT_LINE" ] && [ "$CREDIT_LINE" != "null" ]; then
        # CreditLine constructor takes: morpho, owner, ozd, mm, prover
        OWNER="${OWNER_ADDRESS:-$DEPLOYER}"
        OZD="${OZD_ADDRESS:-$DEPLOYER}"
        PROVER="${PROVER_ADDRESS:-0x0000000000000000000000000000000000000000}"
        
        CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address,address,address,address)" \
            "$MORPHO_CREDIT" "$OWNER" "$OZD" "$MARKDOWN_MANAGER" "$PROVER")
        
        verify_contract "CreditLine" "$CREDIT_LINE" \
            "src/CreditLine.sol:CreditLine" \
            "$CONSTRUCTOR_ARGS"
    fi
}

# Verify InsuranceFund
verify_insurance_fund() {
    if [ ! -z "$INSURANCE_FUND" ] && [ "$INSURANCE_FUND" != "null" ]; then
        # InsuranceFund constructor takes creditLine address
        CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address)" "$CREDIT_LINE")
        
        verify_contract "InsuranceFund" "$INSURANCE_FUND" \
            "src/InsuranceFund.sol:InsuranceFund" \
            "$CONSTRUCTOR_ARGS"
    fi
}

# Verify MarkdownManager
verify_markdown_manager() {
    if [ ! -z "$MARKDOWN_MANAGER" ] && [ "$MARKDOWN_MANAGER" != "null" ]; then
        # MarkdownManager has no constructor args
        verify_contract "MarkdownManager" "$MARKDOWN_MANAGER" \
            "src/MarkdownManager.sol:MarkdownManager" ""
    fi
}

# Main verification flow
main() {
    print_info "Starting contract verification on $NETWORK"
    print_info "================================================"
    
    check_prerequisites
    load_addresses
    
    # Track verification results
    FAILED_VERIFICATIONS=()
    
    # Verify each contract
    verify_timelock || FAILED_VERIFICATIONS+=("TimelockController")
    verify_protocol_config || FAILED_VERIFICATIONS+=("ProtocolConfig")
    verify_morpho_credit || FAILED_VERIFICATIONS+=("MorphoCredit")
    verify_adaptive_curve_irm || FAILED_VERIFICATIONS+=("AdaptiveCurveIrm")
    verify_markdown_manager || FAILED_VERIFICATIONS+=("MarkdownManager")
    verify_credit_line || FAILED_VERIFICATIONS+=("CreditLine")
    verify_insurance_fund || FAILED_VERIFICATIONS+=("InsuranceFund")
    verify_helper || FAILED_VERIFICATIONS+=("Helper")
    
    print_info "================================================"
    
    if [ ${#FAILED_VERIFICATIONS[@]} -eq 0 ]; then
        print_success "All contracts verified successfully!"
    else
        print_warning "Some contracts failed verification:"
        for contract in "${FAILED_VERIFICATIONS[@]}"; do
            print_warning "  - $contract"
        done
        print_info "You can retry verification for failed contracts manually"
    fi
    
    # Print Etherscan links
    print_info ""
    print_info "View contracts on Etherscan:"
    BASE_URL="https://sepolia.etherscan.io/address"
    if [ "$CHAIN_ID" = "1" ]; then
        BASE_URL="https://etherscan.io/address"
    fi
    
    [ ! -z "$TIMELOCK" ] && print_info "  Timelock: $BASE_URL/$TIMELOCK"
    [ ! -z "$PROTOCOL_CONFIG" ] && print_info "  ProtocolConfig: $BASE_URL/$PROTOCOL_CONFIG"
    [ ! -z "$MORPHO_CREDIT" ] && print_info "  MorphoCredit: $BASE_URL/$MORPHO_CREDIT"
    [ ! -z "$ADAPTIVE_CURVE_IRM" ] && print_info "  AdaptiveCurveIrm: $BASE_URL/$ADAPTIVE_CURVE_IRM"
    [ ! -z "$HELPER" ] && print_info "  Helper: $BASE_URL/$HELPER"
    [ ! -z "$CREDIT_LINE" ] && print_info "  CreditLine: $BASE_URL/$CREDIT_LINE"
    [ ! -z "$INSURANCE_FUND" ] && print_info "  InsuranceFund: $BASE_URL/$INSURANCE_FUND"
    [ ! -z "$MARKDOWN_MANAGER" ] && print_info "  MarkdownManager: $BASE_URL/$MARKDOWN_MANAGER"
}

# Handle script arguments
case "${1:-}" in
    --help)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Verifies all deployed contracts on Etherscan"
        echo ""
        echo "Options:"
        echo "  --help     Show this help message"
        echo ""
        echo "Environment variables:"
        echo "  NETWORK              Target network (default: sepolia)"
        echo "  RPC_URL              RPC endpoint URL"
        echo "  ETHERSCAN_API_KEY    Etherscan API key for verification"
        exit 0
        ;;
esac

# Run main verification
main