# Deferred partial withdraw

## Decision anchor

This decision applies to the fresh LCC v2 family on `feat/lcc-v2`, based on commit `88180c5e`. It records why the
shipping interface keeps user exits full-account even though an authorized bouncer may reduce active commitment.

## Deferred design

A user-directed partial withdrawal would remove some active commitment and return the paired active margin while
leaving the rest of the account callable. The local pro-rata arithmetic is straightforward; the historical exit
accounting is not.

When a call opens, LCC freezes exit exposure by call and maturity in aggregate rows. Those rows attribute margin and
commitment to a maturity bucket, but they do not attribute the frozen amounts to individual users. Later,
`_reduceExitBucketsForSlash` consumes those aggregates when unfunded exiters default. A user withdrawal after the
snapshot cannot subtract that user's exact frozen share, because the vault no longer has the per-user information
needed to identify it. Reducing only the live account or bucket would leave the call-local row overstated and can
make later slash reconciliation double-decrement the bucket and underflow.

## Decision

Partial user withdrawal is deferred. `requestExit` remains an irrevocable full-account exit, followed by
`claimExitedMargin` at maturity. `claimRemainingMargin` remains the full wind-down claim under shutdown or terminal
sunset.

`bounceCommitment` does not establish a safe user-withdraw precedent. It is an authorized, active-only reduction
that rejects pending deposits and every exit in progress, rejects live auctions and an opened unfinalized current
call, and materializes the account before changing it. Those sequencing guards ensure no live call-local exit row
can reference the active position being reduced. A user-timed withdrawal cannot impose the same administrative
timing restriction without becoming unavailable exactly when users need normal liquidity.

## Reopening

A future proposal needs per-user attribution for every frozen call/maturity exposure or a new reconciliation design
that proves aggregate rows, buckets, accounts, and global totals stay aligned across arbitrary withdrawal timing. It
must include defaulted-exiter, live-call, maturity-fold, and bounded-replay tests and remeasure LCCVault runtime under
the canonical release settings before changing the interface.
