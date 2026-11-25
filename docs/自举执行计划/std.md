# `packages/std` 边界审计与执行计划

> 归属角色：zray 应用与编译器共享的标准库及平台原语层 · 状态：**以“边界清理与去污染”为主，非算法自举对象** · 总览：[README.md](README.md) · 上位报告：[自举进度诊断和指导报告.md](自举进度诊断和指导报告.md)

---

## 一、现状总账（`HEAD 4a1a0c5a`）

| 维度                                    |                          数值 | 说明                                                                                    |
| --------------------------------------- | ----------------------------: | --------------------------------------------------------------------------------------- |
| 非 seed Zig (`src/`)                    |       **88 文件 / 20,930 行** | 其中 **16,341 行（78.1%）为 Unicode / IDNA 静态只读查找表**                             |
| 纯逻辑/表 Zig                           |           64 文件 / 19,557 行 | 含 `url/host/idna/data/*` (14,210L)、`path/unicode/*` (2,131L)、编码/加密/URL/HTTP 算法 |
| 平台 I/O / OS / 进程                    |            18 文件 / 1,127 行 | `fs/`、`child_process/`、`http/`、`zlib/`、`process/`、`os/`                            |
| 宿主不透明句柄胶水                      |               5 文件 / 316 行 | `bytes/atomic_rows.zig`、`bytes/fast.zig`、`http/` 等                                   |
| `.d.zx` 公开接口                        | **22 份 / 936 行 / 199 函数** | 位于 `interfaces/*.d.zx`                                                                |
| `@ptrCast` / `anyopaque` / `@constCast` |                 **36 / 3 处** | 集中于 `bytes/` 与底层流/缓冲接口                                                       |

---

## 二、核心病灶诊断

1. **Unicode 数据表造成“2 万行 Zig”的统计错觉**：实际可执行的 Zig 逻辑扣除 `idna/data/*` 与 `path/unicode/*` 后仅约 **4,589 行**，且绝大多数属于加密（SHA-256）、压缩（zlib）、文件/进程/HTTP 等标准库能力。按 [AGENTS.md](../../AGENTS.md) zero-runtime 原则，“应用语义所需的 Zig 标准库调用与显式静态原生模块”属于**合法保留边界**。
2. **真正需要整改的污染点（复核报告 H 项）**：
    - [interfaces/bytes.d.zx](../../packages/std/interfaces/bytes.d.zx) 中公开暴露了 `AtomicRows` 与 `fillAtomicRow`（实现位于 [src/bytes/atomic_rows.zig](../../packages/std/src/bytes/atomic_rows.zig)）。该能力目前主要服务于 `genz/uniqueness` 的并行摘要行写入，且依赖裸指针偏移访问，不应混在面向普通应用开发者的公开 `std:bytes` 契约中。
    - 少数辅助文件仍存在 `3 处 @constCast` 与 `@ptrCast`（需同步核查是否存在与 `core/memory` 同源的 `readonly` 别名风险）。

---

## 三、最终保留边界与待退出清单

| 类别                                               | 具体模块                                                                                                                                    | 判定                                                                                                      |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| **合法保留（数据表 + 平台 I/O + 显式原生标准库）** | `url/host/idna/data/*`、`path/unicode/*`、`fs/`、`child_process/`、`http/`、`zlib/`、`crypto/`、`env/`、`os/`、`process/`、`bytes/fast.zig` | **保留**，无需硬迁成 ZX 再反调 OS；按需补充标准库覆盖度。                                                 |
| **需剥离出公开面（迁入编译器私有边界）**           | `AtomicRows`、`fillAtomicRow` 及 `src/bytes/atomic_rows.zig` 中编译器专用并发摘要行原语                                                     | **移出 `std:bytes` 公开接口**，归入编译器内部 `core` 或专用并发摘要模块（并配合 `genz` 唯一性分析收口）。 |
| **修复类型安全**                                   | `src/bytes/` 等处的 3 处 `@constCast`                                                                                                       | 改为显式可变切片或安全指针语义，消除优化器误判风险。                                                      |

---

## 四、分阶段执行计划

### Phase S1（P0 · **Wave 3 已完成**）：消除 3 处 `@constCast` 与边界核查

- **已完成**：已将 `packages/std/interfaces/{bytes,string}.d.zx` 中的 `Writer` 与 `StringSet` 切换为 `mutable_opaque`，并移除 `packages/std/src/bytes/writer.zig` 与 `packages/std/src/string.zig` 全部 **3 处 `@constCast`**；Zig `0.17.1` 下 `packages/std` 的 `ReleaseSmall` 与 `ReleaseSafe` 构建及全仓 `compiler`/`cli` 回归全部通过，`packages/std/src/` `@constCast == 0`。

### Phase S2（P1 · 随 `genz/uniqueness` 收口 · **已完成**）：剥离 `std:bytes` 的编译器私有契约

- 已核查全部引用并将 `AtomicRows` 及 `atomicRowsCount`、`atomicRowLength`、`loadAtomicCell`、`storeAtomicCell`、`fillAtomicRow` 从 `packages/std/interfaces/bytes.d.zx`、`packages/std/src/bytes.zig`、`packages/std/src/bytes/atomic_rows.zig` 迁至编译器内部 `core/memory`（`packages/core/src/memory/atomic_rows.zig`、`packages/core/interfaces/memory/atomic_rows.d.zx`、`packages/core/interfaces/memory/types.d.zx`、`packages/core/src/memory/root.zig`、`packages/compiler/build/memory_interfaces.zig`）；
- 已更新 `packages/compiler/src/backends/zig/regular_calls/` 与 `packages/genz/src/analysis/uniqueness/` 中全部 16 个内部 `.zx` 消费者从 `"memory"` 导入，恢复 `std:bytes` 面向普通应用开发者的纯净边界。

---

## 五、验收与回测口径

- `zig build test`（覆盖 `std` 单元测试及 `conformance` 中标准库接口测试）。
- `zxc check-rx` / 独立应用测试确认普通应用无法再非法引用内部行指针接口，且现有 `genz` 唯一性分析行为与结果零变化。
