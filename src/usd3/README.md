# USD3 & sUSD3 - 3Jane Protocol Yield Strategies

## Overview

USD3 and sUSD3 are tokenized yield strategies built on Yearn V3's architecture for the 3Jane Protocol. These strategies enable unsecured lending through 3Jane's credit-based lending markets (modified Morpho Blue) that use borrower creditworthiness assessment instead of traditional collateral requirements.

## Architecture

### Two-Tier Structure

- **USD3 (Senior Tranche)**: Accepts USDC deposits and deploys capital to 3Jane's MorphoCredit lending markets
- **sUSD3 (Subordinate Tranche)**: Accepts USD3 deposits, provides first-loss protection, and earns levered yield

### Key Features

#### USD3 Strategy
- Direct USDC deposits with automatic deployment to credit markets
- Configurable commitment periods (locally managed by governance)
- Dynamic deployment ratio to MorphoCredit (0-100% via locally managed `maxOnCredit`)
- Protected from losses through sUSD3 first-loss absorption
- Whitelist support for permissioned access (locally managed)
- Emergency withdrawal capabilities

#### sUSD3 Strategy  
- Accepts USD3 tokens to provide subordinate capital
- Configurable lock period for stability (via ProtocolConfig, default 90 days)
- Configurable cooldown period (via ProtocolConfig, default 7 days) + withdrawal window (local, default 2 days)
- Partial cooldown support for better UX
- First-loss absorption protects USD3 holders
- Maximum subordination ratio enforcement (via ProtocolConfig, default 15%)
- Automatic yield distribution from USD3
- Dynamic parameter updates without contract upgrades

### Risk Management

The protocol implements multiple risk controls:
- **Subordination Ratio**: sUSD3 holdings limited by configurable ratio (via ProtocolConfig)
- **Commitment Periods**: Prevent deposit/withdrawal gaming
- **Lock & Cooldown**: Ensure stable liquidity for lending
- **Loss Absorption**: sUSD3 bears losses first, protecting USD3 holders
- **Dynamic Parameters**: Key risk parameters centrally managed via ProtocolConfig, operational parameters locally managed

## Installation

### Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Node.js](https://nodejs.org/en/download/package-manager/)
- Unix-like environment (macOS, Linux, or WSL for Windows)

### Setup

```bash
# Clone repository
git clone --recursive https://github.com/3jane/usd3-strategies
cd usd3-strategies

# Install dependencies
yarn

# Copy and configure environment
cp .env.example .env
# Add your ETH_RPC_URL and other required variables
```

## Building and Testing

### Build Commands

```bash
# Build contracts
make build

# Check contract sizes
make size

# Format code
make fmt
```

### Testing

All tests run in a forked environment. Ensure your `.env` file has valid RPC URLs configured.

```bash
# Run all tests
make test

# Run with traces (recommended for debugging)
make trace

# Run with maximum verbosity
make trace-max

# Test specific contract
make test-contract contract=USD3Test

# Test specific function
make test-test test=test_subordinationRatio

# Generate gas report
make gas
```

### Coverage

```bash
# Generate coverage report
make coverage

# Generate HTML coverage report (requires lcov)
make coverage-html
# View at coverage-report/index.html
```

## Strategy Development

### USD3 Implementation

USD3 inherits from `BaseHooksUpgradeable` and implements three core methods:

```solidity
// Deploy USDC to MorphoCredit
function _deployFunds(uint256 _amount) internal override

// Withdraw from lending positions  
function _freeFunds(uint256 _amount) internal override

// Calculate total assets including interest
function _harvestAndReport() internal override returns (uint256)
```

### sUSD3 Implementation

sUSD3 also inherits from `BaseHooksUpgradeable` but holds USD3 directly:

```solidity
// USD3 tokens stay in strategy (no deployment)
function _deployFunds(uint256 _amount) internal override

// Funds already available (no freeing needed)
function _freeFunds(uint256 _amount) internal override  

// Return USD3 balance (yield auto-received)
function _harvestAndReport() internal override returns (uint256)
```

### Hooks System

Both strategies use hooks for additional logic:
- `_preDepositHook`: Track commitment/lock periods
- `_postWithdrawHook`: Update cooldown states
- `availableDepositLimit`: Enforce subordination ratio
- `availableWithdrawLimit`: Enforce time restrictions

## Deployment

Strategies use the proxy pattern for upgradeability:

1. Deploy implementation contracts
2. Deploy TransparentUpgradeableProxy with initialization
3. Configure parameters via ProtocolConfig
4. Link strategies (USD3 ↔ sUSD3)
5. Set up access controls and whitelists

### Verification

After deployment, verify proxy functions on Etherscan:
1. Navigate to contract's `#code` page
2. Click "More Options" → "Is this a proxy?"
3. Click "Verify" → "Save"

## Testing Structure

```
src/test/
├── USD3.t.sol              # Core USD3 tests
├── sUSD3.t.sol             # Core sUSD3 tests  
├── InterestDistribution.t.sol # Yield distribution tests
├── LossAbsorption.t.sol   # Loss handling tests
├── Invariants.t.sol        # Property-based tests
├── edge/                   # Edge case tests
│   ├── CommitmentEdgeCases.t.sol
│   └── CooldownEdgeCases.t.sol
├── security/               # Security tests
│   ├── ReentrancyTest.t.sol
│   └── BypassAttempts.t.sol
└── stress/                 # Stress tests
    └── MultiUserStress.t.sol
```

## Integration with 3Jane Protocol

### MorphoCredit Markets
- USD3 supplies USDC to credit-based lending markets
- Interest accrues from unsecured loans to verified borrowers
- Per-borrower risk premiums provide additional yield

### ProtocolConfig Integration

Centrally managed parameters (with defaults):
- **sUSD3 Parameters**:
  - Subordination ratio (default 15%)
  - Lock duration (default 90 days)
  - Cooldown period (default 7 days)
  - Interest distribution share

Locally managed parameters:
- **USD3 Parameters**:
  - Commitment period (setMinCommitmentTime)
  - Max deployment ratio (setMaxOnCredit)
  - Whitelist settings
- **sUSD3 Parameters**:
  - Withdrawal window duration (setWithdrawalWindow)

## Security Considerations

- Contracts are upgradeable - ensure proper access controls
- Emergency admin can shutdown strategies
- Whitelist enforcement available for both strategies
- Reentrancy protection on all external calls
- Comprehensive test coverage including invariant testing

## License

AGPL-3.0

## Links

- [3Jane Protocol Documentation](https://docs.3jane.com)
- [Yearn V3 Strategy Guide](https://docs.yearn.fi/developers/v3/strategy_writing_guide)
- [Morpho Blue Documentation](https://docs.morpho.org)