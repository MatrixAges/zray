# Codex Executor Shared Rules (`skills/codex-executor/RULES.md`)

Shared operational, architecture, governance, verification, and response rules for all `codex-cli` workers invoked in this repository. Task briefs reference this file by path so prompts stay concise and carry only task-specific deltas.

---

## 1. Execution Mode & Anti-Hang Safety Redlines

- **Full-Delegation Mode**: You are authorized and expected to execute tasks end-to-end autonomously — code edits, debugging/reproducers, `zig build`, `bootstrap-stage`, single/full package tests (`zig build test`, `test-verification`), 3-stage self-compilation, cold benchmarks, governance audits, artifact cleanup, and wave documentation updates.
- **Bold Full-Subsystem Sweep Discipline**: Maximize safe end-to-end migration volume across your entire declared `--owns` scope in one pass — sweep all addressable handles, `.d.zx` decls, `opaque` wrappers, and hand-written Zig business logic boldly rather than stopping after 1–3 files. Cross-track integration issues are fixed rapidly in the solo closeout pass.
- **Parallel vs. Solo Heavy-Build Gate**:
    - **During parallel waves (2–6 concurrent slots)**: ONLY edit code inside your `--owns` scope and run fast narrow static checks (`zig ast-check`, per-file `zxc fmt "$f" --check`, per-file `zxc lint "$f"`, `git diff --check`). **NEVER** run full `zig build`, `bootstrap-stage`, `zig build test`, `test-verification`, 3-stage bootstraps, or benchmarks concurrently while other workers are active.
    - **Solo (single active slot, after all parallel workers finish)**: Full builds, full test suites, 3-stage bootstraps, cold benchmarks, and full-wave closeouts are allowed ONLY when running solo in an uncontended slot.
- **Always Non-Resident (`ZXC_RESIDENT_GENERATOR=0`)**:
    - Set `export ZXC_RESIDENT_GENERATOR=0` before running any `zig`, `zxc`, or `zxc-bootstrap` command so no `--serve` daemon leaks.
- **Process & Workspace Hygiene**:
    - Do NOT leave persistent background daemons, dev servers, file watchers, `&`/`nohup` orphan jobs, infinite `sleep`/polling loops, or nested subagents running; **Codex built-in `multi_agent` / `multi_agent_v2` subagents are unconditionally disabled and strictly forbidden for ALL Codex executors regardless of model** (`gpt-6.2-sol`, `gpt-6.2-astra`, etc.); bound probes cleanly (e.g., 30s timeout on full-manifest smoke probes) and ensure no `zxc-bootstrap --serve` processes remain before exiting.
    - NEVER delete `/tmp/codex-executor-runs` (or active brief files `/tmp/wave*_brief*.md`).
    - Do NOT run `git commit` or `git push` unless explicitly instructed in the task brief.
    - Stay strictly within declared `--owns` paths (when provided).

---

## 2. Repo Architecture & Governance Redlines (`AGENTS.md`)

- **Positive Self-Hosting Only**: Migrate hand-written Zig algorithms, orchestration, and state **into RX/ZX/`<Store>`** and delete the replaced Zig/bridges. NEVER shrink `.d.zx` counts, entries, or `@ptrCast` by reverting RX/ZX logic or state back to hand-written Zig.
- **Zero New Escapes** (must stay `0` / net-decreasing):
    - No `memory.write*`, `memory.copyBytes`, `memory.fill*`, atomics (`*Relaxed`/`Acquire`/`Release`/`Sequential`, `compareExchange*`, `waitU32`/`wake*`, `fetchAdd*`, `bytes.loadAtomic`), or manual arena/allocator ops (`selectAllocator`, `resetArena*`, `releaseArena`, `rewindScratchArena`); no `<Call fn="memory.*">` in RX.
    - No `mutable_opaque` or atomic concurrency primitives exported by user-facing `packages/std`.
    - No `import ... from "zig:*"` in self-hosted RX/ZX source (use `std:*` or pure ZX).
    - No new side-effecting `void` ZX functions mutating external state via `mutable_opaque` / `*_host` / `memory.write*` (return pure values, or commit via RX `setter={[$store.*]}`).
- **Protected Directories (Do Not Touch Unless Explicitly Authorized)**:
    - `packages/genz/src/analysis/uniqueness/atomic/` (`AtomicRows` / `memory.loadAtomicCell` / `Metadata` — never introduce `storeAtomicCell` or write escapes)
- **ZX & RX Rules & Common Repo Gotchas**:
    - `zxc fmt "$f" --check` and `zxc lint "$f"` accept **ONE file path per invocation** (passing multiple paths prints usage and exits `0`); always loop per file and skip `docs/`.
    - **Zig 0.17 type reflection**: `std.meta.fields` is deprecated and `Type.Struct` has `.field_names` (not `.fields`); use `inline for (@typeInfo(T).@"struct".field_names) |name| { const FT = @FieldType(T, name); ... }`.
    - **Directory-merged `.d.zx` files**: all `.d.zx` files in a directory merge alphabetically, and all `export type` / `export enum` MUST precede all `export declare function`.
    - **Generated ABI structs**: `zxc` emits generated struct fields in alphabetical order; prefer using generated ABI struct types directly on the Zig side rather than duplicating matching hand-written Zig structs for `zx.columns.pointer`.
    - **Auto-rooted `.store.rx`**: every `.store.rx` under `packages/compiler/src` is auto-rooted across all manifests (`host`, `growth`, `main`, `execution`), so its `<Type>` imports must be pure ZX types only. RX forbids `$store.*` directly in `<If on={...}>` or `<Return value={...}>` (read via a pure ZX `<Call in={$store...}>` first). Never pass `.failing` or a zero-byte `FixedBufferAllocator` to a `<Store>`-bearing entry.
    - **`packages/pkgs` & `packages/test` build quirks**: `packages/pkgs` has NO `test` step (`zig build -Doptimize=ReleaseSafe -Dgenerated-partitions=4 -Dstage0=...`). `packages/test` `test-verification` does NOT accept `-Dgenerated-partitions=4`.
    - **Doc boundaries**: one standalone `.md` per wave (`docs/自举执行计划/waves/wave-NNN.md`); update ONLY overview tables/indexes in `docs/自举执行计划/README.md` and `docs/自举执行计划/越界写法治理清单.md`.

---

## 3. Standard Solo Wave Closeout Checklist (7 Steps)

When assigned a full-wave closeout verification task (running solo, with baseline commit `<BASE_SHA>` and wave number `NNN`), execute all 7 steps sequentially with `export ZXC_RESIDENT_GENERATOR=0`:

1. **Static & Lint Checks**:
    - `git diff --check`
    - `zig ast-check` on all modified/new `.zig` files under `packages/`
    - Per-file `zxc fmt "$f" --check` and `zxc lint "$f"` on all modified/new `.rx`/`.zx` files outside `docs/` (confirm zero new lint errors; verify any `rc=134` panics are pre-existing at `<BASE_SHA>`).
2. **Exact Apples-to-Apples Governance Audit (`<BASE_SHA>` vs working tree)**:
    - Measure across `packages/{cli,compiler,genz,core,pkgs,std}`: `mutable_opaque` (total & per-package), `opaque` (total & per-package), business `.d.zx` `export declare function` decls (excl. `packages/std`), RX `fn="host.*"`, `.store.rx` (total & non-cli), `.zx` `U32Buffer` (total & per-package), `void` ZX (authorized `$store` setters vs non-setter), zeroed invariants, and empty diff on protected directories. Fail immediately with `OUTCOME: failed` on any regression.
3. **3-Stage Self-Compilation (`ReleaseSmall -Dgenerated-partitions=4`)**:
    - Clean stale `.zig-cache/verification-tmp/waveNNN/{stage1,stage2,stage3}`.
    - Build `stage1` from previous pinned `stage2`; run a 30s-bounded `packages/compiler/build/manifests/main.json` smoke probe on `waveNNN/stage1` BEFORE starting `stage2`.
    - Build `stage2` from `stage1`, then `stage3` from `stage2`.
    - Verify `shasum -a 256` of `stage1`, `stage2`, `stage3` (`stage2 == stage3`).
4. **Uncontested Cold `main` Benchmark & `PARITY_EXACT`**:
    - Benchmark previous `stage2` vs `waveNNN/stage2` sequentially (uncontested) on `packages/compiler/build/manifests/main.json`, recording wall/user/sys times and comparing against fixed baseline tolerance (single-stage <= +1.0s wall/CPU; cumulative <= +3.0s).
    - Diff all generated `.zig` files (excluding `.zxc-inputs`) and verify `PARITY_EXACT` (or report exact codegen diffs).
5. **Sequential 6-Suite Verification** (`STAGE2=".../waveNNN/stage2/bin/zxc-bootstrap"`):
    - Suite 1 (`packages/compiler`): `zig build -Doptimize=ReleaseSafe -Dstage0=""`
    - Suite 2 (`packages/compiler`): `zig build test -Doptimize=ReleaseSafe -Dgenerated-partitions=4 -Dstage0="$STAGE2"`
    - Suite 3 (`packages/pkgs`): `zig build -Doptimize=ReleaseSafe -Dgenerated-partitions=4 -Dstage0="$STAGE2"`
    - Suite 4 (`packages/cli`): `zig build test -Doptimize=ReleaseSafe -Dgenerated-partitions=4 -Dstage0="$STAGE2"` (0 leaks)
    - Suite 5 (`packages/cli`): `zig build -Doptimize=ReleaseSmall -Dgenerated-partitions=4 -Dstage0="$STAGE2"` (also refresh per-file `zxc fmt --check` & `zxc lint` with this CLI)
    - Suite 6 (`packages/test`): `zig build test-verification -Doptimize=ReleaseSafe -Dstage0="$STAGE2"` (NO `-Dgenerated-partitions=4`!; verify public 8/8, enum 74/74, CLI 20/20)
6. **Artifact Cleanup (only after all 6 suites & parity pass)**:
    - Update `.zig-cache/.cleanup-keep` to pin `.zig-cache/verification-tmp/waveNNN/stage2/bin/zxc-bootstrap` (replacing previous wave's `stage2`, preserving any fixed baseline entry).
    - Remove superseded wave dir and temporary `waveNNN` subdirs except `waveNNN/stage2` (NEVER delete `/tmp/codex-executor-runs`).
    - Confirm no `zxc-bootstrap --serve` processes remain (`NO_SERVE`).
7. **Wave Documentation**:
    - Write standalone `docs/自举执行计划/waves/wave-NNN.md` matching prior wave format.
    - Update ONLY overview tables/indexes in `docs/自举执行计划/README.md` (filling any pending commit SHA on previous wave if missing + adding Wave `NNN` row & totals) and `docs/自举执行计划/越界写法治理清单.md` (top summary table & Wave `NNN` index row).

---

## 4. Required Final Response Format

End your final message with:

```text
OUTCOME: succeeded | failed | blocked
SUMMARY: <1-3 sentences>
FILES_MODIFIED: <comma-separated paths or none>
VERIFICATION: <commands run and exact observed pass/fail or metrics>
BLOCKERS: <none or concrete blocker>
```
