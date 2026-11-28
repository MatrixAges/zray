# 类别 1：`memory` 内部模块越界

> 返回：[越界写法治理清单](../越界写法治理清单.md)

## 三、类别 1：`memory` 内部模块越界（🟡 进行中）

### 3.1 RX 中的 `<Call fn="memory.*">`（✅ 已清零：基线 2 文件 → 当前 0 处）

- [x] 移除 `packages/compiler/src/zx/modules/compiled/load.rx` 的 `memory.u32Views`（Wave 48）。
- [x] 消除 [packages/compiler/src/zx/modules/compiled/loading/install/prepare.rx](../../../packages/compiler/src/zx/modules/compiled/loading/install/prepare.rx) 中最后 3 处 RX `memory.*`（Wave 58：删除 `loading/install/memory.zx`、拆出独立 `compiled_library_publish` 并在 [progress.store.rx](../../../packages/compiler/src/zx/modules/compiled/loading/install/progress.store.rx) 承载 `preparing` 状态）。

### 3.2 底层无锁原子与 futex 唤醒（✅ 已清零：基线 18 文件 / 69 处 → 当前 0）

- [x] 撤销 Wave 47 新增的 `memory.loadU32Relaxed` / `memory.storeU32Relaxed`。
- [x] **清零 `compiler` 侧全部 6 处 worker/ahead 原子游标与状态同步**（Wave 59，`packages/compiler` `atomic_words == 0`）：
    - `packages/compiler/src/backends/zig/cache/writes/worker.zx`（移除原子跳板与 `writeGenerationCacheFile`）
    - `packages/compiler/src/backends/zig/function_sources/{copy_worker,worker}.zx`（OS 线程池取片调用 `copy.zx` / 单行纯返回 `u32` `worker.zx`）
    - `packages/compiler/src/backends/zig/output/parallel/worker.zx`（OS 线程池直接调度 `step.zx`）
    - `packages/compiler/src/rx/analysis/project/mixed/ahead/work.zx`（移除原子跳板与 `preparedMixedIsZX`/`runPreparedMixed*`）
    - `packages/compiler/src/zx/modules/parse_cache/worker/run.zx`（升级为显式 RX 编排 [run.rx](../../../packages/compiler/src/zx/modules/parse_cache/worker/run.rx)，移除 `parseWorkerFailed`/`failParseWorker`）
- [x] **收口 `packages/genz/src/analysis/uniqueness/work/{ahead,pool}/` 共 12 份文件的原子 CAS / `waitU32` / `wake*`**（Wave 60，OS 并发同步统一至 [ring.zig](../../../packages/genz/src/zx/uniqueness/pool/ring.zig) 与 [schedule.zig](../../../packages/genz/src/zx/uniqueness/ahead/schedule.zig)，工作队列调度、memo 探测与 read 校验全部保留在 RX/ZX）。
- [x] **物理删除 `atomic_words.d.zx`、`packages/core/src/memory/atomic.zig` 与 `AtomicIndex`（`types.d.zx`）**（Wave 60，全仓原子/futex 原语彻底清零）。

### 3.3 手动 Arena / Allocator 管理（✅ 已清零：基线 7 函数 / 95 处 → 当前 0）

- [x] **清零 `rewindScratchArena`（含 `ScratchArena`）、`releaseArena` 与 `resetArenaRetainingCapacity` 全部 8 处调用并从 `core/memory` 物理删除**（Wave 61，`arenas.d.zx` 声明 `6 → 3`，`memory` 声明 `339 → 336`）。
- [x] **清零 `packages/cli` 全部 `arenas.d.zx` 调用与 `cli/project/scopes` `U64Buffer` 游标，并清除 `compiler/zx/modules/artifact/prepared/extract.rx` 隐式 `selectAllocator`**（Wave 62，`cli` Arena **6 → 0**，全仓 Arena **83 → 77**）。
- [x] **清除 `external/delivery`、`rx/analysis/project/mixed/imports`、`binding/delivery` 与 `publish_reexports.rx` 全部 6 处 RX 隐式 `selectAllocator` 与 3 组 `ArenaScope`**（Wave 63，RX 隐式 Arena **27 → 21**）。
- [x] `packages/compiler/src/zx/frontend`（27 文件 54 处 `selectAllocator`，Wave 69 已全部清零）
- [x] `packages/compiler`（2 文件 3 处 `.zx` `growU32Scratch`：`zx/ir/canonical/body/workspace.zx`、`rx/analysis/inference/scope/candidates.zx`，Wave 70 已清零；`resolving`/`initializer_registry` `U32Scratch` Wave 71 已清零）
- [x] `packages/genz`（`analysis/uniqueness/memo/encoding/growth/arrange.zx` Wave 70 已清零；`analysis/types/cache/scratch/{grow.zx,prepare.rx}` 与 `types/scratch_seed.zig` Wave 71 已清零）
- [x] `packages/cli/src/cli/project`（Wave 62 已全部清零，`packages/cli` `arenas == 0`）
- [x] `packages/pkgs/src/lock/{packages,dependencies}.zx`（Wave 70 已清零）与 `packages/pkgs/src/install.zig` `Archives` `U32Scratch`（Wave 71 已清零）
- [x] `packages/core/src/bytes/index/borrowed/refresh.zx`（Wave 71 已迁为纯 ZX `u32[]` 重建）
- [x] 最终废止 `arenas.d.zx`、`growU32Scratch`、`ArenaScope` 与 `U32Scratch`（`arenas.d.zx`/`ArenaScope`/`selectAllocator` Wave 69 已删；`growU32Scratch`/`U32Scratch` Wave 71 已物理删除）。

### 3.4 直接原地写内存（`memory.write*` / `copy*` / `fill*` / `setColumn*`）

- [x] 全仓物理删除 `StreamWriter`、`writeStreamText`、`writeStreamJsonBytes`（Wave 50）。
- [x] 收口 `backends/zig/output/mirror/unrecorded.zx` 的 `memory.copyColumnText`（Wave 49）。
- [ ] 按业务子系统逐步把 `memory.write*` / `copy*` / `fill*` 改为纯 ZX 返回或 RX `<Store>` 绑定，最终将 `memory` 收缩为自举期间只读 Zig 表借用并在自举终局整体退场。

---
