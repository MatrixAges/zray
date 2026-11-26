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

### Phase X1（P0 · 构建加速 + 确定缺陷修复 · **Wave 2 已完成**）：合并 7 次冷生成 & 复核 `cache_identity`

1. **已合并 `build/source.zig` 生成管线**：删除 `packages`/`store`/`toolchain`/`watch`/`observation`/`backend.json` 6 份清单，全部并入 [source.json](../../packages/cli/build/source.json) 并合并为单次 `generate CLI source modules (cli)` 进程（更新 `build.zig` 与 26 处 CLI Zig 调用方，`75/75` 构建步骤与 `104/104` 测试步骤全通过）；
2. **已复核 `cache_identity`（复核报告 G 项）**：[cache_identity.zig](../../packages/cli/build/cache_identity.zig) 与 [digest.zig](../../packages/cli/build/cache_identity/digest.zig) 已改为写入 `digest.bin` + `cache_identity.s`，并发任务按独立索引写入 `digests: []anyerror!Digest`，无字符串拼接 Zig 与并发写入竞态。

### Phase X2（大步 #1 · 预计净减 5,000+ 行 Zig）：`cli/rx/`、`cli/compilation/`、`cli/project/scopes/` 统一收口

- **已完成进展（Wave 5 · 2026-11-25）**：提前完成 `packages/cli/src/` 全部 **17 处 `@constCast` UB 清零**——将 `cli/{backend/source/frames,build/dependencies,build/workspace,native_sources,publication,toolchain/cache,toolchain/workflow}` 及 `package/{archive/extract,graph,install,manifest/decode,manifest/layout,manifest/write,store/cache,store/download,store/receipt}` 共 14 份宿主 `.d.zx` 的可变句柄（及 26 份对应 `.zig` 桥接、`publication/effects.zig` `borrow`）切换为 `mutable_opaque`（`*anyopaque` / `*T`），并通过 `cli` `ReleaseSmall`/`ReleaseSafe` 构建与全部测试。
- **由外向内直接从 `main.zig` 子命令入口收敛**：把 `cli/rx/compile.zig`、`load.zig`、`preparation/project.zig`、`compilation/state.zig`、`project/scopes/host.zig` 合并进少数几个顶层 RX 编排树；
- **合并原生接口**：将 `cli/rx/execution/host.d.zx`（144 函数）、`checking/host.d.zx`（38 函数）等按真实 OS 边界（读文件、写文件、调用后端/编译器）收口到 **≤ 25 个粗粒度系统效应函数**，彻底删除中间层状态句柄和 `anyopaque` 传参；
- 剩余 **@constCast 已于 Wave 5 清零**，后续专注合并宿主入口与消灭 `anyopaque` 跳板。

### Phase X3（大步 #2 · 预计净减 4,500+ 行 Zig）：`cli/build/`、`cli/library/`、`cli/watch/`、`cli/lint/`、`package/` 消桥

- **已完成进展（Wave 19 · 2026-11-25）**：完成 `cli/configuration/` 与 `cli/lint/` 纯无副作用原子 ZX + RX 正向迁移：修复 [system_link.zig](../../packages/cli/build/system_link.zig#L20) `-mmacosx-version-min` 补丁号截断，消除 Apple `ld` 警告；在 [source.zig](../../packages/cli/build/source.zig#L28) 接入 `cli/configuration/*.zx`，新增 `configuration/{const,model,has_basename,resolve_layout,maximum_bytes}.zx` 与 `lint/{const,model,ends_with,is_rx,is_source,is_manifest}.zx`，改写 `configuration/run.rx` 与 `lint/{run,source/run,semantic/run}.rx` 直接消费不可变配置与路径输入；物理删除 `cli/configuration/kind.zig`，从 `cli/lint/host.d.zx` 净减 **11 个**纯查询/路径回调并收薄对应 Zig 入口，`cli` `ReleaseSmall` 构建与 `ReleaseSafe` 全量测试全部通过。
- **已完成进展（Wave 20 · 2026-11-25）**：在 `cli/lint/reachable/` 落地全仓首个自举 `<Store>`（[seen.store.rx](../../packages/cli/src/cli/lint/reachable/seen.store.rx)）：新增原子 ZX `admit_path.zx`（显式 `setter={[store.seen.visited]}`）与编排 `step.rx`，重构 `reachable/run.rx` 与 `reachable/model.zx`，物理删除 `module.rx`、`walk.rx`、`source_rows.zx`、`store_rows.zx`（4 份文件），消除 `cli/lint/sources.zig` 中 `std.StringHashMapUnmanaged` 与可变游标状态，并从 `cli/lint/host.d.zx` 净减 **5 个**有状态回调；`cli` `ReleaseSmall` 构建与 `ReleaseSafe` 全量测试全部通过。
- **已完成进展（Wave 21 · 2026-11-26）**：
    - 在 `cli/native_sources/` 落地双对象 `<Store>`（[state.store.rx](../../packages/cli/src/cli/native_sources/collect/state.store.rx)：`queue` + `seen`），将采集队列、已见相对路径表、引用返回、include 查重与路径重定位全部迁入 RX/ZX（`enqueue_one`/`enqueue_batch`/`lookup_seen`/`next_queued`/`add_seen`/`promote_seen` 与 `seed_bundle`/`enqueue_refs`/`relocate`/`relocate_step`），删除 `storage.zig` 中 `Pending`/`Seen`/`Reference` 与 `StringHashMapUnmanaged`、删除 4 份旧胶水并收薄 `collect.zig`/`ast.zig`/`bundle/storage.zig`/`include/storage.zig`；
    - 精简 `cli/library/{workflow,analysis,link,proof}`，以不可变值传入选项/计数/导出切片、`proof/output.zx` 收口为 100% 纯 ZX 并删除 `verify.zig` 可变 `index` 游标；`native_sources/host.d.zx` 与 `library/workflow/host.d.zx` 各自净减并移除旧查询/游标回调，`packages/cli` `ReleaseSmall` 构建与 `ReleaseSafe` 全量测试全部通过。
- **已完成进展（Wave 22 · 2026-11-26）**：
    - 在 `cli/library/retirement/` 落地 `<Store>`（[kept.store.rx](../../packages/cli/src/cli/library/retirement/kept.store.rx)）与 `keep_path.zx`，删除 `targets.zx` 并直接向 `walk`/`check`/`candidate`/`search` 传入不可变 `targets` 与 `RetirementPath.absolute`，删除 `retirement/storage.zig` 中 `StringHashMapUnmanaged` 与状态数组，从 `publication/host.d.zx` 净减 **5 个**回调；
    - 在 `cli/rx/checking/{store,function}/` 落地 `<Store>`（[seen.store.rx](../../packages/cli/src/cli/rx/checking/store/seen.store.rx)）与纯 ZX `has_delegate.zx`，删除 `store_types.zig` 中 `StringHashMapUnmanaged` 去重逻辑及 `function.zig` 中 `default_call`/`delegated` 游标，在 `rx/checking/host.d.zx` 净减 **7 个**原生回调；`packages/cli` `ReleaseSmall` 构建与 `ReleaseSafe` 全量测试全通过。
- **已完成进展（Wave 23 · 2026-11-26）**：
    - 在 `cli/library/resources/` 移除 `U64Buffer` `cursor` 与 `bundle_paths.zx`，改写 `walk.rx`/`modules.rx`/`module.rx` 为常规索引循环并由 `libraryNativeModule`/`bundleNativeModule` 直接返回字段与 `includes`，从 `library/stage/host.d.zx` 净减 **6 个**回调；
    - 在 `watch/output.zig` 预先传递不可变 `logical_inputs`/`physical_inputs`，将 `publication/target/overlap.zx` 收口为纯 ZX 并从 `publication/host.d.zx` 净减 **2 个**游标回调；`packages/cli` `ReleaseSmall` 构建与 `ReleaseSafe` 全量测试全部通过。
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
