# DOX framework

- DOX is a highly performant AGENTS.md hierarchy installed here
- Agent must follow DOX instructions across any edits
- Project: a weight-loss cookbook — a layered Python knowledge-base stack (`src/cookbook_kb/`) exposed over a FastAPI REST boundary, with a native multiplatform SwiftUI client (`app/`) as a thin-but-cached front end. See `ARCHITECTURE.md` for the teaching spine; DOX does not duplicate it.

## Core Contract

- AGENTS.md files are binding work contracts for their subtrees
- Work products, source materials, instructions, records, assets, and durable docs must stay understandable from the nearest applicable AGENTS.md plus every parent AGENTS.md above it

## Read Before Editing

1. Read the root AGENTS.md
2. Identify every file or folder you expect to touch
3. Walk from the repository root to each target path
4. Read every AGENTS.md found along each route
5. If a parent AGENTS.md lists a child AGENTS.md whose scope contains the path, read that child and continue from there
6. Use the nearest AGENTS.md as the local contract and parent docs for repo-wide rules
7. If docs conflict, the closer doc controls local work details, but no child doc may weaken DOX

Do not rely on memory. Re-read the applicable DOX chain in the current session before editing.

## Update After Editing

Every meaningful change requires a DOX pass before the task is done.

Update the closest owning AGENTS.md when a change affects:

- purpose, scope, ownership, or responsibilities
- durable structure, contracts, workflows, or operating rules
- required inputs, outputs, permissions, constraints, side effects, or artifacts
- user preferences about behavior, communication, process, organization, or quality
- AGENTS.md creation, deletion, move, rename, or index contents

Update parent docs when parent-level structure, ownership, workflow, or child index changes. Update child docs when parent changes alter local rules. Remove stale or contradictory text immediately. Small edits that do not change behavior or contracts may leave docs unchanged, but the DOX pass still must happen.

## Hierarchy

- Root AGENTS.md is the DOX rail: project-wide instructions, global preferences, durable workflow rules, and the top-level Child DOX Index
- Child AGENTS.md files own domain-specific instructions and their own Child DOX Index
- Each parent explains what its direct children cover and what stays owned by the parent
- The closer a doc is to the work, the more specific and practical it must be

## Child Doc Shape

- Create a child AGENTS.md when a folder becomes a durable boundary with its own purpose, rules, responsibilities, workflow, materials, or quality standards
- Work Guidance must reflect the current standards of the project or user instructions; if there are no specific standards or instructions yet, leave it empty
- Verification must reflect an existing check; if no verification framework exists yet, leave it empty and update it when one exists

Default section order:
- Purpose
- Ownership
- Local Contracts
- Work Guidance
- Verification
- Child DOX Index

## Style

- Keep docs concise, current, and operational
- Document stable contracts, not diary entries
- Put broad rules in parent docs and concrete details in child docs
- Prefer direct bullets with explicit names
- Do not duplicate rules across many files unless each scope needs a local version
- Delete stale notes instead of explaining history
- Trim obvious statements, repeated rules, misplaced detail, and warnings for risks that no longer exist

## Closeout

1. Re-check changed paths against the DOX chain
2. Update nearest owning docs and any affected parents or children
3. Refresh every affected Child DOX Index
4. Remove stale or contradictory text
5. Run existing verification when relevant
6. Report any docs intentionally left unchanged and why

## User Preferences

Durable, project-wide behaviors the user has asked for. Record new ones here or in the relevant child AGENTS.md.

- **Be critical, not agreeable.** Question and critique suggestions to reach the best solution. Never reflexively agree ("you're right", "absolutely"); give thoughtful, honest answers and surface trade-offs.
- **DRY first.** Before implementing a method/view/endpoint, confirm it doesn't already exist. The iOS/native app trails the backend; when porting, check the existing backend (and the further-ahead app) for an implementation to reuse.
- **Learning-first, per-layer.** This repo is built to be read as a layered progression (`ARCHITECTURE.md`). Keep that spine intact: a change belongs in exactly one layer; don't smear logic across layers.
- **Verify against the live model from the main session, not a sandbox.** The LiteLLM proxy is reachable from the main session but blocked (HTTP 402/403) inside Workflow/subagent sandboxes. Run anything needing `eagle-nothink`/`jina` from the main session.
- **Report outcomes faithfully.** If tests fail, say so with output; if a step was skipped, say it; don't claim done until verified.

## Child DOX Index

- `src/cookbook_kb/AGENTS.md` — the Python knowledge-base stack: the layered teaching spine (functions → tools → agent → sub-agents → harness), the substrate pipeline (llm/ ingest/ extract/ normalize/ store/ retrieve/), the FastAPI REST boundary, and the MCP server. Owns all server-side contracts.
- `app/AGENTS.md` — the native multiplatform SwiftUI client (iPhone/iPad/Mac): a thin-but-cached client over the REST boundary. Owns the SwiftData repository architecture and all client-side contracts.
- `deploy/AGENTS.md` — packaging the `src/cookbook_kb` backend as an Olares app (Dockerfile + Helm chart + manifest) so the client can reach it over the network. Owns the container/deploy contract; does not own application code.

Top-level folders without their own DOX (owned by root): `data/` (the SQLite DB, raw/interim/seed corpora, FDC nutrition CSVs), `scripts/` (one-off ingest entry points + `dox_check.py`, the DOX drift guard, and `hooks/pre-commit`), `tests/`, `research/`, `docs/` (`ARCHITECTURE.md`, `docs/MCP_SERVER.md`, `docs/ui-proposal.md`), `config.yaml`, `pyproject.toml`, `.dockerignore` (backend image build context), `.github/workflows/dox.yml` (CI enforcement) + `build-backend.yml` (builds/pushes the backend image to GHCR).

**DOX drift guard:** `scripts/dox_check.py` flags when source under a boundary changed but its `AGENTS.md` didn't. Local pre-commit (`git config core.hooksPath scripts/hooks`) warns; CI (`.github/workflows/dox.yml`) fails the PR with `--strict`. Run manually: `python scripts/dox_check.py --staged`.
