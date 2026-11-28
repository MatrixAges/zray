# Wave Scheduling & Delegation Patterns

Patterns adapted from multi-agent orchestration (Orca & Herdr) for running up to
3 concurrent Codex executors safely inside a shared workspace without Git
worktrees.

## 0. Task Eligibility & Execution Boundaries (Full-Delegation Mode)

Delegate end-to-end execution cleanly while preventing orphan daemons and resource contention:

- **Delegate to Codex executors**:
    - _During parallel waves (2–3 concurrent slots)_: coding, refactoring, and fast narrow static checks (`zig ast-check`, `zxc fmt --check`, `zxc lint`, `git diff --check`) ONLY—**no concurrent full builds (`zig build`, `bootstrap-stage`), full tests (`zig build test`, `test-verification`), 3-stage bootstraps, or benchmarks**.
    - _Solo (single active slot, after all parallel workers finish)_: debugging/reproducers requiring builds, `zig build`, `bootstrap-stage`, full package tests (`zig build test`, `test-verification`), 3-stage bootstraps, cold benchmarks, governance audits, cleanup, and wave doc updates — always setting `export ZXC_RESIDENT_GENERATOR=0` and cleaning up child processes before exit.
- **Keep on the Orchestrator**: high-level wave decomposition, disjoint
  `--owns` / serial scheduling, `<= 15m` liveness checkpoints, independent final
  acceptance (diff/SHA-256/parity/benchmark/governance review), and `git commit`
  / `git push`. Persistent daemons, dev servers, file watchers, `&`/`nohup`
  orphans, infinite polling loops, and nested subagents remain forbidden inside
  Codex workers.
- **Model selection gate**: use default `gpt-6.2-sol` (`high`, `fast`) for
  implementation, refactor, and verification waves; escalate to `--research`
  (`gpt-6.2-astra`, `high`, `default` tier) **only** for high-order
  architecture, algorithm, or stubborn root-cause research tasks, then route the
  resulting implementation plan back to `gpt-6.2-sol` workers.

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

## 4. Prompt Templates (Concise — Shared Rules Live in `RULES.md`)

Always reference [RULES.md](../RULES.md) by path instead of repeating shared rules, repo gotchas, 7-step closeout procedures, or the `OUTCOME` schema.

### Initial Task-Spec Brief

```markdown
Follow `skills/codex-executor/RULES.md` (and `AGENTS.md`).

# Task: <short imperative title>

- **Owned scope**: `<path1>`, `<path2>`
- **Mode**: `parallel` (edits + narrow checks only) | `solo`
- **Deliverable**: <concrete task change / migration targets>
- **Task-specific acceptance**: <exact command(s) or delta checks>
```

### Solo Wave Closeout Brief

```markdown
Follow `skills/codex-executor/RULES.md` §3 (Standard Solo Wave Closeout Checklist).

# Wave <NNN> Closeout

- **Mode**: `solo`
- **Baseline commit**: `<BASE_SHA>` (previous stage2: `.zig-cache/verification-tmp/wave<PREV>/stage2/bin/zxc-bootstrap`)
- **Wave <NNN> summary**: <short bullet list of subsystems migrated>
- **Extra checks / notes**: <none or task-specific items>
```

### Resumed Delta Prompt (Quota-Saving Follow-up)

```markdown
Follow `skills/codex-executor/RULES.md`. Resume within owned paths (`<path1>`):
<Verification failure output / review findings / next step>
Re-run: `<exact command>`.
```
