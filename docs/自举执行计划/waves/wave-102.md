# Wave 102 自举执行记录（已完成 · 2026-11-27）

> 返回：[总览](../README.md) · [越界台账](../越界写法治理清单.md)

## 核心改动

1. **`packages/core` 与 `packages/pkgs`（`wave102-core-pkgs-writes`）**：
    - 删除零调用写入模块 `core/bytes/map/place.zx` 及其在 `core/bytes/map/model.zx` 中专用的 `Write`/`Table`/`Bind`（`−2` `core` 写）。
    - 将 `core/type_table/{write_first,rebase}.zx` 与 `core/bytes/index/borrowed/refresh.zx` 从原地写 `U32Buffer` 全面改为纯 `u32[]` 返回，并同步更新 `core/type_table/{publication,storage}.zig`（局部 `ArenaAllocator` 释放前写回目标）与 `packages/pkgs/src/{install.zig,install/archive/{model.zx,plan.rx}}`（`−3` `core` 写，保持 `entries.zig` `type_delta_first` 与 `pkgs` 清单一致）。
    - 物理删除全仓零调用的原语 `writeOptionalString`、`OptionalStringBuffer`、`copyU32s` 与 `writeU32`（[buffer_values.d.zx](../../../packages/core/interfaces/memory/buffer_values.d.zx)/[scalar_buffers.d.zx](../../../packages/core/interfaces/memory/scalar_buffers.d.zx)/[types.d.zx](../../../packages/core/interfaces/memory/types.d.zx)/[root.zig](../../../packages/core/src/memory/root.zig)）。
2. **`packages/compiler/src/inputs` 与 `build/`（`wave102-compiler-inputs-build`）**：
    - 从 [inputs/generation/request/host.d.zx](../../../packages/compiler/src/inputs/generation/request/host.d.zx) 移除 5 项 `mutable_opaque` 句柄（`GenerationFileCache`、`SnapshotVersions`、`DocumentReader`、`InterfaceObservations`、`InterfaceLoader`）、7 条宿主声明与 2 项宿主结构，将摘要/版本只读查询与观察计划迁入 RX/ZX，并同步简化 `build/{generate_parser,input_snapshot,interface_inputs,source_collection}.zig`。
3. **`packages/compiler/src/backends/zig` 与 `verification/`（`wave102-compiler-zig-verif`）**：
    - 移除 `BootstrapPartitionScan`、`BootstrapWorkerAllocator`、`ParameterTarget`、`EvidenceOutput` 4 项句柄及 11 条净宿主声明（`scanPartitionRange`、`sameSymbolicFields`、`symbolicParameterField`、`reserveSymbolicParameter` 及 8 条分步 `beginEvidence`/`writeEvidence*`/`finishEvidence` 合并为结构化字段列表 `writeEvidence`）。
    - 修正 `verification/execution/program.zig`（`[]const *const native.Parameter`）与 `verification/solver/publication/evidence/output.zig`（`[]const *const native.EvidenceField`）跨 `.d.zx` 结构切片 ABI 签名。
4. **文档规范重构与无损分档**：
    - 响应用户指令，在 [AGENTS.md](../../../AGENTS.md) 与 [文档分工.md](../../../rules/文档分工.md) 移除 3,000 行上限并确立“每波尽可能大步 + Codex 多轮累积调度 + `.md` 不计入变更统计”；将 `README.md` 与 `越界写法治理清单.md` 的历史记录无损按每 5 波拆入 `waves/wave-001-005.md` … `wave-096-100.md`、`越界治理/category-*.md` 与 `越界治理/waves/`，Wave 101 起严格每波独立一档。

## 实测指标与验收

- **越界治理指标**：`core` `memory` 写 **7→2**（含分配 **9→4** / 实扫 `10→5`，`−5`；全仓仅余 `column_transfer` 与 `owned_text`），`OptionalStringBuffer` **4→0**（清零），`U32Buffer` **115→105**（`−10`），`mutable_opaque` **134→126**（`−8`），`opaque` **95→93**（`−2`），`.d.zx` 声明 **−21**（业务 `src` `1,311→1,293`，`core` `195→192`），RX `fn="host.*"` **315→312**（`−3`），`Output = void` **60→58**（`−2`）；6 个业务/标准库包写与全部已清零不变量（`rx_mem`/`arena`/`atomic`/`zig:*`/`std_opaque`/`storeAtomicCell`）全保持 `0`。
- **三阶段自编译**：`wave102/stage1` 30s `main.json` 冒烟 `5.88 s` 通过；`ReleaseSmall -Dgenerated-partitions=4` 三阶段 `stage1 == stage2 == stage3` SHA-256 一致（`a0353ea71c68717d27d7cd24acdf5bc4319b1616f11d11fe696047902dfe9fa6`）。
- **无争抢冷基准与 Parity**：`main` 清单 566 入口 / 5,122 模块 / 4,535 函数文件：`wave102/stage2` **`4.87 s`**（`15.17 s` user / `2.85 s` sys）vs `wave101/stage2` `4.94 s`（`−0.07 s`、相对 Wave 80 基线 `3.01 s` `+1.86 s` 均在容差内）；除 `.zxc-inputs` 外 `11,365` 产物 `PARITY_EXACT`。
- **全包测试与构建**：`-Dstage0=""` 种子构建、`compiler` `ReleaseSafe` 全量测试、`pkgs` `ReleaseSafe` 构建、`cli` `ReleaseSafe` 测试（零 `SafeAllocator` 泄漏）+ `ReleaseSmall` 构建与 `packages/test` `test-verification` `ReleaseSafe`（枚举 74/74 + 公开 8/8 + CLI 20/20）全部通过。
