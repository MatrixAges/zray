# `packages/pkgs` 自举诊断与执行计划

> 归属角色：包清单解析、依赖图构造、锁文件校验与安装规划 · 状态：**快速清零试点 #2（仅剩 903 行 `src/` Zig，且无 `.d.zx`）** · 总览：[README.md](README.md) · 上位报告：[自举进度诊断和指导报告.md](自举进度诊断和指导报告.md)

---

## 一、现状总账（`HEAD 4a1a0c5a`）

| 维度                                    |                                 数值 | 说明                                                                            |
| --------------------------------------- | -----------------------------------: | ------------------------------------------------------------------------------- |
| 非 seed Zig                             |                 **13 文件 / 968 行** | `src/` 12 文件 903 行 + `build.zig` 66 行                                       |
| seed Zig                                |                                **0** | 无 seed 文件                                                                    |
| RX / ZX 源码                            | **6 份 (296 行) / 77 份 (3,713 行)** | 覆盖 `version`、`workspace`、`metadata`、`graph`、`registry`、`lock`、`install` |
| `.d.zx` 接口                            |                                **0** | 无本地宿主回调接口（直接复用 `core/memory`）                                    |
| `@ptrCast` / `anyopaque` / `@constCast` |                        **53 / 0 处** | 集中于 Zig→Source 封送壳                                                        |

### `src/` Zig 职责分布与大文件

- **纯 Zig 逻辑**（9 文件，483 行，52.8%）：含 `workspace/manifest.zig`（148L）、`workspace/selection.zig`（113L）、`lock/validate.zig`（105L）、`metadata.zig`、`version.zig`、`registry/` 等。
- **不透明指针封送壳**（3 文件，432 行，47.2%）：[install.zig](../../packages/pkgs/src/install.zig)（175L）、[graph.zig](../../packages/pkgs/src/graph.zig)（109L）、[index.zig](../../packages/pkgs/src/index.zig)（74L）、[workspace.zig](../../packages/pkgs/src/workspace.zig)（64L）及 [root.zig](../../packages/pkgs/src/root.zig)。

---

## 二、核心病灶诊断

1. **典型“薄包双倍胶水”现状**：核心包管理算法大部分已在 77 份 ZX 和 6 份 RX 中，但剩余 903 行 Zig 里 **47.2%（432 行）是纯粹的切片封送与 `@ptrCast` 壳**，在 Zig 与 Source 之间来回传递路径与依赖表。
2. **与 `cli/package/` 存在跨包边界割裂**：查看 [packages/pkgs/build.zig](../../packages/pkgs/build.zig) 与 `packages/cli/build/source.zig` 可知，`pkgs` 的核心逻辑与 `cli/src/package/`（`install/host.zig`、`graph/host.zig`、`workspace/host.zig` 等 1,268 行 Zig）被硬生生切在两个包的构建单元里，导致两头各自封送数据。
3. **直接引用 `memory/index.d.zx` 与 `memory/columns.d.zx`**：`pkgs` 自身没有 `.d.zx`，但通过 `build.zig` 引入了 `compiler` 导出的 341 个内存原语。

---

## 三、最终保留边界与待退出清单

| 分类                        | 内容                                                                                                                                                      | 处置                                                     |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| **可保留**                  | 仅面向纯 Zig 外部测试/调用者的极薄公开结构体定义（如无文件/网络 I/O，本包本身不持有 OS 原语）                                                             | 收敛后应 ≤ 100 行，最好并入 `cli` 统一构建图             |
| **必须退出（~800–903 行）** | `install.zig`、`graph.zig`、`workspace/manifest.zig`、`workspace/selection.zig`、`lock/validate.zig`、`index.zig` 全部逻辑与 53 处 `@ptrCast`/`anyopaque` | 合并成统一包管理 RX 入口，与 `cli/src/package/` 协同收口 |

---

## 四、分阶段大步执行计划（1 批收口）

### Phase K1（Phase 2 试点 · 单批收口）：剩余 903 行一次迁入 RX/ZX 并消除封送壳

- **执行动作**：
    1. 将 `workspace/manifest.zig`（148L）、`workspace/selection.zig`（113L）、`lock/validate.zig`（105L）与 `install.zig`、`graph.zig` 中剩余编排/校验逻辑一次迁入 `packages/pkgs/src/` 现有 RX/ZX 管线；
    2. 通过 [packages/pkgs/build.zig](../../packages/pkgs/build.zig) 统一导出高层 RX 模块契约，直接供 `cli` 的 RX 流程（`cli/src/package/`）通过包依赖调用，消除 `pkgs` 与 `cli` 之间重复的 Zig 封送；
    3. 随着 `core` Phase C2 提供独占可变缓冲，退出 `build.zig` 对 `memory_interface` 的借用依赖。
- **阶段门禁**：
    - `packages/pkgs/src/` 非 seed Zig 从 **903 行**降至 **≤ 120 行**（仅保留最薄外部导出类型），`@ptrCast`/`anyopaque` 从 **53 处**降至 **≤ 5 处**；
    - 零新增 `.d.zx` 函数，Zig 换手率 **≤ 0.15**。

---

## 五、验收与回测口径

- **已完成进展（Wave 70 · 2026-11-26）**：清零 `packages/pkgs/src/lock/` 全部 `growU32Scratch`、`U32Scratch` 与 `U32Buffer`（新增共享 [slots.zx](../../packages/pkgs/src/lock/slots.zx) 并将 [packages.zx](../../packages/pkgs/src/lock/packages.zx)、[dependencies.zx](../../packages/pkgs/src/lock/dependencies.zx) 等哈希表校验改为纯 `u32[]` 返回，在 [validate.zig](../../packages/pkgs/src/lock/validate.zig) 使用局部 `ArenaAllocator` + 2 KiB `BufferFirstAllocator` 承接 `rules.lock_validate.executeIn` 临时分配）；通过 `packages/test` `test-package-lock-graphs`/`test-package-lock-parsing`（`ReleaseSafe` 0 泄漏）、`packages/pkgs` 构建与 `packages/cli` 全量测试。
- **已完成进展（Wave 71 · 2026-11-26）**：清零 `packages/pkgs` 最后 1 处 `U32Scratch`（`install.zig` `Archives`）：协同 `core` 升级 [borrowed/refresh.zx](../../packages/core/src/bytes/index/borrowed/refresh.zx)/[probe_slice.zx](../../packages/core/src/bytes/index/borrowed/probe_slice.zx)/[lookup.zx](../../packages/core/src/bytes/index/borrowed/lookup.zx)（同步更新 [build.zig](../../packages/pkgs/build.zig) 与 [build/source.json](../../packages/pkgs/build/source.json)），更新 [install/archive/model.zx](../../packages/pkgs/src/install/archive/model.zx)、[install/archive/plan.rx](../../packages/pkgs/src/install/archive/plan.rx) 与 [install.zig](../../packages/pkgs/src/install.zig)（以及 `cli` [fresh/storage.zig](../../packages/cli/src/package/install/fresh/storage.zig)/[install/host.zig](../../packages/cli/src/package/install/host.zig)）；通过 `packages/test` `test-package-lock-graphs`/`test-package-lock-parsing`/`test-package-archive`/`test-package-install`、`packages/pkgs` 构建与 `packages/cli` 全量测试。
- **验证范围**：`packages/pkgs` 单元测试 + `packages/cli` 中包安装、依赖图、lockfile、workspace 与 watch 集成回归（无需重跑 `compiler` 或 `genz` 生成器 17,560 文件对比）。
