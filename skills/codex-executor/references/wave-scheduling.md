# Wave Scheduling & Delegation Patterns

Patterns adapted from multi-agent orchestration (Orca & Herdr) for running up to
3 concurrent Codex executors safely inside a shared workspace without Git
worktrees.

## 0. Task Eligibility Gate (No Long Background Waiting)

Keep executor slots fast and unblocked by separating **foreground execution** from
**long background waiting**:

- **Keep on the Orchestrator**: long-running builds/bootstraps/benchmarks,
  daemons/dev servers, file watchers, polling/`sleep` loops, waiting on async CI
  or external jobs, and multi-agent fan-out.
- **Delegate to Codex executors**: bounded synchronous foreground work — coding,
  refactoring, bug fixes, targeted unit tests, fast lint/typechecks, and code
  review.

## 1. DAG Wave Decomposition

- **Encode only real dependencies**: group independent tasks into parallel waves
  of at most **3 workers** (`MAX_CONCURRENT=3`).
- **Prefer shallow wide waves**: keep dependency chains shallow (<= 3-4 sequential
  waves) rather than long serial handoffs.
- **Dispatch the full ready wave before waiting**: issue up to 3 parallel
  `run_codex.sh` calls in a single turn (`WaitMsBeforeAsync: 5000`,
  `NotificationTimeoutSeconds: 600`), then stop and wait for reactive wakeups.
- **Queue overflow tasks**: if > 3 tasks are ready, dispatch the first 3 and
  launch the 4th+ only after a slot frees up (exit code `3` rejects a 4th
  concurrent call).

## 2. Disjoint Ownership Without Worktrees

Because `--worktree` is forbidden, concurrent workers edit the same workspace:

- **Always pass `--owns <path>`** (repeatable) on every concurrent worker.
  `run_codex.sh` normalizes paths and rejects overlapping scopes (same path,
  parent, or child) with exit code `3` before spawning `codex`.
- **Shared integration files**: files touched by multiple modules (e.g.,
  `index.ts`, `mod.rs`, `Cargo.toml`, `package.json`, shared schemas/registries)
  must NOT be edited by parallel Wave 1 workers. Instead:
    - Wave 1 (parallel, max 3): each worker builds its isolated module + unit tests.
    - Wave 2 (single sequential worker): one integration worker wires shared exports,
      barrels, or manifests and runs full integration tests.
- **No overlapping edits**: if two subtasks touch the same file, run them
  sequentially inside the **same `-t <topic>` session** so context and cache are
  reused cleanly.

## 3. Role Separation & Review Ownership

- **Review-only workers** (e.g., `-t pr-review` with read-only instructions)
  report findings and must NOT edit implementation files concurrently with an
  active coder.
- **Route fixes back to the owner**: when a reviewer finds defects in module A,
  send the findings as a concise delta prompt to module A's existing `-t <topic>`
  session instead of spawning a new session or having the reviewer edit code.

## 4. Prompt Templates

### Initial Task-Spec Brief

```markdown
# Task: <short imperative title>

## Target

- Primary paths (exclusively owned): `<path1>`, `<path2>`

## Change

<Concrete behavioral specification and deliverables>

## Constraints

- Do NOT edit files outside your owned paths (`<path1>`, `<path2>`).
- Do NOT run long background/waiting tasks (daemons, dev servers, watchers, `&`/`nohup`, `sleep`/polling loops, or nested subagents). If a step requires background waiting, return `OUTCOME: blocked` with the exact command for the orchestrator.
- Follow repo conventions (e.g., AGENTS.md).
- Keep comments/docstrings clean; do not add unnecessary abstractions.

## Observable Acceptance

Run these exact commands and ensure all pass:

1. `<test command>`
2. `<lint/build command>`

## Required Final Response Format

End your final message with:
OUTCOME: succeeded | failed | blocked
SUMMARY: <1-3 sentences>
FILES_MODIFIED: <paths or none>
VERIFICATION: <commands run and observed pass/fail>
BLOCKERS: <none or concrete blocker>
```

### Resumed Delta Prompt (Quota-Saving Follow-up)

```markdown
Follow-up on this same topic:
<Verification failure output / review findings / next step>

Constraints: keep changes within your owned paths (`<path1>`), re-run `<exact command>`,
and end with the standard `OUTCOME / SUMMARY / FILES_MODIFIED / VERIFICATION / BLOCKERS` block.
```
