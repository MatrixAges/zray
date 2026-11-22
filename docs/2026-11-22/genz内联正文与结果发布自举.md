# genz 内联正文与结果发布自举

## Intent · 最终目标

让正式内联入口直接读取已有函数列，由 RX 推进计划、重写与结果发布。普通渲染、独立函数和编译库共用此路径。

## Data · 可用证据

起点为 `af1d281d6`。`prepareWithWorkspace` 的正式分支先在 Zig 为每个函数组装正文描述符和指针数组，再交给 RX 求解。成功后，Zig 复制函数表的四列，并逐行复制和发布重写正文。[内联入口](../../packages/genz/src/zx/inline_call/generated.zig) · [正式编排](../../packages/genz/src/analysis/inline/prepare.rx)

## Edges · 边界与限制

内联计划和重写读取同一份原程序。保留函数编号、入口资格、预算及错误顺序。未修改正文继续借用原存储。失败和中止的重写停留在临时区，已发布结果由调用端的分配区持有。

```mermaid
flowchart LR
    Borrow[借用原程序列] --> Plan[纯度与预算]
    Plan --> Rewrite[选择和重写正文]
    Rewrite --> Entry[交付入口变更]
    Entry --> Functions[发布修改的函数行]
```

```mermaid
flowchart LR
    Original[原程序] --> Scratch[临时计划与重写]
    Scratch --> Owner[已确认的正文与列]
    Original --> Result[最终程序]
    Owner --> Result
```

## Answer · 验收

核对正式路径退出 Zig 的逐函数描述符生成和重写后的发布循环。复用内联、独立生成及库回归，比较冻结输入的生成产物、CPU、墙钟和峰值 RSS。检查未改分支的借用，以及临时区释放后重写正文仍可使用。

### 已接入

内联计划从函数列读取签名和正文。改写状态按编号直接借用原程序的符号、表达式与控制列，程序入口沿同一索引约定访问。移除了逐函数正文描述符和对应指针表。已改动的入口随六个引导目标通过候选生成，现有 modular-loop 回归通过 123 项。内联结果的最终存储发布尚在原生侧。接续优先处理 [ZX 与 RX 依赖方向](ZX与RX依赖方向收口.md)。
