# Operations Runbook

Incident procedures for conditions the contracts do not handle automatically. Each entry states the trigger, why no code path covers it, and the exact steps.

These are live-contract procedures. Every step names its access control, because most require two different actors — a governance action followed by a keeper call — and the second is useless without the first.

## Loss exceeding junior backing, before F-04 part 2 ships

**Trigger.** A `USD3.report()` recognizes a MorphoCredit loss larger than sUSD3's USD3 balance.

**What happens on its own.** `_postReportHook` burns sUSD3's USD3 shares, capped at its balance (`src/usd3/USD3.sol:593-611`, burn at `:614` via `_burnSharesFromSusd3`, `:648`), so the junior tranche wipes to exactly zero and the remainder socializes to USD3 seniors. sUSD3 reports its USD3 balance as total assets (`src/usd3/sUSD3.sol:125`), so after it reports it holds zero assets with shares outstanding. In that state `TokenizedStrategy` converts deposits to zero shares and rejects them, so **the junior tranche cannot be recapitalized**, and `_subordinationDeployCapWaUSDC` returns 0 whenever sUSD3 holds no shares (`USD3.sol:202`), so **senior deployment is frozen**.

**The part that needs an operator, and is time-sensitive.** While the tranche is wiped, *any profitable report* mints the tranche share to the performance-fee recipient, which is sUSD3 — so value that economically belongs to the seniors who absorbed the excess loss accrues to a share class worth nothing, and un-deadens it at a negligible price per share, letting wiped holders redeem the windfall. Nothing in the contracts prevents this.

Do not think of this as a race against a distant recovery event. Ordinary interest — Aave yield on recalled waUSDC plus accrual on the outstanding borrow book — is enough to make the very next report profitable, so the leak begins at the next report rather than at markdown reversal. Markdown reversal determines the *size* of the leak, not whether it starts.

**The control is that `report()` and `syncTrancheShare()` are `onlyKeepers`.** No third party can force a report during the window, and holding reports is cheap because pending profit blocks neither senior withdrawals nor anything else. **The production keeper relayer holds a keeper role and auto-syncs the tranche fee, so `onlyKeepers` does not protect you here.** Halt the relayer's reporting on recognizing the wipe and keep it halted until the fee bits read zero. Then:

1. Set `TRANCHE_SHARE_VARIANT` to `0` via `ProtocolConfig.setConfig` (`src/ProtocolConfig.sol:83`, owner-gated — a governance action through the 24h params timelock, so it is not immediate; start it as soon as a wiping loss is recognized rather than waiting for recovery to look imminent).
2. Once that lands, have a keeper call `USD3.syncTrancheShare()`, which writes the configured zero into the fee bits. **Step 1 has no effect on reports until this runs.**
3. Verify the fee bits are zero, then resume reporting. If a report lands between steps 1 and 2, the old tranche share is still live and the windfall is realized.

In this wiped state the retroactive reprice described below is the *desired* outcome — pending profit belongs to the seniors that absorbed the excess loss — so this is the one procedure where syncing before reporting is correct. Never apply it to a partial junior loss.

## Changing `TRANCHE_SHARE_VARIANT` outside an incident

**Trigger.** Any routine change to the tranche share.

**What the contracts do.** `syncTrancheShare()` (`src/usd3/USD3.sol`) writes the new share straight into the performance-fee bits and deliberately does **not** report first. `TokenizedStrategy.report()` applies whichever fee is live at execution time to the entire profit interval since the previous report (`lib/tokenized-strategy/src/TokenizedStrategy.sol:1119-1161`), so the new share is charged against profit that accrued under the old one. Raising the share transfers already-earned senior yield to sUSD3; lowering it transfers already-earned junior yield to seniors.

This is accepted as an operator-managed policy rather than a code boundary — forcing a report inside `syncTrancheShare` would couple a parameter change to loss recognition and junior-share burning, which is a worse footgun than the reprice. Guardian filed it as round-3 `A/M-15`; it is recorded as accepted residual risk, not remediated.

**Procedure.** For every tranche-share change:

1. **Halt the relayer's tranche-fee sync before the timelocked config change executes.** The relayer can otherwise land the first sync itself, on its own cadence, with no preceding report — which is exactly the failure this procedure exists to prevent, and it is not an ordering you control once the config value is live.
2. Call `USD3.report()` **in the same transaction or multisig batch** as the following `syncTrancheShare()`, in that order. Same-block is exact for profit visible to USD3 accounting: `report()` writes the current NAV to `totalAssets`, so the next report cannot recharge it. Split across blocks, the interval between them is repriced.
3. Resume the relayer only after confirming the fee bits match the configured value.

**What this procedure does not cover.** Borrower-local premium is not enumerated by `report()`; it enters supply assets only when `accruePremiumsForBorrowers` runs (`src/MorphoCredit.sol:146`), which is permissionless and list-driven. Premium earned under the old share but materialized after the change is reported at the new one, and no ordering discipline available to the operator closes that. Sweeping the borrower list immediately before step 2 narrows it. Note also that the timelocked config change is publicly observable, so entry into the favoured tranche during the 24h window is possible and is likewise not closed by this procedure.

**Restoring senior deployment.** Setting `MIN_SUSD3_BACKING_RATIO` to `0` makes `_subordinationDeployCapWaUSDC` return `type(uint256).max` (`USD3.sol:195-196`) and unblocks deployment. This removes the first-loss buffer at exactly the moment tail risk has materialized, so treat it as a deliberate override requiring a decision, not a default step.

**What none of this fixes.** The junior tranche remains unrecapitalizable until F-04 part 2 ships. Nothing revives sUSD3 short of that or a shutdown and redeploy. Reverse step 1 only once the fix is live and the tranche has been reset.

**Before any wipe-and-recall sequence, stop borrowing first.** The F-04 record previously stated that a wiped tranche "stops writing new credit" and that the zero deployment cap is static. Both are false (Guardian round-4 `B/M-25`, corrected in `docs/deferred-f04-dead-tranche.md`). A Morpho repayment returns waUSDC and reduces debt before token collection (`src/Morpho.sol:275-305`), and `_beforeBorrow` (`src/MorphoCredit.sol:601-632`) never checks USD3's live junior cap or a pending recall — so a Current borrower with headroom can redraw the liquidity a repayment just recreated, ahead of tend. Set `IS_PAUSED`, or `DEBT_CAP` to `0`, **before** recalling, and keep it set until the recall has completed. This is dormant at the live configuration only because `MIN_SUSD3_BACKING_RATIO` is `0`, which disables the wipe-drives-cap-to-zero policy outright; it becomes live the moment that ratio is set nonzero with credited borrowers outstanding.

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

## Tend trigger latched after a report in market wind-down

**Trigger.** A `USD3.report()` runs while the MorphoCredit market is in wind-down and local waUSDC sits below the deployment target.

**What happens on its own.** The report rebases `totalAssets` to NAV, clearing the pending-loss suppression, so `_tendTrigger` signals a supply-side tend (`USD3.sol:394`). The supply can never succeed — wind-down rejects it — so `_supplyToMorpho` catches the revert, emits `RebalanceDeferred`, and changes nothing (`USD3.sol:404-413`). The trigger therefore **latches true indefinitely**: every keeper tend is a no-op that re-emits `RebalanceDeferred`. This costs keeper gas only; no funds are at risk.

1. Recognize the pattern: repeated `RebalanceDeferred` emissions with `suppliedWaUSDC()` unchanged across tends.
2. Stop the automated keeper loop for this strategy, or filter its trigger; the signal will not clear on its own.
3. The latch is not exclusive to wind-down ending: `_tendTrigger` recomputes from live deployed, local, and target values (`USD3.sol:378-397`), so it remains true only while its balance and configuration inputs are unchanged. Leaving wind-down or shutting the strategy down clears it, but so does lowering `maxOnCredit` until the target is at or below deployed, a waUSDC pause (`USD3.sol:376`), or drift falling under the trigger threshold.

## LCC Closed-window delivery or oracle outage

**Trigger.** An LCC shortfall auction is in its `Closed` phase and either the margin oracle or the USD3/USD3n delivery path is unavailable long enough that fills cannot execute.

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

## Related

- `docs/architecture.md` — USD3/sUSD3 subordination and tend/report flows.
- `src/lcc/README.md` §12 — LCC sharp edges, including owner-controlled surfaces.
