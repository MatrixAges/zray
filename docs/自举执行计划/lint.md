# `packages/lint` 自举诊断与执行计划

> 归属角色：RX/ZX/pkg.yaml 静态规范检查与格式化规则引擎 · 状态：**大步收敛试点 #1（体量适中、0 个 `.d.zx`，可一次整包收口）** · 总览：[README.md](README.md) · 上位报告：[自举进度诊断和指导报告.md](自举进度诊断和指导报告.md)

---

## 一、现状总账（`HEAD 4a1a0c5a`）

| 维度                                    |                                  数值 | 说明                                                                                                                                                                                             |
| --------------------------------------- | ------------------------------------: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 非 seed Zig (`src/`)                    |                **27 文件 / 1,808 行** | `100% pure_zig`，尚无桥接跳板，但仍保留旧 Zig 规则实现                                                                                                                                           |
| 静态生成快照 (`bootstrap/`)             |                **11 文件 / 3,456 行** | 其中 `bootstrap/layout.zig` 单独占 **3,004 行**（162 KB）                                                                                                                                        |
| `build.zig`                             |                    **1 文件 / 72 行** | 硬编码了 11 条 `Rule` 与 `seed_path`/`root_path` 双轨开关                                                                                                                                        |
| RX / ZX 源码                            | **11 份 (298 行) / 36 份 (1,699 行)** | 已迁移 6+ 组规则（`naming`、`length`、`indentation_line`、`spacing_boundary`、`rx_bounds`、`import_order`、`condition_policy`、`loop_postfix`、`yaml_gap`、`attribute_required`、`layout_rule`） |
| `.d.zx` 接口                            |                                 **0** | 零原生回调声明                                                                                                                                                                                   |
| `@ptrCast` / `anyopaque` / `@constCast` |                        **12 / 15 处** | 少量内部 AST 视图/切片操作                                                                                                                                                                       |

### `src/` 剩余非 seed Zig 分布

- 根目录聚合与输入处理（796 行）：[root.zig](../../packages/lint/src/root.zig)（331L）、[source.zig](../../packages/lint/src/source.zig)（117L）、[spacing.zig](../../packages/lint/src/spacing.zig)（161L）等。
- AST 布局与规则实现：`layout/`（299L，含 `projection.zig` 165L）、`rx/`（298L，含 `root.zig` 126L、`layout.zig` 112L、`node_view.zig`）、`imports/`（110L）、`configuration/`（79L）、`indentation/`（32L）等。

---

## 二、核心病灶诊断

1. **11 个独立生成入口分散在 [packages/compiler/build/entries.zig](../../packages/compiler/build/entries.zig) 与 [packages/lint/build.zig](../../packages/lint/build.zig)**：每条 lint 规则单独注册为一个 `Entry`（`.owner = .lint`）并单独挂接 `generated` 导入，与“单入口统领多规则分发”的设计相悖。
2. **双轨运行与 3,456 行滞留快照**：[packages/lint/build.zig](../../packages/lint/build.zig#L8-L20) 为这 11 条规则同时维护 `seed_path`（含 `bootstrap/layout.zig` 3,004 行生成快照）和 `root_path` 两套加载路径。
3. **跨句/AST 风格规则与总控调度仍在 Zig**：`src/root.zig`（331L）、`spacing.zig`（161L）、`layout/projection.zig`（165L）、`rx/layout.zig`（112L）等仍用 Zig 遍历 AST 并决定规则开关、位置映射与合并输出。

---

## 三、最终保留边界与待退出清单

| 分类                                           | 内容                                                                                                                                  | 处置                                                 |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------- |
| **可保留**                                     | 极薄外部 Zig 库导出适配（若外部 Zig 测试/CLI 仍通过 `lint` 模块结构传参）及文件 I/O 边界                                              | ≤ 150 行纯适配或完全由 `cli` 直接调用自举入口        |
| **必须退出（约 1,800 行 Zig + 3,456 行快照）** | 全部 AST 遍历、空白/缩进/间距/对齐/RX 结构/导入顺序/YAML 规则、`src/root.zig` 规则总控调度、15 处 `@constCast`、`bootstrap/` 静态快照 | 一次大步迁入单一统一 RX 编排树，移除双轨 `seed_path` |

---

## 四、分阶段大步执行计划（1~2 批整包清零）

### 已完成进展（Wave 1 · 2026-11-25）

1. **清理 `bootstrap/` 死快照（−3,341 行 Zig）**：删除 `bootstrap/layout.zig`（3,004L）及 `attribute_required.zig`、`indentation_line.zig`、`rx_bounds.zig`、`yaml_gap.zig`、`length.zig` 共 6 份 `generate-parser` 未调用的快照；保留 `stage0 == ""` 检查实际所需的 5 份小规则（`condition_policy`、`import_order`、`loop_postfix`、`naming`、`spacing_boundary`，合计 115L）。
2. **收口为 3 个统一 RX/ZX 入口**：将原分散的 6 个规则入口收口为 `lint_layout`（`src/layout/entry.rx` + `edits.zx`）、`lint_rx`（`src/rx/entry.rx` + 迭代结构遍历与 `<Loop>` 标签排版，收薄 `rx/root.zig` 与 `rx/layout.zig`）和 `lint_config`（`src/configuration/entry.rx` + `yaml/edits.zx`），并删除对应旧 Zig/RX 包装文件；`packages/compiler/build/entries.zig` 中的 `.owner = .lint` 条目由 **11 个净降至 8 个**，`packages/lint/build.zig` 规则总数降至 **8 个**。
3. **验证通过**：`-Doptimize=ReleaseSmall -Dgenerated-partitions=4` 下 `stage0` 全量 `packages/compiler` 测试与无 `stage0` 的 `bootstrap-stage` 构建均通过。

### 已完成进展（Wave 4 · 2026-11-25）

1. **完成 `layout/projection` 算法自举**：将 [projection.zig](../../packages/lint/src/layout/projection.zig) 收薄为 `RawSpan`/`Op` 记录器（带 OOM `failed` 状态传播），将词法流合并与 7 类布局投影操作迁入 [projection.zx](../../packages/lint/src/layout/projection.zx) 与 `projection/{init,find,opening_at_end,condition,exclude_range,list,set_token}.zx`，并在 [entry.rx](../../packages/lint/src/layout/entry.rx) 与 [rule.zig](../../packages/lint/src/layout/rule.zig) / [root.zig](../../packages/lint/src/layout/root.zig) 间通过 `ProjectionData` 隔离模块边界。
2. **修复静态缓冲 OOM 隐患**：将 `layout/rule.zig` `attributeRequired` 与 `configuration/rule.zig` `checkLength` 中残留的 `[0]u8` `FixedBufferAllocator` 改为 `[256]u8`，通过 `packages/test` `test-rx-formatting`（含 `allocation_test.zig` OOM 全路径）与 `test-configuration-formatting` 及全仓格式化/lint 检查。

### 已完成进展（Wave 37 · 2026-11-26）

1. **完成编辑渲染、排序与源码应用纯 ZX 迁移**：在 `lint_source`、`lint_rx`、`lint_layout` 与 `lint_config` 四套生成管线中新增 [apply_edits.zx](../../packages/lint/src/source/apply_edits.zx)、[first_edit.zx](../../packages/lint/src/source/first_edit.zx) 及三份 `render_edits.zx`，将编辑文案构造、`std.mem.sort` 排序（消除 `packages/lint/src/` 最后 1 处 `std.mem.sort`）与源码文本拼接全部迁入纯 ZX/RX，精简 8 个对应 Zig 宿主封装（`spacing.zig:format` 仅留作 `compiler/zx/frontend` 外部调用接口）。
2. **验证通过**：通过 `packages/lint -Dseed=true` 与 `stage0 == ""` 种子构建、Zig `0.17.1` `ReleaseSmall -Dgenerated-partitions=4` 三阶段自编译（`stage2`/`stage3` `zxc-bootstrap` 二进制 SHA-256 完全一致：`f59b604167da4ce5add80f73878d512e93bf474a0dc37f16ac223b6af090adb5`；`main` 清单 5,809 生成单元 `diff -rq` 逐字节一致，冷生成 `stage2` `3.33 s` / `stage3` `3.41 s`）、`packages/compiler`（`ReleaseSafe`）、`packages/cli`（`ReleaseSmall` 构建与 `ReleaseSafe` 全量测试）、`packages/test` 格式化/lint 套件（`test-configuration-formatting`、`test-semantic-lint`、`test-zx-import-order` 与 `test-rx-formatting` 全路径）及全仓格式化/lint 与 `@constCast == 0` / `std.mem.sort == 0` 核查。

### 后续收口计划（Wave 1+）

- **Phase L1 剩余**：将 `src/root.zig`、`spacing.zig`、`layout/projection.zig`、`imports/` 与 AST 检查调度继续合并为单一检查/格式化入口；消除剩余 `@constCast` / `@ptrCast`；
- **Phase L2**：随全局切掉 `-Dseed` 后清理 `bootstrap/` 剩余 5 份 115L 小规则与 `build.zig` 双轨分支。

---

## 五、验收与回测口径

- **开发期验证**：`cd packages/lint && zig build test`（如有）+ `zxc lint` / `node scripts/format.mjs --check` 对全仓样本复核。
- **阶段收口验证**：对比迁移前后全仓 `.rx` / `.zx` / `pkg.yaml` 的 `zxc lint` 诊断集合与 `zxc fmt` 输出逐字节一致；不需要为 `lint` 重跑无关的编译器冷生成 17,560 文件对比。
