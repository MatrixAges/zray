# `packages/cli` 自举诊断与执行计划

> 归属角色：`zxc` 命令行入口、构建与 `watch` 驱动、产物发布、C/WASM/Node 后端协同与工具链管理 · 状态：**胶水占比全仓最高（77.1% 为跳板/回调/封送，且构建时重复冷启动 7 次生成器）** · 总览：[README.md](README.md) · 上位报告：[自举进度诊断和指导报告.md](自举进度诊断和指导报告.md)

---

## 一、现状总账（`HEAD 4a1a0c5a`）

| 维度                                    |                                       数值 | 说明                                                                                                                  |
| --------------------------------------- | -----------------------------------------: | --------------------------------------------------------------------------------------------------------------------- |
| 非 seed Zig (`src/`)                    |                   **176 文件 / 15,914 行** | 含 `main.zig` 及各子命令、watch、package 宿主                                                                         |
| seed Zig                                |                                      **0** | 无 seed 文件                                                                                                          |
| `build/` 脚本                           |                     **11 文件 / 1,043 行** | 含 [source.zig](../../packages/cli/build/source.zig)（291L）+ 7 份 JSON 清单（**127** 入口）                          |
| RX / ZX 源码                            | **181 份 (6,338 行) / 442 份 (14,438 行)** | 其中 **156 份（35.3%）ZX ≤20 行**                                                                                     |
| `.d.zx` 接口                            |  **30 份 / 1,563 行 / 764 个原生宿主函数** | 含全仓最大的单个 `.d.zx`：[cli/rx/execution/host.d.zx](../../packages/cli/src/cli/rx/execution/host.d.zx)（144 函数） |
| `@ptrCast` / `anyopaque` / `@constCast` |                            **989 / 17 处** | 大量结构体指针强转                                                                                                    |

### `src/` 非 seed Zig 职责拆解（最触目惊心的胶水比）

| 类别                                      | 文件数 |  行数 |      占比 | 典型文件                                                                                                                           |
| ----------------------------------------- | -----: | ----: | --------: | ---------------------------------------------------------------------------------------------------------------------------------- |
| **双向跳板**（`executeIn` + `anyopaque`） |     38 | 6,069 | **38.5%** | `cli/rx/compile.zig`（291L）、`cli/rx/preparation/project.zig`（287L）、`cli/rx/load.zig`（281L）、`package/workspace.zig`（277L） |
| **宿主回调 / 不透明桥接**                 |     54 | 5,439 | **34.5%** | `cli/project/scopes/host.zig`（288L）、`cli/compilation/state.zig`（256L）、`cli/lint/host.d.zx` 等                                |
| **Zig→Source 封送包装**                   |     11 |   641 |  **4.1%** | 各命令外层调用封装                                                                                                                 |
| 平台 I/O / 子进程 / C 工具链边界          |     47 | 2,725 |     17.3% | 文件/目录/进程组/Job Object、`libyaml`、`translate_c`、工具链下载与签名验证                                                        |
| 纯 Zig 逻辑                               |     24 |   906 |      5.7% | 少量尚未包装的配置/状态辅助                                                                                                        |

> **关键发现**：`cli/src/` 中 **77.1%（12,149 行）的 Zig 已经是纯胶水/跳板**！真正的操作系统 I/O 与 C 库边界只有 **2,725 行（17.3%）**，纯逻辑更是只剩 **906 行（5.7%）**。

---

## 二、核心病灶诊断

1. **为了“看起来自举”，把 CLI 拆成了 764 个原生宿主函数与 7 个碎片化生成模块**
    - CLI 天生是一个 **I/O 密集型外壳**（读磁盘源码、调 `zxc` 编译、写产物、管子进程、`watch` 文件监听、调 `zig` 后端进程、解析 `libyaml` 与 `translate_c`）。
    - 过去迁入 RX/ZX 时，把编排放在 Source，把几乎每一次文件读写、路径检查、构建选项读取都暴露成了 `.d.zx` 回调：仅 `cli/rx/execution/host.d.zx` 就有 **144 个宿主函数**，`cli/lint/host.d.zx` **68 个**，`cli/publication/host.d.zx` **48 个**，`cli/library/workflow/host.d.zx` **42 个**，`cli/native_sources/host.d.zx` **40 个**。
    - **结果是典型的“正反两头写两遍”**：例如 `98c1a6eca`（`cli/project/scopes`）只删了几十行老代码，却新造了 288 行的 `scopes/host.zig` + `state.zig` + `host.d.zx`（46 函数）+ 11 个微小的 RX/ZX 文件。
2. **`packages/cli/build/source.zig` 的 7 次独立冷生成进程拖慢全仓编译**
    - [build/source.zig](../../packages/cli/build/source.zig#L276-L290) 分别对 `source.json`（97 项）、`backend.json`（7）、`observation.json`（7）、`watch.json`（5）、`store.json`（5）、`packages.json`（3）、`toolchain.json`（3）调用 `generate()`，且显式设置 `ZXC_RESIDENT_GENERATOR=0`——**每次构建 `cli` 都要冷启动 7 次完整的生成器进程**！
3. **遗留规范违例（复核报告 G 项）**
    - `build/cache_identity.zig` + `build/cache_identity/digest.zig` 通过 `allocPrint` 字符串拼接生成完整 `pub const digest` Zig 源码，且存在多线程并行写共享 `Work.failure` 的竞态缺陷。

---

## 三、最终保留边界与待退出清单

| 分类                                                               | 具体边界                                                                                                                                                                                                                                                  | 处置                                                                         |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| **合法保留（OS / C / 进程 / 构建边界，目标 ~2,500–2,800 行）**     | 操作系统文件/目录/原子写/信号/进程组、`std.process` 后端进程通信、`libyaml` C 绑定、`translate_c` 集成、内嵌 Zig 工具链压缩包解包与 `std:http` 下载、最薄顶层 `main.zig`                                                                                  | **明确保留为平台与外部工具宿主层**，禁止把每个 `std.fs` 调用包装成微 `.d.zx` |
| **必须退出（~12,150 行胶水 + 906 行纯逻辑 + 17 处 `@constCast`）** | `cli/rx/*`（1,296L）、`cli/project/scopes/*`（550L）、`cli/compilation/*`（497L）、`cli/library/*`（854L）、`cli/lint/*`（626L）、`cli/watch/{driver,observation}/*`（~1,000L）、`package/{workspace,install,graph}` 胶水与 989 处 `@ptrCast`/`anyopaque` | 合并外层 RX 入口并直接对接极简 OS 宿主 API，消灭 90% 的 `.d.zx` 回调函数     |

---

## 四、分阶段大步执行计划

### Phase X1（P0 · 构建加速 + 确定缺陷修复）：合并 7 次冷生成 & 修 `cache_identity`

1. **合并 `build/source.zig` 生成管线**：将 `source/packages/store/toolchain/watch/observation/backend` 7 份清单合并为 **1~2 次统一生成**（共享 `memory` 与 `compiler` 类型视图），直接砍掉 5~6 次重复的 `source_generator` 进程启动和冷构建解析时间；
2. **修复 `cache_identity`（复核报告 G 项）**：用“固定 32 字节二进制/数据写入 + 仓库静态 Zig 模板读取”替代字符串拼接完整 Zig 声明，并为多输入错误收集分配独立槽位消除并发写入竞态。

### Phase X2（大步 #1 · 预计净减 5,000+ 行 Zig）：`cli/rx/`、`cli/compilation/`、`cli/project/scopes/` 统一收口

- **由外向内直接从 `main.zig` 子命令入口收敛**：把 `cli/rx/compile.zig`、`load.zig`、`preparation/project.zig`、`compilation/state.zig`、`project/scopes/host.zig` 合并进少数几个顶层 RX 编排树；
- **合并原生接口**：将 `cli/rx/execution/host.d.zx`（144 函数）、`checking/host.d.zx`（38 函数）等按真实 OS 边界（读文件、写文件、调用后端/编译器）收口到 **≤ 25 个粗粒度系统效应函数**，彻底删除中间层状态句柄和 `anyopaque` 传参；
- 同步消除剩余 **17 处 `@constCast`**。

### Phase X3（大步 #2 · 预计净减 4,500+ 行 Zig）：`cli/build/`、`cli/library/`、`cli/watch/`、`cli/lint/`、`package/` 消桥

- 收口 `library/workflow/host.d.zx`（42f）、`publication/host.d.zx`（48f）、`native_sources/host.d.zx`（40f）、`lint/host.d.zx`（68f）与 `package/{workspace,graph}/host.d.zx`（69f）；
- 对接 `pkgs.md` Phase K1 与 `lint.md` Phase L1 的顶层 RX 入口，由 CLI 的 RX 直接 `Call.module` 调用 `pkgs` 与 `lint`，消灭两包之间的 Zig 中转胶水；
- 收口 `cli/watch/{driver,observation}` 仅保留 OS 目录事件/子进程重启原语。

### 门禁指标

- `cli/src/` 非 seed Zig 从 **15,914 行**收敛至 **≤ 3,000 行**（几乎全为纯粹 OS/C/CLI 平台边界）；
- `.d.zx` 函数总数从 **764 个**压减至 **≤ 60 个**；
- `@ptrCast`/`anyopaque` 从 **989 处**压减至 **≤ 50 处**；
- 每阶段 `Zig 换手率 ≤ 0.25`。

---

## 五、验收与回测口径

- **开发期**：`cd packages/cli && zig build test` + 受影响 CLI 子命令端到端冒烟（`build`、`check-rx`、`lint`、`pkg`、`watch --run`）。
- **X1/X2/X3 收口验收**：测量 `cli` 自身构建墙钟时间（核实合并 7 次生成器后的构建加速）、16 组 CLI 核心命令输出与退出码一致性、应用 watch/库发布机器码一致性及单进程峰值 RSS。
