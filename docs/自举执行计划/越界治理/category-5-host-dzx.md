# 类别 5：业务包 `*_host.d.zx` 与 RX `<Call fn="host.*">`

> 返回：[越界写法治理清单](../越界写法治理清单.md)

## 五、类别 5：业务包 `*_host.d.zx` 与 RX `<Call fn="host.*">`（🟡 持续收敛）

> 现状：除 `core`/`std` 外，业务包仍有 83 个 `.d.zx`、1,433 个 `export declare function`，RX 中仍有 278 处 `<Call fn="host.*">`（`compiler` 254、`genz` 24）。

### Top 宿主接口文件收敛清单

- [ ] **`compiler/rx/analysis/project/workflow/host/`**（`mixed.d.zx` 71、`flow.d.zx` 50、`projections.d.zx` 45、`constraints.d.zx` 42、`prepare.d.zx` 39、`body.d.zx` 30）
- [ ] **`compiler/zx/modules/project/execution/project.d.zx`**（53）
- [ ] **`cli` 宿主层**（`cli/lint/host.d.zx` 47、`cli/rx/execution/backend/host.d.zx` 45、`cli/compilation/host.d.zx` 40、`cli/rx/execution/host.d.zx` 36、`cli/publication/host.d.zx` 34、`package/workspace/host.d.zx` 31）
- [ ] **`genz` 宿主层**（`ast/rows/write.d.zx` 40、`uniqueness/program/driver/native.d.zx` 37、`expressions/evaluate/{module,iteration,function}.d.zx` 各 31）
- [ ] **`compiler/backends/zig/output_host.d.zx`（38）与 `compiler/verification/host.d.zx`（35）**

---
