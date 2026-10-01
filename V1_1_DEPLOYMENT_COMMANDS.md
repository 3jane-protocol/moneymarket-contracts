# V1.1 Upgrade Deployment Commands

## Prerequisites

1. **Environment Setup**
   ```bash
   # Copy and configure environment file
   cp .env.mainnet .env

   # Verify all required variables are set
   source .env
   echo "Network: $NETWORK"
   echo "Owner: $OWNER_ADDRESS"
   echo "MorphoCredit: $MORPHO_ADDRESS"
   echo "USD3: $USD3_ADDRESS"
   ```

2. **Account Setup**
   ```bash
   # List available accounts
   cast wallet list

   # Should see: 3jane-p-deployer
   ```

3. **Network Verification**
   ```bash
   # Verify RPC connection
   cast chain-id
   # Should return: 1 (mainnet)

   # Check deployer balance
   cast balance $OWNER_ADDRESS
   ```

---

## Deployment Workflow

### Phase 1: Deploy New Contracts (4 scripts)

These deploy new immutable contracts. No upgrades involved.

#### 1.1 Deploy Jane Token

**Note:** Jane is deployed via CREATE3 (using CreateX) for deterministic addressing independent of constructor parameters.

**Pre-compute deployment address (optional but recommended):**
```bash
# Verify the deployment address before deploying
yarn script:forge script/compute/ComputeJaneAddress.s.sol
```

This will display the deterministic address where Jane will be deployed. The address depends only on:
- `JANE_CREATE3_SALT` - The salt you generated
- `OWNER_ADDRESS` - The deployer address

The address is independent of constructor parameters (owner, distributor) and contract bytecode.

**Dry Run (Simulation):**
```bash
yarn script:forge script/deploy/upgrade/v1.1/01_DeployJane.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS
```

**Wet Run (Actual Deployment):**
```bash
yarn script:forge script/deploy/upgrade/v1.1/01_DeployJane.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS \
  --broadcast --verify
```

**Save Output:**
```bash
# Copy JANE_ADDRESS from output for use in next scripts
export JANE_ADDRESS=<address_from_output>

# Verify the deployed address matches the pre-computed address
echo "Deployed JANE at: $JANE_ADDRESS"
```

#### 1.2 Deploy MarkdownController

**Dry Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/02_DeployMarkdownController.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/02_DeployMarkdownController.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS \
  --broadcast --verify
```

**Save Output:**
```bash
export MARKDOWN_CONTROLLER_ADDRESS=<address_from_output>
```

#### 1.3 Deploy RewardsDistributor

**Dry Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/03_DeployRewardsDistributor.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/03_DeployRewardsDistributor.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS \
  --broadcast --verify
```

**Save Output:**
```bash
export REWARDS_DISTRIBUTOR_ADDRESS=<address_from_output>
```

```

#### 1.5 Deploy HelperV2

**Dry Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/05_DeployHelperV2.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/05_DeployHelperV2.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS \
  --broadcast --verify
```

**Save Output:**
```bash
export HELPER_V2_ADDRESS=<address_from_output>
```

---

### Phase 2: Deploy New Implementations (4 scripts)

These deploy new implementation contracts. **NO UPGRADES EXECUTED** - only deployment.

#### 2.1 Deploy MorphoCredit Implementation

**Dry Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/10_UpgradeMorphoCredit.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/10_UpgradeMorphoCredit.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS \
  --broadcast --verify
```

**Save Output:**
```bash
export MORPHO_CREDIT_IMPL=<address_from_output>
```

#### 2.2 Deploy IRM Implementation

**Dry Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/11_UpgradeIRM.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/11_UpgradeIRM.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS \
  --broadcast --verify
```

**Save Output:**
```bash
export IRM_IMPL=<address_from_output>
```

#### 2.3 Deploy USD3 Implementation

**Dry Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/12_UpgradeUSD3.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/12_UpgradeUSD3.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS \
  --broadcast --verify
```

**Save Output:**
```bash
export USD3_IMPL=<address_from_output>
```

#### 2.4 Deploy sUSD3 Implementation

**Dry Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/13_UpgradeSUSD3.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/13_UpgradeSUSD3.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS \
  --broadcast --verify
```

**Save Output:**
```bash
export SUSD3_IMPL=<address_from_output>
```

---

### Phase 3: Configure All Contracts (Single Safe Transaction)

**⚠️ IMPORTANT**: All Phase 3 configuration happens in ONE atomic Safe multisig transaction.

This batches 9 operations into a single transaction:
1. **MorphoCredit & CreditLine (2 operations):**
   - Set HelperV2 on MorphoCredit
   - Set MarkdownController on CreditLine

2. **ProtocolConfig (7 operations):**
   - Set FULL_MARKDOWN_DURATION (2 years default)
   - Set TRANCHE_RATIO (10000 = 100% default)
   - Set MIN_SUSD3_BACKING_RATIO (10000 = 100% default)
   - Set DEBT_CAP (7M USDC default)
   - Set USD3_SUPPLY_CAP (50M USDC default)
   - Set CURVE_STEEPNESS (1.5 default)
   - Set IRP (10% annual default)

#### Required Environment Variables

Ensure these are set before running:
- `MARKDOWN_CONTROLLER_ADDRESS` - from step 1.2
- `HELPER_V2_ADDRESS` - from step 1.5
- `MORPHO_ADDRESS` - MorphoCredit proxy
- `CREDIT_LINE_ADDRESS` - CreditLine contract
- `PROTOCOL_CONFIG` - ProtocolConfig contract
- `SAFE_ADDRESS` - Safe multisig address
- `WALLET_TYPE` - "account" or "local"
- `SAFE_PROPOSER_ACCOUNT` - Foundry account name (if WALLET_TYPE=account)

**Optional (use defaults if not set):**
- `FULL_MARKDOWN_DURATION` - default: 63072000 (2 years)
- `SUBORDINATED_DEBT_CAP_BPS` - default: 10000 (100%)
- `SUBORDINATED_DEBT_FLOOR_BPS` - default: 10000 (100%)
- `DEBT_CAP` - default: 7000000000000 (7M USDC)
- `USD3_SUPPLY_CAP` - default: 50000000000000 (50M USDC)
- `CURVE_STEEPNESS` - default: 1500000000000000000 (1.5)
- `IRP` - default: 3170979198 (10% annual)
- `BASE_FEE_LIMIT` - default: 50 (gwei)

#### Dry Run (Simulation)

**Always run simulation first** to verify all operations:

```bash
yarn script:forge script/operations/ConfigureV1_1Safe.s.sol \
  --sig "run(bool)" false \
  --sender $OWNER_ADDRESS
```

This will:
- Simulate all 12 operations
- Display transaction details
- Check base fee
- Verify all addresses are set correctly
- **NOT** send to Safe API

#### Wet Run (Propose to Safe)

After verifying simulation succeeds:

```bash
yarn script:forge script/operations/ConfigureV1_1Safe.s.sol \
  --sig "run(bool)" true \
  --sender $OWNER_ADDRESS \
  --broadcast
```

This will:
- Batch all 9 operations
- Sign with your proposer key
- Send transaction to Safe API
- Display Safe UI URL

#### After Proposing

1. **View in Safe UI**: Click the URL displayed in the output
2. **Multisig Approval**: Required signers must approve the transaction
3. **Execute**: Once threshold is reached, anyone can execute
4. **Verify**: All 9 operations execute atomically (all-or-nothing)

---

### Phase 4: Schedule Upgrades via Timelock

**⚠️ CRITICAL**: All proxy upgrades MUST be scheduled through TimelockController via Safe multisig.

**Two approaches available:**
- **Option A (Recommended)**: Schedule all 4 upgrades at once using `ScheduleAllUpgrades.s.sol` (simpler, single operation ID)
- **Option B**: Schedule each upgrade individually (more granular control)

#### 4.1 Get Current USD3 Fee Settings

Before scheduling upgrades, save current USD3 fee settings to restore later:

```bash
# Get current performance fee
cast call $USD3_ADDRESS "performanceFee()" --rpc-url $RPC_URL

# Get current profit unlock time
cast call $USD3_ADDRESS "profitMaxUnlockTime()" --rpc-url $RPC_URL

# Save values
export USD3_PREV_PERFORMANCE_FEE=<value_from_above>
export USD3_PREV_PROFIT_UNLOCK_TIME=<value_from_above>
```

---

#### Option A: Schedule All Upgrades at Once (Recommended)

**Single Timelock operation** containing all 4 ProxyAdmin upgrades:
- MorphoCredit ProxyAdmin.upgradeAndCall()
- IRM ProxyAdmin.upgradeAndCall()
- USD3 ProxyAdmin.upgradeAndCall()
- sUSD3 ProxyAdmin.upgradeAndCall()

**Advantages:**
- Single operation ID to track
- All upgrades execute together
- Simpler workflow

**Dry Run:**
```bash
yarn script:forge script/operations/ScheduleAllUpgrades.s.sol \
  --sig "run(address,address,address,address,bool)" \
  $MORPHO_CREDIT_IMPL $IRM_IMPL $USD3_IMPL $SUSD3_IMPL false \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/operations/ScheduleAllUpgrades.s.sol \
  --sig "run(address,address,address,address,bool)" \
  $MORPHO_CREDIT_IMPL $IRM_IMPL $USD3_IMPL $SUSD3_IMPL true \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS \
  --broadcast
```

**Save Operation ID from output** - You'll only have ONE operation ID for all 4 upgrades.

**Skip to Phase 5** if using this approach.

---

#### Option B: Schedule Each Upgrade Individually

Use this approach if you need granular control over individual upgrades.

##### 4.2 Schedule MorphoCredit Upgrade

**Dry Run (Simulation via Safe):**
```bash
yarn script:forge script/operations/ScheduleMorphoCreditUpgrade.s.sol \
  --sig "run(address,bool)" $MORPHO_CREDIT_IMPL false \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS
```

**Wet Run (Propose to Safe):**
```bash
yarn script:forge script/operations/ScheduleMorphoCreditUpgrade.s.sol \
  --sig "run(address,bool)" $MORPHO_CREDIT_IMPL true \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS \
  --broadcast
```

**Save Operation ID from output**

##### 4.3 Schedule IRM Upgrade

**Dry Run:**
```bash
yarn script:forge script/operations/ScheduleIRMUpgrade.s.sol \
  --sig "run(address,bool)" $IRM_IMPL false \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/operations/ScheduleIRMUpgrade.s.sol \
  --sig "run(address,bool)" $IRM_IMPL true \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS \
  --broadcast
```

**Save Operation ID from output**

##### 4.4 Schedule USD3 ProxyAdmin Upgrade

**⚠️ IMPORTANT**: This schedules ONLY the ProxyAdmin upgrade. The full atomic batch (9 operations) will be executed via Safe at execution time.

**Why Two Steps:**
- Timelock only owns ProxyAdmin, not USD3
- Safe multisig has management/keeper roles on USD3
- Safe batch wraps Timelock execution with USD3 operations at execution time

**Dry Run:**
```bash
yarn script:forge script/operations/ScheduleUSD3AtomicBatch.s.sol \
  --sig "run(address,bool)" $USD3_IMPL false \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/operations/ScheduleUSD3AtomicBatch.s.sol \
  --sig "run(address,bool)" $USD3_IMPL true \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS \
  --broadcast
```

**Save Operation ID from output**

**Scheduled Operation:**
- ProxyAdmin.upgradeAndCall(USD3_PROXY, newImplementation, "")

##### 4.5 Schedule sUSD3 Upgrade

**Dry Run:**
```bash
yarn script:forge script/operations/ScheduleSUSD3Upgrade.s.sol \
  --sig "run(address,bool)" $SUSD3_IMPL false \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/operations/ScheduleSUSD3Upgrade.s.sol \
  --sig "run(address,bool)" $SUSD3_IMPL true \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS \
  --broadcast
```

**Save Operation ID from output**

---

### Phase 5: Wait for Timelock Delay

**Timelock Delay: 2 days (172800 seconds)**

```bash
# Check when operations can be executed
# Each schedule operation output includes "Ready for execution at: <timestamp>"

# Convert to human readable
date -r <timestamp>

# Or check remaining time
cast block-number --rpc-url $RPC_URL
# Calculate: (execution_timestamp - current_timestamp) / 3600 = hours remaining
```

---

### Phase 6: Execute Scheduled Upgrades

After 2-day delay, execute scheduled operations. **Anyone can execute** once delay passes.

**Two approaches available (must match your scheduling approach):**

---

#### Option A: Execute All Upgrades at Once (If you used ScheduleAllUpgrades)

**⚠️ CRITICAL**: Use `ExecuteAllUpgrades.s.sol` to execute all 4 upgrades atomically via Safe.

This script creates a Safe batch with 7 operations:
1. USD3.setPerformanceFee(0)
2. USD3.setProfitMaxUnlockTime(0)
3. USD3.report() [BEFORE upgrade]
4. **Timelock.executeBatch()** → Upgrades all 4 implementations + USD3.reinitialize()
5. USD3.report() [AFTER reinitialize]
6. USD3.syncTrancheShare() [Sets performanceFee to TRANCHE_SHARE_VARIANT]
7. USD3.setProfitMaxUnlockTime(prevUnlockTime)

**Dry Run:**
```bash
yarn script:forge script/operations/ExecuteAllUpgrades.s.sol \
  --sig "run(bytes32,uint256,bool)" \
  <OPERATION_ID> $USD3_PREV_PROFIT_UNLOCK_TIME false \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/operations/ExecuteAllUpgrades.s.sol \
  --sig "run(bytes32,uint256,bool)" \
  <OPERATION_ID> $USD3_PREV_PROFIT_UNLOCK_TIME true \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS \
  --broadcast
```

**Note:** All 4 implementations upgrade + USD3.reinitialize() at step 4. The USD3 atomic batch prevents user losses during waUSDC → USDC migration.

**Skip to Verification** if using this approach.

---

#### Option B: Execute Each Upgrade Individually (If you scheduled individually)

Use this approach if you scheduled upgrades individually in Phase 4 Option B.

##### 6.1 Execute MorphoCredit Upgrade

**Dry Run:**
```bash
yarn script:forge script/operations/ExecuteTimelockViaSafe.s.sol \
  --sig "run(bytes32,bool)" <MORPHO_OPERATION_ID> false \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/operations/ExecuteTimelockViaSafe.s.sol \
  --sig "run(bytes32,bool)" <MORPHO_OPERATION_ID> true \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS \
  --broadcast
```

##### 6.2 Execute IRM Upgrade

**Dry Run:**
```bash
yarn script:forge script/operations/ExecuteTimelockViaSafe.s.sol \
  --sig "run(bytes32,bool)" <IRM_OPERATION_ID> false \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/operations/ExecuteTimelockViaSafe.s.sol \
  --sig "run(bytes32,bool)" <IRM_OPERATION_ID> true \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS \
  --broadcast
```

##### 6.3 Execute USD3 Atomic Batch

**⚠️ CRITICAL**: Use `ExecuteUSD3AtomicBatch.s.sol` to execute the full atomic batch via Safe.

This script creates a Safe batch with 7 operations:
1. USD3.setPerformanceFee(0)
2. USD3.setProfitMaxUnlockTime(0)
3. USD3.report() [BEFORE upgrade]
4. **Timelock.executeBatch()** → ProxyAdmin.upgradeAndCall() + USD3.reinitialize()
5. USD3.report() [AFTER reinitialize]
6. USD3.syncTrancheShare() [Sets performanceFee to TRANCHE_SHARE_VARIANT]
7. USD3.setProfitMaxUnlockTime(prevUnlockTime)

**Dry Run:**
```bash
yarn script:forge script/operations/ExecuteUSD3AtomicBatch.s.sol \
  --sig "run(bytes32,uint256,bool)" \
  <USD3_OPERATION_ID> $USD3_PREV_PROFIT_UNLOCK_TIME false \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/operations/ExecuteUSD3AtomicBatch.s.sol \
  --sig "run(bytes32,uint256,bool)" \
  <USD3_OPERATION_ID> $USD3_PREV_PROFIT_UNLOCK_TIME true \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS \
  --broadcast
```

##### 6.4 Execute sUSD3 Upgrade

**Dry Run:**
```bash
yarn script:forge script/operations/ExecuteTimelockViaSafe.s.sol \
  --sig "run(bytes32,bool)" <SUSD3_OPERATION_ID> false \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/operations/ExecuteTimelockViaSafe.s.sol \
  --sig "run(bytes32,bool)" <SUSD3_OPERATION_ID> true \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS \
  --broadcast
```

---

### Verify All Upgrades

**Check USD3 asset changed to USDC:**
```bash
cast call $USD3_ADDRESS "asset()" --rpc-url $RPC_URL
# Should return USDC address: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48

# Check totalAssets updated correctly
cast call $USD3_ADDRESS "totalAssets()" --rpc-url $RPC_URL
```

---

## Verification Commands

### Verify New Deployments

```bash
# Jane Token
cast call $JANE_ADDRESS "name()" --rpc-url $RPC_URL
cast call $JANE_ADDRESS "owner()" --rpc-url $RPC_URL

# HelperV2
cast call $HELPER_V2_ADDRESS "morphoCredit()" --rpc-url $RPC_URL
cast call $HELPER_V2_ADDRESS "usdc()" --rpc-url $RPC_URL
```

### Verify Upgrades

```bash
# MorphoCredit implementation
cast call $MORPHO_ADDRESS "implementation()" --rpc-url $RPC_URL
# Should return $MORPHO_CREDIT_IMPL

# IRM implementation
cast call $IRM_ADDRESS "implementation()" --rpc-url $RPC_URL
# Should return $IRM_IMPL

# USD3 implementation
cast call $USD3_ADDRESS "implementation()" --rpc-url $RPC_URL
# Should return $USD3_IMPL

# sUSD3 implementation
cast call $SUSD3_ADDRESS "implementation()" --rpc-url $RPC_URL
# Should return $SUSD3_IMPL
```

### Verify Configuration

```bash
# ProtocolConfig - check DEBT_CAP
cast call $PROTOCOL_CONFIG "config(bytes32)" \
  $(cast keccak "DEBT_CAP") --rpc-url $RPC_URL
# Should return 50000000000000 (50M waUSDC in 6 decimals)

# USD3 - check asset changed to USDC
cast call $USD3_ADDRESS "asset()" --rpc-url $RPC_URL
# Should return USDC: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```

---

## All-in-One Orchestration Script

For a complete dry run of Phase 1-3 only:

**Dry Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/DeployV1_1Upgrade.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS
```

**⚠️ Note**: This does NOT execute upgrades - only deploys implementations and configures contracts.
Upgrades must still be scheduled and executed via Timelock (Phases 4-7).

---

## Emergency Rollback

If issues occur after upgrade execution, proxy can be rolled back via Timelock:

1. Deploy previous implementation
2. Schedule downgrade via Safe → Timelock
3. Wait 2 days
4. Execute downgrade

**Note**: USD3 `reinitialize()` is one-way and cannot be easily rolled back.
