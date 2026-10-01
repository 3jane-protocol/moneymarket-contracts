# Deferred: F-04 part 2 — dead-tranche recapitalization

**NOT IMPLEMENTED — deliberately deferred.** This is a commit-pinned decision record, frozen as of commit `3348afb5`; every file/line citation resolves at that commit. It exists so the design and its validation are never re-researched. F-04 **part 1** (blocking sUSD3 deposits while accounting is stale, `sUSD3.sol:254`) *is* implemented and merged; only part 2 is deferred. Code-anchored claims here are frozen facts; governance topology (timelock durations, keeper set, `TRANCHE_SHARE_VARIANT` and `MIN_SUSD3_BACKING_RATIO` values) is deployment state and must be re-verified before acting on anything below.

## The condition

When a MorphoCredit loss exceeds sUSD3's USD3 balance, `_postReportHook` (`USD3.sol:577`) burns sUSD3's entire balance — the burn is capped at that balance (`:593-595`) and executed via `_burnSharesFromSusd3` (`:599`, defined `:633`) — wiping the junior tranche to exactly zero and socializing the remainder to USD3 seniors. sUSD3 reports its USD3 balance as total assets (`sUSD3.sol:125`), so after it reports it holds zero assets with shares outstanding. Three consequences follow:

**Scope carve-out — positive-but-negligible PPS.** This record and the associated operations-runbook procedure address
only the exact zero-asset state above. They do not cover the round-4 `B/H-01` state in which sUSD3 still has positive
assets but its PPS is negligible. A positive balance does not satisfy this design's zero-asset gates, and the dead-
tranche runbook must not be applied to that state. Establish exact zero assets before relying on anything below.

1. **The tranche cannot be recapitalized.** With zero total assets and supply outstanding, `TokenizedStrategy` converts deposits to zero shares and reverts (`ZERO_SHARES`; the mint path reverts `ZERO_ASSETS`).
2. **Senior deployment freezes.** `_subordinationDeployCapWaUSDC` returns 0 whenever sUSD3 holds no USD3 shares (`USD3.sol:195`; only while `MIN_SUSD3_BACKING_RATIO` is nonzero, `:189`), so the effective cap is 0 and every tend/report recalls deployed funds.
3. **Recovery routes to a dead class.** The tranche share mints to the performance-fee recipient, which is sUSD3, so restitution owed to the seniors who absorbed the excess loss accrues to a worthless share class and revives it at negligible price per share.

## Decision, and why

Deferred. Three verified facts and one judgement carry it:

- **USD3 degrades rather than breaks** (fact). With a zero cap, `_applyDeployCap` withdraws from MorphoCredit bounded by available liquidity and cannot revert (`_withdrawFromMorpho` caps at `min(position, liquidity)` and returns 0 when none, `USD3.sol:411-414`), so reports complete and senior withdrawals stay live — the `availableWithdrawLimit` halt gate fires only on unrealized *loss* (`nav() + 2 < totalAssets`, `:456`), never in the profit direction. The recall is liquidity-bounded, not total: borrowed funds return only as borrowers repay, drained progressively by `_tendTrigger`, which stays armed while anything remains deployed (`:375`).
- ~~**The facility stops writing new credit; it does not stop earning** (fact).~~ **CORRECTED — see the correction note below. The first clause is false.** Recalled waUSDC does keep accruing Aave passive yield and the legacy borrow book keeps accruing interest, so the earning half stands.
- ~~**Consequences 1 and 2 are static** (fact).~~ **CORRECTED — see below. Consequence 2 is not static.** What survives: both contracts are upgradeable behind the 7-day timelock, so an upgrade months later still achieves what one now would, and deferring costs foregone spread rather than recoverability.
- **The urgency call** (judgement): a facility earning passive yield with live senior exits is materially different from a bricked vault, so this does not warrant an emergency ship. **This judgement still holds, but on narrower grounds than originally written** — see the correction.

### Correction — two "facts" above were wrong (Guardian round 4, `B/M-25`)

Guardian's `B/M-25` falsifies the premises, not the deferral. Recorded here because this document exists so
the analysis is never re-researched, and re-researching it from the uncorrected text would reproduce the
error.

**"The facility stops writing new credit" is false.** A wiped junior tranche drives
`_subordinationDeployCapWaUSDC` to zero (`src/usd3/USD3.sol:191-209`) and report/tend recall available
liquidity — but nothing stops a *borrower* drawing. A Morpho repayment returns waUSDC and reduces debt
before token collection (`src/Morpho.sol:275-305`), and `_beforeBorrow` (`src/MorphoCredit.sol:601-632`)
checks helper, wind-down, core pause, cycle status, debt cap and minimum borrow — but never USD3's live
junior cap or a pending recall. A Current borrower with headroom can therefore reborrow the liquidity a
repayment just recreated, before tend runs. Credit keeps being written from a dead tranche.

**"Consequences 1 and 2 are static" is false for consequence 2.** The zero cap is not a pure function of the
wiped state: repayment recreates borrowable liquidity, so the gap between the zero cap and actual deployed
exposure drifts with borrower activity while the tranche sits dead. Consequence 1 (deposit rejection) is
genuinely static.

**What this changes.** The deferral itself survives — the exposure is dormant at
`MIN_SUSD3_BACKING_RATIO = 0`, since the "wipe drives the cap to zero" policy is disabled outright, and the
repayment subsystem is unused. But the *procedure* was wrong: before any wipe-and-recall sequence, require
`IS_PAUSED` or `DEBT_CAP = 0` so the recreated liquidity cannot be redrawn. A structural fix — a borrow
admission check against USD3's live cap or a pending recall — is a **prerequisite of ever setting a nonzero
backing ratio with live credited borrowers**, not of today. Note it would sit in MorphoCredit; margin is
386 bytes as of `d0d7bb37` (it was 29 before the premium rewrite).

Consequence 3 is the only irreversible leg and is handled operationally: set `TRANCHE_SHARE_VARIANT` to 0 (`ProtocolConfig.setConfig`, `:83`, owner = 24h params timelock), then keeper-call `USD3.syncTrancheShare()` (`USD3.sol:793`). See `docs/operations-runbook.md`. Sizing the exposure precisely:

- Any **profitable** report after the wipe leaks its tranche share. Ordinary interest (Aave yield on recalled funds, legacy borrow interest) makes the next report profitable, so a trickle leak starts immediately — bounded by trancheShare × interest accrued over the window, not zero.
- The **material** leak — restitution of marked-down principal — requires markdown reversal, which lands the moment a defaulted borrower repays (`MorphoCredit._updateBorrowerMarkdown` runs on repay, `MorphoCredit.sol:647`, `:673`). Any "days to weeks" expectation is a judgement about deep-default borrower behavior, not a mechanism.
- The **controlling fact**: `report()` is keeper-or-management-gated (TokenizedStrategy `onlyKeepers`), so no third party can force the leak. Withholding reports until the fee bits are verified zero is cheap — the withdraw halt gate does not fire on pending profit. The residual is protocol-side report discipline during the timelock window, not a race against outsiders.
- The wipe is loud: the wipe report recalls all available liquidity in the same transaction, the tend trigger stays armed, and the burn emits a full-balance `Transfer` to zero.

Once the fee bits are zero, recovery accrues to seniors through PPS — with the targeting imprecision noted under open questions.

A narrower code fix was designed and also declined: gating the tranche-share mint on sUSD3 holding zero shares, inside the existing `report()` override, using the same slot and mask `syncTrancheShare` already writes. Roughly 60–100 runtime bytes, no new storage. Rejected as low value given the runbook covers the same window. **If the deferral is revisited and only the irreversible leg matters, this is the cheap option — not the full design below.**

## The full design, if re-opened

Three components, revised once and independently validated.

**1. `sUSD3.resetDeadTranche(address[] holders)`, `onlyManagement`.** Zeroes dangling share supply so the next deposit mints 1:1 at PPS 1. Gate tracked `totalAssets` and raw idle USD3 balance **separately**, both in USD3-token units — sUSD3's asset *is* USD3, so they are already commensurable and no conversion belongs here. Zero raw supply and tracked assets atomically, or the first recapitalizing depositor gains a windfall from stale dust. Include `address(this)` in the holder list when locked profit shares exist.

**2. Subordination cap unchanged.** Returning 0 when sUSD3 holds no shares is correct de-risked policy, not a defect; it reopens organically once recapitalization works. Do **not** rely on setting `MIN_SUSD3_BACKING_RATIO` to 0, which removes the first-loss buffer exactly when tail risk has materialized.

**3. `seniorLossCarry` in USD3** — one appended slot, gap 37→36. Accrue the uncovered loss when the burn cap binds, then pre-scale the tranche-share fee bits to `fee × (E − carry) / E` for one report so juniors keep their share on profit beyond the carry. A `seedSeniorLossCarry` management function covers a wipe that predates the upgrade, where accrual could not have run. Splitting the report and post-hoc minting were both evaluated and rejected: the first needs an intermediate write to live accounting, the second must replicate the fee formula and the protocol-fee carve-out.

Storage: USD3 +1 slot, sUSD3 none, clean implementation swap for both proxies.

## Validation findings — do not rediscover

Two claims from the first design pass were checked independently and **corrected**:

- **The `susd3Balance > 0` early-out at `USD3.sol:582` is not a defect.** With a zero balance the burn cap (`:593-595`) would force `sharesToBurn = 0`, so the guarded block and the fall-through are identical in effect; no storage write, event, or accumulator is skipped, and uncovered loss has never been materialized as a value. **But it is a forward-looking constraint on this remediation:** carry accrual written *inside* that block would never run exactly when the tranche is wiped. It must sit above the guard, and must also capture the **partial**-cover truncation at `:593-595` — the full wipe is only the tail of that same bucket.
- **The unlock-state guard is load-bearing, not belt-and-braces.** Zeroing raw supply while `fullProfitUnlockDate` is in the future makes `_unlockedShares()` positive against a zero supply, so `_totalSupply()` underflows and every view reverts. The full-loss report *does* clear the unlock machinery, but that does not make the state unreachable: USD3 wipes sUSD3 by writing USD3's own slots, leaving sUSD3's unlock state untouched until sUSD3 itself reports — the stale window part 1 guards. `profitMaxUnlockTime` defaults to ten days and sUSD3 receives yield as USD3's fee recipient, so the date is very likely in the future there. **Preferred gate:** require `unlockedShares() == 0` and `totalAssets() == 0` rather than zeroing the rate and date directly — correct by construction, and avoids extra writes to upgrade-frozen storage.

Also established: the exhaustive holder loop with `require(burned == rawSupply)` is **safety-critical**. Without it, legacy balances redeem pro-rata against a new depositor's principal, and because `_burn` decrements supply inside `unchecked`, a phantom redeem wraps to ~2²⁵⁶ rather than reverting. Zeroing supply alone converts a stuck tranche into a drainable one.

## Open questions if re-opened

- The `nav()` prediction drift bound for the straddling report is argued from reading `_wrapUSDC`/`_harvestAndReport`, not proven across edge paths (waUSDC paused mid-transaction, `maxMint`-capped wrap, wrap `try/catch` failure).
- The mainnet factory protocol fee was not verified to be zero; a nonzero fee diverts part of the tranche share to the factory recipient and enters the carry pre-scaling math.
- PPS-level restitution inherently reaches all USD3 holders, including any built during restitution — it cannot target only those who bore the loss. Unquantified and accepted.
- `seedSeniorLossCarry` as designed can be re-invoked after exhaustion; making it strictly once needs a packed flag.

## Operational sequence, if implemented

The straddling report mints scaled-fee shares to sUSD3, which can push its idle balance past the reset's dust gate and block the reset. Order matters: wipe report → sUSD3 report → confirm or seed carry → `resetDeadTranche` → resume normal reports. `docs/operations-runbook.md` must be updated at that time.
