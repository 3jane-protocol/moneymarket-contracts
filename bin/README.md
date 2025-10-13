# 3Jane Morpho Blue - Deployment Automation

This directory contains automated deployment scripts for the 3Jane Morpho Blue protocol.

## Quick Start

1. **Setup Environment**
   ```bash
   ./bin/setup-env.sh
   ```

2. **Configure Deployment**
   ```bash
   cp .env.sepolia .env
   # Edit .env with your keys and addresses
   ```

3. **Deploy Core Protocol**
   ```bash
   ./bin/deploy.sh
   ```

4. **Deploy Token Ecosystem**
   ```bash
   ./bin/deploy-tokens.sh
   ```

5. **Verify Contracts**
   ```bash
   ./bin/verify-all.sh
   ```

6. **Health Check**
   ```bash
   ./bin/health-check.sh
   ```

## Scripts Overview

### `setup-env.sh`
Prepares your development environment:
- Checks and installs Foundry
- Installs Node.js dependencies
- Creates required directories
- Generates environment templates
- Validates configuration

### `deploy.sh`
Main deployment orchestration script:
- Deploys all core protocol contracts in correct order
- Handles address propagation between contracts
- Supports resume on failure
- Saves deployment addresses to JSON

**Deployment Order:**
1. TimelockController
2. ProtocolConfig (Proxy)
3. MorphoCredit (Proxy)
4. MarkdownManager
5. CreditLine
6. InsuranceFund
7. AdaptiveCurveIrm (Proxy)
8. Helper

### `deploy-tokens.sh`
Deploys the USD3 token ecosystem:
- waUSDC (ERC4626 wrapper for aUSDC)
- USD3 (Senior tranche token)
- sUSD3 (Subordinate debt token)

**Token Flow:**
```
USDC → Aave Pool → aUSDC → waUSDC → USD3/sUSD3
```

### `verify-all.sh`
Batch verification of all contracts on Etherscan:
- Automatically loads deployed addresses
- Handles constructor arguments
- Retries failed verifications
- Provides Etherscan links

### `health-check.sh`
Post-deployment validation:
- Verifies all contracts are deployed
- Checks proxy implementations
- Validates configurations
- Tests basic functionality

## Environment Variables

### Required
- `PRIVATE_KEY` - Deployer private key
- `RPC_URL` - Network RPC endpoint
- `ETHERSCAN_API_KEY` - For contract verification

### Network Configuration
- `NETWORK` - Target network (sepolia/mainnet/local)
- `SEPOLIA_RPC_URL` - Sepolia RPC endpoint
- `MAINNET_RPC_URL` - Mainnet RPC endpoint

### Protocol Addresses
- `MULTISIG_ADDRESS` - Multisig wallet for governance
- `OWNER_ADDRESS` - Protocol owner
- `OZD_ADDRESS` - OpenZeppelin Defender address

### Timelock Configuration
- `TIMELOCK_DELAY` - Upgrade delay (300 for testnet, 172800 for mainnet)

## Deployment Workflow

### Local Testing
```bash
# Start local fork
anvil --fork-url https://sepolia.infura.io/v3/YOUR_KEY

# Deploy to local fork
export NETWORK=local
export RPC_URL=http://localhost:8545
./bin/deploy.sh
```

### Sepolia Testnet
```bash
# Setup environment
./bin/setup-env.sh

# Configure .env
vim .env

# Deploy core protocol
./bin/deploy.sh

# Deploy tokens
./bin/deploy-tokens.sh

# Verify contracts
./bin/verify-all.sh

# Run health check
./bin/health-check.sh
```

### Mainnet Deployment
```bash
# Use mainnet configuration
export NETWORK=mainnet
export TIMELOCK_DELAY=172800  # 48 hours

# Deploy with extra caution
./bin/deploy.sh

# Immediate verification
./bin/verify-all.sh
```

## Resume Failed Deployment

If deployment fails, you can resume:
```bash
# Resume from last successful step
./bin/deploy.sh

# Or reset and start fresh
./bin/deploy.sh --reset
```

## Deployment Addresses

Addresses are saved to:
- `deployments/{chainId}/latest.json` - Latest deployment
- `deployments/{chainId}/deployment-{timestamp}.json` - Historical

## Aave Integration

The protocol integrates with Aave V3 on Sepolia:

| Contract | Address |
|----------|---------|
| Aave Pool | 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951 |
| USDC | 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8 |
| aUSDC | 0x16dA4541aD1807f4443d92D26044C1147406EB80 |
| Faucet | 0xC959483DBa39aa9E78757139af0e9a2EDEb3f42D |

Get test tokens: https://app.aave.com/faucet/

## Gas Estimates

| Operation | Gas | Cost (30 gwei) |
|-----------|-----|----------------|
| TimelockController | ~500k | ~0.015 ETH |
| ProtocolConfig | ~1.5M | ~0.045 ETH |
| MorphoCredit | ~4M | ~0.12 ETH |
| Other Contracts | ~4.3M | ~0.13 ETH |
| **Total** | **~10.3M** | **~0.31 ETH** |

## Troubleshooting

### "Contract already initialized"
Proxies can only be initialized once. Check if redeploying to same address.

### "Insufficient funds"
Ensure deployer has at least 0.5 ETH. Get Sepolia ETH from faucets.

### "Transaction reverted"
- Check constructor arguments match expected types
- Verify dependency addresses are deployed
- Ensure proper deployment order

### "Verification failed"
- Check Etherscan API key is valid
- Wait a few minutes after deployment
- Try manual verification with constructor args

## Security Considerations

1. **Timelock Delays**
   - Testnet: 5 minutes
   - Mainnet: 48 hours

2. **Access Control**
   - ProxyAdmin owned by TimelockController
   - Multisig controls Timelock proposer role
   - Anyone can execute after delay

3. **Upgrade Process**
   - Propose → Wait → Execute
   - Emergency cancel available
   - All upgrades visible on-chain

## Support

For issues or questions:
- Check deployment logs in `deployments/`
- Review contract verification on Etherscan
- Run health check for diagnostics
- Open issue on GitHub