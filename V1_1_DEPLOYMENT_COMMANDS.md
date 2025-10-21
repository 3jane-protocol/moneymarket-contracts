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

### Phase 1: Deploy New Contracts (5 scripts)

These deploy new immutable contracts. No upgrades involved.

#### 1.1 Deploy Jane Token

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

#### 1.4 Deploy PYTLocker (Optional)

**Dry Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/04_DeployPYTLocker.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/04_DeployPYTLocker.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS \
  --broadcast --verify
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

### Phase 3: Configure Contracts (3 scripts)

Configure newly deployed contracts with roles and parameters.

#### 3.1 Configure Jane Token

**Dry Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/20_ConfigureJane.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/20_ConfigureJane.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS \
  --broadcast
```

#### 3.2 Configure MorphoCredit

**Dry Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/21_ConfigureMorphoCredit.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/21_ConfigureMorphoCredit.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS \
  --broadcast
```

#### 3.3 Configure ProtocolConfig

**Dry Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/22_ConfigureProtocolConfig.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/deploy/upgrade/v1.1/22_ConfigureProtocolConfig.s.sol \
  --account 3jane-p-deployer \
  --sender $OWNER_ADDRESS \
  --broadcast
```

---

### Phase 4: Schedule Upgrades via Timelock

**⚠️ CRITICAL**: All proxy upgrades MUST be scheduled through TimelockController via Safe multisig.

#### 4.1 Get Current USD3 Fee Settings

Before scheduling USD3 batch, save current fee settings to restore later:

```bash
# Get current performance fee
cast call $USD3_ADDRESS "performanceFee()" --rpc-url $RPC_URL

# Get current profit unlock time
cast call $USD3_ADDRESS "profitMaxUnlockTime()" --rpc-url $RPC_URL

# Save values
export USD3_PREV_PERFORMANCE_FEE=<value_from_above>
export USD3_PREV_PROFIT_UNLOCK_TIME=<value_from_above>
```

#### 4.2 Schedule MorphoCredit Upgrade

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

#### 4.3 Schedule IRM Upgrade

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

#### 4.4 Schedule USD3 Atomic Batch (8 Operations)

**⚠️ MOST CRITICAL**: This schedules 8 atomic operations to prevent user losses.

**Dry Run:**
```bash
yarn script:forge script/operations/ScheduleUSD3AtomicBatch.s.sol \
  --sig "run(address,uint16,uint256,bool)" \
  $USD3_IMPL $USD3_PREV_PERFORMANCE_FEE $USD3_PREV_PROFIT_UNLOCK_TIME false \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/operations/ScheduleUSD3AtomicBatch.s.sol \
  --sig "run(address,uint16,uint256,bool)" \
  $USD3_IMPL $USD3_PREV_PERFORMANCE_FEE $USD3_PREV_PROFIT_UNLOCK_TIME true \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS \
  --broadcast
```

**Save Operation ID from output**

**Atomic Batch Operations:**
1. setPerformanceFee(0)
2. setProfitMaxUnlockTime(0)
3. report() [BEFORE upgrade]
4. ProxyAdmin.upgrade()
5. reinitialize()
6. report() [AFTER reinitialize]
7. syncTrancheShare()
8. setPerformanceFee(prevFee)

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

#### 6.1 Execute MorphoCredit Upgrade

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

#### 6.2 Execute IRM Upgrade

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

#### 6.3 Execute USD3 Atomic Batch

**Dry Run:**
```bash
yarn script:forge script/operations/ExecuteTimelockViaSafe.s.sol \
  --sig "run(bytes32,bool)" <USD3_OPERATION_ID> false \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS
```

**Wet Run:**
```bash
yarn script:forge script/operations/ExecuteTimelockViaSafe.s.sol \
  --sig "run(bytes32,bool)" <USD3_OPERATION_ID> true \
  --account 3jane-p-deployer \
  --sender $SAFE_ADDRESS \
  --broadcast
```

**Verify USD3 Upgrade:**
```bash
# Check new asset is USDC (not waUSDC)
cast call $USD3_ADDRESS "asset()" --rpc-url $RPC_URL
# Should return USDC address: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48

# Check totalAssets updated correctly
cast call $USD3_ADDRESS "totalAssets()" --rpc-url $RPC_URL
```

---

### Phase 7: Schedule & Execute sUSD3 Upgrade

**⚠️ IMPORTANT**: Must wait until USD3 upgrade is FULLY COMPLETE before scheduling sUSD3.

#### 7.1 Schedule sUSD3 Upgrade

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

#### 7.2 Wait 2 Days

#### 7.3 Execute sUSD3 Upgrade

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
