# Wave 104 自举执行记录（已完成 · 2026-11-28）

> 返回：[总览](../README.md) · [越界台账](../越界写法治理清单.md)

## 核心改动（多轮 Codex 大步累积 + `packages/cli` 零 `mutable_opaque` 清零 + `core`/`build` 收口）

本波继续采用“`gpt-6.2-sol` + `high` + `fast` 并发 Codex 执行者（同主题 session 复用 + 严格互斥 `--owns`）多轮叠加累积后再单次整波三阶段验收”的大步推进模式，共清除 **22** 项 `mutable_opaque`（`101 → 79`）与 **98** 条业务 `.d.zx` 函数声明（`1,400 → 1,302`），其中 `packages/cli/src` 率先实现 **`mutable_opaque` 清零（`9 → 0`）**：

1. **`packages/cli/src`（`wave104-cli-zero-mut`，清零 CLI `mutable_opaque` + RX/ZX/Zig ABI 全量收口）**：
    - 移除 `packages/cli` 全部剩余 **`9`** 项 `mutable_opaque`（`9 → 0`：`cli/build/dependencies/host.d.zx` `Dependencies`、`cli/native_sources/host.d.zx` `Context`、`cli/publication/host.d.zx` `Verification`、`cli/toolchain/workflow/host.d.zx` `Toolchain`、`package/graph/host.d.zx` `Host`、`package/install/host.d.zx` `Host`、`package/manifest/decode/document.d.zx` `Document`、`package/store/cache/host.d.zx` `Cache`、`package/store/receipt/host.d.zx` `Receipt`），并消除 `Configuration` `opaque`，`.d.zx` 声明 **`512 → 484`（`−28`）**。
    - 修正 `configuration/run.rx`、`configuration/finalize.rx`、`store/receipt/{file,step}.rx`、`package/install/fresh/dependency.rx`、`package/graph/installed/{read,archive,step,member}.rx`、`toolchain/workflow/cache.rx` 中的 RX 可空值收窄与相对路径边界，清理 `package/manifest/decode/path.zx`、`cli/native_sources/bundle/locations.zx`、`package/graph/workspace/diagnostic.zx` 类型检查问题。
    - 对齐 Zig 宿主 ABI 返回签名：`package/graph/installed/storage.zig`（`readInstalledArchive`、`borrowMember` 返回 `?*const abi.PackageManifest`）、`package/install/fresh/storage.zig`（`finishFresh` 返回 `*const abi.LockData`）、`package/install/fresh/archive_io.zig`（`readArchive` 返回 `*const abi.ArchiveManifest`）、`cli/configuration/root.zig` 显式补全 `ConfigurationContent` 三字段，以及 `package/manifest/decode.zig` 显式收敛 `error.OutOfMemory`。
2. **`packages/compiler/src/{rx/analysis,zx,inputs}`（`wave104-compiler-mega`）**：
    - 消除 **`9`** 项 `rx/analysis` / `zx` `mutable_opaque`（`rx/analysis/project/workflow/host/types.d.zx` `ExpressionLink`，以及 `zx/modules/project/execution/types.d.zx` 中 `ArtifactExtraction`、`ArtifactLink`、`CompiledImport`、`NativeCacheLoad`、`ProjectEntry`、`ProjectSignatures`、`ProjectState`、`ProjectWalk`；`zx/modules/project/execution/` 仅余 `ProjectBody` 与 `ProjectImport`）及 `PathAllocator`、`SourceBody` 2 项 `opaque`，保留 `rx/analysis/inference/{optional,assignment}/` 受保护目录零改动。
    - 清理 `execution.json` 与 `inference/forest.zig` 类型/初始化问题，并将 `rx/analysis/project/source_graph/construct/{entry,roots,model}.zx`、`construct/build.rx`、`construct.zig` 中跨越 `self.allocator` 与 `self.scratch` 的 `memory.freeOwnedText(in.allocator, path)` 与 `temporary: Allocator` 一并移除，根治 `r2_stage1` 运行时段错误。
3. **`packages/genz/src` 与 `packages/compiler/src/{backends,verification}`（`wave104-genz-back-verif`）**：
    - `genz` 移除 **`3`** 项 `mutable_opaque`（`analysis/expressions/evaluate/frames.d.zx` `CallFrame`、`FunctionBody`；`iteration_frames.d.zx` `TransformFrame`，`14 → 11`）与 **`14`** 条 `.d.zx` 声明（`267 → 253`）；将 `ast/rows` 全部类型前置集中于 `expressions.d.zx` 满足目录合并顺序，保留 `uniqueness/atomic` 受保护 `AtomicRows` 零改动。
    - `backends/` 与 `verification/` 移除 `Nodes`（`backends/hardware/graph/view.d.zx`）与 `BootstrapPartitionJobs`（`backends/zig/output_host.d.zx` / `output/parallel.zig`），合 `compiler` 全包计 `mutable_opaque 63 → 53`、`opaque 8 → 5`、`.d.zx` 声明 **`432 → 377`（`−55`）**。
4. **`packages/core`、`packages/compiler/build` 与 `packages/compiler/src/root.zig`（`wave104-core-cleanup`）**：
    - 删除独立生成入口 `artifact_graph` 与 `uniqueness_return_only`、8 条无引用 manifest 别名以及死声明 `u64ViewSlice`（`core` `.d.zx` `189 → 188`）。

## 实测指标与验收

- **越界治理指标（严格同口径对照 `HEAD` Wave 103 `ebae849a7`）**：
    - `mutable_opaque`：**`101 → 79`（`−22`）**（`cli 9→0` 清零 / `compiler 63→53` / `genz 14→11` / `core 15→15` / `pkgs 0` / `std 0`）
    - `opaque`：**`86 → 96`（`+10`）**（`cli 47→60` / `compiler 8→5` / `genz 1→1` / `core 30→30`）
    - 业务 `.d.zx` 函数声明：**`1,400 → 1,302`（`−98`）**（含 `cli 512→484` `−28`、`compiler 432→377` `−55`、`genz 267→253` `−14`、`core 189→188` `−1`）；非 `core` 合计 `1,211 → 1,114`（`−97`）
    - RX `fn="host.*"`：**`306 → 295`（`−11`）**
    - `.store.rx`：**`36`**（其中非 `cli` `22`）
    - `Output = void` ZX：共 **62**（其中授权 `$store` setter **31** 份，遗留非 `$store` `void` ZX **31** 份：`core` 28 / `genz` 2 / `cli` 1 / `compiler` 0）
    - `U32Buffer`（`.zx` 引用）：**`94 → 86`（`−8`）**
    - `core` 写保持 9 行；6 个业务/标准库包写与全部已清零不变量（`rx_mem` / `arena` / `atomic` / `zig:*` / `std_opaque` / `storeAtomicCell`）全部保持 **`0`**。
- **静态检查**：`git diff --check` 无空白错误；全部改动/新增 `.zig` 文件 `zig ast-check` 全过（`0` 失败）；新编 `packages/cli/zig-out/bin/zxc` 对全部 **287** 个改动/新增 `.rx`/`.zx`/`.d.zx` 文件检查通过（`packages/genz/src/ast/rows/expressions.d.zx` 532 行通过 `zxc lint --max-lines 600`，`.rx` 格式一致；仅`.zx` 含 `.Omit`/type-only 声明触发与 `HEAD` 相同的既有 `zxc fmt` `rc=134`）。
- **三阶段自编译**：`wave104/stage1` `main.json` 冒烟 `~4.41 s` 通过（564 入口 / 5,122 模块 / 4,527 函数文件）；`ReleaseSmall -Dgenerated-partitions=4` 三阶段 `stage1 == stage2 == stage3` SHA-256 逐位一致（`b779635e00e27962df125d4b03b9a181c497add6282e98ab4f11f249146f2712`）。
- **无争抢冷基准与 Parity**：`main` 清单 564 入口 / 5,122 模块 / 4,527 函数文件：`wave104/stage2` **`4.87 s`**（`14.84 s` user / `2.77 s` sys；`infer 1467ms, emit 2685ms, write 333ms`）vs `wave103/stage2` `4.85 s`（`14.87 s` user / `2.85 s` sys；`infer 1490ms, emit 2664ms, write 367ms`），墙钟 **`+0.02 s`**、CPU **`−0.11 s`**（相对 Wave 80 基线 `3.01 s` `+1.86 s`）；全部 **11,334** 份生成 `.zig` 产物 `PARITY_EXACT`（仅 `.zxc-inputs` stamp 因引导器哈希不同）。
- **全包测试与构建**：`-Dstage0=""` 种子构建、`packages/compiler` `ReleaseSafe` 测试、`packages/pkgs` `ReleaseSafe` 构建、`packages/cli` `ReleaseSafe` 测试（零 `SafeAllocator` 泄漏）+ `ReleaseSmall` 构建，以及 `packages/test` `test-verification` `ReleaseSafe`（CLI 20/20 + 枚举 74/74 + 公开 8/8）全部一次通过。
