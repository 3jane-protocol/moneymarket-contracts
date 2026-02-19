# Tech Stack

## Languages and Runtime

- Solidity `0.8.19`
- TypeScript/Node.js for Hardhat tooling and auxiliary tests
- Foundry as the primary Solidity test/build toolchain

## Package and Task Runner

- Package manager and script runner: `yarn`
- Canonical scripts are in `package.json`

## Foundry Profiles (`foundry.toml`)

- `default`: optimized build settings (`via_ir = true`, high optimizer runs)
- `build`: build-only profile
- `test`: general test profile (excludes IRM path)
- `test-irm`: IRM-specific profile with `via_ir = true`
- `halmos`: symbolic test target path
- `fork`: fork-test profile with pinned block number

## Test Tooling

- Forge for unit/integration/fuzz/invariant/fork suites
- Hardhat for TypeScript-side tests
- Halmos for symbolic checks
- Certora configuration present, workflow currently disabled by triggers

### Jane-focused test entrypoints

- Jane token tests: `test/forge/jane/JaneToken*.t.sol`
- Jane rewards tests: `test/forge/jane/rewards/*.t.sol`
- Markdown + Jane integration: `test/forge/integration/markdown/MarkdownControllerJaneTest.sol`

Useful targeted invocations:

- `yarn run test:forge --match-path 'test/forge/jane/**/*.t.sol' -vvv`
- `yarn run test:forge --match-contract MarkdownControllerJaneTest -vvv`
- `yarn run test:forge --match-contract RewardsDistributorIntegrationTest -vvv`

## CI Tooling

- GitHub Actions workflows under `.github/workflows/`
- Foundry workflow includes baseline, IRM, invariants, and fork jobs
- Formatting and Hardhat workflows run separately
- Fork upgrade tests remain in CI as historical regression checks for the completed USD3 migration.

## Environment Requirements

- Fork tests require `ETH_RPC_URL` secret in GitHub Actions
- Local fork testing also requires `ETH_RPC_URL` in environment
- Node modules managed via `yarn install --frozen-lockfile` in CI
