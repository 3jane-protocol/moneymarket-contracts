#!/bin/bash

# 3Jane Morpho Blue - Environment Setup Script
# Prepares the development environment for deployment

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check and install Foundry
check_foundry() {
    print_info "Checking Foundry installation..."
    
    if command -v forge >/dev/null 2>&1; then
        FORGE_VERSION=$(forge --version | head -n1)
        print_success "Foundry installed: $FORGE_VERSION"
    else
        print_warning "Foundry not found. Installing..."
        curl -L https://foundry.paradigm.xyz | bash
        source ~/.bashrc
        foundryup
        print_success "Foundry installed successfully"
    fi
}

# Check Node.js and Yarn
check_node() {
    print_info "Checking Node.js and Yarn..."
    
    if command -v node >/dev/null 2>&1; then
        NODE_VERSION=$(node --version)
        print_success "Node.js installed: $NODE_VERSION"
    else
        print_error "Node.js not found. Please install Node.js v18 or higher"
        exit 1
    fi
    
    if command -v yarn >/dev/null 2>&1; then
        YARN_VERSION=$(yarn --version)
        print_success "Yarn installed: $YARN_VERSION"
    else
        print_warning "Yarn not found. Installing..."
        npm install -g yarn
        print_success "Yarn installed successfully"
    fi
}

# Check other required tools
check_tools() {
    print_info "Checking required tools..."
    
    # Check jq
    if command -v jq >/dev/null 2>&1; then
        print_success "jq installed"
    else
        print_warning "jq not found. Installing..."
        if [[ "$OSTYPE" == "darwin"* ]]; then
            brew install jq
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            sudo apt-get update && sudo apt-get install -y jq
        else
            print_error "Please install jq manually"
            exit 1
        fi
    fi
    
    # Check bc
    if command -v bc >/dev/null 2>&1; then
        print_success "bc installed"
    else
        print_warning "bc not found. Installing..."
        if [[ "$OSTYPE" == "darwin"* ]]; then
            brew install bc
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            sudo apt-get update && sudo apt-get install -y bc
        else
            print_error "Please install bc manually"
            exit 1
        fi
    fi
}

# Install dependencies
install_dependencies() {
    print_info "Installing project dependencies..."
    
    # Install Node dependencies
    if [ -f "package.json" ]; then
        print_info "Installing Node.js dependencies..."
        yarn install
        print_success "Node.js dependencies installed"
    fi
    
    # Install Foundry dependencies
    print_info "Installing Foundry dependencies..."
    forge install --no-commit || true
    print_success "Foundry dependencies installed"
    
    # Build contracts
    print_info "Building contracts..."
    yarn build:forge || forge build
    print_success "Contracts built successfully"
}

# Create required directories
create_directories() {
    print_info "Creating required directories..."
    
    mkdir -p deployments/11155111  # Sepolia
    mkdir -p deployments/1  # Mainnet
    mkdir -p deployments/31337  # Local
    mkdir -p script/deploy
    mkdir -p script/upgrade
    mkdir -p script/config
    
    print_success "Directories created"
}

# Generate environment file from template
generate_env() {
    print_info "Generating environment files..."
    
    # Create .env.example if it doesn't exist
    if [ ! -f ".env.example" ]; then
        cat > .env.example << 'EOF'
# Network Configuration
NETWORK=sepolia
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_INFURA_KEY
MAINNET_RPC_URL=https://mainnet.infura.io/v3/YOUR_INFURA_KEY

# Deployment Account
PRIVATE_KEY=0x0000000000000000000000000000000000000000000000000000000000000000

# Etherscan Verification
ETHERSCAN_API_KEY=YOUR_ETHERSCAN_API_KEY

# Protocol Addresses
MULTISIG_ADDRESS=0x0000000000000000000000000000000000000000
OWNER_ADDRESS=0x0000000000000000000000000000000000000000
OZD_ADDRESS=0x0000000000000000000000000000000000000000

# Timelock Configuration
TIMELOCK_DELAY=300  # 5 minutes for testnet, 172800 (48 hours) for mainnet

# Token Addresses (Sepolia)
USDC_ADDRESS=0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8
AUSDC_ADDRESS=0x16dA4541aD1807f4443d92D26044C1147406EB80

# Optional Prover Address
PROVER_ADDRESS=0x0000000000000000000000000000000000000000
EOF
        print_success "Created .env.example"
    fi
    
    # Create network-specific env files if they don't exist
    for network in sepolia mainnet local; do
        ENV_FILE=".env.${network}"
        if [ ! -f "$ENV_FILE" ]; then
            cp .env.example "$ENV_FILE"
            print_success "Created $ENV_FILE"
        else
            print_info "$ENV_FILE already exists, skipping"
        fi
    done
    
    print_warning "Please update the .env files with your actual values"
}

# Update Sepolia configuration with Aave addresses
update_sepolia_config() {
    print_info "Updating Sepolia configuration with Aave addresses..."
    
    ENV_FILE=".env.sepolia"
    
    # Update Aave addresses
    sed -i.bak "s|USDC_ADDRESS=.*|USDC_ADDRESS=0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8|" "$ENV_FILE"
    sed -i.bak "s|AUSDC_ADDRESS=.*|AUSDC_ADDRESS=0x16dA4541aD1807f4443d92D26044C1147406EB80|" "$ENV_FILE"
    
    # Add Aave Pool address if not present
    if ! grep -q "AAVE_POOL_ADDRESS=" "$ENV_FILE"; then
        echo "" >> "$ENV_FILE"
        echo "# Aave V3 Addresses (Sepolia)" >> "$ENV_FILE"
        echo "AAVE_POOL_ADDRESS=0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951" >> "$ENV_FILE"
    fi
    
    print_success "Sepolia configuration updated"
}

# Check git repository
check_git() {
    print_info "Checking git repository..."
    
    if [ -d ".git" ]; then
        print_success "Git repository found"
        
        # Check for uncommitted changes
        if ! git diff-index --quiet HEAD -- 2>/dev/null; then
            print_warning "You have uncommitted changes. Consider committing before deployment."
        fi
    else
        print_warning "Not a git repository. Version control is recommended."
    fi
}

# Validate configuration
validate_config() {
    print_info "Validating configuration..."
    
    # Check if any .env file exists
    if [ ! -f ".env" ] && [ ! -f ".env.sepolia" ] && [ ! -f ".env.mainnet" ]; then
        print_error "No .env file found. Please create one from .env.example"
        exit 1
    fi
    
    # Check foundry.toml
    if [ ! -f "foundry.toml" ]; then
        print_error "foundry.toml not found"
        exit 1
    fi
    
    # Check required OpenZeppelin settings in foundry.toml
    if ! grep -q "ffi = true" foundry.toml; then
        print_warning "foundry.toml missing 'ffi = true' - required for OpenZeppelin Upgrades"
    fi
    
    if ! grep -q "ast = true" foundry.toml; then
        print_warning "foundry.toml missing 'ast = true' - required for OpenZeppelin Upgrades"
    fi
    
    print_success "Configuration validated"
}

# Main setup flow
main() {
    print_info "3Jane Morpho Blue - Environment Setup"
    print_info "======================================"
    
    # Check and install tools
    check_foundry
    check_node
    check_tools
    
    # Setup project
    install_dependencies
    create_directories
    generate_env
    update_sepolia_config
    
    # Validate setup
    check_git
    validate_config
    
    print_success "======================================"
    print_success "Environment setup completed!"
    print_info ""
    print_info "Next steps:"
    print_info "1. Update .env.sepolia with your deployment keys and addresses"
    print_info "2. Fund your deployer account with Sepolia ETH"
    print_info "3. Run ./deploy.sh to deploy core protocol"
    print_info "4. Run ./deploy-tokens.sh to deploy token ecosystem"
    print_info ""
    print_info "For local testing:"
    print_info "  anvil --fork-url <SEPOLIA_RPC_URL>"
    print_info "  ./deploy.sh --network local"
}

# Handle script arguments
case "${1:-}" in
    --help)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Sets up the development environment for 3Jane deployment"
        echo ""
        echo "Options:"
        echo "  --help     Show this help message"
        echo ""
        echo "This script will:"
        echo "  - Check and install required tools"
        echo "  - Install project dependencies"
        echo "  - Create required directories"
        echo "  - Generate environment files"
        echo "  - Validate configuration"
        exit 0
        ;;
esac

# Run main setup
main