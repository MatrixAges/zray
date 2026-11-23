# RX 对象构造整行自举

## Intent

接通一行对象构造的展开、候选选择和字段写回。删除 Zig 对象投影交接、展开宿主和应用宿主，让同一 Source 请求直接借用字段列与单对象暂存区。

## Data

起点为 `3b0f2d813`。字段选择已把投影与应用合并为一个 Source 入口。构造的外层 RX 扫描仍逐行调用 Zig，Zig 在三个入口之间转交部件、展开结果与候选，并分别绑定视图。这批接续长执行计划的对象构造阶段。[长执行计划](../手写Zig净减少长执行计划.md)

```mermaid
flowchart LR
    Queue[构造请求] --> Scope[借用单对象暂存区]
    Scope --> Spread[Source 判就绪并投影]
    Spread --> Resolve[选择候选]
    Resolve --> Apply[逐字段登记和约束写入]
    Apply --> Next[交付并推进下一对象]
```

```mermaid
flowchart LR
    Parts[借用原部件及共享图列] --> Projection[按需预留展开列]
    Projection --> Keys[名字集合与既有候选规则]
    Keys --> Target[先处理目标字段]
    Target --> Source[再登记来源和施加约束]
    Source --> View[刷新当前图视图]
```

## Edges

保持原对象和部件的诊断跨度、就绪性缓存和单对象 arena。首个展开之后才预留展开列。构造先处理目标再登记来源，每次更新后重取图视图。初始 seed 单独验收。

## Answer

普通轮和最终轮共用 `construction/apply.rx`。Source 校验对象形状，按需准备展开，选择候选，再按原顺序登记目标、来源与约束。删除 `construction/project.zig`、`construction/projection/host.zig`、`construction/application/host.zig`，三个独立生成入口合为一个。四个按错误分类的 Zig 回调合为一个诊断交付点，消息和位置的选择由 Source 决定。

逐对象暂存区和图视图继续借用原有存储。展开列只在首次展开时预留，候选列直接交给应用流程。生成的 RX 调用代码没有新增用于请求描述符的堆分配。原生边界仍负责暂存区、图列借用、展开就绪查询、图节点登记与约束写入。[构造入口](../../packages/compiler/src/rx/analysis/inference/construction/apply.rx) · [原生边界](../../packages/compiler/src/rx/analysis/inference/construction/object.zig)

五份引导清单的 17,640 个生成文件与 `3b0f2d813` 逐字节一致，10 个常驻编辑场景的结果也一致。候选由上一阶段的 Source 引导器生成，SHA-256 为 `7d9efc8039195d84649e5c75526bb144226a11ea3b138ef35a0139d7cc2dbc87`。

`test-rx-inference` 和 `test-xml-expression` 共 153 项 Zig 回归通过。CLI 磁盘项目与原生 Store 共 17 项通过。初始 seed 单独构建解析引导器，`test-rx` 的 39 项通过。

### 性能对照

沿用同一份 705 入口、16 分区的冻结清单，关闭常驻生成器，交错三轮取中位数。三个工具均由 Source 构建，测量时各自使用 Source 分析和生成。上一批与候选的 9,894 个冻结产物及所有权 memo 逐字节一致。

| 对照     | 冷生成墙钟 | 冷生成 CPU | 冷进程树峰值 RSS | 冷系统记录峰值 RSS | 热生成墙钟 | 热生成 CPU |
| -------- | ---------: | ---------: | ---------------: | -----------------: | ---------: | ---------: |
| 固定基线 |     2.06 s |     8.93 s |         736.9 MB |           760.3 MB |     1.66 s |     6.46 s |
| 上一批   |     1.93 s |     9.46 s |         524.1 MB |           546.9 MB |     1.46 s |     6.31 s |
| 候选     |     1.93 s |     9.42 s |         525.2 MB |           553.0 MB |     1.46 s |     6.23 s |

较上一批，冷生成墙钟持平，CPU 减少 0.04 秒，进程树峰值增加 1.1 MB，系统记录峰值增加 6.1 MB。热生成墙钟持平，CPU 减少 0.08 秒，无改动路径墙钟保持 0.03 秒。较固定基线，冷生成墙钟减少 0.13 秒，CPU 累计增加 0.49 秒，进程树峰值减少 211.7 MB，系统记录峰值减少 207.3 MB。
