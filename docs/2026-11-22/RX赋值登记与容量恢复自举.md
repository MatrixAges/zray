# RX 赋值登记与容量恢复自举

## Intent

迁出 RX 约束图的单项与批量赋值登记循环。两条路径共用赋值行和索引的容量恢复、跨度写入及前缀提交规则。

## Data

起点为 `9106abb48`。普通表达式和对象约束通过 `Graph.expect` 登记单项赋值，序列重放调用 `expectMany`。已有 ZX 负责根查找、去重、行写入及索引重建。仍由 Zig 查收扫描结果、提交行数，在扩容或登记声明类型后恢复。

```mermaid
flowchart LR
    Single[单项赋值] --> Admission[端点归一与索引探测]
    Series[批量赋值] --> Admission
    Admission --> Publish[写入行与原跨度]
    Publish --> Commit[提交已写前缀]
    Commit --> Restore[按需扩容或登记类型]
    Restore --> Admission
```

```mermaid
flowchart LR
    Old[借用已分配的赋值列] --> Add[在现有列尾部写入]
    Add --> Prefix[发布长度与图修订号]
    Prefix --> Rows[按需增长物理行]
    Rows --> Index[分配并重建索引]
    Index --> View[更新借用列]
```

## Edges

去重在容量申请前完成。批量扫描先提交成功前缀，再处理容量、溢出或类型登记。扩容重建只读取已提交的键，旧索引在新索引可用后释放。列缓冲和跨度直接借用，初始 seed 沿用自己的登记实现。

## Answer

- 单项保留直接端点探测。批量写满当前前缀后，先发布长度与修订号，再分流容量请求、声明类型登记或溢出。恢复使用原游标，已有节点、目标和跨度仍借用原列。[单项入口](../../packages/compiler/src/rx/analysis/inference/assignment/registration/single.rx) · [批量入口](../../packages/compiler/src/rx/analysis/inference/assignment/registration/batch.rx)
- 两条路径共用行与跨度写入以及容量恢复。RX 先按需增长行，再分配索引。ZX 初始化新索引并探测已提交键，最后交回宿主更新索引引用。宿主负责物理分配、访问借用列和更新图已有的长度与修订字段。[写入](../../packages/compiler/src/rx/analysis/inference/assignment/registration/publish.zx) · [容量恢复](../../packages/compiler/src/rx/analysis/inference/assignment/registration/reserve.rx)
- 定向生成检查覆盖两个入口。游标留在栈上，探测直接读取现有键，登记直接写入现有列。分配发生在行或索引容量不足时。

### 自编译与产物一致性

由 `9106abb48` 的 Source 工具构建候选，27 个引导步骤通过。候选 SHA-256 为 `bb8b38936b45126ccff061ce9884a9e63352dd0ba15ad46d32e02f38e6d6f0f3`。五份引导清单的 17,657 个生成文件逐字节一致。十次常驻编辑的计数和输出哈希与上阶段一致。RX 和 ZX 改动通过格式与 lint 检查。

候选通过 83 个构建步骤、153 项正式 Zig 测试和 17 项 CLI 集成，覆盖 RX 推导、声明和推导序列、对象字段、诊断位置及分配失败。初始 seed 通过解析器构建和 39 项 RX 回归。

### 性能对照

固定 705 个入口和 16 个分区，关闭常驻生成器，交错三轮取中位数。三个工具均由 Source 构建，使用各自的 Source 分析与生成。对照的 9,894 个生成文件及所有权 memo 逐字节一致。

| 对照     | 冷生成墙钟 | 冷生成 CPU | 冷进程树峰值 RSS | 冷系统记录峰值 RSS | 热生成墙钟 | 热生成 CPU |
| -------- | ---------: | ---------: | ---------------: | -----------------: | ---------: | ---------: |
| 固定基线 |     2.08 s |     9.02 s |         737.6 MB |           760.0 MB |     1.63 s |     6.42 s |
| 上阶段   |     1.95 s |     9.50 s |         524.1 MB |           554.3 MB |     1.44 s |     6.26 s |
| 候选     |     1.95 s |     9.44 s |         529.5 MB |           552.5 MB |     1.43 s |     6.25 s |

较上阶段，冷生成墙钟持平，CPU 减少 0.06 秒，进程树采样峰值增加 5.4 MB，系统记录峰值减少 1.8 MB。热生成墙钟和 CPU 均减少 0.01 秒。无改动检查仍为 0.03 秒。较固定基线，冷生成墙钟减少 0.13 秒，CPU 累计增加 0.42 秒，进程树采样峰值减少 208.1 MB，系统记录峰值减少 207.6 MB。

下一批接续普通与开放字段访问，以及合并字段的准备、校验和交付。沿这些入口核对字段查找、扩展和缺失诊断，沿用现有字段列及合并工作区。[字段访问](../../packages/compiler/src/rx/analysis/inference/fields/access.zig) · [字段合并](../../packages/compiler/src/rx/analysis/inference/unification/fields.zig)
