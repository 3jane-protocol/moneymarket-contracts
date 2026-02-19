Update repository documentation to match current code and CI behavior.

Scope:

- `README.md`
- `AGENTS.md`
- `docs/index.md`
- `docs/architecture.md`
- `docs/tech-stack.md`
- `docs/deployment.md`
- `docs/doc-gardening.md`
- `CLAUDE.md` (wrapper only)

Required process:

1. Read `package.json`, `foundry.toml`, and `.github/workflows/*.yml`.
2. Validate command names, workflow/job names, trigger behavior, and environment requirements.
3. Update docs where references drifted.
4. Keep `CLAUDE.md` as a thin include wrapper.
5. Keep `AGENTS.md` as the operational quick-reference.

Guardrails:

- Do not change protocol/security semantics without explicit code evidence.
- Do not rewrite invariant intent unless matched by concrete contract/test changes.
- Prefer minimal factual edits over stylistic rewrites.

Output:

- Commit only documentation and workflow-command files in scope.
- Include a concise summary of what changed and why.
