# Operations Runbook

Incident procedures for conditions the contracts do not handle automatically. Each entry states the trigger, why no code path covers it, and the exact steps.

These are live-contract procedures. Every step names its access control, because most require two different actors — a governance action followed by a keeper call — and the second is useless without the first.

## Loss exceeding junior backing, before F-04 part 2 ships

**Trigger.** A `USD3.report()` recognizes a MorphoCredit loss larger than sUSD3's USD3 balance.

**What happens on its own.** `_postReportHook` burns sUSD3's USD3 shares, capped at its balance (`src/usd3/USD3.sol:593-595`, burn at `:599` via `_burnSharesFromSusd3`, `:633`), so the junior tranche wipes to exactly zero and the remainder socializes to USD3 seniors. sUSD3 reports its USD3 balance as total assets (`src/usd3/sUSD3.sol:125`), so after it reports it holds zero assets with shares outstanding. In that state `TokenizedStrategy` converts deposits to zero shares and rejects them, so **the junior tranche cannot be recapitalized**, and `_subordinationDeployCapWaUSDC` returns 0 whenever sUSD3 holds no shares (`USD3.sol:195`), so **senior deployment is frozen**.

**The part that needs an operator, and is time-sensitive.** While the tranche is wiped, *any profitable report* mints the tranche share to the performance-fee recipient, which is sUSD3 — so value that economically belongs to the seniors who absorbed the excess loss accrues to a share class worth nothing, and un-deadens it at a negligible price per share, letting wiped holders redeem the windfall. Nothing in the contracts prevents this.

Do not think of this as a race against a distant recovery event. Ordinary interest — Aave yield on recalled waUSDC plus accrual on the outstanding borrow book — is enough to make the very next report profitable, so the leak begins at the next report rather than at markdown reversal. Markdown reversal determines the *size* of the leak, not whether it starts.

**The control is that `report()` is `onlyKeepers`.** No third party can force a report during the window, and holding reports is cheap because pending profit blocks neither senior withdrawals nor anything else. Suspend keeper reporting on recognizing the wipe, then:

1. Set `TRANCHE_SHARE_VARIANT` to `0` via `ProtocolConfig.setConfig` (`src/ProtocolConfig.sol:83`, owner-gated — a governance action through the 24h params timelock, so it is not immediate; start it as soon as a wiping loss is recognized rather than waiting for recovery to look imminent).
2. Once that lands, have a keeper call `USD3.syncTrancheShare()` (`USD3.sol:793`, `onlyKeepers`). This reads the variant and writes the fee bits; **step 1 has no effect on reports until this runs.**
3. Verify the fee bits are zero, then resume reporting. If a report lands between steps 1 and 2, the tranche share is still live.

**Restoring senior deployment.** Setting `MIN_SUSD3_BACKING_RATIO` to `0` makes `_subordinationDeployCapWaUSDC` return `type(uint256).max` (`USD3.sol:188-189`) and unblocks deployment. This removes the first-loss buffer at exactly the moment tail risk has materialized, so treat it as a deliberate override requiring a decision, not a default step.

**What none of this fixes.** The junior tranche remains unrecapitalizable until F-04 part 2 ships. Nothing revives sUSD3 short of that or a shutdown and redeploy. Reverse step 1 only once the fix is live and the tranche has been reset.

## Loss report landing during a waUSDC pause

**Trigger.** A `USD3.report()` recognizes a MorphoCredit loss while the waUSDC wrapper is paused.

**What happens on its own.** The loss reduces junior backing and therefore the permitted senior deployment cap, but `_tend` returns early while waUSDC is paused (`USD3.sol:332`), so the recall never runs and deployment stays above the newly reduced cap. That early return is deliberate and load-bearing: the recall path transfers waUSDC, and the deployed StataTokenV2 blocks transfers while paused, so without it the whole report would revert instead of deferring the recall.

**Why an operator has to notice.** `_tendTrigger` also returns false while paused (`USD3.sol:368`), so **keepers are not signalled** — the deferred recall is silent, not queued. When the pause lifts, the excess Morpho liquidity is immediately borrowable, and a later tend cannot recall what has already been borrowed. A subsequent default then converts previously recallable senior liquidity into additional loss.

1. When a loss report lands during a waUSDC pause, record that a recall is outstanding. Nothing on-chain does this for you.
2. On unpause, have a keeper call `tend` **before** borrowing resumes. Do not wait for the trigger; it will not fire on its own for this condition.
3. Confirm deployed waUSDC is at or below the post-loss cap before treating the incident as closed.

**Residual.** This is a race: an approved borrower can act between unpause and the manual tend. The window is why this is a runbook entry rather than a code guarantee, and closing it properly needs the pending-synchronization flag described in finding L-11.

## Related

- `docs/architecture.md` — USD3/sUSD3 subordination and tend/report flows.
- `src/lcc/README.md` §12 — LCC sharp edges, including owner-controlled surfaces.
