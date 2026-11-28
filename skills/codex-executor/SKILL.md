---
name: codex-executor
description: >-
    Delegate implementation, refactoring, debugging, or verification tasks to the
    local OpenAI codex-cli executor (running non-interactively with --yolo,
    gpt-6.2-sol, high reasoning effort, and fast service tier by default; or
    gpt-6.2-astra with high effort strictly for high-order thinking/research
    tasks) while Antigravity acts as the
    orchestrator. Supports up to 3 concurrent executor sessions and automatic
    same-topic session reuse. Use when the user asks to invoke local Codex as an
    executor, run codex-cli tasks, schedule up to 3 parallel workers, or iterate
    on Codex sessions via resume.
---

# Codex Executor (Orchestrator Mode)

Delegate autonomous execution to local `codex-cli` workers while you act as the
orchestrator owning decomposition, ownership boundaries, wave scheduling,
independent verification, and completion accounting.

## Outcome & Role Boundary

- **Orchestrator (Antigravity)**: sets high-level direction, plans task waves,
  enforces disjoint file ownership, dispatches up to 3 concurrent workers (or a
  single uncontended serial worker for full-wave verification), monitors
  layered liveness (`<= 15m` checkpoints), performs independent acceptance
  (inspecting `git diff`, SHA-256 receipts, benchmarks, test results, and
  governance invariants), and owns final commit/push and completion accounting.
  Never trust a worker's prose self-report without checking independent evidence.
- **Worker (Codex — Full-Delegation Mode)**: executes tasks end-to-end
  autonomously inside `WORKDIR` (within declared `--owns`), including coding,
  refactoring, debugging/reproducers, `zig build`, `bootstrap-stage`, targeted
  and full package tests (`zig build test`, `test-verification`), 3-stage
  bootstraps, benchmarks, governance audits, cleanup, and wave doc updates, and
  reports an explicit structured outcome. Workers must set
  `export ZXC_RESIDENT_GENERATOR=0` on compiler/build commands and must never
  leave persistent daemons, watchers, or orphaned background jobs running.
- **Done gate**: end your turn only when every dispatched task has an explicit
  outcome (`succeeded` / `failed` / `blocked`), independent verification
  evidence, and any unresolved blockers named per task.

## Defaults & Hard Constraints

- **Default command**: `codex exec --yolo -m gpt-6.2-sol -c 'model_reasoning_effort="high"' -c 'service_tier="fast"' --disable sleep_tool --disable goals --disable multi_agent`
- **Model tiering & token budget**:
    - **Default (`gpt-6.2-sol`, `high`, `fast`)**: mandatory default for all
      routine implementation, bulk refactoring, migration, debugging, builds,
      tests, cleanup, and wave docs.
    - **High-order research only (`gpt-6.2-astra`, `high`, `service_tier="default"`,
      via `--research` or `-m gpt-6.2-astra`)**: permitted **only** for
      high-order thinking / deep research tasks (complex architecture or
      compiler/type-system design, stubborn root-cause analysis after standard
      attempts stall, algorithm/paper synthesis and optimization strategy).
      **Forbidden** for routine coding, mechanical refactors, boilerplate, or
      standard verification because it consumes significantly more tokens; always
      reuse its `-t <topic>` session and keep briefs tightly scoped.
- **Wrapper & shared rulebook**: [run_codex.sh](./scripts/run_codex.sh) and [RULES.md](./RULES.md). Always keep task briefs concise: reference `skills/codex-executor/RULES.md` by path instead of repeating shared boilerplate (parallel/solo gates, `ZXC_RESIDENT_GENERATOR=0`, repo gotchas, 7-step closeout checklist, `OUTCOME` format) in every prompt.
- **Concurrency cap**: max **3 concurrent executor sessions** (`MAX_CONCURRENT=3`),
  enforced via slot/topic/session/ownership `flock` locks.
- **Full-delegation safety redlines (no leaked daemons / infinite waits / no concurrent heavy runs)**:
  Codex workers are authorized to run `zig build`, full test suites
  (`zig build test`, `test-verification`), 3-stage bootstraps, and benchmarks,
  provided they always set `export ZXC_RESIDENT_GENERATOR=0`, bound smoke/debug
  probes cleanly, and never leave persistent daemons, dev servers, file
  watchers, `&`/`nohup` orphan jobs, infinite `sleep`/polling loops, or nested
  background subagents running. **No concurrent full builds/tests**: during a
  parallel coding wave (2–3 concurrent workers), workers MUST NOT run full builds
  (`zig build`, `bootstrap-stage`), full test suites (`zig build test`,
  `test-verification`), 3-stage bootstraps, or benchmarks simultaneously—concurrent
  workers only edit code and run fast narrow static checks (`zig ast-check`,
  `zxc fmt --check`, `zxc lint`, `git diff --check`). All full builds, full
  test suites, 3-stage bootstraps, and cold benchmarks MUST execute **solo (single
  active slot)** only after all concurrent workers complete, supervised by
  Orchestrator `<= 15m` checkpoints. `run_codex.sh` disables `sleep_tool`,
  `goals`, and `multi_agent` at the CLI level and injects this policy on new
  sessions.
- **No `--worktree`**: creating Git worktrees or passing `--worktree` is
  **forbidden** (rejected with exit code `2`). Workers operate directly in
  `WORKDIR` under disjoint `--owns` scopes.
- **Flag discipline**: always `--yolo` (single-dash `-yolo` fails) and always
  non-interactive `codex exec` (never interactive TUI).
- **Keep updated**: `codex --version` / `npm install -g @openai/codex@latest`.

## Session Reuse & Quota Conservation

**Always reuse the same session (`-t <topic>`) for same-topic work** (follow-up
steps, review fixes, failing-test repairs) to preserve prompt cache
(`cached_input_tokens`) and context:

1. Check `--list-sessions -C <workdir>` before creating a new topic.
2. Pass `-t <slug>` on every call; `run_codex.sh` stores `(workdir, topic) -> session_id`
   in `~/.cache/codex-executor/sessions.json` and auto-resumes (`SESSION_MODE=resumed`).
3. Verify cache savings via `USAGE=in=... cached=... out=...` and `RECEIPT_FILE`.
4. Send concise **delta prompts** on resume—do not repeat prior background.
5. Never use `--ephemeral` for normal tasks (cannot be resumed).
6. **Post-settlement accounting** (choose one when a workstream settles):
    - **Reuse** the same `-t <topic>` for immediate follow-up work.
    - **Retain** the mapping for later continuation in the same project.
    - **Forget** via `--forget-topic <topic>` once the workstream is completely done.

## Task-Spec & Worker-Outcome Contracts

Every initial task brief references [RULES.md](./RULES.md) by path and passes only the concise task-specific deltas:

1. **Rulebook**: `Follow skills/codex-executor/RULES.md` (never paste shared rules inline).
2. **Target / Ownership**: exact files or directories (`--owns <path>`).
3. **Change**: concrete task deliverable (or baseline SHA + wave `NNN` for standard solo closeout).
4. **Task-Specific Acceptance**: exact delta commands/checks beyond the standard rulebook.

Standard `OUTCOME / SUMMARY / FILES_MODIFIED / VERIFICATION / BLOCKERS` return formatting is defined in [RULES.md](./RULES.md).

## Canonical Wave Loop (Up to 3 Concurrent Sessions)

1. **Pre-flight**: inspect `--list-sessions -C <workdir>` and `--list-active`.
2. **Dispatch independent wave**: launch up to 3 independent tasks in parallel
   with distinct `-t <topic>` and strictly disjoint `--owns <path>` flags
   (`WaitMsBeforeAsync: 5000`, `NotificationTimeoutSeconds: 600`):
    ```bash
    skills/codex-executor/scripts/run_codex.sh \
      -C /path/to/repo -t worker-a --owns src/auth -p /tmp/brief_a.md
    ```
    Wait reactively for completion notifications; never poll in a tight loop.
3. **Checkpoint on timeout**: a timeout is a checkpoint, not proof of failure.
   Inspect `manage_task(status)` + `run_codex.sh --list-active` +
   `run_codex.sh --inspect <slot>` before deciding to wait, kill, or resume.
   Never launch a duplicate editor on the same files while a slot is active.
4. **Verify & advance wave**: inspect `git status`, `git diff`, `RECEIPT_FILE`,
   and run verification yourself; feed failures back to the owning `-t <topic>`,
   then dispatch the next ready wave tasks into freed slots.

## Quick Command Reference

```bash
S=skills/codex-executor/scripts/run_codex.sh

# Pre-flight discovery
"$S" --list-sessions -C /path/to/repo
"$S" --list-active [--json]

# Run or auto-resume a topic with ownership guard (default gpt-6.2-sol, high, fast)
"$S" -C /path/to/repo -t auth-fix --owns src/auth -p /tmp/brief.md

# High-order thinking / deep research ONLY (gpt-6.2-astra, high, default tier — high token cost)
"$S" -C /path/to/repo -t arch-research --research -p /tmp/research_brief.md

# Delta resume via stdin
"$S" -C /path/to/repo -t auth-fix --owns src/auth <<'EOF'
Test foo_test failed with <error>. Fix and re-run pytest tests/test_auth.py.
EOF

# Inspect live slot (1-3) or completed RUN_DIR
"$S" --inspect 1
"$S" --inspect /tmp/codex-executor-runs/20261127-120000-12345 [--json]

# Rotate bloated context / clean up finished topic / explicit resume
"$S" -C /path/to/repo -t auth-fix --new-session -p /tmp/brief.md
"$S" -C /path/to/repo --forget-topic auth-fix
"$S" -C /path/to/repo -r "<SESSION_ID>" -p /tmp/followup.md
```

## Conditional References

Read the matching reference only when needed:

| When you need...                                                                               | Reference                                                                    |
| ---------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| DAG wave decomposition, shared-file handling, review ownership, prompt templates               | [references/wave-scheduling.md](./references/wave-scheduling.md)             |
| Layered liveness (`--list-active`/`--inspect`), timeout checkpoints, 3-failure circuit breaker | [references/recovery-and-liveness.md](./references/recovery-and-liveness.md) |
