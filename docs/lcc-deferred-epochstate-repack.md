# Deferred: LCCVault EpochState / RiskConfig storage repack

**NOT IMPLEMENTED — excluded from current audit scope.** This is a commit-pinned historical decision record, frozen as of commit `cf563d94` and the compiler configuration official solc `0.8.35+commit.47b9dedd`, via-IR, default Yul optimizer sequence, `optimizer_runs = 150`, Cancun. It exists so the analysis is never re-researched; it makes no claims about current contract behavior.

## Decision

Packing `EpochState` from 12 storage slots to 6 (and `RiskConfig` from 6 to 3) is **policy-deferred**. Measured runtime sizes at `optimizer_runs = 150`, against a baseline of 24,208 bytes:

| Variant | Default Yul sequence | Prior official Yul sequence |
| --- | ---: | ---: |
| Full EpochState 12→6 | 24,892 B | 24,543 B |
| Partial 7-slot (flags beside denominator) | 24,775 B | 24,440 B |
| Partial + guard removals + cold-library helper | — | 24,317 B |
| RiskConfig 6→3 | 24,564 B | — |

Several variants fit the hard EIP-170 limit (24,576 bytes) but fail the ≥200-byte reserve policy (reserves of 33 / 136 / 12 bytes). Only the 24,317-byte variant meets the reserve target, and it requires the prior (less-tested) optimizer sequence plus call-graph-dependent guard removals and a linked-library extraction. The rejection is **policy** — default optimizer sequence, typed ABI, no guard coupling — not physics.

## Baseline supersession

The reserve arithmetic above is relative to the 24,208-byte artifact at `cf563d94`. Later size reductions change it: the dead-state removal landed in the same change series shrank the artifact to 23,955 bytes, against which the default-sequence RiskConfig 6→3 variant projects to roughly 24,311 bytes. The release ceiling has since moved deliberately from 24,276 to 24,376 bytes (`MAX_RUNTIME_BYTES` in `scripts/check-lcc-release-artifact.js`); the new ceiling preserves the ≥200-byte EIP-170 reserve policy by construction. The 24,311-byte projection would fit under that ceiling, so the old ceiling no longer settles the variant's verdict. This ceiling move does not re-open or re-decide the repack: **re-measure the variants against the current artifact and current ceiling before treating any per-variant verdict here as binding**; only the measured per-variant costs are frozen facts.

## Foregone gas (for future reference)

`fundCall` −48.4k first funder / −14.2k subsequent (all variants); `openEpochCall` −44.2k; `finalizeEpochSlash` −49.6k dispose path / −27.6k auction path; account replay −2.1k per defaulted epoch.

## Analysis preserved from the decision (derived at `cf563d94`)

- Slot grouping: `A: callOpened + slashFinalized + slashDisabledByShutdown + commitmentDenominator(u128)` · `B: callAmount + marginAtCallOpen` · `C: fundedAmount + marginReleased` · `D: fundedUsersRemainingMargin + fundedUsersRemainingCommitment` · `E: slashedMargin + returnPool` · `F: returnCommitment`. Packing the three flags beside `commitmentDenominator` is mandatory — it keeps the finalize-time flag write on a warm nonzero slot. `{slashedMargin, returnPool}` are paired for the replay short-circuit read.
- Width proofs reduce to existing invariants: `commitmentDenominator`/`marginAtCallOpen` snapshot the u128 `Totals` fields; `callAmount ≤ commitmentDenominator`; the roll identity `fundedAmount + fundedUsersRemainingCommitment ≤ commitmentDenominator`; `marginReleased + fundedUsersRemainingMargin ≤ marginAtCallOpen`; `returnCommitment ≤ packingHeadroom`.
- The analysis identified the coverage the packing would have required: packed round-trips at uint128 boundaries, cast-boundary reverts, the relational invariants above, and the cap-lowered-below-utilization open-and-fund case (recorded for completeness; none of it was implemented).
