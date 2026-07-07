# Docs Index

This directory contains deeper reference docs for engineering and agent workflows.

## Documents

- `docs/architecture.md`: Contract and test architecture, core flows, and invariants context.
  - Includes Jane token/rewards architecture coverage for `src/jane/` and `MarkdownController` interactions.
  - Includes the LCC vault domain for `src/lcc/`, including `LCCVault`, `LCCVaultFactory`, and USD3 Notification Vault (`USD3n`) integration.
- `src/lcc/README.md`: auditor-facing LCC mechanics deep-dive with Mermaid diagrams (epoch phases, funding/slash/auction flows, worked examples).
- `docs/tech-stack.md`: Toolchain, Foundry profiles, and environment requirements.
- `docs/deployment.md`: CI workflow behavior and execution model.
- `docs/doc-gardening.md`: Ongoing documentation maintenance checklist and guardrails.

## Primary Entry Points

- Human quick start: `README.md`
- Agent operational guide: `AGENTS.md`
- Claude compatibility loader: `CLAUDE.md`
