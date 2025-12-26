#!/bin/bash

# 3Jane Token Flattening Script
# Clones USD3 repository and flattens USD3/sUSD3 contracts for deployment

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
FOUNDRY_PROFILE=BUILD

# Helper functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if running from project root
if [ ! -f "foundry.toml" ]; then
    print_error "Please run this script from the project root directory"
    exit 1
fi

print_info "Starting token contract flattening process..."
print_info "================================================"

# Step 1: Clone repositories
print_info "Step 1: Cloning required repositories..."

# Clone USD3 repository
if [ ! -d "/tmp/usd3-repo" ]; then
    print_info "Cloning 3jane-protocol/usd3..."
    gh repo clone 3jane-protocol/usd3 /tmp/usd3-repo -- --depth 1
    if [ $? -eq 0 ]; then
        print_success "USD3 repository cloned successfully"
    else
        print_error "Failed to clone USD3 repository"
        exit 1
    fi
else
    print_info "USD3 repository already cloned, skipping..."
fi

# Step 2: Create output directories
print_info "Step 2: Creating output directories..."
mkdir -p src/tokens/flattened
mkdir -p src/tokens/deployable

# Step 3: Build dependencies in cloned repos
print_info "Step 3: Building dependencies in cloned repository..."

# Build USD3 dependencies
print_info "Building USD3 dependencies..."
cd /tmp/usd3-repo
if [ ! -d "lib" ]; then
    forge install
fi
forge build --skip test --skip script
cd - > /dev/null

# Step 4: Flatten contracts
print_info "Step 4: Flattening contracts..."

# Flatten USD3
print_info "Flattening USD3..."
cd /tmp/usd3-repo
forge flatten src/USD3.sol > $OLDPWD/src/tokens/flattened/USD3.sol 2>/dev/null
if [ $? -eq 0 ]; then
    print_success "USD3 flattened successfully"
else
    print_warning "USD3 flattening had warnings, checking output..."
fi
cd - > /dev/null

# Flatten sUSD3
print_info "Flattening sUSD3..."
cd /tmp/usd3-repo
forge flatten src/sUSD3.sol > $OLDPWD/src/tokens/flattened/sUSD3.sol 2>/dev/null
if [ $? -eq 0 ]; then
    print_success "sUSD3 flattened successfully"
else
    print_warning "sUSD3 flattening had warnings, checking output..."
fi
cd - > /dev/null

# Step 5: Clean up flattened files
print_info "Step 5: Cleaning up flattened contracts..."

for file in src/tokens/flattened/*.sol; do
    if [ -f "$file" ]; then
        filename=$(basename "$file")
        print_info "Cleaning $filename..."
        
        # Create temp file for processing
        temp_file="${file}.tmp"
        
        # Keep only the first SPDX license identifier
        awk '/^\/\/ SPDX-License-Identifier:/ && !found {found=1; print; next} !/^\/\/ SPDX-License-Identifier:/ {print}' "$file" > "$temp_file"
        
        # Replace all pragma solidity statements with 0.8.22
        sed 's/^pragma solidity.*;/pragma solidity 0.8.22;/' "$temp_file" > "${temp_file}2"
        
        # Keep only the first pragma abicoder statement if present
        awk '/^pragma abicoder/ && !found {found=1; print; next} !/^pragma abicoder/ {print}' "${temp_file}2" > "$temp_file"
        
        # Move cleaned file back
        mv "$temp_file" "$file"
        rm -f "${temp_file}2"
        
        # Check if file is not empty
        if [ -s "$file" ]; then
            print_success "$filename cleaned"
        else
            print_error "$filename is empty after cleaning!"
        fi
    fi
done

# Step 6: Verify flattened contracts compile
print_info "Step 6: Verifying flattened contracts compile..."

# Test compilation of each flattened contract
for file in src/tokens/flattened/*.sol; do
    if [ -f "$file" ]; then
        filename=$(basename "$file")
        print_info "Testing compilation of $filename..."
        
        # Try to compile the flattened file
        FOUNDRY_PROFILE=deploy
        forge build --contracts "$file" --skip test --skip script 2>/dev/null
        if [ $? -eq 0 ]; then
            print_success "$filename compiles successfully"
        else
            print_warning "$filename has compilation warnings or errors, manual review needed"
        fi
    fi
done

# Step 7: Create summary
print_info "================================================"
print_success "Token flattening process completed!"
print_info ""
print_info "Flattened contracts created in: src/tokens/flattened/"
print_info "  - USD3.sol (Senior tranche strategy)"
print_info "  - sUSD3.sol (Subordinate tranche strategy)"
print_info ""
print_info "Next steps:"
print_info "  1. Review flattened contracts for any compilation issues"
print_info "  2. Create deployment adapters if needed"
print_info "  3. Run deployment script: forge script script/deploy/10_DeployUSD3.s.sol and 11_DeploySUSD3.s.sol"
print_info ""

# Check file sizes to ensure content exists
print_info "File sizes:"
for file in src/tokens/flattened/*.sol; do
    if [ -f "$file" ]; then
        size=$(wc -c < "$file")
        filename=$(basename "$file")
        echo "  - $filename: $size bytes"
    fi
done
