# `packages/core` 自举诊断与执行计划

> 归属角色：编译器共享 IR 表契约与内存原语底座 · 状态：**P0 最优先阻塞点（UB 源头 + 胶水放大器）** · 总览：[README.md](README.md) · 上位报告：[自举进度诊断和指导报告.md](自举进度诊断和指导报告.md)

---

## 一、现状总账（`HEAD 4a1a0c5a`）

| 维度                     |                                  数值 | 说明                                                      |
| ------------------------ | ------------------------------------: | --------------------------------------------------------- |
| 非 seed Zig (`src/`)     |                **89 文件 / 9,066 行** | 含 `memory/` 3,566 行及 IR 实体表存储                     |
| seed Zig                 |                                 **0** | 无独立 seed 目录                                          |
| RX / ZX 源码             | **4 份 (88 行) / 267 份 (10,351 行)** | 包含 `bytes`、`integer`、`error_effects`、`type_table` 等 |
| `.d.zx` 接口             |     **17 份 / 2,172 行 / 341 个函数** | 集中于 `interfaces/memory/*.d.zx`                         |
| `@ptrCast` / `anyopaque` |                            **564 处** | 全包高度依赖不透明指针强转                                |
| `@constCast`             |                             **36 处** | 全部位于 `src/memory/`                                    |

### `src/` Zig 职责拆解与重灾区文件

| 类别 / 子目录                                                                                                                             | 文件数 |  行数 | 占比 / 角色 |
| ----------------------------------------------------------------------------------------------------------------------------------------- | -----: | ----: | ----------- |
| 纯 Zig 逻辑与表存储（`expression_table` 1,028L、`control_table` 561L、`type_table` 449L、`function_table` 387L、`error_effects` 314L 等） |     61 | 4,905 | 53.7%       |
| `memory/` 底层原语（`root.zig` 852L、`rows.zig` 514L、`write_column.zig` 453L、`column_transfer.zig` 400L、`column_set.zig` 273L）        |     20 | 3,566 | **39.1%**   |
| 宿主回调 / 封送包装（`function_table/publication/host.zig` 等）                                                                           |      7 |   658 | 7.2%        |

---

## 二、核心病灶诊断

1. **最危险的技术债：`*const anyopaque` + `@constCast` 引发系统性 LLVM `readonly` UB**
    - [root.zig](../../packages/core/src/memory/root.zig#L161-L263) 与 [rows.zig](../../packages/core/src/memory/rows.zig) 对外在 `interfaces/memory/*.d.zx` 中声明为只读借用参数，Zig 实现层却用 `*const anyopaque` 接收并做 **36 处 `@constCast`** 直接原地写内存。
    - LLVM 优化器据此给参数标注 `readonly`，已连续两天在 `ReleaseSmall` 下导致崩溃与 `IndexOutOfBounds`。`4a1a0c5a` 前一版在 [root.zig:784](../../packages/core/src/memory/root.zig#L784)（`writeString`）及 [rows.zig:279](../../packages/core/src/memory/rows.zig#L279)、[rows.zig:393](../../packages/core/src/memory/rows.zig#L393) 加上 `pub noinline fn` 只是掩盖内联暴露的未定义行为，**必须作为全仓 P0 立即根治**。
2. **“假自举”放大器：341 个 `memory` 原语替代了语言层可变抽象**
    - 过去几天为了避免 ZX 不可变数组/对象在循环内触发 $O(N^2)$ 复制，`compiler`、`genz`、`cli`、`pkgs` 四处大量引用 `interfaces/memory/` 下的 17 份 `.d.zx`（仅 `views.d.zx` 41 函数、`column_set_operations.d.zx` 39 函数、`column_values.d.zx` 36 函数、`column_writes.d.zx` 35 函数、`row_reads.d.zx` 35 函数）。
    - 这本质上是**用 ZX 语法写手动指针读写 C-style 胶水**，既没有发挥 ZX 类型系统优势，又锁死了 3,566 行 Zig 不能退出。
3. **IR 物理列布局与校验边界分散**
    - `ir.zig`（229L）、`columns.zig`（242L）与 `expression_table` / `control_table` / `type_table` 混合了 SoA 内存分配与若干校验/发布规则。

---

## 三、最终保留边界与待退出清单

| 分类                               | 具体对象                                                                                                                              | 处置原则                                                                           |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| **可保留（平台/物理分配底座）**    | 通用 `Arena` / `ScratchArena`、原子原语、SoA 物理页分配与 OS 内存操作、`columns.zig` 最薄类型化切片布局契约                           | 允许保留为编译器运行时支撑的最小通用原语，**但必须去掉类型擦除与 `@constCast` UB** |
| **过渡保留（随语言能力补齐退场）** | `src/memory/*` 中 341 个逐字段/逐行读写原语（`writeColumnU32`、`readTextColumn` 等）                                                  | 待 `genz` 补齐独占可变数组/切片原语后，成片退役                                    |
| **必须退出到 RX/ZX**               | `expression_table` / `control_table` / `type_table` / `function_table` / `error_effects` 中的逻辑构造、重映射与发布编排（~2,500+ 行） | 逻辑归 ZX，发布时序归 RX，彻底消除 `host_cb_opaque`                                |

---

## 四、分阶段大步执行计划

### Phase C1（P0 · 紧急止血 · **Wave 2 已完成 Hop 1，待 Wave 3 收口**）：根除 `core/memory` `@constCast` UB

- **目标**：消除 `packages/core/src/memory/` 全部 **36 处 `@constCast`** 及 `noinline` 补丁。
- **进展（Wave 2 Hop 1 已完成）**：已在 `core/src/type_table/structure.zig`、`compiler` 与 `genz`（`ExpressionsKind.Pointer` / `Expressions.pointer`）落地 `mutable_opaque` 可变原生句柄类型，能够区分 `*const T`（`opaque`）与 `*T`（`mutable_opaque`）。
- **方案（Hop 2 待 Wave 3 执行）**：
    1. 将 `core/memory` 与 `std` 中承担写入职责的 `.d.zx` 原生句柄切换为 `mutable_opaque`（传递显式 `*T`，而非 `*const anyopaque`）；
    2. 将 `root.zig`、`rows.zig`、`write_column.zig`、`column_set.zig`、`column_transfer.zig`、`atomic.zig`、`arena_scope.zig`、`text_storage.zig` 等文件中的写入目标全部改为正确可变类型；
    3. 删除 `root.zig:784` 和 `rows.zig:279,393` 的 `noinline` 掩盖声明。
- **阶段门禁**：`packages/core/src/memory/` 中 `@constCast == 0`；`ReleaseSmall` 与 `ReleaseSafe` 下无探针直接编译并运行全部目录扫描与观测回归通过。

### Phase C2（P1 · 配合 `genz`）：从 341 个微原语收敛为泛型/类型化独占缓冲原语

- **前置依赖**：`genz` 补齐内部受控独占可变缓冲/切片索引写原语。
- **方案**：以统一的可变缓冲/列视图替代 `writeU8` / `writeU32` / `writeU64` / `writeString` / `readU8` / `readU32` 等按类型复制的数百个接口；目标将 `interfaces/memory/*.d.zx` 从 17 份 341 函数压缩 **≥ 70%**，同步清理 `src/memory/` 至 ≤ 1,200 行通用分配原语。

### Phase C3（P2 · 实体表收口）：收敛 IR 实体表构造与发布逻辑

- **目标**：将 `expression_table`、`control_table`、`type_table`、`function_table`、`error_effects`（~2,800 行）中的非分配规则全部移入已有 `core/*.zx` 并由上层 RX/ZX 直接调用，消灭 `function_table/publication/host.zig` 等 7 份回调封装。
- **门禁**：`Zig 换手率 ≤ 0.25`，`host_cb_opaque` 降为 0。

---

## 五、验收与回测口径

- **开发期最小验证**：`zig build test`（在 `packages/core` 及 `packages/compiler` 针对受影响测试）。
- **C1 收口验证**：必须同时在 `-Doptimize=ReleaseSmall` 与 `-Doptimize=ReleaseSafe` 下运行带深层子目录扫描的 CLI 复现及观察/发布用例，确认无任何未定义值或越界误触发。
