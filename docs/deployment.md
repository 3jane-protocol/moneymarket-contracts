# Deployment and CI Execution

## Scope

This repository is a contracts codebase. "Deployment" here primarily means CI execution and release publishing behavior.

## Mainnet Authority Register

The live-controller rows below were read at mainnet block `25741635`; the LCC rows record the shipped deployment
topology because no facility vault exists yet. They are a monitoring baseline, not immutable properties. Re-read live
roles before every deployment, upgrade, or role-sensitive incident action, and verify each LCC address after deployment.

| Surface | Controller / required owner | Delay / role |
|---|---|---|
| ProxyAdmins for USD3, sUSD3, MorphoCredit, ProtocolConfig, and the rate model | `0x3d3C41419aB401CD25055E8F9421D7D96D887885` | 7-day timelock (`getMinDelay() = 604800`) |
| LCC `UpgradeableBeacon` | same 7-day timelock | Fleet implementation upgrades |
| `ProtocolConfig.owner()` | `0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2` | 24-hour parameters timelock (`getMinDelay() = 86400`) |
| USD3 and sUSD3 TokenizedStrategy `management()` | same 24-hour parameters timelock | `pendingManagement() == address(0)` on both |
| LCC factory | `0x33333333Bd7045F1A601A1E289D7AB21036fB5EF` | 3-of-5 main Safe; creates factory-registered vaults |
| Per-facility LCC vault owner | Explicit nonzero address in the facility manifest | Script verifies the deployed owner against the declaration; no controller is hard-coded |

The upgrade and parameter controllers are deliberately different. The 7-day timelock owns each live ProxyAdmin and
must be monitored for implementation upgrades. The 24-hour timelock owns `ProtocolConfig` and controls parameter
writes. In particular, ProtocolConfig being upgradeable through a 7-day-owned ProxyAdmin does not make its live
`owner()` the 7-day timelock. Release monitoring should resolve every proxy's EIP-1967 admin, verify that admin's
`owner()`, and separately read each implementation-level owner or management role.

The USD3 and sUSD3 management hand-over had completed at the pinned block, with no pending management on either
strategy. That does not mean the broader controller migration was complete: the EmergencyController-to-
OperationalController switch-over below had not happened even though strategy management had moved to the parameters
timelock.

The facility owner is an operational choice, not necessarily the parameters timelock. Choosing the 24-hour timelock
makes every `onlyOwner` LCC action wait through its schedule/execute cycle. In particular, `shutdown()` must land
strictly before `closedEnd(epoch)` to truncate an auction, `unpause()` leaves the effective clock frozen during the
delay, delayed `setMarginOracle()` recovery can cross into terminal state and irreversibly sweep a missing-snapshot
pool, and `openEpochCall()` must land during `PreCall` (the example config gives it exactly 86,400 seconds, equal to the
minimum timelock delay). A fast Safe or a purpose-built operational timelock may therefore be the better owner for a
live facility. Whichever authority is approved must be declared in the durable JSON manifest; the creation simulation
and post-deployment verifier both reject a zero or mismatched owner.

### Emergency authority

At the same pinned block, `ProtocolConfig.emergencyAdmin()` still points to the old `EmergencyController` at
`0x84B31B84917485E221305EDf590B8E3660d2E051`; the OperationalController switch-over had not executed.
That controller's live role census was:

| Role | Live members | Effect |
|---|---|---|
| `OWNER_ROLE` | main 3-of-5 Safe `0x33333333Bd7045F1A601A1E289D7AB21036fB5EF` | Administers `EMERGENCY_AUTHORIZED_ROLE` immediately, with no timelock |
| `EMERGENCY_AUTHORIZED_ROLE` | the main Safe and Hypernative monitoring EOA `0x48c59b01Af01515E69460B6B5b55E557E914941d` | May invoke the controller's restricting emergency actions; does not administer roles |

The missing timelock on `OWNER_ROLE` is real, but this is not single-key ownership: the owner is the 3-of-5 Safe, and
the monitoring EOA holds only the emergency-authorized role. Re-read `ProtocolConfig.emergencyAdmin()` and enumerate
the active controller's roles after the pending switch-over rather than assuming this snapshot remains current.

### USD3 keeper indirection

`USD3.keeper()` was `0xc22158100b823E1EF612fBA265941Efe9e7d7975`, a contract with approximately 7.4 KB of
runtime code, not an EOA. Its downstream authorization surface was not established: probes for `owner()`,
`management()`, `governance()`, `gov()`, `admin()`, `keeper()`, and `authorized(address)` all reverted. Do not publish
an allowlist or claim that one EOA controls this router without verified source/ABI and a fresh authorization census.
At the strategy layer, TokenizedStrategy permits both the configured keeper and strategy management to call keeper
functions, so an operational halt must cover both paths.

## USD3/sUSD3 Control Surface

The implementation ABIs at HEAD contain `USD3.maxOnCredit()` and `sUSD3.withdrawalWindow()` as getters, but contain no
`setMaxOnCredit` or `setWithdrawalWindow` selector. Both values come from `ProtocolConfig`, whose owner is the 24-hour
parameters timelock:

| Control | Authoritative write path | Notes |
|---|---|---|
| Maximum USD3 deployment ratio | `ProtocolConfig.setConfig(MAX_ON_CREDIT, value)` | `USD3.maxOnCredit()` is read-only |
| sUSD3 withdrawal window | `ProtocolConfig.setConfig(SUSD3_WITHDRAWAL_WINDOW, value)` | Getter falls back to 2 days when the key is zero |
| USD3 supply cap | `ProtocolConfig.setConfig(USD3_SUPPLY_CAP, value)` | Emergency authority may only set it to zero |
| Stop all sUSD3 deposits | No reversible config key exists | One-way `sUSD3.shutdownStrategy()` is the only complete stop and requires current sUSD3 management or emergency admin |

The deployed sUSD3 ABI also has no no-argument `withdraw()`, `usd3Strategy()`, or `setUsd3Strategy(address)` selector.
Integrators must use the inherited ERC-4626 withdraw/redeem functions and the actual implementation ABI, not assume
those legacy declarations are callable.

## USD3 v1.2 Upgrade Preconditions

- `USD3_COMMITMENT_TIME` read `0` at mainnet block `25741635`. The v1.2 schedule and execution scripts both enforce
  that it is still zero, because v1.2 no longer enforces the legacy deposit lock. The execution script rechecks the
  value so its own path does not silently release a lock created during the 7-day delay. This is not a contract-level
  prevention: any `EXECUTOR_ROLE` holder, including the main Safe and deployer EOA, can call the TimelockController's
  `execute` directly and bypass both the script and its recheck. Do not set this reader-less key after the upgrade.
- `USD3_REDEMPTION_FLOOR` and `USD3_REDEMPTION_FLOOR_BPS` both read `0` at that block. The implementation upgrade does
  not activate the redemption floor. Before rollout approval, governance must either set reviewed nonzero values
  through the 24-hour parameters timelock or explicitly sign off that the floor launches disabled. Until a nonzero
  configuration is verified, do not describe the source-level floor as an active reserve.

## LCC Implementation Deployment

The canonical `LCCVault` deployment artifact is compiled for Cancun with official solc `0.8.35`, via IR, 150
optimizer runs, and no metadata bytecode hash. Its measured runtime is 24,099 bytes, 177 bytes below the internal
ceiling and 477 bytes below EIP-170.
Because it uses `ReentrancyGuardTransient`, every deployment chain must support EIP-1153. Hardhat uses pinned stable
solc-js `0.8.35` for its LCC compile/test artifact, which must not be deployed.

Run `yarn build:forge:size` before approving an implementation release. In addition to building with sizes, the
command checks the compiler, EVM target, optimizer, metadata, internal 24,276-byte ceiling, linked-library set, and
the recursively canonicalized build-profile storage layout and external ABI. It resolves both `LCCVault` and
`NotificationVault` by their complete compiler settings, rejecting ambiguous or mismatched leftover artifacts with
an explicit diagnostic before applying the release gates.

`LCCAuctionLib` and `LCCConfigLib` are the implementation's two externally linked libraries. Deploy and link both
before deploying each new `LCCVault` implementation, then schedule the beacon upgrade through the 7-day timelock; the
release checker requires exactly those two link references. The account, bucket, type, error, and event libraries are
compiled internally and require no deployment or link addresses. The layout gate
reads the storage layout embedded in the canonical build-profile artifact and compares encoding, byte widths, mapping
key/value types, arrays, and every packed struct member recursively. The versioned
`docs/lcc-vault-storage-layout.json` baseline is reviewer-controlled and is never regenerated by the checker; an
intentional layout update requires a separate reviewed baseline change.

The current layout packs each pending-activation and exit-maturity margin/commitment pair into one
`LCCTypesLib.Bucket` word. The four historical field getters remain ABI-compatible `uint256` views. Exit exposure
uses three words for six `uint128` amounts and keeps its explicit fourth-word `listed` membership guard.
Auction state uses two words for four `uint128` counters; `getAuctionState` remains wire-compatible, and the linked
`LCCAuctionLib` records packed fill updates.

## GitHub Actions Workflows

- `foundry.yml`
  - Non-invariant tests: `forge-test` (matrix: slow + fast fuzz budgets)
    - Includes Jane token/rewards suites under `test/forge/jane/**`
  - IRM tests: `irm-tests`
  - Core invariants: `core-invariant-fast`, `core-invariant-deep`
  - USD3 invariants: `usd3-invariant-fast`, `usd3-invariant-deep`
  - Fork tests (including legacy USD3 migration regression tests): `fork-tests`
- `formatting.yml`: formatter/lint checks
- `hardhat.yml`: hardhat test execution
- `halmos.yml`: halmos symbolic checks
- `certora.yml`: certora workflow definition (triggered section currently commented out)
- `npm-release.yml`: manual publish workflow
- `update-docs.yml`: scheduled and manual doc-gardening automation

## Trigger Model

### Foundry

- PR/push: `forge-test` (both slow + fast matrix) + IRM + fast invariants (core + usd3)
- Schedule: deep invariants (core + usd3) + fork tests
- Manual dispatch: all jobs (non-invariant + IRM + fast/deep invariants + fork tests)
- Fork tests also triggered by PR label `ci/run-fork-tests`
- The `fork-tests` job still runs `test:forge:fork:upgrade` to exercise the current USD3 upgrade path.

### Doc Gardening

- Weekly schedule and manual dispatch
- Opens a PR only when documentation drift is detected

## Secrets and Variables

- `ETH_RPC_URL` (secret): required for fork tests
- `NPM_TOKEN` (secret): required for npm publish
- `ANTHROPIC_API_KEY` (secret): required for doc-gardening automation via Claude Code Action

## Release Notes

When workflow names or test script names change, update:

1. `.github/workflows/*.yml`
2. `package.json` scripts
3. `AGENTS.md` CI map
4. `docs/deployment.md`
