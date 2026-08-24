# Operations Runbook

Incident procedures for conditions the contracts do not handle automatically. Each entry states the trigger, why no code path covers it, and the exact steps.

These are live-contract procedures. Every step names its access control, because most require two different actors — a governance action followed by a keeper call — and the second is useless without the first.

## Loss exceeding junior backing, before F-04 part 2 ships

**Trigger.** A `USD3.report()` recognizes a MorphoCredit loss larger than sUSD3's USD3 balance.

**Scope boundary.** This procedure applies only after sUSD3 reaches exactly zero assets with shares still outstanding.
It does not cover a positive-but-negligible sUSD3 PPS. That distinct state can also make recapitalization ineffective,
but the zero-asset reset assumptions and this runbook do not apply. Confirm the exact zero-asset state before using the
steps below; see `docs/deferred-f04-dead-tranche.md`.

**What happens on its own.** `_postReportHook` burns sUSD3's USD3 shares, capped at its balance (`src/usd3/USD3.sol:593-611`, burn at `:614` via `_burnSharesFromSusd3`, `:648`), so the junior tranche wipes to exactly zero and the remainder socializes to USD3 seniors. sUSD3 reports its USD3 balance as total assets (`src/usd3/sUSD3.sol:125`), so after it reports it holds zero assets with shares outstanding. In that state `TokenizedStrategy` converts deposits to zero shares and rejects them, so **the junior tranche cannot be recapitalized**, and `_subordinationDeployCapWaUSDC` returns 0 whenever sUSD3 holds no shares (`USD3.sol:202`), so **senior deployment is frozen**.

**The part that needs an operator, and is time-sensitive.** While the tranche is wiped, *any profitable report* mints the tranche share to the performance-fee recipient, which is sUSD3 — so value that economically belongs to the seniors who absorbed the excess loss accrues to a share class worth nothing, and un-deadens it at a negligible price per share, letting wiped holders redeem the windfall. Nothing in the contracts prevents this.

Do not think of this as a race against a distant recovery event. Ordinary interest — Aave yield on recalled waUSDC plus accrual on the outstanding borrow book — is enough to make the very next report profitable, so the leak begins at the next report rather than at markdown reversal. Markdown reversal determines the *size* of the leak, not whether it starts.

**The control is that `report()` and `syncTrancheShare()` are `onlyKeepers`.** In TokenizedStrategy this admits both
strategy management and the configured keeper. The live USD3 keeper is a router contract at
`0xc22158100b823E1EF612fBA265941Efe9e7d7975`, but its downstream authorization surface was not established by the
available ABI probes. Do not assume a particular relayer or EOA is the only caller. Halt both the management path and
every router-authorized path verified from current source/ABI; if the router authorization cannot be enumerated, the
halt precondition is not satisfied. Holding reports is cheap because pending profit blocks neither senior withdrawals
nor anything else. Keep both paths halted from recognition of the wipe until the fee bits read zero. Then:

1. Set `TRANCHE_SHARE_VARIANT` to `0` via `ProtocolConfig.setConfig` (`src/ProtocolConfig.sol:83`, owner-gated — a governance action through the 24h params timelock, so it is not immediate; start it as soon as a wiping loss is recognized rather than waiting for recovery to look imminent).
2. Once that lands, have a keeper call `USD3.syncTrancheShare()`, which writes the configured zero into the fee bits. **Step 1 has no effect on reports until this runs.**
3. Verify the fee bits are zero, then resume reporting. If a report lands between steps 1 and 2, the old tranche share is still live and the windfall is realized.

In this wiped state the retroactive reprice described below is the *desired* outcome — pending profit belongs to the seniors that absorbed the excess loss — so this is the one procedure where syncing before reporting is correct. Never apply it to a partial junior loss.

## Changing `TRANCHE_SHARE_VARIANT` outside an incident

**Trigger.** Any routine change to the tranche share.

**What the contracts do.** `syncTrancheShare()` (`src/usd3/USD3.sol`) writes the new share straight into the performance-fee bits and deliberately does **not** report first. `TokenizedStrategy.report()` applies whichever fee is live at execution time to the entire profit interval since the previous report (`lib/tokenized-strategy/src/TokenizedStrategy.sol:1119-1161`), so the new share is charged against profit that accrued under the old one. Raising the share transfers already-earned senior yield to sUSD3; lowering it transfers already-earned junior yield to seniors.

This is accepted as an operator-managed policy rather than a code boundary — forcing a report inside `syncTrancheShare` would couple a parameter change to loss recognition and junior-share burning, which is a worse footgun than the reprice. Guardian filed it as round-3 `A/M-15`; it is recorded as accepted residual risk, not remediated.

**Procedure.** For every tranche-share change:

1. **Halt strategy management and every verified caller behind the keeper router before the timelocked config change
   executes.** Any admitted caller can otherwise land the first sync with no preceding report. The router's current
   allowlist is an explicit evidence requirement; do not infer it from the keeper address alone.
2. Call `USD3.report()` **in the same transaction or multisig batch** as the following `syncTrancheShare()`, in that order. Same-block is exact for profit visible to USD3 accounting: `report()` writes the current NAV to `totalAssets`, so the next report cannot recharge it. Split across blocks, the interval between them is repriced.
3. Resume strategy management and verified keeper-router callers only after confirming the fee bits match the
   configured value.

**What this procedure does not cover.** Borrower-local premium is not enumerated by `report()`; it enters supply assets only when `accruePremiumsForBorrowers` runs (`src/MorphoCredit.sol:146`), which is permissionless and list-driven. Premium earned under the old share but materialized after the change is reported at the new one, and no ordering discipline available to the operator closes that. Sweeping the borrower list immediately before step 2 narrows it. Note also that the timelocked config change is publicly observable, so entry into the favoured tranche during the 24h window is possible and is likewise not closed by this procedure.

**Restoring senior deployment.** Setting `MIN_SUSD3_BACKING_RATIO` to `0` makes `_subordinationDeployCapWaUSDC` return `type(uint256).max` (`USD3.sol:195-196`) and unblocks deployment. This removes the first-loss buffer at exactly the moment tail risk has materialized, so treat it as a deliberate override requiring a decision, not a default step.

**What none of this fixes.** The junior tranche remains unrecapitalizable until F-04 part 2 ships. Nothing revives sUSD3 short of that or a shutdown and redeploy. Reverse step 1 only once the fix is live and the tranche has been reset.

**Before any wipe-and-recall sequence, stop borrowing first.** The F-04 record previously stated that a wiped tranche "stops writing new credit" and that the zero deployment cap is static. Both are false (Guardian round-4 `B/M-25`, corrected in `docs/deferred-f04-dead-tranche.md`). A Morpho repayment returns waUSDC and reduces debt before token collection (`src/Morpho.sol:275-305`), and `_beforeBorrow` (`src/MorphoCredit.sol:568-599`) never checks USD3's live junior cap or a pending recall — so a Current borrower with headroom can redraw the liquidity a repayment just recreated, ahead of tend. Set `IS_PAUSED`, or `DEBT_CAP` to `0`, **before** recalling, and keep it set until the recall has completed. This is dormant at the live configuration only because `MIN_SUSD3_BACKING_RATIO` is `0`, which disables the wipe-drives-cap-to-zero policy outright; it becomes live the moment that ratio is set nonzero with credited borrowers outstanding.

## USD3 and sUSD3 admission controls

`ProtocolConfig.setEmergencyConfig` accepts exactly four restrictions: `IS_PAUSED = 1`, or `DEBT_CAP = 0`,
`MAX_ON_CREDIT = 0`, and `USD3_SUPPLY_CAP = 0`. There is no sUSD3 supply-cap key and no reversible emergency config
write that stops all junior deposits. `USD3_SUPPLY_CAP = 0` stops USD3 deposits, not direct deposits of already-held
USD3 into sUSD3. `DEBT_CAP = 0` also does not necessarily close sUSD3 capacity while actual market debt remains,
because the junior cap uses the greater of actual debt and configured potential debt.

`USD3_SUPPLY_CAP = 0` is a total deposit halt, not a tighter cap: `availableDepositLimit()` returns zero for a zero
cap (`src/usd3/USD3.sol:530-533`) **before** its `supplyCapExempt` early return (`USD3.sol:534-536`), so exempt
receivers are not exempt from the halt. Never set the cap to zero while any LCC facility has an open capital call or
a live shortfall auction: funding and fills both deliver through a USD3 deposit (`src/lcc/LCCVault.sol:898`, reached
from `fundCall` at `:648`/`:655` and `takeAuction` at `:699`), so `fundCall` would revert and compelled funders still
unfunded at the deadline would be slashed for their entire remaining margin. If the halt is unavoidable, pause the
affected facilities' effective clocks before their funding deadlines first, exactly as for an accidentally revoked
exemption flag (see "Creating and authorizing an LCC vault").

Below `10000`, `MAX_ON_CREDIT` is an honest-operation deployment and liquidity-buffer target, not an adversarially
enforceable exposure boundary. If deposit headroom remains open, lower it only while simultaneously sizing
`DEBT_CAP <= m × intended stable senior base`, where `m = MAX_ON_CREDIT / 10000`, and revalidate that bound whenever
the intended stable base changes. Borrow admission enforces `DEBT_CAP` against total debt plus the requested assets
without reading supply (`src/MorphoCredit.sol:585-587`), so a temporary deposit cannot increase the borrowable total.

For an emergency stop that preserves exits, use the pair `MAX_ON_CREDIT = 0` and `DEBT_CAP = 0`: the first stops new
USD3 deployment and the second stops new borrowing. Neither setting blocks USD3 or sUSD3 exits. This pair does not
halt deposits; follow the zero-cap hazard above before considering `USD3_SUPPLY_CAP = 0` separately.

If all new sUSD3 deposits must stop, first read the sUSD3 TokenizedStrategy `management()` and `emergencyAdmin()`
addresses. Either can call `shutdownStrategy()`, which halts deposit/mint but is a one-way, irreversible strategy
shutdown. Do not submit a nonexistent junior-cap key, and do not assume the ProtocolConfig emergency controller also
holds either sUSD3 strategy role without a live read.

## Before enabling markdown

Begin with a live read of `CreditLine.mm()`. The recorded production value is nonzero, so the zero-manager early return
in `_updateBorrowerMarkdown` does not apply; the remaining activation gate is the per-borrower flag controlled by
`MarkdownController.setEnableMarkdown` (`src/MorphoCredit.sol:714-715`, `src/MarkdownController.sol:81-87`,
`audit-round3/onchain-evidence.md:66-78`). Read that flag for every proposed borrower rather than treating the manager
address as the active safety control.

A future change may set `mm` to the zero address. Treat markdown activation as a two-step sequence if and only if the
live read confirms that change has happened: the CreditLine owner must first set a nonzero manager with `setMm`, and
the MarkdownController owner must then enable the borrower (`src/CreditLine.sol:85-94`,
`src/MarkdownController.sol:81-87`). While `mm` remains nonzero, borrower enablement is the single remaining write.

**Standing operating decision:** do not activate the markdown module, and do not post non-empty repayment obligations
on chain. Posting obligations is an owner-or-OZD action and is what supplies the delinquency/default state consumed by
markdown (`src/CreditLine.sol:163-179`, `src/MorphoCredit.sol:515-539`). Cycle closure is not covered by this decision
and must continue on schedule: call `closeCycleAndPostObligations` with empty borrower arrays, the shape
`test/forge/BaseTest.sol` uses at setup. A missed close freezes the market — `_isMarketFrozen`
(`src/MorphoCredit.sol:830-842`) returns true once `block.timestamp >= lastCycleEnd + cycleDuration`, and both
`_beforeBorrow` (`src/MorphoCredit.sol:576`) and `_beforeRepay` (`:610`) then revert `MarketFrozen()`, so borrowers
cannot even repay. Any proposal to reverse this decision must first close and independently verify all five
pre-enable items:

1. Correct stale deposit pricing.
2. Remove withdrawal freezes caused by markdown accounting.
3. Correct cure attribution.
4. Correct tranche fee-share sizing under markdown.
5. Include markdown in deployment accounting.

**Residual risk and operating note — impaired-interest recognition.** This is deliberately not a sixth gate item,
because it cannot be closed. Base interest accrues on gross face debt, while the markdown applied to the market
moves only when the borrower is touched (`_updateMarketMarkdown`, `src/MorphoCredit.sol:782`), so interest on
already-impaired debt reports as USD3 profit through `_harvestAndReport` (`src/usd3/USD3.sol:329-338`, returning
`nav()`, `:723-725`), unlocks to holders, and cannot be clawed back from anyone who exits before the next touch.
Where markdown has been enabled for specific borrowers, pass those borrowers to `accruePremiumsForBorrowers` and
`USD3.report()` in one bundle, with the borrower refresh executing **before** the report. The order is the
substance, not a detail: if the report runs first, it recognizes the gross interest as profit and the later refresh
leaves the markdown loss pending.

This is best-effort, not a sufficient control. `accruePremiumsForBorrowers` refreshes only the addresses its
caller passes (`src/MorphoCredit.sol:147-153`), so the ordered bundle removes ordering risk for the borrowers named and
nothing more — it cannot prove discovery or prevent omission. Any borrower left out still has gross interest
reported as profit before its markdown catches up. The set of enabled borrowers is owner-authored and
reconstructible from our own events — `markdownEnabled` has exactly one writer, `setEnableMarkdown`, owner-gated,
one borrower per call, emitting `MarkdownEnabledUpdated` (`src/MarkdownController.sol:84-87`) — which makes the
sweep tractable, not complete. This remains accepted residual risk; this note alone does not make markdown
activation safe.

### Other one-write configuration re-arms

Treat each of these separately from markdown activation and require a live configuration read plus an explicit review
before the privileged write:

- Issuing a third-party credit line through `setCreditLines` takes one owner-or-OZD write, not an owner-only write
  (`src/CreditLine.sol:118-130`). The `_afterBorrow` premium-accrual timestamp correction in
  `src/MorphoCredit.sol:633-636` must be live before issuing it.
- Setting `MIN_SUSD3_BACKING_RATIO` to a nonzero value takes one owner `ProtocolConfig.setConfig` write and restores the
  junior-backing deployment constraint; the recorded production value is zero (`src/ProtocolConfig.sol:80-86`,
  `src/usd3/USD3.sol:193-213`, `audit-round3/onchain-evidence.md:44`).
- Setting `SUSD3_LOCK_DURATION` to a nonzero value takes one owner `ProtocolConfig.setConfig` write and causes successful
  deposits or mints to set `lockedUntil` (`src/ProtocolConfig.sol:47`, `src/ProtocolConfig.sol:80-86`,
  `src/usd3/sUSD3.sol:145-149`).
- Setting `MIN_CREDIT_LINE` to a nonzero value takes one owner `ProtocolConfig.setConfig` write
  (`src/ProtocolConfig.sol:80-86`) and disables emergency revocation: a zero-credit update reverts
  `MinCreditLineExceeded` (`src/CreditLine.sol:150`) whenever the minimum is positive, which disables
  `EmergencyController.emergencyRevokeCreditLine` (`src/EmergencyController.sol:81-102`) and the identical route in
  `OperationalController` (`src/OperationalController.sol:88-108`). `MIN_CREDIT_LINE` must stay zero while emergency
  revocation is a relied-on control. Replacing `CreditLine` itself is unreachable for the live market: it is
  non-upgradeable, and `creditLine` is a field of `MarketParams` whose hash is the market id
  (`src/libraries/MarketParamsLib.sol:16-19`), so a redeployed CreditLine is a different market. The credit line
  itself, however, is stored as `position[id][borrower].collateral` inside MorphoCredit (`src/MorphoCredit.sol:359-367`,
  written by `setCreditLine`, gated `onlyCreditLine`), and MorphoCredit is ProxyAdmin-managed behind the 7-day
  timelock (`docs/deployment.md:15`), so a MorphoCredit implementation upgrade adding a narrowly authorized
  revocation path that zeroes that collateral directly — without changing `MarketParams` or its id — remains an
  available remedy if a permanent selective-revocation path is ever needed. `MIN_CREDIT_LINE` sits behind the 24h
  params timelock, so zeroing it back is not an emergency path; the immediate fallback is
  `setConfig(DEBT_CAP, 0)` (`src/EmergencyController.sol:70-72`), which is blunt rather than selective.
- Setting `MIN_BORROW` to a nonzero value takes one owner `ProtocolConfig.setConfig` write and blocks terminal-dust
  insurance repayment: `_beforeRepay` rejects a repayment leaving `0 < remaining < minBorrow`
  (`src/MorphoCredit.sol:617-625`), which blocks `CreditLine.settle` from applying insurance cover immediately before
  write-off (`src/CreditLine.sol:204-226`). `MIN_BORROW` must stay zero unless the settlement exemption ships first:
  before setting it nonzero, exempt `msg.sender == marketParams.creditLine` from the remaining-debt minimum.

## Before enabling the Morpho fee

**Standing operating decision:** do not enable the MorphoCredit market fee, and do not set a fee recipient. This
section is also the operator-facing record of the accepted fee-recipient risk: USD3 subtracts the ring fence from
withdrawal capacity while MorphoCredit grants the fee recipient an independent exception, and that acceptance rests
entirely on the fee staying zero. The recorded production values are a zero market `fee` and
`MorphoCredit.feeRecipient()` of `address(0)`; take a live read of both before relying on this section.

A nonzero market fee is the common precondition for both numbered items below, but which one it arms depends on who
the recipient is, and the two arming conditions are mutually exclusive:

- **Item 1 arms on a nonzero fee with a fee recipient that is not USD3.** `_beforeWithdraw` returns early for USD3
  itself before the fee-recipient exception is reached (`src/MorphoCredit.sol:558`, then `:561`), so when
  `feeRecipient` is USD3 the exception is never the operative path and the fee shares stay inside USD3's own
  accounting. A non-USD3 recipient makes the `:561` exception live: that recipient withdraws its own fee shares and
  pulls market cash that USD3 has reserved through `ringFencedLiquidity` (`src/usd3/USD3.sol:508`).
- **Item 2 arms on a nonzero fee with the fee recipient set to USD3.** `expectedSupplyAssets`
  (`src/libraries/periphery/MorphoBalancesLib.sol:90-104`) adds the fee shares that accrual mints to the projected
  `totalSupplyShares` (`:54-56`) but reads the queried account's stored share balance (`:100`), so the denominator
  is complete while the fee recipient's numerator is short: the fee recipient's own balance is understated and every
  other account's is exact. While either write is missing, USD3's position read — item 2's concern — is exact.

Any proposal to reverse this decision must first close and independently verify both items:

1. The fee-recipient/ring-fence interaction above, on its own merits rather than on the fee-stays-zero commitment.
2. A fee-recipient-aware position calculation in `suppliedWaUSDC` (`src/usd3/USD3.sol:717`). The shape of the fix:
   when `feeRecipient()` is USD3 itself, add the projected fee shares — the difference between the expected and
   stored total supply shares — to USD3's own share balance before converting shares to assets, instead of calling
   `expectedSupplyAssets` directly; every import and `using` declaration this needs is already present in the file.
   It is not shipped today because `suppliedWaUSDC` feeds `nav()` and therefore every live accounting path, and the
   branch it would correct cannot execute while the fee and recipient stay unset.

## Helper seed for recurring junior top-ups

The one-transaction Helper hop deposits USDC into USD3 with the Helper as the immediate USD3 receiver, then deposits
the newly minted USD3 into sUSD3 for the user. The Helper normally returns to a zero USD3 share balance, so USD3's
receiver-based opening minimum applies again on every hop even when the final sUSD3 user is established.

Seed the production Helper permanently with one USD3 base-unit share and verify `USD3.balanceOf(Helper) >= 1` after
deployment, any Helper replacement, and any strategy migration. The hop deposits only the newly minted shares, so the
seed remains behind; USD3 losses change PPS rather than the seed's share count. Prefer the seed over
`supplyCapExempt[Helper]`: either addresses the receiver-level first-time minimum, and `Helper` prechecks the final
receiver's `availableDepositLimit` (`src/Helper.sol:70`) so supply-cap headroom and borrower restrictions bind under
both, but the exemption grants the Helper broader standing privilege than the opening minimum requires. If the seed
is absent, sub-minimum hops revert atomically; users can use the two-transaction USD3-then-sUSD3 route until the seed
is restored.

## Deposit admission and borrowing during a USD3 pending loss

**Trigger.** Live NAV falls behind stored `totalAssets` — the `_pendingLoss()` predicate (`src/usd3/USD3.sol:185-187`) — between a MorphoCredit loss materializing and the `report()` that recognizes it.

**What happens on its own.** Senior withdrawals halt (`availableWithdrawLimit` returns zero on the predicate, `USD3.sol:473-475`) and new deployment to MorphoCredit stops (`_supplyToMorpho` gate, `USD3.sol:409`). Two further guards recommended in review (Guardian round-2 M-04, re-raised on the merged board as M-03) are deliberately **not** implemented. These are standing deviations, not mitigations:

- **Deposit admission stays open.** `availableDepositLimit()` (`USD3.sol:520`) is not zeroed while a loss is pending. A hard constraint rules out exactly one placement for such a guard: `supplyCapExempt` receivers return `type(uint256).max` at the early return (`USD3.sol:534-536`) before any later check, so a pending-loss guard **above** it would make `LCCVault.fundCall`'s USD3 deposit revert (`src/lcc/LCCVault.sol:898`, reached from `fundCall` at `:648`/`:655`) during a pending loss — converting an accounting delay into missed capital-call obligations and margin slashing. A guard placed **below** that early return, before the cap math at `USD3.sol:538`, would have preserved the exemption path and still zeroed deposits for everyone else; leaving the non-exempt path open as well was a deliberate decision, not forced by the constraint.
- **No Morpho-side borrow prevention.** Nothing stops new borrowing that leaves deployed exposure above what live junior backing supports. Pre-existing over-cap deployment remains borrowable through the pending-loss window, and through the post-unpause window described under "Junior exit during a waUSDC pause" below.

**Residual for deposits admitted during the window.** Admitted deposits sit in local waUSDC and cannot reach MorphoCredit until `report()` recognizes the loss. When the junior tranche fully covers the loss, such a depositor is exactly neutral: the required burn `loss·preSupply/preAssets` (`USD3.sol:620`) is independent of the deposit, so post-report PPS is unchanged. When the loss exceeds sUSD3's balance, the burn is capped at that balance (`USD3.sol:630-632`) and the remainder socializes across all seniors — including the admitted depositor, who cannot exit in the meantime because withdrawals are halted on the same predicate. On the exempt path this falls on LCC funders meeting a capital call, who are compelled depositors — declining costs them their margin — which is why that path is the one the placement constraint rules out gating.

**What the operator must do.**

1. Treat prompt loss recognition as the control: `report()` closes both windows, and no code guard substitutes for it. When the "Loss exceeding junior backing" procedure applies, its report hold takes precedence and deliberately extends this window; record that decision.
2. If the window overlaps a waUSDC pause, follow the junior-exit entry below on unpause: keeper `tend` before borrowing resumes.
3. Do not reach for `USD3_SUPPLY_CAP = 0` as a stopgap deposit halt while any LCC facility has an open call; see the zero-cap hazard under "USD3 and sUSD3 admission controls" above.

## Deferred JANE slash while markdown is disabled

**Trigger.** A borrower is settled while `markdownEnabled[borrower]` is false in the MarkdownController — the
recorded production state for every borrower. Settlement reaches `slashJaneFull` whenever `CreditLine.mm()` is
nonzero, but the slash returns zero on the disabled borrower flag (`src/MorphoCredit.sol:883-886`,
`src/MarkdownController.sol:191`); a zero manager would also skip the call. Either way the JANE slash is deferred
rather than performed automatically.

**Procedure.**

1. Verify `Jane.transferable()` is false and record the current `Jane.markdownController` value.
2. Have the JANE `OWNER_ROLE` point the controller slot at a purpose-built slasher, or a Safe adapter with the same
   callable surface.
3. From that address call `redistributeFromBorrower(borrower, amount)`, using the borrower's full current balance for
   the settlement slash. The function calls `_transfer` directly (`src/jane/Jane.sol:129-133`), so the slash itself
   bypasses ordinary transfer and freeze checks.
4. Have the JANE owner restore the recorded controller and verify the slot.

Every nonzero address placed in the controller slot, including a temporary or restored controller, must implement
`isFrozen(address)`: every transfer that would otherwise be permitted calls that interface while the slot is nonzero
(`src/jane/Jane.sol:142-154`). Do not call the one-way `setTransferable()` switch. Non-transferability is what
prevents an ordinary settled borrower from moving JANE before the manual slash lands; once transfers are enabled,
this deferred recovery cannot protect borrowers settled in the intervening window.

## Loss report landing during a waUSDC pause

**Trigger.** A `USD3.report()` recognizes a MorphoCredit loss while the waUSDC wrapper is paused.

**What happens on its own.** The loss reduces junior backing and therefore the permitted senior deployment cap, but the rebalance returns early while waUSDC is paused (`_applyDeployCap`, `USD3.sol:351`, reached from `_tend`), so the recall never runs and deployment stays above the newly reduced cap. That early return is deliberate and load-bearing: the recall path transfers waUSDC, and the deployed StataTokenV2 blocks transfers while paused, so without it the whole report would revert instead of deferring the recall.

**Why an operator has to notice.** `_tendTrigger` also returns false while paused (`USD3.sol:376`), so **keepers are not signalled** — the deferred recall is silent, not queued. When the pause lifts, the excess Morpho liquidity is immediately borrowable, and a later tend cannot recall what has already been borrowed. A subsequent default then converts previously recallable senior liquidity into additional loss.

1. When a loss report lands during a waUSDC pause, record that a recall is outstanding. Nothing on-chain does this for you.
2. On unpause, have a keeper call `tend` **before** borrowing resumes. Do not wait for the trigger; it will not fire on its own for this condition.
3. Confirm deployed waUSDC is at or below the post-loss cap before treating the incident as closed.

**Residual.** This is a race: an approved borrower can act between unpause and the manual tend. `RebalanceDeferred` (`USD3.sol:410`) is the observability signal that finding L-11 asked for, but it fires only when an attempted Morpho supply is rejected — a paused-wrapper deferral attempts nothing, so nothing is emitted, and the borrower race between unpause and the manual tend is **not** closed by it. The window is why this is a runbook entry rather than a code guarantee.

## Junior exit during a waUSDC pause (deployment cap exceeded)

**Trigger.** sUSD3 withdraws or redeems USD3 while the waUSDC wrapper is paused.

**What happens on its own.** The deployment cap is **advisory, not enforced**. The L-12 fix converts a junior exit under a paused wrapper from reverting into succeeding with the recall deferred: `_postTransferHook` (`USD3.sol:628`) calls `_applyDeployCap` (`USD3.sol:629`), which returns early while paused (`USD3.sol:351`). The junior's backing reduction lands immediately, but the matching pullback of senior deployment does not, so deployed waUSDC can exceed the subordination cap for the full pause duration. The excess is **not** borrowable during the pause itself — a borrow completes through the waUSDC transfer at `src/Morpho.sol:269`, which the paused wrapper rejects — so the exposure opens **after unpause and before the keeper tend**, the same race described for a paused loss report above. If a borrower draws the excess in that window, `_withdrawFromMorpho` clamps every later recall at available market liquidity (`USD3.sol:424-430`), so the recall is **unfulfillable until liquidity returns or borrowers repay** (repayment returns waUSDC to the market at `src/Morpho.sol:305`); until then the over-cap exposure is ordinary senior credit risk.

1. Track junior exits that land during a wrapper pause; each one leaves a deferred pullback that nothing on-chain queues.
2. On unpause, have a keeper call `tend` before borrowing resumes, exactly as for a paused loss report above.
3. Confirm deployed waUSDC is back at or below the effective cap before closing the incident.

## Servicing a borrower approaching Default

**Trigger.** A borrower with a drawn line crosses into grace or delinquency and is heading for Default.

**What happens on its own.** Nothing prices the loss in. While `markdownEnabled[borrower]` is false — the recorded
production state — `calculateMarkdown` returns zero (`src/MarkdownController.sol:94-100`), so no touch can impair the
debt: settlement is the first accounting event that records the principal loss, and USD3's `_pendingLoss` predicate
(`src/usd3/USD3.sol:185-187`) only trips after it. Between publicly observable Default and settlement, USD3 entry and
exit both price at par. The same window opens regardless of the borrower flag if the markdown manager is ever set to
zero, since `_updateBorrowerMarkdown` then returns before consulting the controller (see "Before enabling markdown").

1. Monitor borrowers crossing grace and delinquency; repayment status is derivable on chain by anyone, so treat the
   crossing as the start of the window rather than as advance private notice.
2. Minimise the interval between Default and settlement.
3. Submit the settlement (`CreditLine.settle`, `src/CreditLine.sol:204-226`) together with `USD3.report()` and
   `sUSD3.report()` as one private bundle, so no entry or exit lands between the write-down and its recognition.
4. If a delay is unavoidable, use the existing USD3 supply-cap and redemption-floor controls to narrow entry and
   exit at par — after first confirming no open LCC call depends on USD3 deposits; see the zero-cap hazard under
   "USD3 and sUSD3 admission controls".

## Settlement near the supply share-price floor

**Trigger.** A retirement or loss settlement is proposed while the MorphoCredit market is near its minimum supply
share price. The floor in supply-asset units is
`(totalSupplyShares + VIRTUAL_SHARES - 1) / 1e15`; the ratio is fixed by
`SUPPLY_SHARE_PRICE_FLOOR_RATIO` (`src/MorphoCredit.sol:98-99`, `src/MorphoCredit.sol:942-944`).

`marketInWindDown == false` does not by itself show that recapitalization is safe. It only shows that an earlier floor
clamp has not left the latch set; new lending remains open until the raw assets fall below the computed floor or the
latch is set (`src/MorphoCredit.sol:947-953`). A deposit made at a depressed share price can increase supply shares and
therefore raise the floor before the next settlement.

Before every settlement, take and archive one state-consistent snapshot containing:

1. `totalSupplyAssets`.
2. `totalSupplyShares`.
3. The floor computed from those shares with the formula above.
4. The net loss being settled.
5. Supply received since the last material loss.

Once retirement settlements begin, complete all remaining settlements without an intervening recapitalizing supply.
Do not infer safety from the unlatching state or from deposit admission remaining open.

For each settlement, reproduce `_applySettlement`'s values before execution: `protectedAssets` is the lesser of the
computed floor and pre-settlement supply assets, and pre-clamp `remainingAssets` is supply assets minus the net loss,
floored at zero (`src/MorphoCredit.sol:918-931`). Whenever `remainingAssets <= protectedAssets` makes the clamp fire,
compute and record `protectedAssets - remainingAssets` using that pre-clamp value. No code deducts this amount from USD3
NAV: MorphoCredit stores `protectedAssets`, and USD3 reads the resulting supply balance through `suppliedWaUSDC()` into
`nav()` (`src/usd3/USD3.sol:713-724`).

Do not clear the wind-down latch merely because the reopening ratio is later satisfied. `clearMarketWindDown` checks
only share-price recovery and does not reconcile any recorded clamp difference (`src/MorphoCredit.sol:128-141`). Keep
the market closed until the settlement record, the unreflected amount, and the downstream USD3 NAV treatment have been
explicitly reconciled.

## Tend trigger latched after a report in market wind-down

**Trigger.** A `USD3.report()` runs while the MorphoCredit market is in wind-down and local waUSDC sits below the deployment target.

**What happens on its own.** The report rebases `totalAssets` to NAV, clearing the pending-loss suppression, so `_tendTrigger` signals a supply-side tend (`USD3.sol:394`). The supply can never succeed — wind-down rejects it — so `_supplyToMorpho` catches the revert, emits `RebalanceDeferred`, and changes nothing (`USD3.sol:404-413`). The trigger therefore **latches true indefinitely**: every keeper tend is a no-op that re-emits `RebalanceDeferred`. This costs keeper gas only; no funds are at risk.

1. Recognize the pattern: repeated `RebalanceDeferred` emissions with `suppliedWaUSDC()` unchanged across tends.
2. Stop the automated keeper loop for this strategy, or filter its trigger; the signal will not clear on its own.
3. The latch is not exclusive to wind-down ending: `_tendTrigger` recomputes from live deployed, local, and target values (`USD3.sol:378-397`), so it remains true only while its balance and configuration inputs are unchanged. Leaving wind-down or shutting the strategy down clears it, but so does lowering `maxOnCredit` until the target is at or below deployed, a waUSDC pause (`USD3.sol:376`), or drift falling under the trigger threshold.

## Creating and authorizing an LCC vault

LCC deployment has split authority. The main Safe holds the non-upgradeable `LCCVaultFactory`'s sole `OWNER_ROLE`;
USD3 management is the 24-hour parameters timelock `0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2`; and the LCC beacon's
separate fleet upgrade authority is the 7-day timelock. Do not require or represent those roles as one account. Vault
manifests contain facility parameters and risk acknowledgements, not an independent authority address. The factory
owner controls every vault in the family, so an ownership change has family-wide rather than per-facility blast radius.

Before each deployment, review and record `factory.owner()`, enumerate `factory.OWNER_ROLE()` with
`getRoleMemberCount` and `getRoleMember`, and review `factory.pendingOwner()`. The owner must match the intended main
Safe and the `OWNER_ROLE` census must contain that sole member. If `pendingOwner()` is nonzero, resolve or expressly
approve the pending family-wide authority transfer before proceeding. See `docs/deployment.md` for the timing
trade-offs of factory-wide authority.

Use `script/operations/CreateLCCVaultSafe.s.sol` with the same finalized JSON in every phase:

1. Complete the facility-specific leverage-dispersion and per-stake loss-budget review. The example deliberately leaves
   `acknowledgePerpetualTenor`, `acknowledgeHoldToMaturity`, and `acknowledgeFullAuctionAward` false. Set the first true
   only when a perpetual `maxEpochs = 0` facility has an approved dispersion justification; set the second true only
   when `minCommitmentEpochs + exitDelayEpochs >= maxEpochs != 0` deliberately makes terminal wind-down the only exit;
   set the third true only when the loss budget approves `maxAuctionAwardBps = 10000`, the maximum award-loss case.
   Record the named approver. The script rejects each case without its acknowledgement.
2. Keep `startTimestamp` far enough in the future to survive the governance delay. Run
   `schedulePrerequisites(string,uint256,bool)` with an attempt nonce (start at `0`). The script computes the CREATE2
   address from the final parameters and facility ID, confirms the factory owner, confirms the beacon is owned by the
   expected 7-day timelock, confirms USD3 management is the expected 24-hour timelock, and prepares one timelock
   operation containing
   `setSupplyCapExempt(predictedVault, true)` and
   `setRingFenceConduit(predictedVault, true)`.
3. After the 24-hour delay, run `executePrerequisites(string,uint256,bool)` with byte-identical JSON and the same
   attempt nonce. A completed TimelockController operation cannot be rescheduled; use a fresh nonce for a new attempt.
   Confirm both USD3 flags are true at the predicted, still-undeployed address.
4. Run `run(string,bool)`. The factory Safe creates only that pre-authorized CREATE2 vault. The script verifies the
   simulated vault's address, factory provenance, protocol wiring, and both USD3 flags.
5. After the Safe transaction executes on chain, run `verify(string)` with the deployment JSON. Archive its successful
   output with the manifest. `verify(address)` with the vault is the fallback when the JSON is unavailable, but
   `verify(string)` is authoritative because it also recomputes the expected address from the manifest.
6. Before the first depositor transaction, have a `LISTER_ROLE` account call `setDepositorCaps` with the approved
   beneficiary commitment limits. Caps are in funding-asset commitment units and apply to each vault's post-deposit
   active-plus-pending total; equality is admitted, zero is an absolute denial, and `type(uint128).max` is unlimited.
   The launch `defaultDepositorCap` is zero. Use `clearDepositorCaps` only to restore fallback to the live default;
   never treat clearing as revocation if that default is nonzero.

**Opening and closing the family.** `defaultDepositorCap` is the switch that the old whitelist flag used to be, and
it sizes as well as admits. Zero — the launch value — is the enforced-allowlist mode: only depositors with an
explicit cap are admitted. A nonzero value opens the family to unlisted depositors up to that size. `type(uint128).max`
opens it without limit. Unlike the flag it replaces, opening the family does **not** re-admit anyone you revoked: an
override explicitly set to zero denies at any default, and only `clearDepositorCaps` returns that address to
fallback. Raising the default is an M-02 revalidation trigger, because it changes the admissible cohort.

The two USD3 flags are continuing operating preconditions, not one-time deployment ceremony. Before approving any USD3
management batch that touches either mapping, resolve whether the target is a factory-registered LCC vault. Never clear
either flag for an active facility, and never clear only one: revocation must be paired and atomic. Planned retirement
may revoke both only after the facility is permanently in shutdown or terminal wind-down, no call or auction remains
open, every off-chain purchase has settled, and the related ring-fence amount has been released. Re-run the verifier
after every registry change; an active vault must still pass both flag checks.

If either permission is accidentally revoked while a facility is live, treat it as a funding incident. Pause the LCC
effective clock before the affected deadline, schedule and execute restoration through USD3 management, run the
post-deployment verifier, and unpause only after an end-to-end funding simulation succeeds. Ordinary USD3 cap headroom
is not a substitute for the exemption.

## LCC funding cash and approval sizing

For every open call, `obligationOf(epoch, user)` is the authoritative gross funding obligation. Margin does not offset
that amount. `fundCall` pulls `max(obligation, USD3.previewMint(1))`, with the second term permitted to exceed the
obligation by at most 1,000 funding-asset base units so dust funding can mint one USD3 share. Size both liquid cash and
allowance for that pulled amount.

Example: a 20% call against a user's $1,000,000 active commitment produces a $200,000 obligation (subject only to the
contract's upward unit rounding). If the user has $75,000 of active margin and amortizes, the vault pulls the full
$200,000 first and returns $15,000 of margin as a separate transfer; it does not reduce the amount due to $125,000.
The incorrect $125,000 figure is $75,000 short, understating the gross requirement by 37.5%. The user's net cash change
after both legs is $185,000, but $200,000 must be available for the atomic funding pull. In
the corresponding auction example, a $37,500 margin award on a $200,000 fill is an 18.75% cash-on-cash return; dividing
the award by the $1,000,000 commitment and reporting 3.75% uses the wrong capital base.

Funding is all-or-nothing. A revert records no partial payment, and an account still unfunded at the deadline is
slash-eligible for its entire remaining margin, not only the called fraction. Re-read `obligationOf` and
`USD3.previewMint(1)` immediately before submission rather than funding from an illustrative estimate.

## LCC Closed-window delivery or oracle outage

**Trigger.** An LCC shortfall auction is in its `Closed` phase and either the margin oracle or the USD3/USD3l delivery path is unavailable long enough that fills cannot execute.

**Why intervention matters.** Completed settlement cannot distinguish “nobody bid” from “nobody could bid.” If an auction-eligible epoch reaches its effective Closed end with zero fills, the whole gross slash pool accrues to treasury. Wall-clock delay alone does not justify different settlement economics.

**Mitigation.** Before the effective Closed end, the guardian or owner calls `pause()`. Pausing freezes the vault's effective time, including the auction clock, so it preserves the remaining Closed window instead of burning it while the dependency is unavailable. Restore or rotate the margin oracle as applicable, restore USD3 and notification-vault delivery, verify the fill path off-chain, then have the owner call `unpause()`. The auction resumes with the same effective time remaining. Do not unpause until fillers can execute, and do not assume a later lazy settlement can infer that the outage prevented bids.

**If recovery is not possible.** Escalate to the owner for the facility's shutdown decision while effective time remains frozen. Shutdown is an economic wind-down action, not an automatic substitute for completing the auction, and should follow the facility's incident authority and loss-allocation process.

**Before submitting shutdown.** Settle every pending auction first whenever its normal settlement path is available.
Before its Closed end, `shutdown()` remains a live discriminator for surplus disposal: a partially filled auction
settled immediately before shutdown receives completed-auction treatment, while the same auction first settled by
`shutdown()` is shutdown-truncated and can allocate the remainder differently. At or after the Closed end, shutdown
uses the same fee and protocol-cap allocation terms as a permissionless touch; only exceptional price-failure
tolerance follows the live shutdown state. Operators should still confirm `pendingAuctionEpochPlusOne == 0` before
submission whenever the normal path is available.

**Missing call-open price snapshot.** Treat a zero snapshot as corruption or an upgrade-writer incident. If the live
margin oracle is healthy, the owner may recover the pool by sending a `synced` call, including `shutdown()`. If both
the snapshot and live oracle are dead, call `setMarginOracle` first with a responsive nonzero oracle and only then
send an owner-side `synced` call. `shutdown()` alone is non-bricking in that state, but it is not recovery: price
failure is tolerated by sending the otherwise returnable pool to treasury, and the disposal cannot be replayed.

**Before submitting `setRiskCaps`.** Settle pending auctions first. `setRiskCaps` is `synced`, so it can finalize a
newly eligible default, create the auction slot, and then revert on its own pending-auction guard when the transaction
also changes `protocolCommitmentCap`. That reverts the entire timelocked transaction, including unrelated
`userCommitmentCap`, `exitCapBps`, and `minDeposit` changes, even if no slot existed when it was queued. The risk is
bounded by the pending auction's Closed window. If the other three parameters must change while a slot is live,
re-pass the current protocol cap unchanged.

## Granting DEPOSIT_OPERATOR_ROLE

**Hard rule.** Never grant `DEPOSIT_OPERATOR_ROLE` to a generic arbitrary-calldata router. The factory authenticates
the payer contract, not the router's end user and not the beneficiary's consent. A generic router would let any user
deposit for a capped beneficiary. Grant only to a dedicated adapter that verifies beneficiary authorization, to a
closed facility operator with a documented consent channel, or to a self-service adapter whose only deposit paths
hard-bind the beneficiary to `msg.sender` and expose no receiver, `onBehalfOf`, `depositFor`, owner, upgrade, rescue,
or generic-call capability. A consent-verifying adapter must bind at least a nonce, deadline, vault, payer, asset and
commitment bounds, and the `allowPendingActivation` choice. A self-only adapter structurally supplies these choices
through the beneficiary's own transaction and sets no precedent for any delegated flow. If a generic router must be
admitted, implement the factory consent registry or in-protocol signature check first.

**Trust consequences.** A role holder can refresh a beneficiary's `commitmentStartEpoch` with floor-sized deposits,
consume the beneficiary's factory-cap and vault `userCommitmentCap` headroom and the protocol cap, and stage pending
exposure that blocks both `requestExit` and the bouncer's `bounceCommitment`. Margin is irrevocably credited to the
beneficiary; the payer has no recovery right. Revocation stops new delegated deposits but does not unwind credited
active or pending exposure. The payer is intentionally not checked against a depositor cap; the beneficiary is always
checked against both the factory and vault caps, while new opens and reopens additionally pass the one-vault policy
and admissions module. The payer-role check runs before the beneficiary factory cap, including on same-vault top-ups,
so an unauthorized payer must fail first.

Before granting the role:

1. Verify the candidate is the approved consent-verifying adapter bytecode or approved self-only adapter bytecode,
   or record the closed facility operator's consent channel and accountable owner. For a self-only adapter, verify
   every deposit entrypoint hard-binds the beneficiary to `msg.sender` and that there is no receiver, `onBehalfOf`,
   `depositFor`, owner, upgrade, rescue, or generic-call surface. Reject any target that forwards caller-selected
   arbitrary calldata.
2. Verify `factory.getRoleAdmin(factory.DEPOSIT_OPERATOR_ROLE()) == factory.OWNER_ROLE()` and that the Safe is the
   sole owner. Submit `grantRole` from the factory owner.
3. Verify `factory.isDepositOperator(candidate)` is true. The view is for operations and integrations; enforcement
   occurs inside `authorizeDeposit`.

Before every delegated adapter-routed deposit, pre-check the beneficiary is nonzero, resolve its explicit or default
factory cap, include both active and pending commitment in the projected total, confirm it has no exit in progress or
incompatible pending activation, and confirm eligibility under the warm one-vault pointer and admissions module.
Check the vault beneficiary and protocol caps, current oracle availability, commitment bounds, and deadline. Default
`allowPendingActivation` to `false`; permit `true` only when the beneficiary's signed authorization explicitly chose
pending activation. These pre-checks reduce failed transactions but do not replace the adapter's consent proof.
This per-deposit operator pre-check list is not applicable to an approved self-service adapter: its beneficiary calls
directly and supplies the vault, asset path, commitment bounds, pending-activation choice, and deadline in-band.

## LCC depositor bounce

**Trigger.** A family `BOUNCER_ROLE` operator must remove some or all of a depositor's active commitment.

1. If the account can be more than 64 finalized calls behind, call `materializeAccount(user)` permissionlessly until
   bounded replay is complete. A bounce never bypasses replay.
2. Check `pauseState`. A paused vault makes every `synced` entrypoint revert, including `bounceCommitment`; the owner
   must unpause before the bouncer acts.
3. Check the current account. A pending deposit makes the bounce revert `PendingDepositExists`; wait for its next-epoch
   activation and retry. Any exit in progress, including matured-but-unclaimed exit margin, makes the bounce revert
   `ExitInProgress`; let the exit mature and have the user call `claimExitedMargin` instead.
4. Check `pendingAuctionEpochPlusOne` and the current call. A live auction or an opened, unfinalized current call makes
   the bounce revert `InvalidPhase`; settle or finalize that call first.
5. Submit `bounceCommitment(user, commitment)`. The amount is nominal active commitment, and the returned margin is
   the pro-rata floor. Removing the entire active commitment closes only an otherwise plain active account; it is not
   a full-closeout sentinel and does not absorb pending or exit state.

The return transfer goes directly to the depositor. If a blacklistable margin token refuses transfers to that
holder, the whole bounce reverts. There is no escrow override: pause the facility while the incident is assessed,
and use the established shutdown/wind-down process if governance decides the facility cannot safely continue.
Shutdown does not make the blocked transfer succeed, but it prevents new exposure and enables the ordinary claims
that remain transferable.

## LCC family registry migration

The registry moves lazily; no administrator deregisters users. To migrate from vault A to vault B, first reach a
permanently closed account in A, then deposit into B. B's successful deposit calls the factory last, and the factory
automatically re-points `vaultOf[user]` from A to B. A matured exiter with nonzero claimable margin is still open
until the user calls `claimExitedMargin`. An exiter whose full obligation was funded, discharging its remaining
margin and commitment, is cleared at funding time and is already eligible to re-point. Shutdown users likewise call
`claimRemainingMargin`; an otherwise plain account whose entire active commitment was bounced is already eligible
to re-point.

If A has more than 64 finalized calls beyond the user's stored cursor, the first B deposit is conservatively denied.
Call `materializeAccount(user)` on A permissionlessly, in batches if needed, then retry B. A live auction can also
keep the closure replay incomplete until settlement.

Disabling `oneVaultPolicyEnabled` is prospective-only: deposits may create multiple open positions and the outermost
successful deposit remains the warm `vaultOf` pointer. The factory cap is enforced per vault during that interval,
not against the family aggregate. Before re-enabling, inventory all such users, reconcile every multi-vault user
offchain to one open position, verify each affected user's aggregate family commitment is at or below their resolved
factory cap, and verify that no family vault is paused or shut with an unclaimable position. Admission checks only the
vault named by the warm pointer: if A remains open while B is recorded, closing
and reopening B after re-enablement does not discover A. Re-enabling does not close existing positions, and the latest
warm pointer can top-up-block a healthy older position until the recorded vault closes.

Lowering an explicit or default factory cap is prospective only. It blocks subsequent deposits, including top-ups,
but does not unwind incumbent exposure or return-pool re-credits and must not block funding, exits, bounce, or claims.
Treat every `setDepositorCaps`, `clearDepositorCaps`, or `setDefaultDepositorCap` change as an M-02 revalidation
trigger before execution.

## LCC factory ownership rotation

A two-step factory ownership transfer re-keys every family vault, including exceptional settlement recovery. Do not
start or accept a rotation while any vault has a pending auction slot with a missing call-open price snapshot. Both
steps of recovery — installing a healthy margin oracle and sending the owner-triggered `synced` disposal — must stay
under one owner throughout the incident. Confirm every family vault's pending slot and snapshot state before
proposing the new owner.

## Related

- `docs/architecture.md` — USD3/sUSD3 subordination and tend/report flows.
- `src/lcc/README.md` §12 — LCC sharp edges, including owner-controlled surfaces.
