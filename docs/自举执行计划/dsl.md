# `packages/dsl` 自举诊断与执行计划

> 归属角色：编译期 XML DSL Schema 构造器与通用文本解析组合子库 · 状态：**低优先级 / 终局阶段边界判定对象** · 总览：[README.md](README.md) · 上位报告：[自举进度诊断和指导报告.md](自举进度诊断和指导报告.md)

---

## 一、现状总账（`HEAD 4a1a0c5a`）

| 维度                                    |                   数值 | 说明                                                                               |
| --------------------------------------- | ---------------------: | ---------------------------------------------------------------------------------- |
| 非 seed Zig                             | **13 文件 / 1,453 行** | `src/` 11 文件 1,293 行（100% `pure_zig`）+ `examples/` 143 行 + `build.zig` 30 行 |
| seed Zig                                |                  **0** | 无 seed 文件                                                                       |
| RX / ZX / `.d.zx`                       |          **0 / 0 / 0** | 完全由手写 Zig 实现                                                                |
| `@ptrCast` / `anyopaque` / `@constCast` |          **0 / 0 / 0** | 无指针强转胶水                                                                     |

### 主要文件分布

- **XML 解析与位置映射**（`src/xml/`，481 行）：[parser.zig](../../packages/dsl/src/xml/parser.zig)（359L）、[attribute_location.zig](../../packages/dsl/src/xml/attribute_location.zig)（70L）等。
- **RX Schema 编译期类型生成与校验**（`src/` 根目录，812 行）：[grammar.zig](../../packages/dsl/src/grammar.zig)（204L）、[children.zig](../../packages/dsl/src/children.zig)（179L）、[attributes.zig](../../packages/dsl/src/attributes.zig)（129L）、[ast.zig](../../packages/dsl/src/ast.zig)（104L）、[root.zig](../../packages/dsl/src/root.zig)（101L）、[element.zig](../../packages/dsl/src/element.zig)、[diagnostic.zig](../../packages/dsl/src/diagnostic.zig)。

---

## 二、核心病灶诊断

1. **当前不属于阻塞项，禁止提前拆迁**：`dsl` 仅 1,293 行纯净 Zig、无任何 `@ptrCast`/`anyopaque`/`.d.zx` 胶水，也不拖慢当前迁移速率；现阶段强行迁移只会凭空制造新的 `.d.zx` 边界。
2. **存在“Zig `comptime` 元编程 vs 自举边界”的双重属性**：
    - `grammar.zig` / `children.zig` / `attributes.zig` 依赖 Zig `comptime` 类型反射，用于在 Zig 侧为编译器标签生成静态强类型结构体；如果 `compiler/src/rx/` 的标签定义与校验全部迁入 RX/ZX，这部分 Zig `comptime` 宿主 DSL 引擎应随之一同退役或转为编译器自有语法支持，而不是继续留在正式编译器传递依赖中。
    - `src/xml/parser.zig` 与 `grammar(Parser, Token, Error)` 属于**通用词法/语法解析引擎**，在 [自举完成标准.md](../../rules/自举完成标准.md) 明确将“词法、语法、AST 与解析栈的自有实现”列为待迁内容，且 `compiler` 自身已经有自举后的 `rx/syntax/parse.rx` 与 `zx/frontend/parser/program.rx`。

---

## 三、最终保留边界与待退出清单

| 模块部分                                                  | 归属判定                                     | 处理策略                                                                                                                                                                                     |
| --------------------------------------------------------- | -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/xml/`（481L）与 `grammar.zig`（204L）                | 与 `compiler` 已自举的 XML/ZX 解析器职责重叠 | **待退出正式编译器依赖**：待 `compiler/src/rx/` 脱离 `dsl` 依赖后，正式编译器全面使用自举后的 `rx/syntax` 与 `zx/frontend/parser`，`dsl` 仅作为独立外围 Zig 工具库保留（或提供等价 ZX 库）。 |
| `src/{ast,attributes,children,element,root}.zig`（~580L） | 依赖 Zig `comptime` 的 RX Schema 校验壳      | **随 `compiler/src/rx/labels/` 一并退出**：当 RX Schema 检查完全由 `rx/schema/`（已在 `entries.zig`）承担时，移除编译器对 `dsl` 模块的依赖。                                                 |

---

## 四、分阶段执行计划

> 调度定位：**排在 Phase 4–6（`compiler` 收口期）**，P0/P1 期间**保持冻结、不动一字节**。

### Phase D1（随 `compiler/rx/` 收口触发）：切断 `compiler` 对 `dsl` 的正式运行依赖

- **前置条件**：`compiler/src/rx/`（`labels/`、`features/`、`syntax_adapter/`）完成自举收口。
- **执行动作**：
    1. 核对 `compiler/build.zig` 中 `rx`、`rx_analysis` 对 `dsl` 的导入点（当前为 `rx` 和 `rx_analysis` 的 imports）；
    2. 将仍由 `dsl` 执行的 `xml.parse` 与 `Schema` 校验路径切换为 `compiler` 内已有自举 `rx/syntax/parse.rx` 与 `rx/schema/*`；
    3. 将 `dsl` 移出 `zxc` 正式二进制的传递依赖闭包（保留独立包 `zig build dsl-example` 作为 Zig 生态示例）。
- **门禁**：`zxc` 正式构建依赖闭包中不再引用 `dsl` 模块，零新增 `.d.zx` 与 Zig 桥接代码。

---

## 五、验收与回测口径

- 独立验证：`zig build dsl-example`。
- 脱钩验证：检查 `packages/compiler/build.zig`、`packages/compiler/build.zig.zon` 与生成的构建图，确认 `zxc` 不再引入 `dsl` 执行编译器语法或 Schema 校验。
