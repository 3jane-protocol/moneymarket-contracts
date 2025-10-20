# Audit Issues

## Summary

Total Issues: 19 (2 closed)
- **CRITICAL**: 2 (2 FIXED)
- **HIGH**: 0 (1 will not fix - contract removed)
- **MEDIUM**: 2 (1 will not fix)
- **LOW**: 3 (1 invalid, 1 will not fix)
- **INFORMATIONAL**: 9 (2 FIXED, 1 invalid)

**Sources**:
- Sherlock Competition: 3 issues (1 duplicate of Electisec #2)
- Electisec Report (https://github.com/electisec/moneymarket-report/): 17 issues

**Invalid Issues**: Electisec #1 (referral codes are opaque hashes), Electisec #10 (check exists in TokenizedStrategy), Electisec #13 (subordination is debt-based, not TVL-based)

**Will Not Fix**: Electisec #2 (PYTLocker contract removed), Electisec #8 (JANE non-transferable short-term), Electisec #16 (transfer whitelist bypass - accepted risk)

---

## CRITICAL Priority

### Sherlock Comp #21 - Market Creation DOS Vulnerability (FIXED)

**Status**: FIXED
**Date Fixed**: 2025-10-17
**Impact**: Critical - Attacker can permanently prevent creation of any market by frontrunning with ~20k gas

**Description**:
`accruePremiumsForBorrowers()` is an external function with no authorization checks. It calls `_accrueInterest()` which sets `market[id].lastUpdate = block.timestamp` even for non-existent markets. Since `createMarket()` checks if `market[id].lastUpdate != 0` and reverts with `MarketAlreadyCreated` if true, an attacker can permanently block any market creation by calling this function with a calculated market ID before the admin creates the market.

**Attack Vector**:
1. Admin announces new market with specific parameters
2. Attacker calculates the market ID: `keccak256(abi.encode(marketParams))`
3. Attacker frontruns admin's `createMarket` transaction
4. Attacker calls `accruePremiumsForBorrowers(id, [])` with empty array (~20k gas)
5. This sets `market[id].lastUpdate` without creating the market
6. Admin's `createMarket` now reverts with `MarketAlreadyCreated`
7. Market can never be created with those parameters

**Fix Implemented**:
Added market existence validation:

```solidity
function accruePremiumsForBorrowers(Id id, address[] calldata borrowers) external {
    if (market[id].lastUpdate == 0) revert ErrorsLib.MarketNotCreated();
    // ... rest of function
}
```

Note: The single-borrower `accrueBorrowerPremium()` method was subsequently removed to save bytecode size, leaving only the batch method.

**Files Modified**:
- src/MorphoCredit.sol:125-147

**Tests Added**:
- test/forge/usd3/regression/MarketCreationDOS.t.sol (comprehensive regression test suite)

**Test Coverage**:
- ✅ `test_fix_prevents_dos_accruePremiumsForBorrowers()` - Verifies attacker cannot DOS via batch function
- ✅ `test_legitimate_usage_after_fix()` - Verifies functions work correctly for existing markets
- ✅ `test_multiple_frontrun_attempts_blocked()` - Verifies repeated attacks are blocked
- ✅ `test_empty_array_reverts_for_non_existent_market()` - Verifies edge case handling
- ✅ `test_multiple_borrowers_revert_for_non_existent_market()` - Verifies batch function validation
- ✅ `test_attack_cost_is_minimal()` - Documents attack economic feasibility (~20k gas)

**Validation**:
- All 7 regression tests pass
- Full test suite: 1239 tests pass, 0 failures
- No regressions introduced

---

### Sherlock Comp #70 - Stale Markdown Burn Baseline Vulnerability (FIXED)

**Status**: FIXED
**Date Fixed**: 2025-10-17
**Impact**: Critical - Borrowers face accelerated JANE token burns on subsequent defaults due to stale baseline tracking

**Description**:
`MarkdownController` tracks JANE token burn state using `initialJaneBalance` and `janeBurned` mappings to calculate proportional burns during default periods. However, these state variables are never reset when a borrower exits Default status (returns to Current). This causes the burn mechanism to use stale baselines from previous default episodes, leading to disproportionate burn rates.

**Attack Vector / Unexpected Behavior**:
1. Borrower enters Default with 1000 JANE tokens
2. MarkdownController snapshots `initialJaneBalance[borrower] = 1000`
3. Some burns occur (e.g., 200 JANE burned)
4. Borrower repays obligation and exits Default (returns to Current status)
5. **Stale state remains**: `initialJaneBalance = 1000`, `janeBurned = 200`
6. Borrower transfers out 500 JANE tokens (now holds 300 JANE)
7. Borrower defaults again
8. Burns continue from stale baseline of 1000 JANE instead of fresh 300 JANE
9. **Result**: Burns happen at ~3.3x the expected rate (1000/300)

**Fix Implemented**:
Added `resetBorrowerState()` function to `MarkdownController` and integrated it into status transition logic:

```solidity
// IMarkdownController.sol
function resetBorrowerState(address borrower) external;

// MarkdownController.sol
function resetBorrowerState(address borrower) external override onlyMorpho {
    initialJaneBalance[borrower] = 0;
    janeBurned[borrower] = 0;
    emit BorrowerStateReset(borrower);
}

// MorphoCredit.sol - _updateBorrowerMarkdown()
bool isInDefault = status == RepaymentStatus.Default && statusStartTime > 0;
bool wasInDefault = lastMarkdown > 0;

if (isInDefault && !wasInDefault) {
    IMarkdownController(manager).resetBorrowerState(borrower);  // Reset on entry
    emit EventsLib.DefaultStarted(id, borrower, statusStartTime);
} else if (!isInDefault && wasInDefault) {
    IMarkdownController(manager).resetBorrowerState(borrower);  // Reset on exit
    emit EventsLib.DefaultCleared(id, borrower);
}
```

**Files Modified**:
- src/interfaces/IMarkdownController.sol:56-57 (interface)
- src/MarkdownController.sol:215-226 (implementation)
- src/MorphoCredit.sol:732-737 (integration)

**Tests Added**:
- test/forge/usd3/regression/StaleMarkdownBurnBaseline.t.sol (comprehensive regression test suite)

**Test Coverage**:
- ✅ `test_fix_prevents_accelerated_burns()` - Main vulnerability test demonstrating proportional burns after fix
- ✅ `test_baseline_resets_on_default_entry()` - Verifies baseline resets when entering Default status
- ✅ `test_baseline_resets_on_default_exit()` - Verifies baseline resets when exiting Default status
- ✅ `test_multiple_default_episodes_with_varying_jane()` - Tests multiple default episodes with different JANE balances
- ✅ `test_zero_jane_balance_handling()` - Edge case: borrower with zero JANE balance

**Validation**:
- All 5 regression tests pass
- Burn rates are now proportional to current JANE holdings in each default episode
- No regressions introduced
- Baseline tracking is fresh for each new default episode

---

## HIGH Priority

### Electisec #2 - Pendle YT tokens interests are lost during lock period

**Duplicate**: Sherlock Competition #35 (same root cause and impact)

**Status**: WILL NOT FIX
**Impact**: None - Contract removed from codebase

**Description**:
The `PYTLocker` contract locks Pendle Yield Tokens (YT) until their expiry but fails to handle the yield accrual mechanism. When users deposit YT tokens, the contract becomes the holder and receives the right to claim all yield payments, but these yields are never distributed back to the original depositors, resulting in permanent loss of yield.

**Resolution**: The PYTLocker contract and all associated tests have been removed from the codebase. The contract will not be deployed, resolving this issue by eliminating the affected code entirely.

**No Action Required**

---

## MEDIUM Priority

### Electisec #8 - JANE burn mechanism is unfair and gameable

**Status**: WILL NOT FIX (Short-term)
**Impact**: Medium - The burn mechanism can be exploited by strategic actors

**Description**:
The JANE burn mechanism has multiple flaws:

1. **Snapshot timing issue**: `MarkdownController.burnJaneProportional()` takes a snapshot of the borrower's balance only at the time of the first burn. Any JANE received after the snapshot is not incorporated into the target burn, causing systematic under-penalization.

2. **Transfer avoidance**: Once transfers are globally enabled, borrowers can transfer their JANE tokens to other addresses before entering delinquent/default status, effectively avoiding the penalty mechanism.

3. **Debt-agnostic penalty**: Two borrowers with equal JANE balances but very different outstanding debts accrue the same burn curve, which is not proportional to credit risk contribution.

**Note**: JANE will be non-transferable in the short term, which eliminates the transfer avoidance vector (flaw #2). A better burn mechanism addressing all three flaws will be designed for the longer term when transfers are enabled.

**Recommendation**:
Consider one of the following approaches for future implementation:

**Option A**: Replace liquid JANE emissions with a non-transferable, vesting reward token (e.g. `veJANE`):
- Have the penalty mechanism burn unvested veJANE
- Upon entering delinquent/default status, immediately stop vesting and farming
- Take a deterministic snapshot at the state transition
- Optionally scale the penalty by outstanding debt for better fairness

**Option B**: Allow burning not yet claimed JANE:
- Implement function that helps burn unclaimed JANE from the RewardsDistributor using a Merkle proof

**No Immediate Action Required**

---

### Electisec #11 - Cooldown restart allows users to bypass cooldown mechanism

**Status**: DEFERRED
**Impact**: Medium - Users can maintain withdrawal readiness at all times without opportunity cost
**GitHub Issue**: https://github.com/3jane-protocol/moneymarket-contracts/issues/87

**Description**:
Users can repeatedly call `cancelCooldown()` and `startCooldown()` to reset their cooldown timer while maintaining shares in an active cooldown state. This allows them to:

1. Keep shares "ready for withdrawal" without any opportunity cost
2. Continue earning yield during the cooldown period
3. Maintain a rolling cooldown window by calling `startCooldown()` every few days

When they actually want to withdraw, they only need to wait from their most recent `startCooldown()` call.

**Note**: This issue is legitimate and will be fixed in a subsequent release (not v1.1).

**Recommendation**:
Implement a snapshot mechanism where shares in cooldown don't earn new yield but are still exposed to losses:

**Key principle**:
- If share price **increases** during cooldown → user only gets the snapshotted value (no yield gains)
- If share price **decreases** during cooldown → user is affected by losses (first-loss protection still works)

**Implementation**:

1. Update the `UserCooldown` struct to include snapshotted assets:
```solidity
struct UserCooldown {
    uint64 cooldownEnd;        // When cooldown expires
    uint64 windowEnd;          // When withdrawal window closes
    uint128 shares;            // Shares locked for withdrawal
    uint256 snapshotAssets;    // Asset value when cooldown started (NEW)
}
```

2. Modify `startCooldown()` to snapshot the current value
3. Update `availableWithdrawLimit()` to use minimum of snapshot and current value
4. Update `cancelCooldown` to burn shares to maintain the same number of underlying

**Note**: When a user withdraws with the snapshot mechanism and the share price has increased:
- User receives `snapshotAssets` (lower than current value)
- But `shares` are burned from the total supply
- The difference remains in the contract and immediately increases the price per share for remaining users

**Action Items**:
- See GitHub issue #87 for tracking (deferred to subsequent release)

---

### Electisec #13 - USD3 withdrawals ignore sUSD3 subordination constraints

**Status**: INVALID
**Impact**: None - Issue is based on incorrect understanding of subordination model

**Description**:
`USD3.availableWithdrawLimit()` returns liquidity based only on idle funds, market liquidity, and commitment time. It does not enforce any junior subordination constraint, allowing withdrawals that can violate tranche policy.

**Why Invalid**:
The subordination model is **debt-based, not TVL-based**. The constraint is:
```
sUSD3 TVL ≤ (market debt × maxSubordinationRatio)
```

USD3 withdrawals reduce USD3 supply but **do not affect market debt**. Therefore, USD3 withdrawals cannot violate subordination constraints. The constraint is enforced on sUSD3 deposits (which must check if additional subordinate capital would exceed the ratio based on current debt), not on USD3 withdrawals.

See test/forge/usd3/regression/DebtBasedSubordinationLimits.t.sol:22-26 for confirmation:
```solidity
 * The new model works as follows:
 * 1. sUSD3 deposits are limited by: min(actualDebt, potentialDebt) * maxSubordinationRatio
 * 2. USD3 withdrawals are NOT limited by subordination ratio (only by liquidity and MAX_ON_CREDIT)
```

**No Action Required**

---

## LOW Priority

### Electisec #16 - USD3 transfer checks ignore whitelist in `_preTransferHook`

**Status**: WILL NOT FIX
**Files**: src/usd3/USD3.sol:506

**Description**:
The `_preTransferHook()` function in USD3 enforces commitment period restrictions but does not validate whitelist requirements when `whitelistEnabled` is true. This allows whitelisted users to transfer their USD3 shares to non-whitelisted addresses, effectively bypassing the whitelist access control.

**Recommendation**:
Add whitelist validation to `_preTransferHook()` when whitelist is enabled.

**No Action Required**

---

### Electisec #1 - Helper.deposit() and Helper.borrow() functions allow self-referral

**Status**: INVALID
**Impact**: None - Issue is based on incorrect assumption

**Description**:
`Helper.deposit()` and `Helper.borrow()` with referral parameters accept any address without validation. Users can pass their own address, allowing them to self-refer and potentially claim referral rewards they shouldn't be entitled to.

**Files**:
- src/Helper.sol:59 (`deposit()`)
- src/Helper.sol:84 (`borrow()`)

**Why Invalid**:
Referral codes will be generated off-chain and be opaque, likely something like `keccak256(SALT + address)`. Users cannot self-refer because they won't know their own referral code mapping.

**No Action Required**

---

### Electisec #14 - Commitment period can be retroactively modified

**Status**: OPEN
**Impact**: Low - Changes to minCommitmentTime affect existing depositors retroactively

**Description**:
The USD3 contract enforces a minimum commitment period to prevent users from withdrawing immediately after depositing. However, the implementation stores only the `depositTimestamp` and dynamically calculates the commitment end time by reading `minCommitmentTime()` from the ProtocolConfig. Since `minCommitmentTime()` reads from ProtocolConfig, any changes to this parameter will retroactively affect all existing depositors.

**Recommendation**:
Store the commitment end timestamp directly instead of recalculating it dynamically.

**Action Items**:
- [ ] Update storage to include commitmentEndTimestamp
- [ ] Modify deposit logic to store the calculated end time
- [ ] Update withdrawal checks to use stored timestamp
- [ ] Write migration tests
- [ ] Verify existing depositors are not affected

---

## INFORMATIONAL

### Electisec #3 - RewardsDistributor.Claimed event emits incorrect user total claimed (FIXED)

**Status**: FIXED
**Date Fixed**: 2025-10-17
**Files**: src/jane/RewardsDistributor.sol:190

**Description**:
The `Claimed` event docs state the third parameter is "The total amount the user has claimed after this claim", but the emission passes `totalAllocation` instead of the updated user total claimed.

**Fix Implemented**:
```solidity
// Update claimed amount
uint256 newTotalClaimed = alreadyClaimed + claimable;
claimed[user] = newTotalClaimed;
totalClaimed += claimable;

// ... token distribution ...

emit Claimed(user, claimable, newTotalClaimed);
```

**Gas Optimization**: Cached the calculated value in `newTotalClaimed` to avoid an extra SLOAD when emitting the event.

**Test Coverage**:
- ✅ `test_fix_claimedEventEmitsCorrectTotal()` - Verifies event emits cumulative claimed amount through multiple claim cycles

**Validation**:
- Event now correctly emits the user's total claimed amount after each claim
- No regressions in existing tests

---

### Electisec #4 - RewardsDistributor.getClaimable() ignores global cap (FIXED)

**Status**: FIXED
**Date Fixed**: 2025-10-17
**Files**: src/jane/RewardsDistributor.sol:199-207

**Description**:
`getClaimable()` returns the user's uncapped delta `totalAllocation - claimed[user]` but ignores the global cap based on `maxClaimable - totalClaimed`. The cap is only enforced during `_claim()`.

**Fix Implemented**:
```solidity
function getClaimable(address user, uint256 totalAllocation) external view returns (uint256) {
    if (maxClaimable == 0 || totalClaimed >= maxClaimable) return 0;

    uint256 alreadyClaimed = claimed[user];
    uint256 unclaimed = totalAllocation > alreadyClaimed ? totalAllocation - alreadyClaimed : 0;

    uint256 remaining = maxClaimable - totalClaimed;
    return unclaimed > remaining ? remaining : unclaimed;
}
```

**Test Coverage**:
- ✅ `test_fix_getClaimableRespectsGlobalCap()` - Verifies getClaimable returns 0 when cap exhausted
- ✅ `test_fix_getClaimablePartialRemaining()` - Verifies getClaimable returns min(unclaimed, remaining) when partially capped
- ✅ `test_fix_getClaimableZeroCap()` - Verifies getClaimable returns 0 when maxClaimable is 0

**Validation**:
- getClaimable now accurately reflects the actual claimable amount respecting global cap
- View function now matches the behavior of the actual claim function
- No regressions in existing tests

---

### Electisec #5 - Unnecessary cast

**Status**: OPEN (Partial - CreditLine will not fix)

**Locations**:
- ~~src/CreditLine.sol:218~~ (CreditLine already deployed, will not fix)
- src/irm/adaptive-curve-irm/AdaptiveCurveIrm.sol:189
- src/usd3/USD3.sol:713

**Description**:
Variables are being cast to their own type.

**Note**: CreditLine.sol is already deployed and this informational issue does not warrant a contract redeployment.

**Action Items**:
- [ ] Remove unnecessary cast in AdaptiveCurveIrm.sol:189
- [ ] Remove unnecessary cast in USD3.sol:713

---

### Electisec #6 - Unused import

**Status**: OPEN (Partial - CreditLine will not fix)

**Locations**:
- ~~src/CreditLine.sol:8 - `EventsLib`~~ (CreditLine already deployed, will not fix)
- src/MorphoCredit.sol:18 - `IMorphoRepayCallback`
- src/MorphoCredit.sol:27 - `WAD` from MathLib
- src/irm/adaptive-curve-irm/AdaptiveCurveIrm.sol:11 - `ConstantsLib`
- src/irm/adaptive-curve-irm/AdaptiveCurveIrm.sol:16 - `ReserveDataLegacy`
- src/usd3/sUSD3.sol:4 - `SafeERC20`

**Note**: CreditLine.sol is already deployed and this informational issue does not warrant a contract redeployment.

**Action Items**:
- [ ] Remove unused imports from MorphoCredit.sol (2 items)
- [ ] Remove unused imports from AdaptiveCurveIrm.sol (2 items)
- [ ] Remove unused import from sUSD3.sol

---

### Electisec #7 - Missing event emission

**Status**: OPEN (Partial - CreditLine will not fix)

**Description**:
The following setters are missing events:

**CreditLine** (already deployed, will not fix):
- ~~setOzd() - src/CreditLine.sol:79~~
- ~~setMm() - src/CreditLine.sol:90~~
- ~~setProver() - src/CreditLine.sol:102~~
- ~~setInsuranceFund() - src/CreditLine.sol:112~~

**MorphoCredit**:
- setHelper() - src/MorphoCredit.sol:113
- setUsd3() - src/MorphoCredit.sol:118

**Note**: CreditLine.sol is already deployed and this informational issue does not warrant a contract redeployment.

**Action Items**:
- [ ] Add event for setHelper()
- [ ] Add event for setUsd3()

---

### Electisec #10 - sUSD3.availableDepositLimit() should return zero during shutdown

**Status**: INVALID
**Files**: src/usd3/sUSD3.sol:250

**Description**:
When `sUSD3` strategy is in shutdown, `sUSD3.availableDepositLimit()` still reports deposit capacity. This can mislead integrators and UIs into showing that deposits are possible, despite shutdown normally disabling deposits at execution time.

**Why Invalid**:
The check already exists in the TokenizedStrategy base contract at https://github.com/yearn/tokenized-strategy/blob/master/src/TokenizedStrategy.sol#L874. The base implementation handles shutdown state correctly, making this additional check redundant.

**No Action Required**

---

### Electisec #12 - Cap cover to borrower's total debt instead of assets in CreditLine.settle()

**Status**: WILL NOT FIX
**Files**: ~~src/CreditLine.sol:204~~

**Description**:
`CreditLine.settle()` accepts an `assets` parameter that should represent the assets to settle. However, the function always settles the full position and optionally repays using `cover`, which is passed directly without capping it to `assets`. The `cover` parameter should be capped to the borrower's actual outstanding debt.

**Note**: CreditLine.sol is already deployed and this informational issue does not warrant a contract redeployment.

**Recommendation**:
- Compute the borrower's current debt
- Cap `cover` to that amount
- Remove `assets` from the signature to avoid ambiguity

**No Action Required**

---

### Electisec #15 - Code duplicate

**Status**: OPEN
**Files**: src/Helper.sol:144-145

**Description**:
A function already exists to wrap USDC into WAUSDC (`_wrap()`); it's used as part of repay, but not for full repay.

**Current code**:
```solidity
IERC20(USDC).safeTransferFrom(msg.sender, address(this), usdcNeeded);
IERC4626(WAUSDC).deposit(usdcNeeded, address(this));
```

**Should be**:
```solidity
_wrap(msg.sender, usdcNeeded);
```

**Action Items**:
- [ ] Replace duplicate code with _wrap() call
- [ ] Verify tests still pass

---

### Electisec #17 - Update misleading comment about subordination ratio enforcement

**Status**: OPEN
**Files**: src/usd3/sUSD3.sol:247

**Description**:
NatSpec comment in `sUSD3.availableDepositLimit()` states the subordination ratio is enforced relative to USD3 total supply, but the implementation uses market debt as the base.

**Recommendation**:
Update comments to reflect debt-based subordination enforcement.

**Action Items**:
- [ ] Update NatSpec comments in sUSD3.sol:247
- [ ] Verify comment accurately describes debt-based subordination

---

## Closed Issues

### Electisec #9 - sUSD3.availableWithdrawLimit() over-reports per-user limit during shutdown

**Status**: CLOSED
**Date Closed**: 2025-10-14

---

## Work Tracking

### Phase 1: Quick Fixes (Informational)
- [ ] Electisec #17 - Update misleading comment (simplest)
- [ ] Electisec #15 - Code duplicate
- [ ] Electisec #5 - Unnecessary casts (2 locations, CreditLine skipped)
- [ ] Electisec #6 - Unused imports (5 locations, CreditLine skipped)
- [x] Electisec #3 - Fix Claimed event (FIXED)
- [x] Electisec #4 - Fix getClaimable() (FIXED)
- [ ] Electisec #7 - Add missing events (2 functions, CreditLine skipped)
- ~~[ ] Electisec #12 - CreditLine.settle() improvements~~ (CreditLine already deployed, will not fix)

### Phase 2: Security Fixes (Low/Medium)
- [ ] Electisec #14 - Fix commitment period storage
- ~~[ ] Electisec #11 - Fix cooldown restart exploit~~ (Deferred to subsequent release, tracked in #87)

### Completed / Will Not Fix
- [x] Sherlock Comp #21 - Market Creation DOS (FIXED)
- [x] Sherlock Comp #70 - Stale Markdown Burn Baseline (FIXED)
- ~~[ ] Electisec #8 - JANE burn redesign~~ (Will not fix - JANE non-transferable short-term)
- ~~[ ] Electisec #2 - PYTLocker yield distribution~~ (Will not fix - contract removed)

---

## Notes

- Electisec #9 is closed and does not require action
- Electisec #1, #10, and #13 are invalid
- Electisec #8 and #2 require design decisions and team discussion before implementation
- All other issues have clear remediation paths
- Recommend tackling in order: Informational → Low → Medium → High
- Each fix should include comprehensive tests and regression prevention
