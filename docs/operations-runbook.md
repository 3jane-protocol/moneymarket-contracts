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

**Before any wipe-and-recall sequence, stop borrowing first.** The F-04 record previously stated that a wiped tranche "stops writing new credit" and that the zero deployment cap is static. Both are false (Guardian round-4 `B/M-25`, corrected in `docs/deferred-f04-dead-tranche.md`). A Morpho repayment returns waUSDC and reduces debt before token collection (`src/Morpho.sol:275-305`), and `_beforeBorrow` (`src/MorphoCredit.sol:601-632`) never checks USD3's live junior cap or a pending recall — so a Current borrower with headroom can redraw the liquidity a repayment just recreated, ahead of tend. Set `IS_PAUSED`, or `DEBT_CAP` to `0`, **before** recalling, and keep it set until the recall has completed. This is dormant at the live configuration only because `MIN_SUSD3_BACKING_RATIO` is `0`, which disables the wipe-drives-cap-to-zero policy outright; it becomes live the moment that ratio is set nonzero with credited borrowers outstanding.

## USD3 and sUSD3 admission controls

`ProtocolConfig.setEmergencyConfig` accepts exactly four restrictions: `IS_PAUSED = 1`, or `DEBT_CAP = 0`,
`MAX_ON_CREDIT = 0`, and `USD3_SUPPLY_CAP = 0`. There is no sUSD3 supply-cap key and no reversible emergency config
write that stops all junior deposits. `USD3_SUPPLY_CAP = 0` stops USD3 deposits, not direct deposits of already-held
USD3 into sUSD3. `DEBT_CAP = 0` also does not necessarily close sUSD3 capacity while actual market debt remains,
because the junior cap uses the greater of actual debt and configured potential debt.

If all new sUSD3 deposits must stop, first read the sUSD3 TokenizedStrategy `management()` and `emergencyAdmin()`
addresses. Either can call `shutdownStrategy()`, which halts deposit/mint but is a one-way, irreversible strategy
shutdown. Do not submit a nonexistent junior-cap key, and do not assume the ProtocolConfig emergency controller also
holds either sUSD3 strategy role without a live read.

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

## Creating and authorizing an LCC vault

LCC deployment has split authority. The main Safe owns `LCCVaultFactory`; USD3 management is the 24-hour parameters
timelock `0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2`; and each facility manifest must explicitly declare its approved,
nonzero vault owner. The LCC beacon's separate fleet upgrade authority is the 7-day timelock. Do not require or
represent those roles as one account. See `docs/deployment.md` for the timing trade-offs when selecting a facility
owner.

Use `script/operations/CreateLCCVaultSafe.s.sol` with the same finalized JSON in every phase:

1. Complete the facility-specific leverage-dispersion and per-stake loss-budget review. The example deliberately leaves
   `acknowledgePerpetualTenor`, `acknowledgeHoldToMaturity`, and `acknowledgeFullAuctionAward` false. Set the first true
   only when a perpetual `maxEpochs = 0` facility has an approved dispersion justification; set the second true only
   when `minCommitmentEpochs + exitDelayEpochs >= maxEpochs != 0` deliberately makes terminal wind-down the only exit;
   set the third true only when the loss budget approves `maxAuctionAwardBps = 10000`, the maximum award-loss case.
   Record the named approver. The script rejects each case without its acknowledgement and rejects a missing or zero
   `params.owner`; it verifies the deployed owner against that explicit declaration but does not mandate a particular
   address.
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
   simulated vault's address, factory provenance, owner, protocol wiring, and both USD3 flags.
5. After the Safe transaction executes on chain, run `verify(string)` with the deployment JSON. Archive its successful
   output with the manifest. `verify(address,address)` with the vault and explicit expected owner is a fallback when the
   JSON is unavailable, but the JSON-based check is authoritative because it also recomputes the expected address.

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
