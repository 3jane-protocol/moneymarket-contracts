# Deferred full-closeout bounce

## Decision anchor

This decision applies to `feat/lcc-v2`, based on commit `88180c5e`. The measured full-closeout experiment and the
active-only replacement both used the canonical LCC compiler settings: solc `0.8.35`, Cancun, via IR, and 150
optimizer runs.

## Deferred design

The full-closeout form used `type(uint256).max` as a sentinel for `bounceCommitment`. Unlike a nominal bounce equal
to the account's active commitment, the sentinel also unwound an unmatured exit bucket, refunded pending deposits,
paid matured-but-unclaimed exit margin, cleared exit state, and shared a new `_closeout` helper with
`claimRemainingMargin`.

That implementation measured 24,791 runtime bytes at 150 runs, 215 bytes over EIP-170. It forced exit accounting and
maturity assignment into a third externally linked library solely to recover enough vault bytecode.

## Owner decision

Full closeout is deferred. The required bouncer action is a reduction of the active depositor position: partial or
entire active commitment, with the paired active margin returned pro rata. The more complicated states already
self-resolve: a mid-exit user is irrevocably leaving, a matured-but-unclaimed user is economically out and can claim,
and a pending deposit folds within one epoch. The bouncer therefore waits for pending activation and leaves exiting
users to their exit.

The active-only experiment still measured 24,703 bytes without `LCCExitLib`, 127 bytes over EIP-170, so the library
remains in the shipping topology. With the library and current remediations, the shipping vault measures 24,144 bytes.

## Reopening

Re-including sentinel closeout semantics reopens the byte-lever decision. A future proposal must remeasure against
the then-current canonical artifact and explicitly choose how to fund the added runtime: retain or expand linked
extraction, reduce other vault code, or revise the release ceiling policy. Exit-bucket unwind, pending refund,
matured-claim handling, and the `claimRemainingMargin` sharing regression must return as one reviewed unit.
