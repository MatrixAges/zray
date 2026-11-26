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
- **已完成进展（Wave 24 · 2026-11-26）**：
    - 在 `cli/compilation/`、`cli/cache.zig` 与 `cli/fpga.zig` 消除 `rx/execution/host.d.zx` **12 个**纯查询/路径判断/游标回调：新增纯 ZX `compilation/is_configuration.zx` 并复用 `../lint/is_rx`/`../lint/is_manifest`，在 `compilation/cache/` 与 `compilation/fpga/` 改传不可变脏标与合约布尔切片并将 `proof_required.zx` 收口为 100% 纯 ZX，`packages/cli` `ReleaseSmall` 构建与 `ReleaseSafe` 全量测试全通过。
- **已完成进展（Wave 25 · 2026-11-26）**：
    - 在 `cli/watch/driver/` 落地 `<Store>`（[state.store.rx](../../packages/cli/src/cli/watch/driver/state.store.rx)）与 `clear_diagnostic.zx`/`report_diagnostic.zx`，将 `Cycle`/`Poll` 改为纯 ZX/RX 值构造，消除 `DoubleBuffer` 与 `writeCycle`/`writePoll`/`clearDiagnostic`；
    - 在 `cli/rx/execution/backend/` 移除 `U64Buffer` `cursor`、`watch.preloaded`、`modules/names.zx` 宿主依赖与 **8 个**回调，`packages/cli` `ReleaseSmall` 构建与 `ReleaseSafe` 全量测试全通过。
- **已完成进展（Wave 26 · 2026-11-26）**：
    - 完成 `cli/lint/`（`semantic`、`special`、`workspace`）纯化：将入口分类（`Ordinary`/`Store`/`Gateway`）与语义/工作区检查结果枚举迁入纯 ZX/RX（[entry_kind.zx](../../packages/cli/src/cli/lint/semantic/entry_kind.zx)、[loaded.rx](../../packages/cli/src/cli/lint/semantic/loaded.rx)），从 [lint/host.d.zx](../../packages/cli/src/cli/lint/host.d.zx) 净减 **5 个**回调（`rejectSemanticLintInput`、`semanticEntry`、`semanticHasExports`、`lintGatewayHasServices`、`workspaceLintManifest`）与 `Entry` 枚举；
    - 在 `cli/watch/observation/` 落地 `<Store>`（[entries.store.rx](../../packages/cli/src/cli/watch/observation/directory/entries.store.rx)）与纯 ZX 归并排序/载荷拼接（`admit_entry.zx`、`merge_ranges.zx`、`sort_order.zx`、`build_payload.zx`），消除 `directory/{collect,feed}.zx` 与 `capture_entries.zx` 中的宿主累加状态及 **4 个**回调；
    - 纯化 `cli/rx/execution/gateway/`（[exports.zx](../../packages/cli/src/cli/rx/execution/gateway/exports.zx)、[analyze.rx](../../packages/cli/src/cli/rx/execution/gateway/analyze.rx)）消除 `requireGatewaySource`、`reserveGatewayServices`、`recordGatewayService` 及 `services.zx`，并将 `cli/rx/execution/host.d.zx` 按职责拆分为 `rx_execution_host`、`native_build_host`（[backend/host.d.zx](../../packages/cli/src/cli/rx/execution/backend/host.d.zx)）与 `compilation_host`（[compilation/host.d.zx](../../packages/cli/src/cli/compilation/host.d.zx)）三份高内聚接口；`packages/cli` `ReleaseSmall` 构建与 `ReleaseSafe` 全量测试全部通过。
- **已完成进展（Wave 27 · 2026-11-26）**：
    - 完成 `package/graph/` 纯化迁移：在 [package/graph/host.d.zx](../../packages/cli/src/package/graph/host.d.zx) 中令 `openLock`、`openMapping`（返回含 `is_archive`/`archive_digests` 切片的 `Mapping`）、`prepareWorkspace` 与 `assembleWorkspace` 直接返回不可变值并接入 `std:path`，将 [mapping.zx](../../packages/cli/src/package/graph/installed/mapping.zx) 与 [archive.zx](../../packages/cli/src/package/graph/installed/archive.zx) 等收口为纯/无冗余查询 ZX，物理删除 **15 个**纯查询/路径/游标回调（`package_graph_host` **30 → 15**）；
    - 在 `cli/sources/template/` 落地 `<Store>`（[seen.store.rx](../../packages/cli/src/cli/sources/template/seen.store.rx)）与原子去重 ZX [admit_path.zx](../../packages/cli/src/cli/sources/template/admit_path.zx)，删除 `contains.zx` 及 `templates.zig` 中的 `State.path` 与 **3 个**计数/游标回调；`packages/cli` `ReleaseSmall` 构建与 `ReleaseSafe` 全量测试全部通过。
- **已完成进展（Wave 28 · 2026-11-26）**：
    - 完成 `package/workspace/` 与 `package/project/` 正向迁移并从 [package/workspace/host.d.zx](../../packages/cli/src/package/workspace/host.d.zx) 净减 **8 个**宿主回调（`39 → 31`）：新增纯 ZX [paths/parent.zx](../../packages/cli/src/package/workspace/paths/parent.zx)（基于 `std:path`）移除 `parentDirectory`；将 [discover/member.zx](../../packages/cli/src/package/workspace/discover/member.zx) 纯化为读取 `MemberSearch.paths` 移除 `workspacePackagePath`；
    - 在 `package/workspace/collection/` 落地双对象 `<Store>`（[state.store.rx](../../packages/cli/src/package/workspace/collection/state.store.rx)：`discovered` + `seen`）、原子操作 `seed_seen`/`record_path`/`register_name` 及纯 ZX 归并排序 `merge_paths`/`sort_paths`，删除 `workspace.zig` 中 `ArrayList`、`source_index.Owned` 与 `std.mem.sort` 状态及 `recordDirectory`/`orderMembers`/`registerMember`；将 `package/project/` 与 `package/project/scope/` 改传 `config_path`/`Surface` 并移除 `projectConfiguration`/`reportProjectEntry`/`scopeEntry`/`scopeLibrary`；`packages/cli` `ReleaseSmall` 构建与 `ReleaseSafe` 全量测试全部通过。
- **已完成进展（Wave 29 · 2026-11-26）**：
    - 在 `cli/rx/collection/` 落地 `<Store>`（[physical.store.rx](../../packages/cli/src/cli/rx/collection/physical.store.rx)：`seen`）与原子查重 ZX [register_physical.zx](../../packages/cli/src/cli/rx/collection/files/register_physical.zx)，并在 [outside.zx](../../packages/cli/src/cli/rx/collection/files/outside.zx) 接入 `std:path` 解除对 `publication/index.absolutePath` 的跨区耦合；删除 `state.zig` 中 `physical: std.StringHashMapUnmanaged` 与 **5 个**回调（`rx_collection_host` **24 → 19**）；
    - 完成 `package/install/` 纯化迁移：在 [package/install/host.d.zx](../../packages/cli/src/package/install/host.d.zx) 中令 `findArchive` 返回 `ArchiveLookup`、`beginReplay` 返回 `is_archive` 切片，提取 [install_archive.rx](../../packages/cli/src/package/install/fresh/install_archive.rx)，物理删除 `fresh/locate.zx`、`fresh/storage.zig` 的 `archive_is_local` 及 `localArchive`/`indexedArchive`/`lockedArchive` **3 个**回调；`packages/cli` `ReleaseSmall` 构建与 `ReleaseSafe` 全量测试全部通过。
- **已完成进展（Wave 30 · 2026-11-26）**：
    - 在 `cli/rx/preparation/` 落地 `<Store>`（[seen.store.rx](../../packages/cli/src/cli/rx/preparation/types/seen.store.rx)：`visited`）与原子读写 `seed_seen.zx`/`admit_path.zx`，移除 `type_sources.zig` 中 `seen: std.StringHashMapUnmanaged`、`types/initial.zx` 以及 `rx_preparation_host` 中 **9 个**纯查询/路径/游标回调（`29 → 20`）；令 `resolvePreparationTarget` 返回 `ResolvedTarget`、`loadPreparationRoot` 返回 `LoadedRange?`、`inferPreparedProject` 返回 `u64?`；
    - 完成 `cli/sources/discovery/` 纯化迁移：令 `prepareSource`/`openHeader` 直接接收 `row`、`resolveImport` 返回 `ResolvedImport`、`selectImportFile` 返回查重后的可空路径，删除 `discovery/host.zig` 中 `State.row` 及 `source_loader_host` **3 个**回调（`selectSource`、`importPath`、`hasSource`）；`packages/cli` `ReleaseSmall` 构建与 `ReleaseSafe` 全量测试全部通过。
- **已完成进展（Wave 31 · 2026-11-26）**：
    - 完成 `package/archive/path/`、`package/archive/extract/`、`package/store/{receipt,download}/` 正向纯化迁移：以纯 ZX [normalize.zx](../../packages/cli/src/package/archive/path/normalize.zx) 取代 `archive/path.zig` 与 `normalize.rx`，为 `package_store` 接入 `cli_abi` 并直接由 `loadReceipt` 返回 `LoadedReceipt`、`hashTreeFile` 返回 `HashedFile?`、`nextTreeEntry` 返回 `TreeKind?`、`nextTar` 返回 `Entry?`、`claimTarPath` 返回 `string?`、`receiveHead` 返回 `ResponseHead` 并直接向 `download` 传入 `is_local`；将 [header.zx](../../packages/cli/src/package/store/receipt/header.zx) 收口为纯 ZX，合计从 `package_receipt_host`（`21 → 9`）、`package_extract_host`（`9 → 4`）与 `package_download_host`（`7 → 3`）净减 **21 个**宿主回调；
    - 完成 `cli/toolchain/{cache,workflow}/` 纯化收口：在 [cache/root.zx](../../packages/cli/src/cli/toolchain/cache/root.zx) 中接入 `std:path` 直接计算并输出平台缓存路径，彻底删除 `cli/toolchain/cache/host.d.zx`（`4 → 0`）、`cache.zig` 中 `Context` 桥接及 `@ptrCast`，并直接向 `toolchain/workflow` 传入 `expected_marker` 与 `zip` 消除 `expectedMarker`/`zip` 2 个查询回调（`20 → 18`）；`packages/cli` `ReleaseSmall` 构建与 `ReleaseSafe` 全量测试全部通过。
- **已完成进展（Wave 32 · 2026-11-26）**：
    - 完成 `cli/publication/` 纯化与接口收敛：在 [publication/host.d.zx](../../packages/cli/src/cli/publication/host.d.zx) 中令 `nextEntry` 直接返回 `DirectoryEntry`、以纯 ZX [destination.zx](../../packages/cli/src/cli/publication/target/destination.zx)（基于 `std:path` / `std:encoding`）与 `Outcome` 消除 `keepOutputPath` 与 `Target.result`，并在 [includes.zx](../../packages/cli/src/cli/library/resources/includes.zx)、[disjoint.zx](../../packages/cli/src/cli/publication/library/disjoint.zx) 接入 `std:path` 移除 `entryPath` 与 `absolutePath`；
    - 完成 `cli/library/inventory/` 与 `cli/native_sources/resources/` 双 `<Store>` + 纯 ZX 排序迁移：新增 [collected.store.rx](../../packages/cli/src/cli/library/inventory/collected.store.rx)（`library_inventory`：`entries`）、纯 ZX 分类与归并排序（`classify_entry.zx`/`finish.zx` 复用 `sort_order`）及原子 `append_entry.zx`，删除 `collector.zig` 中 `Collector`、`ArrayList`、`std.mem.sort` 与 `scan.zx`/`file.zx`；新增 [resources/collected.store.rx](../../packages/cli/src/cli/native_sources/resources/collected.store.rx)（`native_resources`：`discovered`）、原子 `keep_path.zx` 与纯 ZX `finish.zx`（复用 `sort_paths`），删除 `resources.zig` 中 `ArrayList`/`std.mem.sort`/`Walk.current` 与 `walk.zx`，从 `publication_host` 净减 **7 个**回调（`41 → 34`）；`packages/cli` `ReleaseSmall` 构建与 `ReleaseSafe` 全量测试全部通过。
- **已完成进展（Wave 34 · 2026-11-26）**：
    - 完成 `cli/native_sources/`（`references` + `include`）去 AST 游标与纯 ZX/RX 收口：移除 `openAst`/`closeAst`/`nextBuiltin`/`builtinName`/`builtinArguments`/`builtinHasLiteral`/`discardLiteral` **7 个**回调并替换为 `scanBuiltins` 与无状态 `decodeLiteral`/`selectInclude`/`includeFiles`/`writeInclude`（`native_resource_host` **29 → 23**），删除 `storage.Context` 中 5 个旁路字段，将 [references/read.zx](../../packages/cli/src/cli/native_sources/references/read.zx) 收口为 100% 纯 ZX 并通过 `append_decoded.zx`、`decode_step.rx` 与 `read.rx` 编排错误与字面量解码；
    - 完成 `cli/sources/discovery/` `<Store>` 化迁移：新增 [seen.store.rx](../../packages/cli/src/cli/sources/discovery/seen.store.rx)（`source_discovery`：`paths` + `has_rx`）、纯查询 `has_seen.zx` 与原子操作 `record_seen.zx`/`mark_rx.zx`（`$store.seen.state`），删除 `sources.zig` 中 `Traversal.paths`（`std.StringHashMapUnmanaged`）与 `has_rx` 旁路并移除 `markRxImport`（`source_loader_host` **13 → 12**）；
    - 完成 `cli/rx/checking/project/` 调用索引纯化：删除 `function.zig` 中 `CallIndex` 与 4 个游标回调，替换为 `readCheckCallModule`/`recordCheckFunctionCalls`（`rx_checking_host` **31 → 29**）、纯 ZX `call_member.zx`/`match_calls.zx` 与 RX `index_calls.rx`/`index_module.rx`，并删除旧 `index_calls.zx`/`index_module.zx`；`packages/cli` `ReleaseSmall` 构建与 `ReleaseSafe` 全量测试、全量格式化与 `zxc lint` 及 `@constCast == 0` 全部通过。
- **已完成进展（Wave 35 · 2026-11-26）**：
    - 完成 `package/store/receipt/` 纯 ZX 化：令 `nextTreeEntry` 返回 `TreeEntry` 并在纯 ZX [paths.zx](../../packages/cli/src/package/store/receipt/paths.zx) 与 [lookup.zx](../../packages/cli/src/package/store/receipt/lookup.zx) 完成重复校验与归一化索引查找，删除 `storage.zig` 中 `names: std.StringHashMapUnmanaged` 及 `package_receipt_host` 的 `claimFile`/`lookupFile`（**9 → 7**）；
    - 完成 `package/archive/extract/` `<Store>` + RX + 纯 ZX 迁移：新增 [seen.store.rx](../../packages/cli/src/package/archive/extract/seen.store.rx)（`archive_extract`：`claimed`）、纯 ZX `classify_entry.zx`、原子去重 `admit_path.zx`（`$store.seen.claimed`）及 RX 编排 `step.rx`/`unpack.rx`（删除旧 `unpack.zx`/`entry.zx`），移除 `extract/storage.zig` 中 `paths: std.StringHashMapUnmanaged` 与 `claimTarPath`（`package_extract_host` **4 → 3**）；
    - 完成 `cli/watch/observation/capture` 去 `std.mem.sort` 迁移：令 `captureEntry` 返回路径并通过 [capture.rx](../../packages/cli/src/cli/watch/observation/capture.rx) 复用 `directory/sort_order` 完成排序，删除 `capture.zig` 中 `std.mem.sort`/`lessThan` 与 `snapshot_host` 中 `sortCapture`（全 `packages/cli/src/` `std.mem.sort == 0`）；`packages/cli` `ReleaseSmall` 构建与 `ReleaseSafe` 全量测试全部通过。
- **已完成进展（Wave 36 · 2026-11-26）**：
    - 完成 `cli/watch/driver/` 快照状态 `<Store>` 化与去 `Snapshot` 句柄：在 [state.store.rx](../../packages/cli/src/cli/watch/driver/state.store.rx) 新增 `snapshots` 对象并添加 `record_snapshot.zx`（`$store.watch_state.snapshots`），将 [previous.zx](../../packages/cli/src/cli/watch/driver/previous.zx) 收口为 100% 纯 ZX，删除 `Snapshot` 不透明类型与 `borrowSnapshot`/`snapshotLength`/`reobserve`，替换为 `snapshotEntries`/`reobservePath` 与 RX `restore.rx`/`reobserve_step.rx`（`watch_host` **26 → 25**）；
    - 完成 `cli/rx/preparation/` 引用遍历去游标：令 `selectPreparationModule` 返回 `ModuleReference[]`，在 `{compiled,types}/walk_reference.rx` 中直接依据 `role` 与 `is_package` 分派并将 `ref_index` 传给 `resolvePreparationTarget`/`reportPreparationReference`/`readPreparedTypeSource`，删除 `references.zig` 中 `Cursor.entry`/`Cursor.attribute` 与 `preparationReferenceRole`/`isPreparationPackage`（`rx_preparation_host` **20 → 18**）；`packages/cli` `ReleaseSmall` 构建与 `ReleaseSafe` 全量测试全部通过。
- **已完成进展（Wave 49 · 2026-11-26）**：彻底清零 `packages/cli` 中的 `std:bytes.Writer` 用法（**1 → 0**）：将 [diagnostics/normalize.zx](../../packages/cli/src/cli/watch/diagnostics/normalize.zx) 收口为 100% 纯 ZX（以不可变切片数组与 `std:string.join` 直接返回 `string?`），同步删除 [diagnostics.zig](../../packages/cli/src/cli/watch/diagnostics.zig) 中的 `std.Io.Writer.Allocating` 与 `@ptrCast`；通过 `packages/cli` `ReleaseSmall` 构建与 `ReleaseSafe` 全量测试、`format.mjs --check` 与 `zxc lint`。
- **已完成进展（Wave 62 · 2026-11-26）**：彻底清零 `packages/cli` 全部 `arenas.d.zx` 调用与 `cli/project/scopes/` `U64Buffer` 循环游标——删除 `advance.zx` 与 `advance_module.zx`，将 [run.rx](../../packages/cli/src/cli/project/scopes/run.rx)、[next.rx](../../packages/cli/src/cli/project/scopes/next.rx)、[scope.rx](../../packages/cli/src/cli/project/scopes/scope.rx)、[modules.rx](../../packages/cli/src/cli/project/scopes/modules.rx)、[next_module.rx](../../packages/cli/src/cli/project/scopes/next_module.rx) 与 [prepare_module.zx](../../packages/cli/src/cli/project/scopes/prepare_module.zx) 改为显式传递 `row: u64`，移除 [index.zx](../../packages/cli/src/cli/project/scopes/index.zx) 的 `memory` 重导出以及 [resolve_names.zx](../../packages/cli/src/cli/project/scopes/resolve_names.zx)/[bind.zx](../../packages/cli/src/cli/project/scopes/bind.zx)/[compiled.zx](../../packages/cli/src/cli/project/scopes/rules/naming/compiled.zx)/[dependency.zx](../../packages/cli/src/cli/project/scopes/rules/dependency.zx) 中的 `resetArena`/`selectAllocator`/`selectArena`（改为显式 `copyColumnText`），同步收口 [host.zig](../../packages/cli/src/cli/project/scopes/host.zig)、[state.zig](../../packages/cli/src/cli/project/scopes/state.zig)、[projections.zig](../../packages/cli/src/cli/project/scopes/projections.zig) 与 [scopes.zig](../../packages/cli/src/cli/project/scopes.zig)；`packages/cli` `arenas == 0`，`ReleaseSmall` 构建与 `ReleaseSafe` 全量测试全部通过。
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
