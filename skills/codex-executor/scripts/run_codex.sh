#!/usr/bin/env bash
set -euo pipefail

MODEL="gpt-6.2-sol"
EFFORT="high"
SERVICE_TIER="fast"
SERVICE_TIER_EXPLICIT=0
MAX_CONCURRENT=6
WORKDIR="$(pwd)"
WORKDIR_EXPLICIT=0
PROMPT_FILE=""
RESUME_ID=""
TOPIC=""
NEW_SESSION=0
LIST_SESSIONS=0
LIST_ACTIVE=0
INSPECT_TARGET=""
JSON_OUT=0
JSON_SUMMARY=0
FORGET_TOPIC=""
LAST_MSG_FILE=""
EVENTS_FILE=""
SCHEMA_FILE=""
EPHEMERAL=0
SKIP_GIT_CHECK=0
EXTRA_CONFIGS=()
OWNS_PATHS=()

SESSION_STORE="${CODEX_EXECUTOR_SESSIONS_FILE:-$HOME/.cache/codex-executor/sessions.json}"
LOCK_DIR="${CODEX_EXECUTOR_LOCK_DIR:-$HOME/.cache/codex-executor/locks}"

usage() {
  cat <<'EOF'
Usage: run_codex.sh [OPTIONS]

Run local codex-cli non-interactively with --yolo as an orchestrator executor.
Supports up to 6 concurrent executor sessions (slot/topic/session/ownership locks),
automatic same-topic session reuse via ~/.cache/codex-executor/sessions.json,
layered liveness inspection, structured run receipts, supports full-delegation
execution (builds, tests, 3-stage bootstraps, benchmarks, docs, cleanup) while
disabling sleep_tool/goals/multi_agent/multi_agent_v2 (all models) and forbidding --worktree.
Reads prompt from --prompt-file or stdin.

Options:
  -C, --workdir <DIR>         Working directory (default: current directory)
  -p, --prompt-file <FILE>    File containing the task prompt (default: stdin)
  -t, --topic <SLUG>          Topic/workstream slug; auto-resumes saved session for (workdir, topic)
  -r, --resume <SESSION_ID>   Explicitly resume a Codex session ID
      --owns <PATH>           Declare exclusive file/dir ownership in workdir (repeatable)
      --new-session           Force a fresh session even if --topic has a saved session
      --list-sessions         List saved topic -> session mappings (filtered by -C if given)
      --list-active           List currently running concurrent executor slots (max 6)
      --inspect <SLOT|DIR>    Inspect active slot (1-6) or past RUN_DIR (events/receipt/stderr)
      --json                  Emit JSON for --list-active or --inspect
      --json-summary          Emit receipt.json to stdout instead of key=value summary
      --forget-topic <SLUG>   Remove saved session mapping for (workdir, slug)
  -m, --model <MODEL>         Codex model (default: gpt-6.2-sol)
  -e, --effort <EFFORT>       Reasoning effort (default: high)
      --service-tier <TIER>   Service tier (default: fast; default for *-astra*)
      --research              High-order thinking/research preset (gpt-6.2-astra, high, default tier)
  -o, --output-file <FILE>    Path to save last agent message
      --events-file <FILE>    Path to save JSONL event stream
      --schema <FILE>         JSON Schema file for --output-schema
      --ephemeral             Do not persist session files (incompatible with --resume/--topic)
      --skip-git-repo-check   Allow running outside a Git repository
      --extra-config <k=v>    Extra -c config override (repeatable)
  -h, --help                  Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -C|--workdir)
      WORKDIR="${2:-}"
      WORKDIR_EXPLICIT=1
      shift 2
      ;;
    -p|--prompt-file)
      PROMPT_FILE="${2:-}"
      shift 2
      ;;
    -t|--topic)
      TOPIC="${2:-}"
      shift 2
      ;;
    -r|--resume)
      RESUME_ID="${2:-}"
      shift 2
      ;;
    --owns)
      OWNS_PATHS+=("${2:-}")
      shift 2
      ;;
    --new-session)
      NEW_SESSION=1
      shift
      ;;
    --list-sessions)
      LIST_SESSIONS=1
      shift
      ;;
    --list-active)
      LIST_ACTIVE=1
      shift
      ;;
    --inspect)
      INSPECT_TARGET="${2:-}"
      shift 2
      ;;
    --json)
      JSON_OUT=1
      shift
      ;;
    --json-summary)
      JSON_SUMMARY=1
      shift
      ;;
    --forget-topic)
      FORGET_TOPIC="${2:-}"
      shift 2
      ;;
    -m|--model)
      MODEL="${2:-}"
      shift 2
      ;;
    -e|--effort)
      EFFORT="${2:-}"
      shift 2
      ;;
    --service-tier)
      SERVICE_TIER="${2:-}"
      SERVICE_TIER_EXPLICIT=1
      shift 2
      ;;
    --research)
      MODEL="gpt-6.2-astra"
      EFFORT="high"
      shift
      ;;
    -o|--output-file)
      LAST_MSG_FILE="${2:-}"
      shift 2
      ;;
    --events-file)
      EVENTS_FILE="${2:-}"
      shift 2
      ;;
    --schema)
      SCHEMA_FILE="${2:-}"
      shift 2
      ;;
    --worktree)
      echo "ERROR: --worktree is forbidden by codex-executor policy." >&2
      exit 2
      ;;
    --ephemeral)
      EPHEMERAL=1
      shift
      ;;
    --skip-git-repo-check)
      SKIP_GIT_CHECK=1
      shift
      ;;
    --extra-config)
      case "${2:-}" in
        *multi_agent*)
          echo "ERROR: Enabling multi_agent/multi_agent_v2 is forbidden for all models by codex-executor policy." >&2
          exit 2
          ;;
      esac
      EXTRA_CONFIGS+=("${2:-}")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$SERVICE_TIER_EXPLICIT" -eq 0 && "$MODEL" == *-astra* ]]; then
  SERVICE_TIER="default"
fi

if [[ "$LIST_ACTIVE" -eq 1 ]]; then
  python3 - "$LOCK_DIR" "$MAX_CONCURRENT" "$JSON_OUT" <<'PY'
import datetime
import errno
import fcntl
import json
import os
import sys
import time

lock_dir = sys.argv[1]
max_concurrent = int(sys.argv[2])
json_out = sys.argv[3] == "1"
now = time.time()
active = []

def _pid_alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False

def _inspect_events(events_file, started_at):
    event_count = 0
    last_event = "-"
    idle_sec = None
    if events_file and os.path.exists(events_file):
        try:
            idle_sec = max(0, int(now - os.path.getmtime(events_file)))
            with open(events_file, "r", encoding="utf-8", errors="replace") as ef:
                for line in ef:
                    line = line.strip()
                    if not line:
                        continue
                    event_count += 1
                    try:
                        obj = json.loads(line)
                        if isinstance(obj, dict) and obj.get("type"):
                            ev_type = str(obj["type"])
                            item = obj.get("item")
                            if isinstance(item, dict) and item.get("type"):
                                last_event = f"{ev_type}:{item['type']}"
                            else:
                                last_event = ev_type
                    except Exception:
                        pass
        except OSError:
            pass
    elapsed_sec = None
    if started_at:
        try:
            dt = datetime.datetime.strptime(started_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
            elapsed_sec = max(0, int(now - dt.timestamp()))
            if idle_sec is None:
                idle_sec = elapsed_sec
        except Exception:
            pass
    return event_count, last_event, elapsed_sec, idle_sec

for slot in range(1, max_concurrent + 1):
    path = os.path.join(lock_dir, f"slot-{slot}.lock")
    if not os.path.exists(path):
        continue
    try:
        with open(path, "r+", encoding="utf-8") as f:
            try:
                fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(f.fileno(), fcntl.LOCK_UN)
                continue
            except OSError as exc:
                if exc.errno not in (errno.EACCES, errno.EAGAIN):
                    raise
                f.seek(0)
                raw = f.read().strip()
                meta = {}
                if raw:
                    try:
                        meta = json.loads(raw)
                    except Exception:
                        meta = {}
                pid = meta.get("pid")
                events_file = meta.get("events_file", "")
                started_at = meta.get("started_at", "")
                event_count, last_event, elapsed_sec, idle_sec = _inspect_events(events_file, started_at)
                active.append({
                    "slot": meta.get("slot", slot),
                    "pid": pid,
                    "pid_alive": _pid_alive(pid),
                    "topic": meta.get("topic", ""),
                    "session_id": meta.get("session_id", ""),
                    "session_mode": meta.get("session_mode", ""),
                    "model": meta.get("model", ""),
                    "effort": meta.get("effort", ""),
                    "service_tier": meta.get("service_tier", ""),
                    "owns": meta.get("owns", []),
                    "started_at": started_at,
                    "elapsed_sec": elapsed_sec,
                    "event_count": event_count,
                    "last_event": last_event,
                    "idle_sec": idle_sec,
                    "run_dir": meta.get("run_dir", ""),
                    "workdir": meta.get("workdir", ""),
                })
    except FileNotFoundError:
        continue

if json_out:
    print(json.dumps({"active": active}, indent=2))
    sys.exit(0)

if not active:
    print("(no active executors)")
    sys.exit(0)

print("SLOT\tPID\tALIVE\tTOPIC\tELAPSED\tLAST_EVENT\tIDLE_SEC\tOWNS\tRUN_DIR")
for item in active:
    owns_str = ",".join(item["owns"]) if item["owns"] else "-"
    elapsed_str = f"{item['elapsed_sec']}s" if item["elapsed_sec"] is not None else "-"
    idle_str = f"{item['idle_sec']}s" if item["idle_sec"] is not None else "-"
    print("\t".join([
        str(item["slot"]),
        str(item["pid"] or "-"),
        "yes" if item["pid_alive"] else "no",
        item["topic"] or "-",
        elapsed_str,
        f"{item['last_event']}({item['event_count']})",
        idle_str,
        owns_str,
        item["run_dir"] or "-",
    ]))
PY
  exit 0
fi

if [[ -n "$INSPECT_TARGET" ]]; then
  python3 - "$LOCK_DIR" "$MAX_CONCURRENT" "$INSPECT_TARGET" "$JSON_OUT" <<'PY'
import errno
import fcntl
import json
import os
import sys
import time

lock_dir, max_conc_s, target, json_out_s = sys.argv[1:5]
max_conc = int(max_conc_s)
json_out = json_out_s == "1"

slot_meta = None
run_dir = None

if target.isdigit() and 1 <= int(target) <= max_conc:
    slot = int(target)
    lock_path = os.path.join(lock_dir, f"slot-{slot}.lock")
    if not os.path.exists(lock_path):
        sys.stderr.write(f"ERROR: Slot {slot} is not active.\n")
        sys.exit(1)
    with open(lock_path, "r+", encoding="utf-8") as f:
        try:
            fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(f.fileno(), fcntl.LOCK_UN)
            sys.stderr.write(f"ERROR: Slot {slot} is not active.\n")
            sys.exit(1)
        except OSError as exc:
            if exc.errno not in (errno.EACCES, errno.EAGAIN):
                raise
            f.seek(0)
            raw = f.read().strip()
            slot_meta = json.loads(raw) if raw else {"slot": slot}
            run_dir = slot_meta.get("run_dir")
else:
    run_dir = os.path.abspath(target)
    if not os.path.isdir(run_dir):
        sys.stderr.write(f"ERROR: Inspect target is neither an active slot (1-{max_conc}) nor an existing directory: {target}\n")
        sys.exit(2)

receipt_path = os.path.join(run_dir, "receipt.json") if run_dir else ""
events_path = (slot_meta or {}).get("events_file") or (os.path.join(run_dir, "events.jsonl") if run_dir else "")
stderr_path = (slot_meta or {}).get("stderr_file") or (os.path.join(run_dir, "stderr.log") if run_dir else "")
last_msg_path = (slot_meta or {}).get("last_message_file") or (os.path.join(run_dir, "last_message.txt") if run_dir else "")

receipt = None
if receipt_path and os.path.exists(receipt_path):
    try:
        with open(receipt_path, "r", encoding="utf-8") as rf:
            receipt = json.load(rf)
    except Exception:
        receipt = None

events_summary = []
total_events = 0
if events_path and os.path.exists(events_path):
    with open(events_path, "r", encoding="utf-8", errors="replace") as ef:
        for line in ef:
            line = line.strip()
            if not line:
                continue
            total_events += 1
            try:
                obj = json.loads(line)
            except Exception:
                events_summary.append({"raw": line[:160]})
                continue
            ev_type = obj.get("type", "unknown") if isinstance(obj, dict) else "unknown"
            summary = {"type": ev_type}
            if isinstance(obj, dict):
                if obj.get("thread_id"):
                    summary["thread_id"] = obj["thread_id"]
                item = obj.get("item")
                if isinstance(item, dict):
                    summary["item_type"] = item.get("type")
                    if item.get("text"):
                        summary["text_preview"] = str(item["text"])[:120]
                    elif item.get("command"):
                        summary["command"] = str(item["command"])[:120]
                if obj.get("usage"):
                    summary["usage"] = obj["usage"]
            events_summary.append(summary)

recent_events = events_summary[-10:]
stderr_tail = ""
if stderr_path and os.path.exists(stderr_path):
    with open(stderr_path, "r", encoding="utf-8", errors="replace") as sf:
        lines = sf.readlines()
        stderr_tail = "".join(lines[-20:]).strip()

last_msg_preview = ""
if last_msg_path and os.path.exists(last_msg_path):
    with open(last_msg_path, "r", encoding="utf-8", errors="replace") as lf:
        last_msg_preview = lf.read().strip()

payload = {
    "state": "completed" if receipt is not None else ("active" if slot_meta is not None else "unknown"),
    "run_dir": run_dir,
    "active_slot": slot_meta,
    "receipt": receipt,
    "total_events": total_events,
    "recent_events": recent_events,
    "stderr_tail": stderr_tail,
    "last_message": last_msg_preview,
}

if json_out:
    print(json.dumps(payload, indent=2))
    sys.exit(0)

print(f"STATE={payload['state']}")
print(f"RUN_DIR={run_dir}")
if slot_meta is not None:
    print(f"SLOT={slot_meta.get('slot', '')} PID={slot_meta.get('pid', '')} TOPIC={slot_meta.get('topic', '')} OWNS={','.join(slot_meta.get('owns', [])) or '-'}")
if receipt is not None:
    print(f"STATUS={receipt.get('status')} EXIT_CODE={receipt.get('exit_code')} SESSION_ID={receipt.get('session_id')} DURATION_SEC={receipt.get('duration_sec')}")
    usage = receipt.get("usage") or {}
    if usage:
        print(f"USAGE=in={usage.get('input_tokens', 0)} cached={usage.get('cached_input_tokens', 0)} out={usage.get('output_tokens', 0)} reasoning={usage.get('reasoning_output_tokens', 0)}")
print(f"TOTAL_EVENTS={total_events}")
print("--- RECENT EVENTS (up to 10) ---")
for ev in recent_events:
    print(json.dumps(ev, ensure_ascii=False))
if last_msg_preview:
    print("--- LAST MESSAGE ---")
    print(last_msg_preview)
if stderr_tail:
    print("--- STDERR TAIL ---")
    print(stderr_tail)
PY
  exit 0
fi

if [[ -z "$WORKDIR" || ! -d "$WORKDIR" ]]; then
  echo "ERROR: Working directory does not exist: $WORKDIR" >&2
  exit 2
fi
WORKDIR="$(cd "$WORKDIR" && pwd)"

if [[ "$LIST_SESSIONS" -eq 1 ]]; then
  FILTER_WORKDIR=""
  if [[ "$WORKDIR_EXPLICIT" -eq 1 ]]; then
    FILTER_WORKDIR="$WORKDIR"
  fi
  python3 - "$SESSION_STORE" "$FILTER_WORKDIR" <<'PY'
import fcntl
import json
import os
import sys

store_path, filter_workdir = sys.argv[1], sys.argv[2]
if not os.path.exists(store_path):
    print("(no saved sessions)")
    sys.exit(0)

lock_path = store_path + ".lock"
os.makedirs(os.path.dirname(lock_path), exist_ok=True)
with open(lock_path, "a+", encoding="utf-8") as lf:
    fcntl.flock(lf.fileno(), fcntl.LOCK_SH)
    if not os.path.exists(store_path):
        print("(no saved sessions)")
        sys.exit(0)
    with open(store_path, "r", encoding="utf-8") as f:
        data = json.load(f)

sessions = data.get("sessions", {})
rows = []
for wd, topics in sorted(sessions.items()):
    if filter_workdir and wd != filter_workdir:
        continue
    if not isinstance(topics, dict):
        continue
    for topic, meta in sorted(topics.items()):
        if not isinstance(meta, dict):
            continue
        rows.append((
            topic,
            meta.get("session_id", ""),
            meta.get("model", ""),
            meta.get("effort", ""),
            meta.get("updated_at", ""),
            wd,
        ))

if not rows:
    print("(no saved sessions)")
    sys.exit(0)

print("TOPIC\tSESSION_ID\tMODEL\tEFFORT\tUPDATED_AT\tWORKDIR")
for r in rows:
    print("\t".join(r))
PY
  exit 0
fi

if [[ -n "$FORGET_TOPIC" ]]; then
  python3 - "$SESSION_STORE" "$WORKDIR" "$FORGET_TOPIC" <<'PY'
import fcntl
import json
import os
import sys
import tempfile

store_path, workdir, topic = sys.argv[1], sys.argv[2], sys.argv[3]
if not os.path.exists(store_path):
    print(f"FORGOT_TOPIC={topic} WORKDIR={workdir} removed=no")
    sys.exit(0)

lock_path = store_path + ".lock"
os.makedirs(os.path.dirname(lock_path), exist_ok=True)
removed = False
with open(lock_path, "a+", encoding="utf-8") as lf:
    fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
    if os.path.exists(store_path):
        with open(store_path, "r", encoding="utf-8") as f:
            data = json.load(f)

        sessions = data.get("sessions", {})
        wd_map = sessions.get(workdir, {})
        if isinstance(wd_map, dict) and topic in wd_map:
            del wd_map[topic]
            removed = True
            if not wd_map:
                sessions.pop(workdir, None)
            data["sessions"] = sessions
            os.makedirs(os.path.dirname(store_path), exist_ok=True)
            fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(store_path), prefix=".sessions.", suffix=".tmp")
            with os.fdopen(fd, "w", encoding="utf-8") as tf:
                json.dump(data, tf, indent=2, sort_keys=True)
                tf.write("\n")
            os.replace(tmp_path, store_path)

print(f"FORGOT_TOPIC={topic} WORKDIR={workdir} removed={'yes' if removed else 'no'}")
PY
  exit 0
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "ERROR: 'codex' CLI not found in PATH. Install with: npm install -g @openai/codex@latest" >&2
  exit 127
fi

if [[ "$EPHEMERAL" -eq 1 && ( -n "$RESUME_ID" || -n "$TOPIC" ) ]]; then
  echo "ERROR: --ephemeral cannot be combined with --resume or --topic" >&2
  exit 2
fi

if [[ "$NEW_SESSION" -eq 1 && -n "$RESUME_ID" ]]; then
  echo "ERROR: --new-session cannot be combined with --resume" >&2
  exit 2
fi

if [[ -n "$SCHEMA_FILE" && ! -f "$SCHEMA_FILE" ]]; then
  echo "ERROR: Schema file not found: $SCHEMA_FILE" >&2
  exit 2
fi

if [[ -z "$RESUME_ID" && -n "$TOPIC" && "$NEW_SESSION" -eq 0 ]]; then
  RESUME_ID="$(python3 - "$SESSION_STORE" "$WORKDIR" "$TOPIC" <<'PY'
import fcntl
import json
import os
import sys

store_path, workdir, topic = sys.argv[1], sys.argv[2], sys.argv[3]
if not os.path.exists(store_path):
    sys.exit(0)
lock_path = store_path + ".lock"
os.makedirs(os.path.dirname(lock_path), exist_ok=True)
try:
    with open(lock_path, "a+", encoding="utf-8") as lf:
        fcntl.flock(lf.fileno(), fcntl.LOCK_SH)
        if not os.path.exists(store_path):
            sys.exit(0)
        with open(store_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    sid = data.get("sessions", {}).get(workdir, {}).get(topic, {}).get("session_id", "")
    if sid:
        print(sid)
except Exception:
    pass
PY
)"
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="/tmp/codex-executor-runs/${TIMESTAMP}-$$"
mkdir -p "$RUN_DIR"

if [[ -z "$LAST_MSG_FILE" ]]; then
  LAST_MSG_FILE="$RUN_DIR/last_message.txt"
else
  mkdir -p "$(dirname "$LAST_MSG_FILE")"
fi

if [[ -z "$EVENTS_FILE" ]]; then
  EVENTS_FILE="$RUN_DIR/events.jsonl"
else
  mkdir -p "$(dirname "$EVENTS_FILE")"
fi

STDERR_FILE="$RUN_DIR/stderr.log"
SLOT_FILE="$RUN_DIR/slot.txt"
META_OUT_FILE="$RUN_DIR/run_meta.json"
RECEIPT_FILE="$RUN_DIR/receipt.json"

if [[ -n "$PROMPT_FILE" ]]; then
  if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "ERROR: Prompt file not found: $PROMPT_FILE" >&2
    exit 2
  fi
  PROMPT_SRC="$PROMPT_FILE"
else
  if [[ -t 0 ]]; then
    echo "ERROR: No --prompt-file provided and stdin is empty (TTY)." >&2
    exit 2
  fi
  PROMPT_SRC="$RUN_DIR/prompt.txt"
  cat > "$PROMPT_SRC"
fi

if [[ ! -s "$PROMPT_SRC" ]]; then
  echo "ERROR: Prompt is empty." >&2
  exit 2
fi

if [[ "$SKIP_GIT_CHECK" -eq 0 ]]; then
  if ! git -C "$WORKDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    SKIP_GIT_CHECK=1
  fi
fi

CODEX_VERSION="$(codex --version 2>/dev/null || echo "unknown")"

COMMON_ARGS=(
  --yolo
  -m "$MODEL"
  -c "model_reasoning_effort=\"$EFFORT\""
  -c "service_tier=\"$SERVICE_TIER\""
  --disable sleep_tool
  --disable goals
  --disable multi_agent
  --disable multi_agent_v2
  --json
  -o "$LAST_MSG_FILE"
)

if [[ "$EPHEMERAL" -eq 1 ]]; then
  COMMON_ARGS+=(--ephemeral)
fi
if [[ "$SKIP_GIT_CHECK" -eq 1 ]]; then
  COMMON_ARGS+=(--skip-git-repo-check)
fi
if [[ -n "$SCHEMA_FILE" ]]; then
  COMMON_ARGS+=(--output-schema "$SCHEMA_FILE")
fi
if [[ ${#EXTRA_CONFIGS[@]} -gt 0 ]]; then
  for cfg in "${EXTRA_CONFIGS[@]}"; do
    COMMON_ARGS+=(-c "$cfg")
  done
fi

if [[ -n "$RESUME_ID" ]]; then
  SESSION_MODE="resumed"
  EFFECTIVE_PROMPT_SRC="$PROMPT_SRC"
  CMD=(codex exec resume "${COMMON_ARGS[@]}" "$RESUME_ID" -)
else
  SESSION_MODE="new"
  EFFECTIVE_PROMPT_SRC="$RUN_DIR/effective_prompt.txt"
  cat > "$EFFECTIVE_PROMPT_SRC" <<'POLICY'
[EXECUTOR POLICY]
Read and strictly follow `skills/codex-executor/RULES.md` (and `AGENTS.md`) before executing this task.

POLICY
  cat "$PROMPT_SRC" >> "$EFFECTIVE_PROMPT_SRC"
  CMD=(codex exec "${COMMON_ARGS[@]}" --color never -C "$WORKDIR" -)
fi

OWNS_JSON="[]"
if [[ ${#OWNS_PATHS[@]} -gt 0 ]]; then
  OWNS_JSON="$(python3 -c 'import json,sys; print(json.dumps([x for x in sys.argv[1:] if x]))' "${OWNS_PATHS[@]}")"
fi

set +e
python3 - "$LOCK_DIR" "$MAX_CONCURRENT" "$WORKDIR" "$TOPIC" "$RESUME_ID" "$SESSION_MODE" "$MODEL" "$EFFORT" "$SERVICE_TIER" "$OWNS_JSON" "$RUN_DIR" "$EFFECTIVE_PROMPT_SRC" "$EVENTS_FILE" "$STDERR_FILE" "$LAST_MSG_FILE" "$SLOT_FILE" "$META_OUT_FILE" "${CMD[@]}" <<'PY'
import datetime
import errno
import fcntl
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time

(
    lock_dir,
    max_concurrent_s,
    workdir,
    topic,
    resume_id,
    session_mode,
    model,
    effort,
    service_tier,
    owns_json,
    run_dir,
    prompt_src,
    events_file,
    stderr_file,
    last_msg_file,
    slot_file,
    meta_out_file,
    *cmd,
) = sys.argv[1:]

max_concurrent = int(max_concurrent_s)
owns_raw = json.loads(owns_json)
os.makedirs(lock_dir, exist_ok=True)

def _norm_own(p):
    joined = p if os.path.isabs(p) else os.path.join(workdir, p)
    return os.path.realpath(joined)

def _disp_own(norm_p):
    wd_real = os.path.realpath(workdir)
    try:
        rel = os.path.relpath(norm_p, wd_real)
        if not rel.startswith(".."):
            return rel
    except ValueError:
        pass
    return norm_p

def _paths_overlap(a, b):
    if a == b:
        return True
    try:
        common = os.path.commonpath([a, b])
        return common == a or common == b
    except ValueError:
        return False

owns_norm = []
owns_disp = []
for raw_p in owns_raw:
    np = _norm_own(raw_p)
    owns_norm.append(np)
    owns_disp.append(_disp_own(np))

def _fail(msg, code=3):
    sys.stderr.write(msg.rstrip() + "\n")
    with open(stderr_file, "w", encoding="utf-8") as sf:
        sf.write(msg.rstrip() + "\n")
    sys.exit(code)

topic_fp = None
if topic:
    t_hash = hashlib.sha256(f"{workdir}\0{topic}".encode("utf-8")).hexdigest()[:16]
    topic_lock_path = os.path.join(lock_dir, f"topic-{t_hash}.lock")
    topic_fp = open(topic_lock_path, "a+", encoding="utf-8")
    try:
        fcntl.flock(topic_fp.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        topic_fp.close()
        if exc.errno not in (errno.EACCES, errno.EAGAIN):
            raise
        _fail(f"ERROR: Topic '{topic}' in '{workdir}' is already active in another concurrent executor.")

session_fp = None
if resume_id:
    safe_id = re.sub(r"[^A-Za-z0-9_.-]", "_", resume_id)
    sess_lock_path = os.path.join(lock_dir, f"session-{safe_id}.lock")
    session_fp = open(sess_lock_path, "a+", encoding="utf-8")
    try:
        fcntl.flock(session_fp.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        session_fp.close()
        if topic_fp is not None:
            topic_fp.close()
        if exc.errno not in (errno.EACCES, errno.EAGAIN):
            raise
        _fail(f"ERROR: Session '{resume_id}' is already active in another concurrent executor.")

dispatch_lock_path = os.path.join(lock_dir, "dispatch.lock")
slot_num = None
slot_fp = None
active_summaries = []
wd_real = os.path.realpath(workdir)

with open(dispatch_lock_path, "a+", encoding="utf-8") as dlf:
    fcntl.flock(dlf.fileno(), fcntl.LOCK_EX)
    for idx in range(1, max_concurrent + 1):
        path = os.path.join(lock_dir, f"slot-{idx}.lock")
        fp = open(path, "a+", encoding="utf-8")
        try:
            fcntl.flock(fp.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            if slot_fp is None:
                slot_num = idx
                slot_fp = fp
                # Keep checking remaining slots only if we have owns_norm to verify against active slots
                if not owns_norm:
                    break
            else:
                fcntl.flock(fp.fileno(), fcntl.LOCK_UN)
                fp.close()
        except OSError as exc:
            if exc.errno not in (errno.EACCES, errno.EAGAIN):
                fp.close()
                raise
            fp.seek(0)
            raw = fp.read().strip()
            fp.close()
            active_summaries.append(f"slot-{idx}: {raw or '(active)'}")
            if owns_norm and raw:
                try:
                    other_meta = json.loads(raw)
                except Exception:
                    other_meta = {}
                other_wd = other_meta.get("workdir", "")
                if other_wd and os.path.realpath(other_wd) == wd_real:
                    other_owns_norm = other_meta.get("owns_norm") or [
                        _norm_own(op) for op in other_meta.get("owns", [])
                    ]
                    other_owns_disp = other_meta.get("owns") or other_owns_norm
                    for our_n, our_d in zip(owns_norm, owns_disp):
                        for their_n, their_d in zip(other_owns_norm, other_owns_disp):
                            if _paths_overlap(our_n, their_n):
                                if slot_fp is not None:
                                    fcntl.flock(slot_fp.fileno(), fcntl.LOCK_UN)
                                    slot_fp.close()
                                if session_fp is not None:
                                    session_fp.close()
                                if topic_fp is not None:
                                    topic_fp.close()
                                _fail(
                                    f"ERROR: Ownership conflict with active slot {idx} "
                                    f"(topic={other_meta.get('topic') or '-'}): "
                                    f"'{our_d}' overlaps '{their_d}'."
                                )

    if slot_fp is None:
        if session_fp is not None:
            session_fp.close()
        if topic_fp is not None:
            topic_fp.close()
        _fail(
            f"ERROR: Max concurrent codex-executor sessions ({max_concurrent}) already running.\n"
            + "\n".join(active_summaries)
        )

    started_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    meta = {
        "slot": slot_num,
        "pid": None,
        "topic": topic,
        "session_id": resume_id,
        "session_mode": session_mode,
        "model": model,
        "effort": effort,
        "service_tier": service_tier,
        "owns": owns_disp,
        "owns_norm": owns_norm,
        "workdir": workdir,
        "run_dir": run_dir,
        "events_file": events_file,
        "stderr_file": stderr_file,
        "last_message_file": last_msg_file,
        "started_at": started_at,
    }
    slot_fp.seek(0)
    slot_fp.truncate(0)
    slot_fp.write(json.dumps(meta))
    slot_fp.flush()

proc = None

def _forward_signal(signum, _frame):
    if proc is not None and proc.poll() is None:
        try:
            proc.send_signal(signum)
        except OSError:
            pass

signal.signal(signal.SIGTERM, _forward_signal)
signal.signal(signal.SIGINT, _forward_signal)

t0 = time.monotonic()
rc = 1
try:
    with open(slot_file, "w", encoding="utf-8") as sff:
        sff.write(str(slot_num))

    with open(prompt_src, "rb") as pf, \
         open(events_file, "wb") as ef, \
         open(stderr_file, "wb") as sf:
        proc = subprocess.Popen(cmd, cwd=workdir, stdin=pf, stdout=ef, stderr=sf)
        meta["pid"] = proc.pid
        slot_fp.seek(0)
        slot_fp.truncate(0)
        slot_fp.write(json.dumps(meta))
        slot_fp.flush()
        rc = proc.wait()
finally:
    duration_sec = round(time.monotonic() - t0, 2)
    with open(meta_out_file, "w", encoding="utf-8") as mf:
        json.dump({
            "slot": slot_num,
            "owns": owns_disp,
            "duration_sec": duration_sec,
            "started_at": started_at,
        }, mf)
    try:
        slot_fp.seek(0)
        slot_fp.truncate(0)
        slot_fp.flush()
    except OSError:
        pass
    if session_fp is not None:
        try:
            fcntl.flock(session_fp.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
        session_fp.close()
    if topic_fp is not None:
        try:
            fcntl.flock(topic_fp.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
        topic_fp.close()
    try:
        fcntl.flock(slot_fp.fileno(), fcntl.LOCK_UN)
    except OSError:
        pass
    slot_fp.close()

sys.exit(rc)
PY
RC=$?
set -e

SLOT_NUM=""
if [[ -f "$SLOT_FILE" ]]; then
  SLOT_NUM="$(cat "$SLOT_FILE" 2>/dev/null || true)"
fi

PARSED_INFO="$(python3 - "$EVENTS_FILE" "$META_OUT_FILE" "$RECEIPT_FILE" "$RC" "$CODEX_VERSION" "$MODEL" "$EFFORT" "$SERVICE_TIER" "$SESSION_MODE" "$TOPIC" "$RESUME_ID" "$WORKDIR" "$RUN_DIR" "$LAST_MSG_FILE" "$STDERR_FILE" <<'PY'
import datetime
import json
import os
import sys

(
    events_path,
    meta_out_path,
    receipt_path,
    rc_s,
    codex_version,
    model,
    effort,
    service_tier,
    session_mode,
    topic,
    resume_id,
    workdir,
    run_dir,
    last_msg_file,
    stderr_file,
) = sys.argv[1:]

rc = int(rc_s)
session_id = ""
event_count = 0
last_event_type = ""
usage_totals = {}

if os.path.exists(events_path):
    with open(events_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            event_count += 1
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if not isinstance(obj, dict):
                continue
            if obj.get("type"):
                last_event_type = str(obj["type"])
            if not session_id and obj.get("type") == "thread.started" and obj.get("thread_id"):
                session_id = str(obj["thread_id"])
            if obj.get("type") == "turn.completed" and isinstance(obj.get("usage"), dict):
                for k, v in obj["usage"].items():
                    if isinstance(v, (int, float)):
                        usage_totals[k] = usage_totals.get(k, 0) + int(v)

if not session_id and resume_id:
    session_id = resume_id

run_meta = {}
if os.path.exists(meta_out_path):
    try:
        with open(meta_out_path, "r", encoding="utf-8") as mf:
            run_meta = json.load(mf)
    except Exception:
        run_meta = {}

receipt = {
    "status": "ok" if rc == 0 else "failed",
    "exit_code": rc,
    "codex_version": codex_version,
    "slot": run_meta.get("slot"),
    "session_mode": session_mode,
    "topic": topic or None,
    "session_id": session_id or None,
    "workdir": workdir,
    "owns": run_meta.get("owns", []),
    "requested": {
        "model": model,
        "effort": effort,
        "service_tier": service_tier,
        "disabled_features": ["sleep_tool", "goals", "multi_agent", "multi_agent_v2"],
    },
    "started_at": run_meta.get("started_at"),
    "completed_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "duration_sec": run_meta.get("duration_sec"),
    "event_count": event_count,
    "last_event_type": last_event_type or None,
    "usage": usage_totals or None,
    "files": {
        "run_dir": run_dir,
        "last_message_file": last_msg_file,
        "events_file": events_path,
        "stderr_file": stderr_file,
        "receipt_file": receipt_path,
    },
}

with open(receipt_path, "w", encoding="utf-8") as rf:
    json.dump(receipt, rf, indent=2)
    rf.write("\n")

usage_str = ""
if usage_totals:
    usage_str = (
        f"in={usage_totals.get('input_tokens', 0)} "
        f"cached={usage_totals.get('cached_input_tokens', 0)} "
        f"out={usage_totals.get('output_tokens', 0)} "
        f"reasoning={usage_totals.get('reasoning_output_tokens', 0)}"
    )

print(json.dumps({
    "session_id": session_id,
    "usage_str": usage_str,
    "duration_sec": run_meta.get("duration_sec"),
}))
PY
)"

PARSED_SESSION_ID="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("session_id",""))' "$PARSED_INFO")"
USAGE_STR="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("usage_str",""))' "$PARSED_INFO")"
DURATION_SEC="$(python3 -c 'import json,sys; v=json.loads(sys.argv[1]).get("duration_sec"); print("" if v is None else v)' "$PARSED_INFO")"

if [[ -n "$TOPIC" && -n "$PARSED_SESSION_ID" && "$RC" -eq 0 ]]; then
  python3 - "$SESSION_STORE" "$WORKDIR" "$TOPIC" "$PARSED_SESSION_ID" "$MODEL" "$EFFORT" "$SERVICE_TIER" <<'PY'
import datetime
import fcntl
import json
import os
import sys
import tempfile

store_path, workdir, topic, sid, model, effort, service_tier = sys.argv[1:8]
lock_path = store_path + ".lock"
os.makedirs(os.path.dirname(store_path), exist_ok=True)

with open(lock_path, "a+", encoding="utf-8") as lf:
    fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
    data = {"sessions": {}}
    if os.path.exists(store_path):
        try:
            with open(store_path, "r", encoding="utf-8") as f:
                loaded = json.load(f)
                if isinstance(loaded, dict):
                    data = loaded
        except Exception:
            data = {"sessions": {}}

    sessions = data.setdefault("sessions", {})
    wd_map = sessions.setdefault(workdir, {})
    wd_map[topic] = {
        "session_id": sid,
        "model": model,
        "effort": effort,
        "service_tier": service_tier,
        "updated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }

    fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(store_path), prefix=".sessions.", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as tf:
        json.dump(data, tf, indent=2, sort_keys=True)
        tf.write("\n")
    os.replace(tmp_path, store_path)
PY
fi

if [[ "$JSON_SUMMARY" -eq 1 ]]; then
  cat "$RECEIPT_FILE"
  exit "$RC"
fi

if [[ "$RC" -eq 0 ]]; then
  echo "STATUS=ok"
else
  echo "STATUS=failed, EXIT_CODE=$RC"
fi
echo "CODEX_VERSION=$CODEX_VERSION"
echo "MODEL=$MODEL"
echo "EFFORT=$EFFORT"
echo "SERVICE_TIER=$SERVICE_TIER"
if [[ -n "$SLOT_NUM" ]]; then
  echo "SLOT=$SLOT_NUM"
fi
echo "SESSION_MODE=$SESSION_MODE"
if [[ -n "$TOPIC" ]]; then
  echo "TOPIC=$TOPIC"
fi
echo "SESSION_ID=${PARSED_SESSION_ID:-unknown}"
if [[ ${#OWNS_PATHS[@]} -gt 0 ]]; then
  echo "OWNS=$(IFS=,; echo "${OWNS_PATHS[*]}")"
fi
if [[ -n "$DURATION_SEC" ]]; then
  echo "DURATION_SEC=$DURATION_SEC"
fi
if [[ -n "$USAGE_STR" ]]; then
  echo "USAGE=$USAGE_STR"
fi
echo "WORKDIR=$WORKDIR"
echo "RECEIPT_FILE=$RECEIPT_FILE"
echo "LAST_MESSAGE_FILE=$LAST_MSG_FILE"
echo "EVENTS_FILE=$EVENTS_FILE"
echo "STDERR_FILE=$STDERR_FILE"
echo "--- LAST MESSAGE ---"
if [[ -f "$LAST_MSG_FILE" ]]; then
  cat "$LAST_MSG_FILE"
  echo ""
else
  echo "(no last message captured)"
fi

if [[ "$RC" -ne 0 && -s "$STDERR_FILE" ]]; then
  echo "--- STDERR ---"
  cat "$STDERR_FILE"
fi

exit "$RC"
