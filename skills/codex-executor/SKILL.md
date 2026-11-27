---
name: codex-executor
description: >-
    Delegate implementation, refactoring, debugging, or verification tasks to the
    local OpenAI codex-cli executor (running non-interactively with --yolo,
    gpt-6.2-sol, and high reasoning effort) while Antigravity acts as the
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

- **Orchestrator (Antigravity)**: plans task waves, enforces disjoint file
  ownership, dispatches up to 3 foreground-only workers, handles long-running
  background/waiting tasks directly, monitors layered liveness, verifies
  diffs/tests independently, and accounts for every worker before ending the
  turn. Never trust a worker's prose self-report without checking `git diff`
  and running verification yourself.
- **Worker (Codex)**: executes one bounded synchronous foreground brief inside
  `WORKDIR`, runs required checks, and reports an explicit structured outcome.
  If a step requires long background waiting, the worker stops and returns
  `OUTCOME: blocked` with the exact command for the Orchestrator.
- **Done gate**: end your turn only when every dispatched task has an explicit
  outcome (`succeeded` / `failed` / `blocked`), independent verification
  evidence, and any unresolved blockers named per task.

## Defaults & Hard Constraints

- **Default command**: `codex exec --yolo -m gpt-6.2-sol -c 'model_reasoning_effort="high"' --disable sleep_tool --disable goals --disable multi_agent`
- **Wrapper script**: [run_codex.sh](./scripts/run_codex.sh)
- **Concurrency cap**: max **3 concurrent executor sessions** (`MAX_CONCURRENT=3`),
  enforced via slot/topic/session/ownership `flock` locks.
- **No long background / waiting tasks**: Orchestrator must **not** delegate
  tasks requiring long background waiting (full builds like `zig build`, full
  test suites like `zig build test`, 3-stage bootstraps, cold benchmarks,
  long-running compilation/verification, daemons/dev servers, file watchers,
  `sleep`/polling loops, waiting on async CI/external jobs, or nested background
  subagents) to Codex executors—all full builds, full test suites, and
  long-running verifications MUST run directly on the Orchestrator side so
  executor slots never block overall progress. Codex workers may only run fast,
  narrowly-scoped checks (e.g. `zxc fmt`, `zxc lint`, `zig fmt`,
  `zig ast-check`). `run_codex.sh` disables `sleep_tool`, `goals`, and
  `multi_agent` at the CLI level and prepends a foreground-only policy preamble
  on new sessions.
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

Every initial task brief must specify five fields:

1. **Target**: exact files, modules, or directories in scope.
2. **Change**: concrete deliverable to produce.
3. **Constraints**: invariants, `AGENTS.md` rules, and do-not-touch boundaries.
4. **Ownership**: files this worker may edit (matching `--owns <path>`).
5. **Observable acceptance**: exact test/lint/build commands to run and pass.

Require every worker to end its final message with an explicit outcome block
(never encode failure only in prose):

```text
OUTCOME: succeeded | failed | blocked
SUMMARY: <1-3 sentences>
FILES_MODIFIED: <comma-separated paths or none>
VERIFICATION: <commands run and exact observed pass/fail>
BLOCKERS: <none or concrete blocker>
```

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

# Run or auto-resume a topic with ownership guard (default gpt-6.2-sol, high)
"$S" -C /path/to/repo -t auth-fix --owns src/auth -p /tmp/brief.md

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
