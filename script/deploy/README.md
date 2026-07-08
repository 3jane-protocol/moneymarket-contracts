# 3Jane Morpho Blue Deployment Scripts

## Overview

This directory contains deployment scripts for the 3Jane Morpho Blue protocol. The deployment uses OpenZeppelin's Transparent Proxy pattern with TimelockController for secure upgrades.

## Contract Architecture

### Upgradeable Contracts (Proxy Pattern)
- **ProtocolConfig**: Protocol configuration management
- **MorphoCredit**: Main lending protocol
- **AdaptiveCurveIrm**: Interest rate model

### Non-Upgradeable Contracts
- **TimelockController**: Time-delayed execution for upgrades
- **Helper**: User interaction helper
- **CreditLine**: Credit line management
- **InsuranceFund**: Insurance fund for bad debt
- **MarkdownManager**: Markdown calculations

## Deployment Order

1. **TimelockController** - Controls proxy upgrades
2. **ProtocolConfig** - Protocol parameters
3. **MorphoCredit** - Main protocol (requires ProtocolConfig)
4. **MarkdownManager** - Markdown calculations
5. **CreditLine** - Credit management (requires MarkdownManager)
6. **InsuranceFund** - Insurance fund (requires CreditLine)
7. **AdaptiveCurveIrm** - Interest rate model
8. **Helper** - User helper functions

## Prerequisites

1. Install dependencies:
```bash
yarn install
forge install OpenZeppelin/openzeppelin-foundry-upgrades
```

2. Set up environment variables:
```bash
cp .env.sepolia .env
# Edit .env with your values
```

## Deployment Instructions

### Local Testing (Fork)

```bash
# Start local fork
anvil --fork-url https://sepolia.infura.io/v3/YOUR_KEY

# In another terminal, deploy to fork
source .env
forge script script/deploy/DeployAll.s.sol --rpc-url http://localhost:8545 --broadcast
```

### Sepolia Testnet

```bash
# Load environment
source .env

# Deploy all contracts
forge script script/deploy/DeployAll.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify

# Or deploy individually
forge script script/deploy/00_DeployTimelock.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
# ... continue with other scripts in order
```

## Post-Deployment

### 1. Set Insurance Fund in CreditLine
```solidity
creditLine.setInsuranceFund(insuranceFundAddress)
```

### 2. Configure Protocol Parameters
```solidity
// Via TimelockController after delay
protocolConfig.setParameter(key, value)
```

### 3. Create Initial Markets
```solidity
morphoCredit.createMarket(marketParams)
```

## Upgrade Process

1. Deploy new implementation:
```solidity
MorphoCredit newImpl = new MorphoCredit(protocolConfig);
```

2. Schedule upgrade via Timelock:
```solidity
timelock.schedule(
    proxyAdmin,
    0,
    abi.encodeCall(ProxyAdmin.upgrade, (proxy, newImpl)),
    predecessor,
    salt,
    delay
);
```

3. Execute after delay:
```solidity
timelock.execute(
    proxyAdmin,
    0,
    abi.encodeCall(ProxyAdmin.upgrade, (proxy, newImpl)),
    predecessor,
    salt
);
```

## Verification

Contracts are automatically verified if `--verify` flag is used. For manual verification:

```bash
forge verify-contract \
    --chain-id 11155111 \
    --num-of-optimizations 999999 \
    --watch \
    --constructor-args $(cast abi-encode "constructor(address)" "$PROTOCOL_CONFIG") \
    --compiler-version v0.8.22 \
    $CONTRACT_ADDRESS \
    src/MorphoCredit.sol:MorphoCredit
```

## Gas Costs (Estimated)

- TimelockController: ~500k gas
- ProtocolConfig (Proxy + Impl): ~1.5M gas
- MorphoCredit (Proxy + Impl): ~4M gas
- AdaptiveCurveIrm (Proxy + Impl): ~2M gas
- Helper: ~800k gas
- CreditLine: ~1M gas
- InsuranceFund: ~300k gas
- MarkdownManager: ~200k gas

**Total: ~10.3M gas**

## Security Considerations

1. **Timelock Delay**: 5 minutes on testnet, 48 hours on mainnet
2. **ProxyAdmin**: Owned by TimelockController
3. **Multisig**: Controls Timelock proposer and admin roles
4. **Initialization**: All proxies initialized in same transaction as deployment

## Deployed Addresses

Deployment addresses are saved to:
- `deployments/{chainId}/latest.json` - Latest deployment
- `deployments/{chainId}/deployment-{timestamp}.json` - Historical deployments

## Troubleshooting

### "Contract already initialized"
- Proxies can only be initialized once
- Check if trying to redeploy to same address

### "Bytecode size exceeds limit"
- MorphoCredit is near size limit (22,328/24,576 bytes)
- Use Transparent Proxy (adds 0 bytes to implementation)

### "Insufficient funds"
- Ensure deployer has enough ETH
- Sepolia faucets: https://sepoliafaucet.com

### "Transaction reverted"
- Check constructor arguments match expected types
- Verify all dependency addresses are deployed
- Ensure proper deployment order