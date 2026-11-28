# Wave 103 自举执行记录（已完成 · 2026-11-28）

> 返回：[总览](../README.md) · [越界台账](../越界写法治理清单.md)

## 核心改动（多轮 Codex 大步累积 + `core`/`root.zig` 收口）

本波首次全面采用“`gpt-6.2-sol` + `high` + `fast` 并发 Codex 执行者（同主题 session 复用 + 严格互斥 `--owns`）多轮叠加累积后再单次整波三阶段验收”的大步推进模式，共清除 **25** 项 `mutable_opaque`（`126 → 101`）、**7** 项 `opaque`（`93 → 86`）与 **96** 条业务 `.d.zx` 宿主声明（`1,496 → 1,400`）：

1. **`packages/cli/src`（`wave103-cli-mega`，Round 1 + Round 2 + 跨 ABI 标量化修正）**：
    - 移除 **`7`** 项 `mutable_opaque`（`16 → 9`：`Output`、`Library`、`Response`、`FileSystem`、`Scanner`、`Archive`、`Download`），并将包清单解码句柄 `Node` 一并消解，`.d.zx` 声明 **`554 → 512`（`−42`）**。
    - 重点消解 `cli/publication`（输出/库发布编排与预检 `library/preflight.zx`）、`cli/backend/source/frames`、`cli/build/{dependencies,workspace}`（工作区文件构建与 `host_directories.zx`）、`cli/native_sources`、`cli/toolchain/workflow`、`cli/watch/observation`、`package/manifest/{decode,layout}`、`package/archive/extract` 与 `package/store/{cache,download,receipt}` 中的宿主状态与声明，将工作区写入/缓存写入/归档读取与相对路径改为纯 ZX/RX 逻辑及跨 ABI 标量/切片传参（`artifacts.zig` 与 `package/manifest/decode.zig` 统一接入 `executeIn`）。
2. **`packages/compiler/src/{rx/analysis,zx}`（`wave103-compiler-mega`，Round 1 + Round 2 + bonus）**：
    - 移除 `SourceEntry`、`AnalysisEntry`、`AnalysisPublication`、`GraphInternalModules`、`ParseWorker`、`CacheSlot`、`ProgramEntry` 等多组句柄，`.d.zx` 声明与包装函数净减（`rx/analysis` 与 `zx/modules/project/execution/` / `parse_cache/`），保持受保护目录 `rx/analysis/inference/{optional,assignment}/` 零改动；新增合乎规范的 `<Store>` 状态（`.store.rx` `compiler` 侧扩充），将 `entry_body/publication` 与 `parse_cache/worker` 转为 `$store.*` 显式授权更新，并将 `zx/` 下 3 处 `U32Buffer` 替换为只读切片。
    - 统一解决 [workflow/host/types.d.zx](../../../packages/compiler/src/rx/analysis/project/workflow/host/types.d.zx) 与 `call_types.d.zx` 类型前置顺序、`workflow/solve/constraints.rx` `$ctx` 重名分支，以及 Zig 0.17.1 `std.lang.Type.Struct.field_names`（[surface/host.zig](../../../packages/compiler/src/zx/modules/link/source/surface/host.zig)）与 `Ports.Slice.set` 可变切片问题。
3. **`packages/genz/src` 与 `packages/compiler/src/{backends,verification}`（`wave103-genz-back-verif`，Round 1 + Round 2）**：
    - `genz` 移除 **`9`** 项 `mutable_opaque`（`23 → 14`）与 **`10`** 条 `.d.zx` 声明（`277 → 267`）：精简 `analysis/expressions/evaluate/{frames,iteration_frames}.d.zx`（消除 `SequenceFrame`、`ObjectFrame`、`IterationCallFrame`、`MatchFrame`、`CollectionFrame`、`IterationResultApplication`、`SortFrame`、`SortWorkerFrame`、`TaskWorker` 等帧句柄）、[ast/rows/write.d.zx](../../../packages/genz/src/ast/rows/write.d.zx)（`38 → 33` 声明）与 `collections`/`aggregate`/`transform`/`sorting` lowering 链路（受保护的 `AtomicRows`/`Metadata` 与 `uniqueness` 原子通道保持零改动）。
    - `backends/` 与 `verification/` 移除 **`8`** 项句柄（`BootstrapWriter`、`EvidenceInputs`、`EvidenceSources`、`GraphRegistration`、`SelectionGraph`、`SymbolicInvocation`、`SymbolicTarget`、`SymbolicValue`），净减 13 条 `.d.zx` 声明（`symbolicQueryPrefix` 改为返回快照；[verification/execution/call.zig](../../../packages/compiler/src/verification/execution/call.zig) 修正 `@ptrCast(handle)`），合 `compiler` 全包计 `mutable_opaque 72→63`、`opaque 16→8`、`.d.zx` 声明 `473→432（−41）`。
4. **`packages/core` 与 `packages/compiler/src/root.zig`（`wave103-core-cleanup`）**：
    - 删除 [compiler/src/root.zig](../../../packages/compiler/src/root.zig) 中零调用的旧 `evidence_output` 导入与 7 条证据导出（`beginEvidence`、`writeEvidenceSources`、`writeEvidenceText`、`writeEvidenceNumber`、`writeEvidenceInputs`、`writeEvidenceProgram`、`finishEvidence`）。
    - 删除 `packages/core/interfaces/memory/{column_set_operations,views}.d.zx` 及 [packages/core/src/memory/root.zig](../../../packages/core/src/memory/root.zig) 中无调用方的 `borrowFunctionBodyBytes`、`borrowForwardedBodyBytes`、`u32View`（`core` `.d.zx` 声明 `192 → 189`）。

## 实测指标与验收

- **越界治理指标（严格同口径对照 `HEAD` Wave 102）**：
    - `mutable_opaque`：**`126 → 101`（`−25`）**（`cli 16→9` / `compiler 72→63` / `genz 23→14` / `core 15→15` / `pkgs 0` / `std 0`）
    - `opaque`：**`93 → 86`（`−7`）**（`cli 46→47` / `compiler 16→8` / `core 30→30` / `genz 1→1`）
    - 业务 `.d.zx` 函数声明：**`1,496 → 1,400`（`−96`）**（含 `cli 554→512` `−42`、`compiler 473→432` `−41`、`genz 277→267` `−10`、`core 192→189` `−3`）；非 `core` 合计 `1,304 → 1,211`（`−93`）
    - RX `fn="host.*"`：**`312 → 306`（`−6`）**
    - `.store.rx`：**`32 → 36`**（其中非 `cli` `18 → 22`）
    - `Output = void` ZX：共 **62**（其中授权 `$store` setter **31** 份，遗留非 `$store` `void` ZX 仅剩 **31** 份：`core` 28 / `genz` 2 / `cli` 1 / `compiler` 0）
    - `U32Buffer`：**`105 → 97`（`−8`**，非 `core` `99 → 92`） / `U64Buffer` `10` / `StringBuffer` `9` / `OptionalStringBuffer` `0`
    - `core` 写保留 9 行；6 个业务/标准库包写与全部已清零不变量（`rx_mem` / `arena` / `atomic` / `zig:*` / `std_opaque` / `storeAtomicCell`）全部保持 **`0`**。
- **静态检查**：新编 `packages/cli/zig-out/bin/zxc` 对全部 **320** 个改动/新增 `.zx`/`.rx`/`.d.zx`/`.store.rx` 运行 `zxc fmt --check` 与 `zxc lint` 全过，全部 **94** 个改动 Zig 文件 `zig ast-check` 全过，`git diff --check` 无空白错误。
- **三阶段自编译**：`wave103/stage1` 30s `main.json` 冒烟 `5.19 s` 通过（566 入口 / 5,130 模块 / 4,534 函数文件）；`ReleaseSmall -Dgenerated-partitions=4` 三阶段 `stage1 == stage2 == stage3` SHA-256 完全一致（`9d7cec9986d70d1280a518bf5fef232910428a353d6164b37d0e23d025ffaeb7`）。
- **无争抢冷基准与 Parity**：`main` 清单 566 入口 / 5,130 模块 / 4,534 函数文件：`wave103/stage2` **`4.86 s`**（`14.85 s` user / `2.79 s` sys）vs `wave102/stage2` `4.95 s`（`15.04 s` user / `2.88 s` sys），墙钟 **`−0.09 s`**、CPU **`−0.28 s`**（相对 Wave 80 基线 `3.01 s` `+1.85 s`，均远优于容差上限）；全部 **11,357** 份生成 `.zig` 产物 `PARITY_EXACT`（仅 `.zxc-inputs` stamp 因引导器哈希不同）。
- **全包测试与构建**：`-Dstage0=""` 种子构建、`packages/compiler` `ReleaseSafe` 全量测试、`packages/pkgs` `ReleaseSafe` 构建、`packages/cli` `ReleaseSafe` 测试（零 `SafeAllocator` 泄漏）+ `ReleaseSmall` 构建，以及 `packages/test` `test-verification` `ReleaseSafe`（CLI 20/20 + 枚举 74/74 + 公开 8/8）全部一次通过。
