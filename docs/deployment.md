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
| LCC factory `owner()` / sole `OWNER_ROLE` | `0x33333333Bd7045F1A601A1E289D7AB21036fB5EF` | 3-of-5 main Safe; creates vaults and controls every family vault |

The upgrade and parameter controllers are deliberately different. The 7-day timelock owns each live ProxyAdmin and
must be monitored for implementation upgrades. The 24-hour timelock owns `ProtocolConfig` and controls parameter
writes. In particular, ProtocolConfig being upgradeable through a 7-day-owned ProxyAdmin does not make its live
`owner()` the 7-day timelock. Release monitoring should resolve every proxy's EIP-1967 admin, verify that admin's
`owner()`, and separately read each implementation-level owner or management role.

The USD3 and sUSD3 management hand-over had completed at the pinned block, with no pending management on either
strategy. That does not mean the broader controller migration was complete: the EmergencyController-to-
OperationalController switch-over below had not happened even though strategy management had moved to the parameters
timelock.

LCC v2 has no per-facility owner. The non-upgradeable factory's sole `OWNER_ROLE` is the family-wide authority for
`openEpochCall`, `shutdown`, unpause, oracle rotation, mutable risk configuration, vault creation, and subordinate role
administration. The shipped owner is the main 3-of-5 Safe rather than the 24-hour parameters timelock, avoiding a
mandatory day-long delay on phase-sensitive actions: `shutdown()` must land strictly before `closedEnd(epoch)` to
truncate an auction, and `openEpochCall()` must land during `PreCall`. Two-step factory ownership transfer re-keys every
vault at once, so verify `factory.owner()`, its role census, and any pending owner before each deployment or incident.
The durable JSON manifest records facility parameters and risk acknowledgements, not an independent vault owner.

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
| USD3 supply cap | `ProtocolConfig.setConfig(USD3_SUPPLY_CAP, value)` | Emergency authority may only set it to zero; zero blocks even exempt receivers, so it can slash LCC funders mid-call — see the zero-cap hazard in `docs/operations-runbook.md` |
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
optimizer runs, and no metadata bytecode hash. Its measured runtime is 24,254 bytes, 22 bytes below the internal
ceiling and 322 bytes below EIP-170. The active-only bounce and family-authority monolith measured 24,703 bytes,
127 bytes over EIP-170, so exit-exposure reconciliation and maturity assignment remain extracted into `LCCExitLib`
at 150 runs.
Because it uses `ReentrancyGuardTransient`, every deployment chain must support EIP-1153. Hardhat uses pinned stable
solc-js `0.8.35` for its LCC compile/test artifact, which must not be deployed.

Run `yarn build:forge:size` before approving an implementation release. In addition to building with sizes, the
command checks the compiler, EVM target, optimizer, metadata, internal 24,276-byte ceiling, linked-library set, and
the recursively canonicalized build-profile storage layout and external ABI. It resolves both `LCCVault` and
`NotificationVault` by their complete compiler settings, rejecting ambiguous or mismatched leftover artifacts with
an explicit diagnostic before applying the release gates.

`LCCAuctionLib`, `LCCConfigLib`, and `LCCExitLib` are the implementation's three externally linked libraries. Deploy
and link all three before deploying each new `LCCVault` implementation, then schedule the beacon upgrade through the
7-day timelock; the release checker requires exactly those three link references. The account, bucket, type, error,
and event libraries are compiled internally and require no deployment or link addresses. The layout gate
reads the storage layout embedded in the canonical build-profile artifact and compares encoding, byte widths, mapping
key/value types, arrays, and every packed struct member recursively. The versioned
`docs/lcc-vault-storage-layout.json` baseline is reviewer-controlled and is never regenerated by the checker; an
intentional layout update requires a separate reviewed baseline change.

Before deploying a new implementation or pointing the beacon at one, verify onchain that each linked address contains
the expected `LCCAuctionLib`, `LCCConfigLib`, or `LCCExitLib` runtime bytecode from the approved canonical build, and
verify that the implementation's link references resolve to those addresses. This bytecode verification is the only
control against a bad library link; the implementation deliberately has no onchain code-size or authenticity guard.
An `extcodesize` check would catch only a codeless link, while a wrong-but-code-bearing library -- the likelier
deployment error -- would pass it. Retaining that partial guard would imply the class was handled onchain even though
the release procedure must authenticate every linked bytecode regardless.

The exact-return-shape check at the `LCCExitLib` boundary is not a general link guard. Only
`assignExitMaturity`, the sole returning entrypoint, rejects a codeless or malformed return. The four void call sites
require zero return bytes, which is exactly what a successful delegatecall to a codeless address produces. On an
upgrade with existing exit state, such a link makes `openEpochCall` skip `snapshotExitBucketsForCall` and slash
finalization skip `reduceExitBucketsForSlash` while aggregate totals still decrement. Maturity then decrements the
same buckets again and bricks sync. Installing any bad link already requires the beacon owner acting through the
7-day timelock, the same authority that could install arbitrary implementation logic, so authenticity remains an
explicit deployment-procedure obligation.

The current layout packs each pending-activation and exit-maturity margin/commitment pair into one
`LCCTypesLib.Bucket` word. The four historical field getters remain ABI-compatible `uint256` views. Exit exposure
uses three words for six `uint128` amounts and keeps its explicit fourth-word `listed` membership guard.
`LCCExitLib` operates on those unchanged vault storage roots through a typed storage anchor; extraction adds no library
storage and does not change the vault layout or ABI. Auction state uses two words for four `uint128` counters;
`getAuctionState` remains wire-compatible, and the linked `LCCAuctionLib` records packed fill updates.

The release checker currently pins only the `LCCVault` external ABI, not `LCCVaultFactory`. The approved
pre-deployment factory delta includes the prior `requireBouncer` to boolean `isBouncer` change, removal of
`admissionsModuleVersion`, and two-argument `AdmissionsModuleUpdated`, plus this release's
`DEPOSIT_OPERATOR_ROLE()` and `isDepositOperator(address)` views, three-argument
`authorizeDeposit(address payer,address beneficiary,bool hadOpenExposure)`, and
`UnauthorizedDepositOperator(address payer)` error. The vault ABI baseline intentionally changes only the `deposit`
selector/input list and the `DepositCheckpointed` payer field/topic; its storage-layout baseline remains unchanged.
There is no deployed compatibility impact. After factory deployment, any further ABI or event-signature change must
be treated as an explicit release decision rather than assumed to be covered by the vault ABI gate.

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
