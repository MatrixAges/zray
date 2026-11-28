# Wave 105 自举执行记录（已完成 · 2026-11-28）

> 返回：[总览](../README.md) · [越界台账](../越界写法治理清单.md)

## 核心改动（多轮 Codex 大步累积 · 全仓正向大收敛）

本波由 Orchestrator 统筹调度 4 路互斥 `--owns` Codex 执行者（`gpt-6.2-sol` + `high` + `fast`，复用同主题 session 多轮叠做），在 `380` 处变更文件与 `45` 个新增源码文件的大步累积下，实现全仓 **`mutable_opaque` 79 → 62（−17）**、**`opaque` 96 → 88（−8）**、**业务 `.d.zx` 函数声明 1,302 → 1,163（−139）**、**RX `fn="host.*"` 295 → 273（−22）** 与 **`.zx` `U32Buffer` 86 → 38（−48）**，并新增 `4` 份 `.store.rx`（`36 → 40`）：

1. **`packages/compiler/src/{rx/analysis,zx}`（`wave105-compiler-workflow` · 两轮累计）**：
    - 移除 **`5`** 项 `mutable_opaque`（`HistoryParseCache`、`StoreRegistryPublication`、`MixedWorkspace`、`GraphVisit`、`MixedImports`），新增 `rx/analysis/project/mixed/ahead/workspace.store.rx`、`rx/analysis/store/registry/publication.store.rx`、`rx/analysis/project/source_graph/scan/dependencies.store.rx` 与 `rx/analysis/project/mixed/imports/binding.store.rx`。
    - 将非受保护目录下的 `.zx` `U32Buffer` 引用由 26 项压降至 2 项（全仓 `compiler` `75 → 27`，保留受保护目录 `rx/analysis/inference/{optional,assignment}/` 零改动）。
    - 将 `rx/analysis/project/mixed/imports/model.zx` `Rows` 与 `source_graph/scan/dependencies.store.rx` 类型彻底去耦出 `execution` 专属宿主接口（满足全清单 `.store.rx` 自动入根约束），并把 `$store.*` 在 `advance.rx` `<Return>` 与 `imports/step.rx` `<If>` 中的读取改为通过纯 ZX reader 调用承接；同步修复 `store/registry.zig` scratch allocator 与 `history/admission.zig` 可空字段初始化。
2. **`packages/genz/src` 与 `packages/compiler/src/{backends,verification}`（`wave105-genz-back-verif-inputs` · 两轮累计）**：
    - 移除 **`11`** 项 `mutable_opaque`（含 `BootstrapPartition`、`FunctionSourceWorker`、`StatePublication`、`BasisWork`、`FunctionSources`、`ApplicationInitializers`、`BootstrapMirror`、`SymbolicProgram`、`AnalysisWork`、`ValueFunction`、`ModuleFrame`），使 `genz` `mutable_opaque 11 → 7`、`backends` 降至 `1`（`HardwareBuild`）、`verification` 降至 `3`（保留受保护 `uniqueness/atomic` `AtomicRows` 零改动）。
    - 移除 **`71`** 条 `.d.zx` 函数声明（`genz 253 → 212` `−41`，其余 `−30` 计入 `compiler`）；并修正 `verification/execution/program.zig:75` 对 `zx.columns.borrow` 的显式 `*const zx.ir.TypeTable` 只读借用指针。
3. **`packages/cli/src`（`wave105-cli-host-shrink` · 两轮累计）**：
    - 在保持 `mutable_opaque == 0` 的同时，进一步消减 **`52`** 条 `.d.zx` 函数声明（`484 → 432`）与 **`9`** 项 `opaque`（`60 → 51`），覆盖 `compilation`、`lint`、`publication`、`rx/{checking,collection,execution,preparation}`、`library/{workflow,stage,resources,retirement,link,analysis}`、`package/{project,workspace}`、`watch/{driver,observation}`。
    - 修正 `cli/watch/observation/scan.zig:46`（改为模块函数 `read.observe`）与 `package/project.zig:52`（对齐多字段 `Outcome` 的 `workspace_project.executeIn`）。
4. **`packages/core`、`packages/compiler/{build,src/inputs,src/root.zig}`（`wave105-core-build`）**：
    - 删除 `OptionalU32Buffer`（`core` `mutable_opaque 15 → 14`）及 `optionalU32Views`/`bindColumnRanges`/`borrowWriteColumn`（`core` `.d.zx` `188 → 187`），将 `inputs/generation/request` 的 stamp 比对与构建收口至纯 ZX/RX（`readGenerationStamp`、`invalidateGenerationStamp`、`writeGenerationStamp` 直接声明精确 I/O 原语，不再经 `GenerationRequest` 封装）。
    - 移除 `12` 个无引用生成入口与死解析器 `parsed_inputs`。

## 实测指标与验收

- **越界治理指标（严格同口径对照 `HEAD` Wave 104 `03d85d08a`）**：
    - `mutable_opaque`：**`79 → 62`（`−17`）**（`cli 0` / `compiler 53→41` / `genz 11→7` / `core 15→14` / `pkgs 0` / `std 0`）
    - `opaque`：**`96 → 88`（`−8`）**（`cli 60→51` / `compiler 5→6` / `genz 1` / `core 30`)
    - 业务 `.d.zx` 函数声明（不含 `std` 180）：**`1,302 → 1,163`（`−139`）**（`cli 484→432` `−52`、`compiler 377→332` `−45`、`genz 253→212` `−41`、`core 188→187` `−1`）；含 `std` 总计 `1,482 → 1,343`（`−139`）
    - RX `fn="host.*"`：**`295 → 273`（`−22`）**（`compiler 276→254` / `genz 19`）
    - `.store.rx`：**`36 → 40`（`+4`）**（其中非 `cli` `22 → 26`、`cli 14`）
    - `Output = void` ZX：共 **66**（其中授权 `$store` setter `31 → 35`（`+4`），遗留非 `$store` `void` ZX 保持 **31**：`core` 28 / `genz` 2 / `cli` 1 / `compiler` 0）
    - `U32Buffer`（`.zx` 引用）：**`86 → 38`（`−48`）**（`compiler 75→27` / `genz 9` / `core 2`）
    - `core` 写保持不变（3 处 `memory.*` 直接写 + 6 处列写）；全部 6 个业务与标准库包 `memory.*` 写、以及全部已清零不变量（`rx_mem` / `arena` / `atomic` / `zig:*` / `std_opaque` / `storeAtomicCell`）全部保持 **`0`**。
- **静态检查**：`git diff --check` 无空白错误；全部 **98** 份改动/新增 `.zig` 文件 `zig ast-check` 全过；新编 `packages/cli/zig-out/bin/zxc` 对 **110** 份改动 `.rx` 文件 `zxc fmt --check` 全过（`0` 失败），对 **303** 份改动/新增 `.rx`/`.zx`/`.d.zx` 文件运行 `zxc lint`（296/296 通过，其中 `genz/src/ast/rows/expressions.d.zx` 通过 `--max-lines 600`；余 7 份仅含类型声明/.Omit 触发与 `HEAD` `03d85d08a` 完全一致的既有 `zxc lint` `rc=134`）。
- **三阶段自编译**：`wave105/stage1` `main.json` 30s 冒烟通过（554 入口 / 5,066 模块 / 4,475 函数文件 / 5,174 生成；`infer 1440ms, emit 2681ms, write 365ms`）；`ReleaseSmall -Dgenerated-partitions=4` 三阶段 `stage1 == stage2 == stage3` SHA-256 逐位一致（`26dc7c87794e25cb0443afe348dedd01c65067556407823ddc5be876c4d9a1a0`）。
- **无争抢冷基准与 Parity**：`main` 清单 554 入口 / 5,066 模块 / 4,475 函数文件：`wave105/stage2` **`4.85 s`**（`14.72 s` user / `2.81 s` sys；`infer 1455ms, emit 2677ms, write 366ms`）vs `wave104/stage2` `4.96 s`（`14.73 s` user / `2.96 s` sys；`infer 1477ms, emit 2670ms, write 411ms`），墙钟 **`−0.11 s`**、CPU **`−0.16 s`**（相对 Wave 80 基线 `3.01 s` `+1.84 s`，处于容差内）；全部 **11,203** 份生成 `.zig` 产物 `PARITY_EXACT`（排除 `.zxc-inputs`）。
- **全包测试与构建**：`-Dstage0=""` 种子构建、`packages/compiler` `ReleaseSafe` 测试、`packages/pkgs` `ReleaseSafe` 构建、`packages/cli` `ReleaseSafe` 测试（零泄漏）+ `ReleaseSmall` 构建，以及 `packages/test` `test-verification` `ReleaseSafe`（公开 8/8 + 枚举 74/74 + CLI 20/20）全部一次通过。
