#!/bin/bash

# 3Jane Morpho Blue - Main Deployment Script
# This script orchestrates the entire deployment process with error handling and resume capability

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
DEPLOYMENT_DIR="deployments"
PROGRESS_FILE=".deployment_progress"
NETWORK="${NETWORK:-sepolia}"
RPC_URL="${RPC_URL:-$SEPOLIA_RPC_URL}"

# Function to print colored output
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Function to check if a step is completed
is_step_complete() {
    if [ -f "$PROGRESS_FILE" ]; then
        grep -q "^$1=done$" "$PROGRESS_FILE" 2>/dev/null
        return $?
    fi
    return 1
}

# Function to mark a step as complete
mark_step_complete() {
    echo "$1=done" >> "$PROGRESS_FILE"
    print_success "Step $1 completed"
}

# Function to run forge script with optional verification
run_forge_script() {
    local script_path=$1
    local error_msg=$2
    
    if [ "$NETWORK" = "local" ]; then
        # For local, use private key if available, otherwise account
        if [ ! -z "$PRIVATE_KEY" ]; then
            forge script $script_path \
                --rpc-url $RPC_URL \
                --private-key $PRIVATE_KEY \
                --broadcast \
                -vvv || {
                print_error "$error_msg"
                exit 1
            }
        else
            forge script $script_path \
                --rpc-url $RPC_URL \
                --account $DEPLOYER_ACCOUNT \
                --broadcast \
                -vvv || {
                print_error "$error_msg"
                exit 1
            }
        fi
    else
        forge script $script_path \
            --rpc-url $RPC_URL \
            --account $DEPLOYER_ACCOUNT \
            --broadcast \
            --verify \
            --etherscan-api-key $ETHERSCAN_API_KEY \
            -vvv || {
            print_error "$error_msg"
            exit 1
        }
    fi
}

# Function to load deployed addresses
load_deployed_address() {
    local var_name=$1
    local json_key=$2
    local chain_id=$(cast chain-id --rpc-url $RPC_URL)
    local json_file="$DEPLOYMENT_DIR/$chain_id/latest.json"
    
    if [ -f "$json_file" ]; then
        local address=$(jq -r ".$json_key // empty" "$json_file" 2>/dev/null)
        if [ ! -z "$address" ] && [ "$address" != "null" ]; then
            export "$var_name=$address"
            print_info "Loaded $var_name: $address"
            return 0
        fi
    fi
    return 1
}

# Pre-flight checks
preflight_checks() {
    print_info "Running pre-flight checks..."
    
    # Check required tools
    command -v forge >/dev/null 2>&1 || { print_error "forge not found. Please install Foundry."; exit 1; }
    command -v cast >/dev/null 2>&1 || { print_error "cast not found. Please install Foundry."; exit 1; }
    command -v jq >/dev/null 2>&1 || { print_error "jq not found. Please install jq."; exit 1; }
    
    # Check environment variables
    if [ -z "$PRIVATE_KEY" ] && [ -z "$DEPLOYER_ACCOUNT" ]; then
        print_error "Neither PRIVATE_KEY nor DEPLOYER_ACCOUNT is set. Please set one of them."
        print_info "Use DEPLOYER_ACCOUNT with --account flag (recommended) or PRIVATE_KEY for direct key usage."
        exit 1
    fi
    
    if [ -z "$RPC_URL" ]; then
        print_error "RPC_URL not set. Please set your RPC URL."
        exit 1
    fi
    
    # Check network connection
    print_info "Checking network connection to $NETWORK..."
    CHAIN_ID=$(cast chain-id --rpc-url $RPC_URL 2>/dev/null) || {
        print_error "Failed to connect to $RPC_URL"
        exit 1
    }
    print_success "Connected to chain ID: $CHAIN_ID"
    
    # Check deployer balance
    DEPLOYER=$(cast wallet address $PRIVATE_KEY)
    print_info "Deployer address: $DEPLOYER"
    
    BALANCE=$(cast balance $DEPLOYER --rpc-url $RPC_URL)
    BALANCE_ETH=$(cast to-unit $BALANCE ether)
    print_info "Deployer balance: $BALANCE_ETH ETH"
    
    # Check minimum balance (0.5 ETH recommended)
    MIN_BALANCE="500000000000000000" # 0.5 ETH in wei
    if [ $(echo "$BALANCE < $MIN_BALANCE" | bc) -eq 1 ]; then
        print_warning "Low balance! Recommended minimum: 0.5 ETH"
        read -p "Continue anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    print_success "Pre-flight checks passed"
}

# Deploy TimelockController
deploy_timelock() {
    if is_step_complete "timelock"; then
        print_info "Timelock already deployed, loading address..."
        
        # Try to load from saved JSON first
        if load_deployed_address TIMELOCK_ADDRESS timelock; then
            return 0
        fi
        
        # If not in JSON, try to extract from broadcast file
        local chain_id=$(cast chain-id --rpc-url $RPC_URL)
        local broadcast_file="broadcast/00_DeployTimelock.s.sol/$chain_id/run-latest.json"
        
        if [ -f "$broadcast_file" ]; then
            TIMELOCK_ADDRESS=$(jq -r '.receipts[0].contractAddress' "$broadcast_file")
            export TIMELOCK_ADDRESS
            print_info "Loaded TIMELOCK_ADDRESS from broadcast: $TIMELOCK_ADDRESS"
        fi
        
        return 0
    fi
    
    print_info "Deploying TimelockController..."
    
    # Set required environment variables
    export MULTISIG_ADDRESS="${MULTISIG_ADDRESS:-$DEPLOYER}"
    export OWNER_ADDRESS="${OWNER_ADDRESS:-$DEPLOYER}"
    export TIMELOCK_DELAY="${TIMELOCK_DELAY:-300}"  # 5 minutes for testnet
    
    run_forge_script "script/deploy/00_DeployTimelock.s.sol" "Timelock deployment failed"
    
    # Extract and save deployed address
    local chain_id=$(cast chain-id --rpc-url $RPC_URL)
    local broadcast_file="broadcast/00_DeployTimelock.s.sol/$chain_id/run-latest.json"
    
    if [ -f "$broadcast_file" ]; then
        TIMELOCK_ADDRESS=$(jq -r '.receipts[0].contractAddress' "$broadcast_file")
        export TIMELOCK_ADDRESS
        
        # Save to deployment file
        mkdir -p "$DEPLOYMENT_DIR/$chain_id"
        echo "{\"timelock\": \"$TIMELOCK_ADDRESS\"}" | jq '.' > "$DEPLOYMENT_DIR/$chain_id/latest.json"
        
        print_success "TimelockController deployed at: $TIMELOCK_ADDRESS"
    fi
    
    mark_step_complete "timelock"
}

# Deploy ProtocolConfig
deploy_protocol_config() {
    if is_step_complete "protocol_config"; then
        print_info "ProtocolConfig already deployed, loading address..."
        
        # Try to load from saved JSON first
        if load_deployed_address PROTOCOL_CONFIG protocolConfig; then
            return 0
        fi
        
        # If not in JSON, try to extract from broadcast file
        local chain_id=$(cast chain-id --rpc-url $RPC_URL)
        local broadcast_file="broadcast/01_DeployProtocolConfig.s.sol/$chain_id/run-latest.json"
        
        if [ -f "$broadcast_file" ]; then
            PROTOCOL_CONFIG=$(jq -r '.returns.proxy.value' "$broadcast_file")
            export PROTOCOL_CONFIG
            print_info "Loaded PROTOCOL_CONFIG from broadcast: $PROTOCOL_CONFIG"
        fi
        
        return 0
    fi
    
    print_info "Deploying ProtocolConfig..."
    
    # Ensure timelock address is set
    if [ -z "$TIMELOCK_ADDRESS" ]; then
        load_deployed_address TIMELOCK_ADDRESS timelock || {
            print_error "TIMELOCK_ADDRESS not found"
            exit 1
        }
    fi
    
    run_forge_script "script/deploy/01_DeployProtocolConfig.s.sol" "ProtocolConfig deployment failed"
    
    # Extract and save deployed addresses
    local chain_id=$(cast chain-id --rpc-url $RPC_URL)
    local broadcast_file="broadcast/01_DeployProtocolConfig.s.sol/$chain_id/run-latest.json"
    
    if [ -f "$broadcast_file" ]; then
        PROTOCOL_CONFIG=$(jq -r '.returns.proxy.value' "$broadcast_file")
        PROTOCOL_CONFIG_IMPL=$(jq -r '.returns.implementation.value' "$broadcast_file")
        
        # Export for use in subsequent deployments
        export PROTOCOL_CONFIG
        export PROTOCOL_CONFIG_IMPL
        
        # Save to deployment file
        mkdir -p "$DEPLOYMENT_DIR/$chain_id"
        if [ -f "$DEPLOYMENT_DIR/$chain_id/latest.json" ]; then
            jq --arg pc "$PROTOCOL_CONFIG" --arg pci "$PROTOCOL_CONFIG_IMPL" \
               '. + {protocolConfig: $pc, protocolConfigImpl: $pci}' \
               "$DEPLOYMENT_DIR/$chain_id/latest.json" > "$DEPLOYMENT_DIR/$chain_id/latest.json.tmp" && \
            mv "$DEPLOYMENT_DIR/$chain_id/latest.json.tmp" "$DEPLOYMENT_DIR/$chain_id/latest.json"
        else
            echo "{\"protocolConfig\": \"$PROTOCOL_CONFIG\", \"protocolConfigImpl\": \"$PROTOCOL_CONFIG_IMPL\"}" | \
            jq '.' > "$DEPLOYMENT_DIR/$chain_id/latest.json"
        fi
        
        print_success "ProtocolConfig deployed at: $PROTOCOL_CONFIG"
    fi
    
    mark_step_complete "protocol_config"
}

# Deploy MorphoCredit
deploy_morpho_credit() {
    if is_step_complete "morpho_credit"; then
        print_info "MorphoCredit already deployed, loading address..."
        
        # Try to load from saved JSON first
        if load_deployed_address MORPHO_ADDRESS morphoCredit; then
            return 0
        fi
        
        # If not in JSON, try to extract from broadcast file
        local chain_id=$(cast chain-id --rpc-url $RPC_URL)
        local broadcast_file="broadcast/02_DeployMorphoCredit.s.sol/$chain_id/run-latest.json"
        
        if [ -f "$broadcast_file" ]; then
            MORPHO_ADDRESS=$(jq -r '.returns.proxy.value' "$broadcast_file")
            export MORPHO_ADDRESS
            print_info "Loaded MORPHO_ADDRESS from broadcast: $MORPHO_ADDRESS"
        fi
        
        return 0
    fi
    
    print_info "Deploying MorphoCredit..."
    
    # Ensure dependencies are set
    if [ -z "$PROTOCOL_CONFIG" ]; then
        load_deployed_address PROTOCOL_CONFIG protocolConfig || {
            print_error "PROTOCOL_CONFIG not found"
            exit 1
        }
    fi
    
    run_forge_script "script/deploy/02_DeployMorphoCredit.s.sol" "MorphoCredit deployment failed"
    
    # Extract and save deployed addresses
    local chain_id=$(cast chain-id --rpc-url $RPC_URL)
    local broadcast_file="broadcast/02_DeployMorphoCredit.s.sol/$chain_id/run-latest.json"
    
    if [ -f "$broadcast_file" ]; then
        MORPHO_ADDRESS=$(jq -r '.returns.proxy.value' "$broadcast_file")
        MORPHO_IMPL=$(jq -r '.returns.implementation.value' "$broadcast_file")
        
        # Export for use in subsequent deployments
        export MORPHO_ADDRESS
        export MORPHO_IMPL
        
        # Save to deployment file
        mkdir -p "$DEPLOYMENT_DIR/$chain_id"
        if [ -f "$DEPLOYMENT_DIR/$chain_id/latest.json" ]; then
            jq --arg ma "$MORPHO_ADDRESS" --arg mi "$MORPHO_IMPL" \
               '. + {morphoCredit: $ma, morphoCreditImpl: $mi}' \
               "$DEPLOYMENT_DIR/$chain_id/latest.json" > "$DEPLOYMENT_DIR/$chain_id/latest.json.tmp" && \
            mv "$DEPLOYMENT_DIR/$chain_id/latest.json.tmp" "$DEPLOYMENT_DIR/$chain_id/latest.json"
        else
            echo "{\"morphoCredit\": \"$MORPHO_ADDRESS\", \"morphoCreditImpl\": \"$MORPHO_IMPL\"}" | \
            jq '.' > "$DEPLOYMENT_DIR/$chain_id/latest.json"
        fi
        
        print_success "MorphoCredit deployed at: $MORPHO_ADDRESS"
    fi
    
    mark_step_complete "morpho_credit"
}

# Deploy MarkdownManager
deploy_markdown_manager() {
    if is_step_complete "markdown_manager"; then
        print_info "MarkdownManager already deployed, loading address..."
        
        # Try to load from saved JSON first
        if load_deployed_address MARKDOWN_MANAGER_ADDRESS markdownManager; then
            return 0
        fi
        
        # If not in JSON, try to extract from broadcast file
        local chain_id=$(cast chain-id --rpc-url $RPC_URL)
        local broadcast_file="broadcast/07_DeployMarkdownManager.s.sol/$chain_id/run-latest.json"
        
        if [ -f "$broadcast_file" ]; then
            MARKDOWN_MANAGER_ADDRESS=$(jq -r '.receipts[0].contractAddress' "$broadcast_file")
            export MARKDOWN_MANAGER_ADDRESS
            print_info "Loaded MARKDOWN_MANAGER_ADDRESS from broadcast: $MARKDOWN_MANAGER_ADDRESS"
        fi
        
        return 0
    fi
    
    print_info "Deploying MarkdownManager..."
    
    run_forge_script "script/deploy/07_DeployMarkdownManager.s.sol" "MarkdownManager deployment failed"
    
    # Extract and save deployed address
    local chain_id=$(cast chain-id --rpc-url $RPC_URL)
    local broadcast_file="broadcast/07_DeployMarkdownManager.s.sol/$chain_id/run-latest.json"
    
    if [ -f "$broadcast_file" ]; then
        MARKDOWN_MANAGER_ADDRESS=$(jq -r '.receipts[0].contractAddress' "$broadcast_file")
        export MARKDOWN_MANAGER_ADDRESS
        
        # Save to deployment file
        if [ -f "$DEPLOYMENT_DIR/$chain_id/latest.json" ]; then
            jq --arg mm "$MARKDOWN_MANAGER_ADDRESS" \
               '. + {markdownManager: $mm}' \
               "$DEPLOYMENT_DIR/$chain_id/latest.json" > "$DEPLOYMENT_DIR/$chain_id/latest.json.tmp" && \
            mv "$DEPLOYMENT_DIR/$chain_id/latest.json.tmp" "$DEPLOYMENT_DIR/$chain_id/latest.json"
        else
            echo "{\"markdownManager\": \"$MARKDOWN_MANAGER_ADDRESS\"}" | jq '.' > "$DEPLOYMENT_DIR/$chain_id/latest.json"
        fi
        
        print_success "MarkdownManager deployed at: $MARKDOWN_MANAGER_ADDRESS"
    fi
    
    mark_step_complete "markdown_manager"
}

# Deploy CreditLine
deploy_credit_line() {
    if is_step_complete "credit_line"; then
        print_info "CreditLine already deployed, loading address..."
        load_deployed_address CREDIT_LINE_ADDRESS creditLine
        return 0
    fi
    
    print_info "Deploying CreditLine..."
    
    # Ensure dependencies are set
    if [ -z "$MORPHO_ADDRESS" ]; then
        load_deployed_address MORPHO_ADDRESS morphoCredit || {
            print_error "MORPHO_ADDRESS not found"
            exit 1
        }
    fi
    
    if [ -z "$MARKDOWN_MANAGER_ADDRESS" ]; then
        load_deployed_address MARKDOWN_MANAGER_ADDRESS markdownManager || {
            print_error "MARKDOWN_MANAGER_ADDRESS not found"
            exit 1
        }
    fi
    
    # Set OZD address (use deployer for testnet if not set)
    export OZD_ADDRESS="${OZD_ADDRESS:-$DEPLOYER}"
    
    run_forge_script "script/deploy/05_DeployCreditLine.s.sol" "CreditLine deployment failed"
    
    # Extract and save deployed address
    local chain_id=$(cast chain-id --rpc-url $RPC_URL)
    local broadcast_file="broadcast/05_DeployCreditLine.s.sol/$chain_id/run-latest.json"
    
    if [ -f "$broadcast_file" ]; then
        CREDIT_LINE_ADDRESS=$(jq -r '.receipts[0].contractAddress' "$broadcast_file")
        export CREDIT_LINE_ADDRESS
        
        # Save to deployment file
        mkdir -p "$DEPLOYMENT_DIR/$chain_id"
        if [ -f "$DEPLOYMENT_DIR/$chain_id/latest.json" ]; then
            jq --arg cl "$CREDIT_LINE_ADDRESS" \
               '. + {creditLine: $cl}' \
               "$DEPLOYMENT_DIR/$chain_id/latest.json" > "$DEPLOYMENT_DIR/$chain_id/latest.json.tmp" && \
            mv "$DEPLOYMENT_DIR/$chain_id/latest.json.tmp" "$DEPLOYMENT_DIR/$chain_id/latest.json"
        else
            echo "{\"creditLine\": \"$CREDIT_LINE_ADDRESS\"}" | jq '.' > "$DEPLOYMENT_DIR/$chain_id/latest.json"
        fi
        
        print_success "CreditLine deployed at: $CREDIT_LINE_ADDRESS"
    fi
    
    mark_step_complete "credit_line"
}

# Deploy InsuranceFund
deploy_insurance_fund() {
    if is_step_complete "insurance_fund"; then
        print_info "InsuranceFund already deployed, loading address..."
        load_deployed_address INSURANCE_FUND_ADDRESS insuranceFund
        return 0
    fi
    
    print_info "Deploying InsuranceFund..."
    
    # Ensure CreditLine is deployed
    if [ -z "$CREDIT_LINE_ADDRESS" ]; then
        load_deployed_address CREDIT_LINE_ADDRESS creditLine || {
            print_error "CREDIT_LINE_ADDRESS not found"
            exit 1
        }
    fi
    
    run_forge_script "script/deploy/06_DeployInsuranceFund.s.sol" "InsuranceFund deployment failed"
    
    # Extract and save deployed address
    local chain_id=$(cast chain-id --rpc-url $RPC_URL)
    local broadcast_file="broadcast/06_DeployInsuranceFund.s.sol/$chain_id/run-latest.json"
    
    if [ -f "$broadcast_file" ]; then
        INSURANCE_FUND_ADDRESS=$(jq -r '.receipts[0].contractAddress' "$broadcast_file")
        export INSURANCE_FUND_ADDRESS
        
        # Save to deployment file
        mkdir -p "$DEPLOYMENT_DIR/$chain_id"
        if [ -f "$DEPLOYMENT_DIR/$chain_id/latest.json" ]; then
            jq --arg insf "$INSURANCE_FUND_ADDRESS" \
               '. + {insuranceFund: $insf}' \
               "$DEPLOYMENT_DIR/$chain_id/latest.json" > "$DEPLOYMENT_DIR/$chain_id/latest.json.tmp" && \
            mv "$DEPLOYMENT_DIR/$chain_id/latest.json.tmp" "$DEPLOYMENT_DIR/$chain_id/latest.json"
        else
            echo "{\"insuranceFund\": \"$INSURANCE_FUND_ADDRESS\"}" | jq '.' > "$DEPLOYMENT_DIR/$chain_id/latest.json"
        fi
        
        print_success "InsuranceFund deployed at: $INSURANCE_FUND_ADDRESS"
    fi
    
    mark_step_complete "insurance_fund"
}

# Deploy AdaptiveCurveIrm
deploy_adaptive_curve_irm() {
    if is_step_complete "adaptive_curve_irm"; then
        print_info "AdaptiveCurveIrm already deployed, loading address..."
        load_deployed_address ADAPTIVE_CURVE_IRM_ADDRESS adaptiveCurveIrm
        return 0
    fi
    
    print_info "Deploying AdaptiveCurveIrm..."
    
    # Ensure MorphoCredit is deployed
    if [ -z "$MORPHO_ADDRESS" ]; then
        load_deployed_address MORPHO_ADDRESS morphoCredit || {
            print_error "MORPHO_ADDRESS not found"
            exit 1
        }
    fi
    
    run_forge_script "script/deploy/03_DeployAdaptiveCurveIrm.s.sol" "AdaptiveCurveIrm deployment failed"
    
    # Extract and save deployed address
    local chain_id=$(cast chain-id --rpc-url $RPC_URL)
    local broadcast_file="broadcast/03_DeployAdaptiveCurveIrm.s.sol/$chain_id/run-latest.json"
    
    if [ -f "$broadcast_file" ]; then
        ADAPTIVE_CURVE_IRM_ADDRESS=$(jq -r '.receipts[0].contractAddress' "$broadcast_file")
        export ADAPTIVE_CURVE_IRM_ADDRESS
        
        # Save to deployment file
        mkdir -p "$DEPLOYMENT_DIR/$chain_id"
        if [ -f "$DEPLOYMENT_DIR/$chain_id/latest.json" ]; then
            jq --arg aci "$ADAPTIVE_CURVE_IRM_ADDRESS" \
               '. + {adaptiveCurveIrm: $aci}' \
               "$DEPLOYMENT_DIR/$chain_id/latest.json" > "$DEPLOYMENT_DIR/$chain_id/latest.json.tmp" && \
            mv "$DEPLOYMENT_DIR/$chain_id/latest.json.tmp" "$DEPLOYMENT_DIR/$chain_id/latest.json"
        else
            echo "{\"adaptiveCurveIrm\": \"$ADAPTIVE_CURVE_IRM_ADDRESS\"}" | jq '.' > "$DEPLOYMENT_DIR/$chain_id/latest.json"
        fi
        
        print_success "AdaptiveCurveIrm deployed at: $ADAPTIVE_CURVE_IRM_ADDRESS"
    fi
    
    mark_step_complete "adaptive_curve_irm"
}

# Deploy Helper
deploy_helper() {
    if is_step_complete "helper"; then
        print_info "Helper already deployed, loading address..."
        load_deployed_address HELPER_ADDRESS helper
        return 0
    fi
    
    print_info "Deploying Helper..."
    
    # Check token addresses
    if [ -z "$USD3_ADDRESS" ] || [ -z "$SUSD3_ADDRESS" ] || [ -z "$USDC_ADDRESS" ] || [ -z "$WAUSDC_ADDRESS" ]; then
        print_warning "Token addresses not set. Please deploy tokens first using ./deploy-tokens.sh"
        print_info "Skipping Helper deployment for now..."
        return 1
    fi
    
    run_forge_script "script/deploy/04_DeployHelper.s.sol" "Helper deployment failed"
    
    # Extract and save deployed address
    local chain_id=$(cast chain-id --rpc-url $RPC_URL)
    local broadcast_file="broadcast/04_DeployHelper.s.sol/$chain_id/run-latest.json"
    
    if [ -f "$broadcast_file" ]; then
        HELPER_ADDRESS=$(jq -r '.receipts[0].contractAddress' "$broadcast_file")
        export HELPER_ADDRESS
        
        # Save to deployment file
        mkdir -p "$DEPLOYMENT_DIR/$chain_id"
        if [ -f "$DEPLOYMENT_DIR/$chain_id/latest.json" ]; then
            jq --arg h "$HELPER_ADDRESS" \
               '. + {helper: $h}' \
               "$DEPLOYMENT_DIR/$chain_id/latest.json" > "$DEPLOYMENT_DIR/$chain_id/latest.json.tmp" && \
            mv "$DEPLOYMENT_DIR/$chain_id/latest.json.tmp" "$DEPLOYMENT_DIR/$chain_id/latest.json"
        else
            echo "{\"helper\": \"$HELPER_ADDRESS\"}" | jq '.' > "$DEPLOYMENT_DIR/$chain_id/latest.json"
        fi
        
        print_success "Helper deployed at: $HELPER_ADDRESS"
    fi
    
    mark_step_complete "helper"
}

# Post-deployment configuration
post_deployment_config() {
    print_info "Running post-deployment configuration..."
    
    # Set InsuranceFund in CreditLine
    if [ ! -z "$CREDIT_LINE_ADDRESS" ] && [ ! -z "$INSURANCE_FUND_ADDRESS" ]; then
        print_info "Setting InsuranceFund in CreditLine..."
        cast send $CREDIT_LINE_ADDRESS \
            "setInsuranceFund(address)" \
            $INSURANCE_FUND_ADDRESS \
            --private-key $PRIVATE_KEY \
            --rpc-url $RPC_URL || print_warning "Failed to set InsuranceFund"
    fi
    
    print_success "Post-deployment configuration completed"
}

# Main deployment flow
main() {
    print_info "Starting 3Jane Morpho Blue deployment to $NETWORK"
    print_info "================================================"
    
    # Check if resuming
    if [ -f "$PROGRESS_FILE" ]; then
        print_warning "Found existing deployment progress. Resuming..."
    else
        print_info "Starting fresh deployment"
    fi
    
    # Run pre-flight checks
    preflight_checks
    
    # Deploy core protocol contracts
    deploy_timelock
    deploy_protocol_config
    deploy_morpho_credit
    deploy_markdown_manager
    deploy_credit_line
    deploy_insurance_fund
    deploy_adaptive_curve_irm
    
    # Deploy Helper (may skip if tokens not ready)
    deploy_helper
    
    # Run post-deployment configuration
    post_deployment_config
    
    print_success "================================================"
    print_success "Deployment completed successfully!"
    print_info "Deployment addresses saved to: $DEPLOYMENT_DIR/$CHAIN_ID/latest.json"
    
    # Clean up progress file on success
    rm -f "$PROGRESS_FILE"
}

# Handle script arguments
case "${1:-}" in
    --reset)
        print_warning "Resetting deployment progress..."
        rm -f "$PROGRESS_FILE"
        print_success "Progress reset. Run script again to start fresh."
        exit 0
        ;;
    --help)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --reset    Reset deployment progress and start fresh"
        echo "  --help     Show this help message"
        echo ""
        echo "Environment variables:"
        echo "  NETWORK              Target network (default: sepolia)"
        echo "  RPC_URL              RPC endpoint URL"
        echo "  PRIVATE_KEY          Deployer private key"
        echo "  ETHERSCAN_API_KEY    Etherscan API key for verification"
        echo "  MULTISIG_ADDRESS     Multisig wallet address"
        echo "  OWNER_ADDRESS        Protocol owner address"
        exit 0
        ;;
esac

# Run main deployment
main