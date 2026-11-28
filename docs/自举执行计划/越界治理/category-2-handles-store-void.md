# 类别 2：`mutable_opaque` / `<Store>` / `void` ZX

> 返回：[越界写法治理清单](../越界写法治理清单.md)

## 四、类别 2：`mutable_opaque` / `<Store>` 迁移 / 纯副作用 `void` ZX（⬜ 重点攻坚）

> 现状：全库非测试 `.store.rx` 共 **31** 份（`cli` 14 + `compiler` 15 + `genz` 2 份）。跨调用状态正从 `[1]T` 标量缓冲、`mutable_opaque`/`opaque` 逐步收敛入 `.store.rx`。

### 重点 `mutable_opaque` 句柄与 `<Store>` 迁移清单

- [ ] **`packages/compiler/src/rx/analysis/project/workflow/`**：消减 [host/types.d.zx](../../../packages/compiler/src/rx/analysis/project/workflow/host/types.d.zx) 中 49 处 `mutable_opaque`（为 `compiler` 落地首批 `.store.rx` `$store.*`）。
- [ ] **`packages/compiler/src/zx/modules/project/`**：消减 [execution/types.d.zx](../../../packages/compiler/src/zx/modules/project/execution/types.d.zx) 中 21 处 `mutable_opaque`。
- [ ] **`packages/genz/src/analysis/expressions/evaluate/`**：消减 [frames.d.zx](../../../packages/genz/src/analysis/expressions/evaluate/frames.d.zx)（17 处）与 [iteration_frames.d.zx](../../../packages/genz/src/analysis/expressions/evaluate/iteration_frames.d.zx)（10 处）的 `mutable_opaque`，推进 `genz` 侧 `.store.rx` 建模。
- [ ] **`packages/compiler/src/inputs/generation/request/host.d.zx`（7 处）与 `backends/zig/output_host.d.zx`（7 处）**：拆解生成期状态入 `<Store>` 或显式 RX 数据流。
- [ ] **`packages/compiler/src/verification/host.d.zx`（5 处）、`execution/program/host.d.zx`（2 处）、`backends/hardware/graph/view.d.zx`（2 处）**。
- [ ] **`packages/genz/src/ast/rows/write.d.zx`（4 处 `AstWriter` 等）与 `uniqueness/program/driver/native.d.zx`（4 处）**。
- [ ] **`packages/core/interfaces/memory/types.d.zx`（33 处）与 `column_sets.d.zx`（5 处）**：随 `memory` 写操作收敛同步退出。

- [ ] **纯副作用 `void` ZX 销项（基线 707 → Wave 52: 678 → Wave 53: 668 → Wave 54: 647 → Wave 55: 624 → Wave 56: 580 → Wave 57: 567 → Wave 82: 438 → Wave 83: 427 → Wave 84: 418 → Wave 85: 399 → Wave 86: 378 → Wave 87: 372 → Wave 88: 365 → Wave 89: 342 → Wave 90: 331 → Wave 91: 290 → Wave 92: 227）**：将非纯写入的 `void` 包装与中间缓冲区回调迁出，保持 ZX 返回纯值或仅在 RX 授权 `setter={[$store.*]}` 下更新 `<Store>`。

---
