# `packages/napi` 外部 ABI 边界审计与保留清单

> 归属角色：Node.js N-API 原生扩展静态适配层 · 状态：**无需自举迁移（纯粹外部 C-ABI 边界，仅做生成端去重联动）** · 总览：[README.md](README.md) · 上位报告：[自举进度诊断和指导报告.md](自举进度诊断和指导报告.md)

---

## 一、现状总账（`HEAD 4a1a0c5a`）

| 维度                                    |                                                             数值 | 说明                                                                   |
| --------------------------------------- | ---------------------------------------------------------------: | ---------------------------------------------------------------------- |
| 非 seed Zig                             |                                              **8 文件 / 438 行** | `src/` 7 文件 430 行 + `build.zig` 16 行（文件统计口径含 `build.zig`） |
| 职责分类                                | `platform_io_c` 83.5% / `host_cb_opaque` 15.1% / `pure_zig` 1.4% | 全部为 N-API C-ABI 结构体、值编码与资源句柄                            |
| RX / ZX / `.d.zx`                       |                                                    **0 / 0 / 0** | 无编译器逻辑                                                           |
| `@ptrCast` / `anyopaque` / `@constCast` |                                                    **16 / 0 处** | C `napi_env` / `napi_value` 互操作指针                                 |

### 文件清单

- [src/declarations.zig](../../packages/napi/src/declarations.zig)（120L）、[src/read.zig](../../packages/napi/src/read.zig)（100L）、[src/value.zig](../../packages/napi/src/value.zig)（65L）、[src/api.zig](../../packages/napi/src/api.zig)（65L）、[src/write.zig](../../packages/napi/src/write.zig)（59L）、[src/root.zig](../../packages/napi/src/root.zig)（15L）、[src/resources.zig](../../packages/napi/src/resources.zig)（6L）、[build.zig](../../packages/napi/build.zig)（16L）。

---

## 二、核心结论：为什么 `napi` 属于“合法保留边界”

1. **符合 [自举完成标准.md](../../rules/自举完成标准.md) 与 zero-runtime 原则**：`packages/napi` 不包含任何词法、语法、类型推导、IR 构造或编译器优化语义，它的唯一职责是在编译出的 Node 原生插件里提供 `napi_env`、`napi_value` 读写与异步队列粘合 C ABI。
2. **体量极小且零债务**：总共仅 438 行 Zig、`0` 处 `@constCast`、`0` 份 seed，强制写成 ZX 反调 `.d.zx` 只会人为制造无效的跨层胶水。

---

## 三、跨包联动清理项（落在 `genz` 与 `cli` 中）

虽然 `packages/napi` 本身保留，但与之配套的**代码生成端**存在两项来自复核报告的轻微整理需求：

1. **N-API Codec 生成去重（联动 `genz.md`）**：`packages/genz/src/analysis/host/node/napi/codec/` 下的 `read_result.zx` 与 `return_result.zx` 字节完全相同，应在 `genz` 收口时合并为一个文件并同步更新 `extend.rx` 调用方。
2. **宿主生命周期与构造共享归属（联动 `genz.md`）**：确保 `packages/genz/src/analysis/host/wasm/` 不再反向依赖 `host/node/task/` 私有目录（把通用 AST 调用/方法构造提取至共同 `ast` 或 `host` 公共层）。

---

## 四、验收与回测口径

- **保留边界核查**：确认 `packages/napi` 不被 `packages/compiler` 依赖，仅被 `packages/cli` 用于 Node 绑定产物构建；
- **回归范围**：保持现有 N-API 构建与 Node JS 宿主加载测试通过即可，不为其单开迁移阶段。
