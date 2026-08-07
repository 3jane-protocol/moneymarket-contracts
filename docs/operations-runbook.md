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
deposit for a whitelisted victim. Grant only to a dedicated adapter that verifies beneficiary authorization, or to a
closed facility operator with a documented consent channel. A consent-verifying adapter must bind at least a nonce,
deadline, vault, payer, asset and commitment bounds, and the `allowPendingActivation` choice. If a generic router must
be admitted, implement the factory consent registry or in-protocol signature check first.

**Trust consequences.** A role holder can refresh a beneficiary's `commitmentStartEpoch` with floor-sized deposits,
consume the beneficiary's `userCommitmentCap` and the protocol cap, and stage pending exposure that blocks both
`requestExit` and the bouncer's `bounceCommitment`. Margin is irrevocably credited to the beneficiary; the payer has
no recovery right. Revocation stops new delegated deposits but does not unwind credited active or pending exposure.
The payer is intentionally not checked against the depositor whitelist; the beneficiary still passes the whitelist,
one-vault policy, and admissions module.

Before granting the role:

1. Verify the candidate is the approved consent-verifying adapter bytecode, or record the closed facility operator's
   consent channel and accountable owner. Reject any target that forwards caller-selected arbitrary calldata.
2. Verify `factory.getRoleAdmin(factory.DEPOSIT_OPERATOR_ROLE()) == factory.OWNER_ROLE()` and that the Safe is the
   sole owner. Submit `grantRole` from the factory owner.
3. Verify `factory.isDepositOperator(candidate)` is true. The view is for operations and integrations; enforcement
   occurs inside `authorizeDeposit`.

Before every adapter-routed deposit, pre-check the beneficiary is nonzero and whitelisted, has no exit in progress,
has no incompatible pending activation, and is eligible under the warm one-vault pointer and admissions module.
Check beneficiary and protocol cap headroom, current oracle availability, commitment bounds, and deadline. Default
`allowPendingActivation` to `false`; permit `true` only when the beneficiary's signed authorization explicitly chose
pending activation. These pre-checks reduce failed transactions but do not replace the adapter's consent proof.

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
automatically re-points `vaultOf[user]` from A to B. A matured exiter is still open until the user calls
`claimExitedMargin`, even when the claim amount is zero. Shutdown users likewise call `claimRemainingMargin`; an
otherwise plain account whose entire active commitment was bounced is already eligible to re-point.

If A has more than 64 finalized calls beyond the user's stored cursor, the first B deposit is conservatively denied.
Call `materializeAccount(user)` on A permissionlessly, in batches if needed, then retry B. A live auction can also
keep the closure replay incomplete until settlement.

Disabling `oneVaultPolicyEnabled` is prospective-only: deposits may create multiple open positions and the outermost
successful deposit remains the warm `vaultOf` pointer. Before re-enabling, inventory all such users, reconcile every
multi-vault user offchain to one open position, and verify that no family vault is paused or shut with an unclaimable
position. Admission checks only the vault named by the warm pointer: if A remains open while B is recorded, closing
and reopening B after re-enablement does not discover A. Re-enabling does not close existing positions, and the latest
warm pointer can top-up-block a healthy older position until the recorded vault closes.

## LCC factory ownership rotation

A two-step factory ownership transfer re-keys every family vault, including exceptional settlement recovery. Do not
start or accept a rotation while any vault has a pending auction slot with a missing call-open price snapshot. Both
steps of recovery — installing a healthy margin oracle and sending the owner-triggered `synced` disposal — must stay
under one owner throughout the incident. Confirm every family vault's pending slot and snapshot state before
proposing the new owner.

## Related

- `docs/architecture.md` — USD3/sUSD3 subordination and tend/report flows.
- `src/lcc/README.md` §12 — LCC sharp edges, including owner-controlled surfaces.
