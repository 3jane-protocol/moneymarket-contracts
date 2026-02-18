# USD3 & sUSD3 - 3Jane Protocol Yield Strategies

## Overview

USD3 and sUSD3 are tokenized yield strategies built on Yearn V3's architecture for the 3Jane Protocol. These strategies enable unsecured lending through 3Jane's credit-based lending markets (modified Morpho Blue) that use borrower creditworthiness assessment instead of traditional collateral requirements.

## Architecture

### Two-Tier Structure

- **USD3 (Senior Tranche)**: Accepts USDC deposits and internally wraps to waUSDC for deployment to 3Jane's MorphoCredit lending markets
- **sUSD3 (Subordinate Tranche)**: Accepts USD3 deposits, provides first-loss protection, and earns levered yield

### Key Features

#### USD3 Strategy

- Direct USDC deposits from users (not waUSDC)
- Automatic internal wrapping of USDC to waUSDC for MorphoCredit deployment
- Configurable commitment periods (locally managed by governance)
- Dynamic deployment ratio to MorphoCredit (0-100% via locally managed `maxOnCredit`)
- Local waUSDC buffer for gas-efficient withdrawals
- Protected from losses through sUSD3 first-loss absorption
- Whitelist support for permissioned access (locally managed)
- Emergency withdrawal capabilities
- Seamless upgrade path from waUSDC-based to USDC-based implementation via `reinitialize()`

#### sUSD3 Strategy

- Accepts USD3 tokens to provide subordinate capital
- Configurable lock period for stability (via ProtocolConfig, default 90 days)
- Configurable cooldown period (via ProtocolConfig, default 7 days) + withdrawal window (local, default 2 days)
- Partial cooldown support for better UX
- First-loss absorption protects USD3 holders
- Maximum subordination ratio enforcement (via ProtocolConfig, default 15%)
- Automatic yield distribution from USD3
- Dynamic parameter updates without contract upgrades

### USDC to waUSDC Wrapping

The USD3 strategy now handles USDC directly from users while maintaining compatibility with MorphoCredit markets that use waUSDC:

1. **Deposits**: Users deposit USDC → Strategy wraps to waUSDC → Deploys to MorphoCredit
2. **Withdrawals**: Strategy withdraws from MorphoCredit → Unwraps waUSDC to USDC → Returns USDC to users
3. **Local Buffer**: Maintains a waUSDC buffer (up to `1 - maxOnCredit` ratio) for efficient withdrawals
4. **Yield Accrual**: waUSDC yield automatically accrues and is captured during reports

### Risk Management

The protocol implements multiple risk controls:

- **Subordination Ratio**: sUSD3 holdings limited by configurable ratio (via ProtocolConfig)
- **Commitment Periods**: Prevent deposit/withdrawal gaming
- **Lock & Cooldown**: Ensure stable liquidity for lending
- **Loss Absorption**: sUSD3 bears losses first, protecting USD3 holders
- **Dynamic Parameters**: Key risk parameters centrally managed via ProtocolConfig, operational parameters locally managed
- **Wrapping Precision**: Careful handling of USDC/waUSDC conversions to prevent rounding losses

## Upgrade Process

### Migrating from waUSDC to USDC

For existing deployments using waUSDC directly, the upgrade process is:

1. **Deploy New Implementation**: Deploy the new USD3 contract that accepts USDC
2. **Upgrade Proxy**: Point the proxy to the new implementation
3. **Reinitialize**: Call `reinitialize()` to switch the asset from waUSDC to USDC
4. **Critical**: Execute as atomic multisig batch with `report()` to prevent user losses

**Important**: The upgrade MUST be executed as an atomic multisig batch transaction:

```solidity
// Multisig Batch Transaction
1. strategy.setPerformanceFee(0)              // Prevent fee distribution
2. strategy.setProfitMaxUnlockTime(0)         // Ensure immediate profit availability
3. strategy.report()                           // Update totalAssets to correct USDC value
4. strategy.syncTrancheShare()                 // Restore performance fee to sUSD3
5. strategy.setProfitMaxUnlockTime(previous)  // Restore profit unlock schedule
```

See `test/forge/usd3/integration/USD3UpgradeMultisigBatch.t.sol` for comprehensive tests.

## Installation

### Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Node.js](https://nodejs.org/en/download/package-manager/)
- Unix-like environment (macOS, Linux, or WSL for Windows)

### Setup

```bash
# Clone repository
git clone --recursive https://github.com/3jane/3jane-morpho-blue
cd 3jane-morpho-blue

# Install dependencies
yarn

# Copy and configure environment
cp .env.example .env
# Add your ETH_RPC_URL and other required variables
```

## Building and Testing

### Build Commands

```bash
# Build contracts with Forge
yarn build:forge

# Build contracts with Hardhat
yarn build:hardhat

# Check contract sizes
yarn build:forge:size

# Format code
forge fmt
```

### Testing

```bash
# Run all Forge tests
yarn test:forge

# Run integration tests only
yarn test:forge:integration

# Run invariant tests only
yarn test:forge:invariant

# Run Hardhat tests
yarn test:hardhat

# Run fork tests (requires ETH_RPC_URL)
yarn test:forge:fork

# Test specific contract
yarn test:forge --match-contract USD3Test -vvv

# Test specific function
yarn test:forge --match-test test_wrappingMechanics -vvv

# Generate gas report
yarn test:forge --gas-report
```

### Fork Testing

Fork tests are opt-in and require `ETH_RPC_URL` to be set:

```bash
# Run all fork tests
ETH_RPC_URL=$ETH_RPC_URL yarn test:forge:fork

# Run USD3 upgrade fork tests specifically
ETH_RPC_URL=$ETH_RPC_URL yarn test:forge:fork:upgrade
```

Fork tests are automatically skipped when `ETH_RPC_URL` is not set, ensuring normal test runs are not affected.

### CI Fork Workflow

Fork tests run in CI in the `Foundry` workflow:

- PRs: add label `ci/run-fork-tests` to trigger fork suites on demand.
- Nightly: runs automatically at `07:00 UTC`.
- Manual: available via `workflow_dispatch`.
- PRs without the label: fork tests are not part of the normal PR gate.

### Coverage

```bash
# Generate coverage report
yarn test:forge:coverage

# View coverage in terminal
forge coverage --report summary
```

## Strategy Development

### USD3 Implementation

USD3 inherits from `TokenizedStrategy` and implements core methods with USDC/waUSDC wrapping:

```solidity
// Deploy USDC by wrapping to waUSDC and supplying to MorphoCredit
function _deployFunds(uint256 _amount) internal override

// Withdraw from lending positions and unwrap waUSDC to USDC
function _freeFunds(uint256 _amount) internal override

// Calculate total assets including waUSDC yield
function _harvestAndReport() internal override returns (uint256)

// Helper functions for wrapping/unwrapping
function _supplyToMorpho(uint256 _waUSDCAmount) internal
function _withdrawFromMorpho(uint256 _waUSDCNeeded) internal
```

### sUSD3 Implementation

sUSD3 also inherits from `TokenizedStrategy` but holds USD3 directly:

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

## Testing Structure

```
test/forge/usd3/
├── unit/                   # Unit tests
│   ├── WaUSDCWrappingTest.t.sol
│   ├── ReinitializeTest.t.sol
│   └── LocalBufferTest.t.sol
├── integration/            # Integration tests
│   ├── USD3IntegrationTest.t.sol
│   ├── USD3SimplifiedUpgradeTest.t.sol
│   └── USD3UpgradeMultisigBatch.t.sol
├── fuzz/                   # Fuzz tests
│   └── USD3UpgradeFuzzTest.t.sol
├── fork/                   # Mainnet fork tests (opt-in)
│   ├── MainnetForkBase.t.sol
│   └── USD3UpgradeForkTest.t.sol
├── invariant/              # Property-based tests
│   └── USD3InvariantTest.t.sol
└── utils/                  # Test utilities
    └── Setup.sol
```

## Integration with 3Jane Protocol

### MorphoCredit Markets

- USD3 wraps USDC to waUSDC and supplies to credit-based lending markets
- Interest accrues from unsecured loans to verified borrowers
- Per-borrower risk premiums provide additional yield
- waUSDC yield automatically captured and passed through to USD3 holders

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
- Careful handling of USDC/waUSDC wrapping to prevent precision loss
- Comprehensive test coverage including invariant and fuzz testing
- Atomic multisig batch required for safe upgrades

## License

AGPL-3.0

## Links

- [3Jane Protocol Documentation](https://docs.3jane.com)
- [Yearn V3 Strategy Guide](https://docs.yearn.fi/developers/v3/strategy_writing_guide)
- [Morpho Blue Documentation](https://docs.morpho.org)
