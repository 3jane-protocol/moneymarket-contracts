# Doc Gardening

## Goal

Keep operational and architectural documentation synchronized with code, tests, and workflows.

## Cadence

- Weekly automated pass via `update-docs.yml`
- Manual on-demand run via workflow dispatch or `/3jane:update-docs`

## Source of Truth Priority

1. Code and workflow files
2. `package.json` scripts
3. Operational docs (`AGENTS.md`)
4. Deep docs (`docs/*.md`)

## Checklist

- Verify command names match `package.json`
- Verify workflow/job names match `.github/workflows/`
- Verify test-suite references match current paths
- Remove stale files/modules and dead references
- Ensure README links resolve
- Ensure docs index points to existing files

## Guardrails

Automation may safely update:

- Paths, file names, command names, workflow labels, and stale references
- Missing cross-links between docs

Automation must flag for human review (do not rewrite silently):

- Security-sensitive runbooks
- Invariant semantics or expected-failure rationale
- Protocol formulas and economics
- Behavioral claims not grounded in code references

## Change Reporting Format

When doc gardening opens a PR, include:

- What drift was found
- Which files were updated
- Why each update is mechanically correct (script/workflow/path evidence)
- Any unresolved items requiring human review
