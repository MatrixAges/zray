# Layered Liveness, Recovery & Completion Accounting

Operational safety rules for supervising parallel `codex-cli` executors without
guessing or creating duplicate conflicting editors.

## 1. Layered Liveness Diagnostics

Never judge an active executor from a single signal. Inspect both OS process
state and event-stream progress:

```bash
S=skills/codex-executor/scripts/run_codex.sh
"$S" --list-active
"$S" --list-active --json
"$S" --inspect 1          # active slot 1..3
"$S" --inspect <RUN_DIR>  # completed or failed run directory
```

Interpret the layered fields together:

- **`ALIVE=yes` + recent `IDLE_SEC` + advancing `LAST_EVENT`** (e.g. `item.completed`):
  worker is actively making progress — keep waiting.
- **`ALIVE=yes` + high `IDLE_SEC` (>300s) + stuck `LAST_EVENT`** (e.g. `turn.started`
  with no new events): inspect `--inspect <slot>` and `STDERR_FILE` / `manage_task(status)`
  to distinguish deep reasoning or slow build/test from a hung subprocess.
- **`ALIVE=no` while slot file exists**: abnormal process death; inspect `RUN_DIR`
  before retrying. (OS `flock` releases automatically once the process exits.)

## 2. Timeout-as-Checkpoint Discipline

A `NotificationTimeoutSeconds` wakeup or empty wait is **a checkpoint, not proof
of failure**:

- **Do NOT kill** a running task merely because one timeout elapsed.
- **Do NOT launch a duplicate worker** on the same `-t <topic>` or `--owns <path>`
  without positive proof the previous process has exited (`ALIVE=no` or task `DONE`/`FAILED`).
  `run_codex.sh` enforces this with topic, session, and ownership locks (exit code `3`).
- If the worker is still legitimately progressing (`ALIVE=yes`, active child test/build),
  schedule a follow-up `schedule` checkpoint (<= 15 min) or wait for task completion.

## 3. Failure Triage & 3-Failure Circuit Breaker

When `STATUS=failed` (or worker reports `OUTCOME: failed` / `OUTCOME: blocked`):

1. **Inspect evidence first**: read `RECEIPT_FILE`, `--inspect <RUN_DIR>`, and
   `STDERR_FILE` (plus `git status` / `git diff` in `WORKDIR`).
2. **Handle background-wait blocks on the Orchestrator**: if a worker returns
   `OUTCOME: blocked` because a required step involves long background waiting,
   daemons/watchers, or long async monitoring, run that background command
   directly as an Orchestrator async task instead of forcing Codex to wait. Once
   it finishes, resume `-t <topic>` with the result if further edits are needed.
3. **Never retry unchanged**: retrying the exact same prompt in a broken state
   wastes quota. Either:
    - Resume the same `-t <topic>` with the concrete error output and diagnostic
      clues (preferred when partial progress or cache is valuable), **or**
    - Rotate a polluted/off-track session with `--new-session` on `-t <topic>`.
4. **3-failure circuit breaker**: if the **same task** fails **3 consecutive attempts**
   (exit non-zero, `OUTCOME: failed`, or repeated `OUTCOME: blocked`), **stop
   retrying automatically** and escalate to the user with:
    - Task scope and all 3 `RUN_DIR` / `RECEIPT_FILE` paths
    - Root-cause summary and `git diff` state
    - Concrete options for how to proceed

## 4. Exit Codes Quick Reference

| Exit Code      | Meaning                                                                | Orchestrator Action                                            |
| -------------- | ---------------------------------------------------------------------- | -------------------------------------------------------------- |
| `0`            | Codex exited cleanly                                                   | Verify diff/tests independently; inspect `OUTCOME` and `USAGE` |
| `2`            | Invalid CLI args or forbidden `--worktree`                             | Fix invocation flags (never use `--worktree`)                  |
| `3`            | Concurrency limit (3), active topic/session lock, or `--owns` conflict | Check `--list-active`; wait for slot or fix disjoint `--owns`  |
| `127`          | `codex` binary missing from `PATH`                                     | Install/repair `@openai/codex`                                 |
| Other non-zero | Codex runtime/auth/task failure                                        | Run `--inspect <RUN_DIR>` and `codex doctor`                   |

## 5. Completion Accounting

Before ending the orchestrator turn, account for every dispatched topic:

- **Reuse** (`-t <topic>`): keep mapping for follow-up waves or user review fixes.
- **Retain**: keep mapping intentionally if multi-day work continues later.
- **Forget** (`--forget-topic <topic>`): remove completed one-off workstream mappings
  from `~/.cache/codex-executor/sessions.json`.
