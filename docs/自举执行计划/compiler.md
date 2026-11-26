# `packages/compiler` 自举诊断与执行计划

> 归属角色：词法/语法前端、ZX 语义与类型分析、RX 图与项目联结、语义缓存、后端与形式化验证 · 状态：**最大核心包（占全仓非 seed Zig 近 60%，入口膨胀至 954 项）** · 总览：[README.md](README.md) · 上位报告：[自举进度诊断和指导报告.md](自举进度诊断和指导报告.md)

---

## 一、现状总账（`HEAD 4a1a0c5a`）

| 维度                                    |                                           数值 | 说明                                                                                                                                                                                                                         |
| --------------------------------------- | ---------------------------------------------: | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 非 seed Zig（`src/` + `bootstrap/`）    |                       **823 文件 / 77,642 行** | `src/` 760 文件 **66,500 行** + `bootstrap/` 62 文件 **10,990 行**（不含 `build/`）                                                                                                                                          |
| seed Zig（`*seed*.zig`）                |                        **101 文件 / 8,288 行** | `rx/analysis`、`zx/modules`、`zx/ir`、`backends/zig` 等处滞留                                                                                                                                                                |
| `build/` 构建脚本                       |                         **39 文件 / 5,704 行** | 含 [entries.zig](../../packages/compiler/build/entries.zig)（1,055L / **954 入口**）、[parser.zig](../../packages/compiler/build/parser.zig)（678L）、[bootstrap_tool.zig](../../packages/compiler/build/bootstrap_tool.zig) |
| RX / ZX 源码                            | **689 份 (26,603 行) / 3,301 份 (150,426 行)** | 存在 **796 份 ≤20 行碎片 ZX** 与 **96 份 ≤15 行碎片 RX**                                                                                                                                                                     |
| `.d.zx` 接口                            |      **28 份 / 3,006 行 / 653 个原生宿主函数** | 集中于 `rx/analysis/project/workflow/host/*.d.zx`（11 份）与 `project.d.zx` 等                                                                                                                                               |
| `@ptrCast` / `anyopaque` / `@constCast` |                             **2,434 / 165 处** | 全仓最大不透明指针集中区                                                                                                                                                                                                     |

### `src/` 非 seed Zig 职责分类

| 类别                                  | 文件数 |   行数 |      占比 |
| ------------------------------------- | -----: | -----: | --------: |
| 纯 Zig 状态与未迁逻辑                 |    476 | 33,250 |     49.4% |
| 宿主回调 / 不透明桥接                 |    146 | 14,180 | **21.1%** |
| 双向跳板（`executeIn` + `anyopaque`） |     77 | 12,508 | **18.6%** |
| Zig→Source 封送包装                   |     31 |  2,673 |  **4.0%** |
| 平台 I/O / 外部工具边界               |     30 |  4,649 |      6.9% |

### 8 大剩余 Zig 子树（`src/` 非 seed + seed）

| 子目录                                                                                              |        非 seed Zig | seed Zig | RX+ZX 现有量 | 核心痛点                                                                                                                   |
| --------------------------------------------------------------------------------------------------- | -----------------: | -------: | -----------: | -------------------------------------------------------------------------------------------------------------------------- |
| `rx/analysis/`（含 `project/` 9,912L、`inference/` 5,027L、`program/` 2,487L、`store/` 1,658L）     | **223f / 22,886L** |   2,293L |      39,964L | `mixed.zig`/`ahead.zig`/`invocation/host.zig`/`source_graph/construct.zig` 等重度跳板，以及 11 份 `rx_project_host/*.d.zx` |
| `zx/modules/`（含 `link/` 2,696L、`project/` 2,694L、`semantic_cache/` 2,060L、`artifact/` 1,656L） | **174f / 15,521L** |   1,551L |      31,791L | `project.zig`（738L）、`parse_cache.zig`（700L）大文件持有核心状态与多线程缓存调度                                         |
| `zx/analysis/`（主分析器表达式/语句/契约/符号）                                                     |  **101f / 7,891L** |     864L |      38,395L | 语义绑定、类型推导回退、符号表仍经 Zig 桥中转                                                                              |
| `backends/zig/`（Zig 代码与模块/库/缓存输出）                                                       |   **56f / 5,929L** |     964L |       9,726L | `library.zig`、`modules.zig`、`cache.zig`（525L）、`function_sources.zig`（397L）、`mirror.zig`（394L）                    |
| `zx/frontend/` + `zx/ir/`                                                                           |   **78f / 5,739L** |   1,540L |      31,756L | 词法/语法保留与 IR 校验/重映射桥接                                                                                         |
| `rx/` 核心（`labels/`、`schema/`、`dependency_graph/`、`syntax_adapter/`、`features/`）             |   **58f / 2,834L** |     331L |       6,964L | 仍依赖 `dsl` 解析标签及部分图校验宿主                                                                                      |
| `verification/` + `backends/{hardware,verilog}`                                                     |   **27f / 3,393L** |     413L |       6,982L | SMT 查询装配、符号执行、硬件图与 Verilog 输出                                                                              |
| `bootstrap/` 静态生成快照                                                                           |  **62f / 10,990L** |        — |            — | `constants/`、`input_snapshot/`、`partition/`、`ownership/`、`lexer/`、`resource_scan.zig` 等大快照                        |

---

## 二、核心病灶诊断

1. **954 个微入口 + 6 个独立生成集的构建复杂度爆炸**
    - [entries.zig](../../packages/compiler/build/entries.zig) 包含 `main`(647)、`execution`(219)、`growth`(38)、`collections`(19)、`host`(31) 共 **954** 个编译单元入口，外加 `checks` 等。每增删一个内部步骤就要修改 `entries.zig`、`parser.zig` 与 Zig import 表。
2. **默认 `bootstrap_tool.zig` 活体 seed 迫使全仓留双轨**
    - [compiler/build.zig](../../packages/compiler/build.zig) 与 [parser.zig](../../packages/compiler/build.zig#L15-L20) 在 `stage0 == ""` 时从 `seed_rx.zig` + `compiler.zig(..., null, ...)` 编译纯 Zig `generate-parser`，直接制造了 **101 份（8,288 行）** `*_seed.zig` 与遍布 `rx/analysis` / `zx/modules` 的 `if (generated)` 双分支。
3. **`rx_project_host`（11 份 `.d.zx`）与 `project_host`（4 份 `.d.zx`）的碎裂回调**
    - `parser.zig` 第 48–58 行需要将 `types.d.zx`、`call_types.d.zx`、`mixed.d.zx`（71 函数）、`flow.d.zx`（50 函数）、`projections.d.zx`（45 函数）、`constraints.d.zx`（42 函数）、`prepare.d.zx`（39 函数）等拼成巨型 `.d.zx` 胶水文件，再由 Zig `mixed.zig` / `ahead.zig` / `derive/host.zig` 充当中心路由器。
4. **遗留架构整改项（已并入本计划收口）**
    - `backends/zig/modules.zig` 仍为普通应用预建 `library.zig` 专用的重入摘要与重复计算能力；`zx/modules/project.zig` 与 `verified_compile.zig` 存在最终 IR 双重校验路径待收口。

---

## 三、最终保留边界与待退出清单

| 分类                                             | 具体边界                                                                                                                                                                                                                                          | 处置                                                   |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| **可保留（最小 OS/外部工具/引导边界）**          | 文件读取、多线程线程池与 OS 原子操作、`std` 哈希/加密、`build/` 构建脚本接线（~1,500–2,000 行）                                                                                                                                                   | 保留平台 I/O 与构建驱动                                |
| **必须退出（~7.2 万行非 seed + 8,288 行 seed）** | `rx/analysis/*`、`zx/modules/*`、`zx/analysis/*`、`zx/frontend/*`、`zx/ir/*`、`backends/{zig,hardware,verilog}`、`verification/*`、`rx/{labels,schema,dependency_graph,syntax_adapter}` 全部算法、状态表与跳板，以及 `bootstrap/` 与 `*_seed.zig` | 按 6 个垂直大步阶段全部迁入统一粗粒度 RX/ZX 并物理删除 |

---

## 四、分阶段大步执行计划（每阶段 2,000~5,000 行级垂直收口）

> **前置条件**：全包先切换默认构建支持**固定 `stage0` 引导器**（Phase P0），此后所有 `compiler` 迁移阶段**严禁新增 `*_seed.zig` 与 `if (generated)`**，旧实现随阶段直接 `git rm`。

### Phase M1：`rx/analysis/inference/` + `program/` 显式工作栈收口（消掉 7,500+ 行 Zig）

- 用 **显式工作栈 `Loop` + 独占原地可变集合**（来自 `genz` G0）由外向内接管约束合并（`unification`）、字段投影与类型求解主循环；
- 合并 `rx/analysis/inference/` 零散入口，一次性删除 `constraints.d.zx`（42f）、`projections.d.zx`（45f）、`flow.d.zx`（50f）及其 Zig `host.zig` 跳板。

### Phase M2：`rx/analysis/project/` + `store/` 合并消桥（消掉 ~11,500 行 Zig）

- 把 `mixed.zig`（332L）、`ahead.zig`（459L）、`prepare/invocation/host.zig`（426L）、`source_graph/construct.zig`（362L）、`derive/host.zig`（312L）的整个调度窗口和混合历史状态机整体移入 `rx/analysis/project/` 的单一顶级 RX 编排树；
- 消除 `rx_project_host` 下 11 份 `.d.zx`（~350+ 函数），保留纯文件读与线程池启动口。

### Phase M3：`zx/modules/`（`project`、`link`、`semantic_cache`、`compiled`）垂直收口（消掉 ~15,500 行 Zig）

- 优先整体拿下 [parse_cache.zig](../../packages/compiler/src/zx/modules/parse_cache.zig)（700L）与 [project.zig](../../packages/compiler/src/zx/modules/project.zig)（738L）的跨模块加载/缓存事务状态；
- 同时关闭复核遗留项 #5（`validateProjectPrefix` vs `validateIr` 双重 IR 校验收口）；
- 消灭 `project/execution/*.d.zx` 与 `zx/modules/**/host.zig` 胶水。

### Phase M4：`zx/analysis/` + `zx/frontend/` + `zx/ir/` 收口（消掉 ~13,600 行 Zig）

- 将词法/语法保留状态、主分析器表达式/语句/契约推导、IR 规范校验的剩余 Zig 胶水与状态收归已有 RX/ZX 主入口，消灭 `entries.zig` 中的海量单函数微入口。

### Phase M5：`backends/zig/` + `verification/` + `backends/{hardware,verilog}`（消掉 ~9,300 行 Zig）

- 收口 `backends/zig/` 的 [cache.zig](../../packages/compiler/src/backends/zig/cache.zig)（525L）、[function_sources.zig](../../packages/compiler/src/backends/zig/function_sources.zig)（397L）、[mirror.zig](../../packages/compiler/src/backends/zig/output/mirror.zig)（394L）、`library.zig`、`modules.zig`；
- 顺手关闭复核遗留项 #2/#3（普通应用不再为库分配重入摘要，复用能力计算事实）；
- 收口 `verification/host.d.zx`（52 函数）与硬件/Verilog 后端。

### Phase M6：`rx/` 脱离 `dsl` + 物理删光 `*_seed.zig` 与 `bootstrap/` 快照（净减 19,278+ 行）

- 完成 `rx/labels/`、`rx/schema/`、`rx/dependency_graph/` 与 `syntax_adapter/` 向纯 RX/ZX 收口，切断 `dsl` 依赖（联动 `dsl.md` Phase D1）；
- 物理移除 101 份 `*_seed.zig`（8,288L）及不再需要的 `bootstrap/` 旧生成快照（10,990L），将 `entries.zig` **954 入口**压减到 **≤ 50 个**子系统级粗粒度入口。

### 全包统一门禁（M1–M6）

- 每阶段 `Zig 换手率 ≤ 0.25`；每阶段 `entries.zig` 入口数、`.d.zx` 宿主函数数、`@ptrCast`/`anyopaque` 数量三项指标必须同步净降；禁止以拆分 ≤20 行微文件规避合并。

---

## 五、验收与回测口径

- **已完成进展（Wave 1 · 2026-11-25）**：已物理删除 `verification`、`backends/hardware`、`backends/verilog`、`backends/zig/gateway`、`rx/analysis/gateway` 下 12 份非自举 `*seed*.zig`（含 `verilog/seed/*`、`hardware/*/seed.zig`、`verification/*/seed.zig`、`gateway/state_seed.zig`、`rx/analysis/gateway/routes/seed.zig`）并移除对应 `parser_options.generated_parser` / `rx_options.generated_graph` 双轨退路分支；通过 `ReleaseSmall -Dgenerated-partitions=4` 三阶段自编译与全量 `compiler`/`cli` 测试。
- **已完成进展（Wave 6 · 2026-11-25）**：彻底清零 `packages/compiler/src` 与 `packages/compiler/build` 全部 **149 处 `@constCast` UB**（全仓 10 个非测试源码目录 `@constCast == 0`），移除 `retention/order.zx` 与 `parser_publish_orders` 跳板（`entries.zig` `main` 629 → 628）并将 15 份宿主 `.d.zx` 可变句柄切换为 `mutable_opaque`；完成 Zig `0.17.1` 下 `ReleaseSmall -Dgenerated-partitions=4` 三阶段自编译（`stage2`/`stage3` SHA-256 `ad48a78aeff912a822655b58febd4a4db12bae6c391e94da402f2f8e35a3ccc4`）、非驻留冷生成 **3,157.7 ms**（热 **60.1 ms**）与 `compiler`/`cli` 全量测试。
- **已完成进展（Wave 22 · 2026-11-25）**：物理删除 `backends/zig/` 全部 **3 份**宿主接口（`gateway/workflow/host.d.zx`、`state/publication/host.d.zx`、`output_host.d.zx`），精简 **50 个**宿主回调并从 [entries.zig](../../packages/compiler/build/entries.zig) 移除 **15 条** execution 入口同时将纯 ZX `output_parents` 与 `state_publication_fingerprint` 升格至 `main`（总入口 `888 → 875`），同步注销 [root.zig](../../packages/compiler/src/root.zig) `resolveNative` 中 **12 个**宿主模块并清理 [parser.zig](../../packages/compiler/build/parser.zig) / [compiler.zig](../../packages/compiler/build/compiler.zig) 接线；通过 `stage0=""` 种子构建与 Zig `0.17.1` `ReleaseSmall -Dgenerated-partitions=4` 三阶段自编译（`stage2`/`stage3` SHA-256 `28904301c0813424acae0ea0497fcd005142ee3358bfb99c26443a5e386fce94`）、非驻留 `stage2` 冷生成 **3.18 s**（热 **0.04 s**）与 `compiler`/`cli` 全量构建测试。
- **开发期**：`cd packages/compiler && zig build test-rx` / `zig build test-frontend` 或单文件测试复现，不跑全仓 17,560 文件比较。
- **阶段收口（每个 M1–M6 结束时）**：`ReleaseSmall` 16 分区构建 `zxc-bootstrap`、372+ 编译器全测试、冻结清单生成产物字节一致性与冷/热/RSS 基准对比。
