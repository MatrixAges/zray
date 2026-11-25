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

### Phase L1（Phase 2 试点 · 单批大步迁移）：剩余规则统一迁入 RX/ZX 并合并为粗粒度入口

- **前置依赖**：固定 `stage0` 引导器就绪（不再需要 `lint` 运行 `-Dseed=true` 从 `bootstrap/` 重生）。
- **执行内容**：
    1. 将 `src/` 剩余规则（`spacing.zig`、`layout/projection.zig`、`rx/layout.zig`、`rx/root.zig`、`imports/`、`configuration/`、`source.zig`）与 `src/root.zig` 总控调度一次迁入 `packages/lint/src/` 的统一 RX 入口（例如 `lint/check.rx` + `lint/format.rx`）；
    2. 在 `compiler/build/entries.zig` 中将 11 个分散的 `.lint` 条目**合并为 1~2 个统一入口**（净减 **9~10** 个入口），**禁止新增任何 `.d.zx` 宿主函数**；
    3. 同步消除 15 处 `@constCast` 与 12 处 `@ptrCast`/`anyopaque`。
- **门禁**：`packages/lint/src/*.zig` 净减 **≥ 85%**，Zig 换手率 **≤ 0.15**。

### Phase L2（收口清理）：退役 `packages/lint/bootstrap/` 与 `build.zig` 双轨逻辑

- 使用固定 `stage0` 切掉 `seed_path` 逻辑，删除 `packages/lint/bootstrap/` 下 11 份静态快照（直接净减 **3,456** 行 Zig，其中 `bootstrap/layout.zig` 3,004 行）。

---

## 五、验收与回测口径

- **开发期验证**：`cd packages/lint && zig build test`（如有）+ `zxc lint` / `node scripts/format.mjs --check` 对全仓样本复核。
- **阶段收口验证**：对比迁移前后全仓 `.rx` / `.zx` / `pkg.yaml` 的 `zxc lint` 诊断集合与 `zxc fmt` 输出逐字节一致；不需要为 `lint` 重跑无关的编译器冷生成 17,560 文件对比。
