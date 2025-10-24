#!/bin/bash

# 3Jane Morpho Blue - Token Deployment Script
# Deploys USD3 ecosystem tokens that mirror mainnet architecture using Aave

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

# Function to print colored output
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Sepolia Aave V3 addresses (official deployments)
AAVE_POOL_SEPOLIA="0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951"
USDC_SEPOLIA="0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8"  # Aave's test USDC
AUSDC_SEPOLIA="0x16dA4541aD1807f4443d92D26044C1147406EB80"  # Aave's aUSDC token

# Check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites for token deployment..."
    
    # Check required tools
    command -v forge >/dev/null 2>&1 || { print_error "forge not found. Please install Foundry."; exit 1; }
    command -v cast >/dev/null 2>&1 || { print_error "cast not found. Please install Foundry."; exit 1; }
    
    # Check environment variables
    if [ -z "$PRIVATE_KEY" ]; then
        print_error "PRIVATE_KEY not set. Please set your deployer private key."
        exit 1
    fi
    
    if [ -z "$RPC_URL" ]; then
        print_error "RPC_URL not set. Please set your RPC URL."
        exit 1
    fi
    
    # Check MorphoCredit is deployed
    if [ -z "$MORPHO_ADDRESS" ]; then
        print_error "MORPHO_ADDRESS not set. Please deploy core protocol first using ./deploy.sh"
        exit 1
    fi
    
    print_success "Prerequisites check passed"
}

# Deploy ERC4626 wrapper for aUSDC (waUSDC)
deploy_wausdc() {
    print_info "Deploying ERC4626 wrapper for aUSDC (waUSDC)..."
    
    # Create temporary Solidity script for deployment
    cat > script/deploy/DeployWAUSDC.s.sol << 'EOF'
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Simple ERC4626 wrapper for aUSDC
contract WrappedAUSDC is ERC4626 {
    constructor(IERC20 _aUSDC) 
        ERC4626(_aUSDC) 
        ERC20("Wrapped Aave USDC", "waUSDC") 
    {}
}

contract DeployWAUSDC is Script {
    function run() external returns (address) {
        address aUSDC = vm.envAddress("AUSDC_ADDRESS");
        
        vm.startBroadcast();
        
        WrappedAUSDC waUSDC = new WrappedAUSDC(IERC20(aUSDC));
        
        console.log("waUSDC deployed at:", address(waUSDC));
        console.log("Underlying aUSDC:", aUSDC);
        
        vm.stopBroadcast();
        
        return address(waUSDC);
    }
}
EOF
    
    export AUSDC_ADDRESS=$AUSDC_SEPOLIA
    
    WAUSDC_ADDRESS=$(forge script script/deploy/DeployWAUSDC.s.sol \
        --rpc-url $RPC_URL \
        --private-key $PRIVATE_KEY \
        --broadcast \
        --verify \
        --etherscan-api-key $ETHERSCAN_API_KEY \
        -vvv | grep "waUSDC deployed at:" | awk '{print $NF}')
    
    export WAUSDC_ADDRESS
    print_success "waUSDC deployed at: $WAUSDC_ADDRESS"
}

# Deploy USD3 (MetaMorpho vault)
deploy_usd3() {
    print_info "Deploying USD3 (MetaMorpho vault)..."
    
    # Note: USD3 should be a MetaMorpho vault that uses waUSDC as the underlying asset
    # For now, we'll create a placeholder that demonstrates the concept
    
    cat > script/deploy/DeployUSD3.s.sol << 'EOF'
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Simplified USD3 for testing - in production this would be MetaMorpho
contract USD3 is ERC4626 {
    constructor(IERC20 _waUSDC) 
        ERC4626(_waUSDC) 
        ERC20("3Jane USD", "USD3") 
    {}
}

contract DeployUSD3 is Script {
    function run() external returns (address) {
        address waUSDC = vm.envAddress("WAUSDC_ADDRESS");
        
        vm.startBroadcast();
        
        USD3 usd3 = new USD3(IERC20(waUSDC));
        
        console.log("USD3 deployed at:", address(usd3));
        console.log("Underlying waUSDC:", waUSDC);
        
        vm.stopBroadcast();
        
        return address(usd3);
    }
}
EOF
    
    USD3_ADDRESS=$(forge script script/deploy/DeployUSD3.s.sol \
        --rpc-url $RPC_URL \
        --private-key $PRIVATE_KEY \
        --broadcast \
        --verify \
        --etherscan-api-key $ETHERSCAN_API_KEY \
        -vvv | grep "USD3 deployed at:" | awk '{print $NF}')
    
    export USD3_ADDRESS
    print_success "USD3 deployed at: $USD3_ADDRESS"
}

# Deploy sUSD3 (Subordinate debt token)
deploy_susd3() {
    print_info "Deploying sUSD3 (Subordinate debt token)..."
    
    cat > script/deploy/DeploySUSD3.s.sol << 'EOF'
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Simplified sUSD3 for testing - subordinate tranche
contract SUSD3 is ERC4626 {
    constructor(IERC20 _waUSDC) 
        ERC4626(_waUSDC) 
        ERC20("3Jane Subordinate USD", "sUSD3") 
    {}
}

contract DeploySUSD3 is Script {
    function run() external returns (address) {
        address waUSDC = vm.envAddress("WAUSDC_ADDRESS");
        
        vm.startBroadcast();
        
        SUSD3 susd3 = new SUSD3(IERC20(waUSDC));
        
        console.log("sUSD3 deployed at:", address(susd3));
        console.log("Underlying waUSDC:", waUSDC);
        
        vm.stopBroadcast();
        
        return address(susd3);
    }
}
EOF
    
    SUSD3_ADDRESS=$(forge script script/deploy/DeploySUSD3.s.sol \
        --rpc-url $RPC_URL \
        --private-key $PRIVATE_KEY \
        --broadcast \
        --verify \
        --etherscan-api-key $ETHERSCAN_API_KEY \
        -vvv | grep "sUSD3 deployed at:" | awk '{print $NF}')
    
    export SUSD3_ADDRESS
    print_success "sUSD3 deployed at: $SUSD3_ADDRESS"
}

# Update environment file with token addresses
update_env_file() {
    print_info "Updating environment file with token addresses..."
    
    ENV_FILE=".env.${NETWORK}"
    
    # Update or append token addresses
    if grep -q "USDC_ADDRESS=" "$ENV_FILE" 2>/dev/null; then
        sed -i.bak "s|USDC_ADDRESS=.*|USDC_ADDRESS=$USDC_SEPOLIA|" "$ENV_FILE"
    else
        echo "USDC_ADDRESS=$USDC_SEPOLIA" >> "$ENV_FILE"
    fi
    
    if grep -q "WAUSDC_ADDRESS=" "$ENV_FILE" 2>/dev/null; then
        sed -i.bak "s|WAUSDC_ADDRESS=.*|WAUSDC_ADDRESS=$WAUSDC_ADDRESS|" "$ENV_FILE"
    else
        echo "WAUSDC_ADDRESS=$WAUSDC_ADDRESS" >> "$ENV_FILE"
    fi
    
    if grep -q "USD3_ADDRESS=" "$ENV_FILE" 2>/dev/null; then
        sed -i.bak "s|USD3_ADDRESS=.*|USD3_ADDRESS=$USD3_ADDRESS|" "$ENV_FILE"
    else
        echo "USD3_ADDRESS=$USD3_ADDRESS" >> "$ENV_FILE"
    fi
    
    if grep -q "SUSD3_ADDRESS=" "$ENV_FILE" 2>/dev/null; then
        sed -i.bak "s|SUSD3_ADDRESS=.*|SUSD3_ADDRESS=$SUSD3_ADDRESS|" "$ENV_FILE"
    else
        echo "SUSD3_ADDRESS=$SUSD3_ADDRESS" >> "$ENV_FILE"
    fi
    
    print_success "Environment file updated: $ENV_FILE"
}

# Get test tokens from faucet
get_test_tokens() {
    print_info "Getting test USDC from Aave faucet..."
    
    DEPLOYER=$(cast wallet address $PRIVATE_KEY)
    
    # Check if Aave faucet contract exists
    FAUCET_ADDRESS="0xC959483DBa39aa9E78757139af0e9a2EDEb3f42D"  # Aave Sepolia faucet
    
    print_info "Requesting 10,000 test USDC for $DEPLOYER..."
    
    # Call mint function on the faucet (if available)
    cast send $FAUCET_ADDRESS \
        "mint(address,address,uint256)" \
        $USDC_SEPOLIA \
        $DEPLOYER \
        "10000000000" \
        --private-key $PRIVATE_KEY \
        --rpc-url $RPC_URL 2>/dev/null || {
        print_warning "Could not get tokens from faucet. You may need to get test USDC manually."
        print_info "Visit: https://app.aave.com/faucet/ to get test tokens"
    }
    
    # Check USDC balance
    BALANCE=$(cast call $USDC_SEPOLIA "balanceOf(address)" $DEPLOYER --rpc-url $RPC_URL)
    BALANCE_DEC=$(cast to-dec $BALANCE)
    print_info "USDC balance: $(echo "scale=2; $BALANCE_DEC / 1000000" | bc) USDC"
}

# Main deployment flow
main() {
    print_info "Starting 3Jane token deployment to $NETWORK"
    print_info "================================================"
    
    check_prerequisites
    
    # Deploy tokens
    deploy_wausdc
    deploy_usd3
    deploy_susd3
    
    # Update environment file
    update_env_file
    
    # Try to get test tokens
    get_test_tokens
    
    print_success "================================================"
    print_success "Token deployment completed successfully!"
    print_info ""
    print_info "Deployed addresses:"
    print_info "  USDC (Aave test): $USDC_SEPOLIA"
    print_info "  aUSDC (Aave): $AUSDC_SEPOLIA"
    print_info "  waUSDC: $WAUSDC_ADDRESS"
    print_info "  USD3: $USD3_ADDRESS"
    print_info "  sUSD3: $SUSD3_ADDRESS"
    print_info ""
    print_info "Next steps:"
    print_info "1. Deploy Helper contract using ./deploy.sh"
    print_info "2. Configure token approvals"
    print_info "3. Create initial markets"
}

# Handle script arguments
case "${1:-}" in
    --help)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Deploys USD3 ecosystem tokens for 3Jane protocol"
        echo ""
        echo "Options:"
        echo "  --help     Show this help message"
        echo ""
        echo "Environment variables:"
        echo "  NETWORK              Target network (default: sepolia)"
        echo "  RPC_URL              RPC endpoint URL"
        echo "  PRIVATE_KEY          Deployer private key"
        echo "  ETHERSCAN_API_KEY    Etherscan API key for verification"
        echo "  MORPHO_ADDRESS       MorphoCredit contract address"
        exit 0
        ;;
esac

# Run main deployment
main