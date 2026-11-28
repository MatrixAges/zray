# Wave 107 自举执行记录（已验收 · 2026-11-28）

> 返回 [总览](../README.md) · [越界台账](../越界写法治理清单.md)

## 核心改动

1. **Printer 借用 AST 表。** 渲染入口把 AST 表与声明范围分开。表达式、语句等渲染步骤通过只读借用访问同一份 AST，消除热循环中 3,720 字节的 `Source` 复制。
2. **语义类型查找直接比较。** 查找先比类型和形状，再按列或索引比对内容。条目比较循环只推进索引，发现差异立即结束。
3. **唯一性位置判定。** 同区域且任一侧没有分支臂时直接结束排他检查。循环捕获只读列和上下文，只携带需要更新的游标与结果。
4. **唯一性函数层级查询。** 查询计算一次槽位索引并随请求传入。递归子请求计算自己的槽位，叶节点直接完成当前结果。
5. **唯一性反馈入参收窄。** Zig 入口借出上一轮函数对应的调用者切片，RX 保留反馈发布与后续调度顺序。
6. **执行者配置。** 槽位上限为 6。新建和恢复会话共用 `--disable multi_agent` 与 `--disable multi_agent_v2`，适用于所有模型。脚本语法检查通过，两种尝试开启的额外配置均返回 2，本次执行进程带有两项禁用参数。

## 治理审计

以 Wave 106 提交 `b3af303c4` 与 Wave 107 工作树对照，包含未跟踪源文件，排除测试和示例。表中各项在前后两份源码的计数相同。通过 RX 的 `setter={[$store.*]}` 解析授权所对应的 ZX 文件。

| 指标                            | CLI | Compiler | Genz | Core | Pkgs | Std |  合计 |
| ------------------------------- | --: | -------: | ---: | ---: | ---: | --: | ----: |
| `mutable_opaque`                |   0 |       25 |    7 |   14 |    0 |   0 |    46 |
| `opaque`                        |  45 |        6 |    1 |   30 |    0 |   0 |    82 |
| `.d.zx` 函数声明                | 406 |      213 |  203 |  187 |    0 | 180 | 1,189 |
| RX `fn="host.*"`                |   0 |      180 |   19 |    0 |    0 |   0 |   199 |
| `.store.rx`                     |  14 |       34 |    2 |    0 |    0 |   0 |    50 |
| `U32Buffer`（`src` 中的 `.zx`） |   0 |       25 |    0 |    0 |    0 |   0 |    25 |
| `U32Buffer`（含接口中的 `.zx`） |   0 |       25 |    0 |    3 |    0 |   0 |    28 |
| `void` ZX                       |  17 |       26 |    5 |   28 |    0 |   0 |    76 |
| 授权 `$store` setter            |  16 |       26 |    3 |    0 |    0 |   0 |    45 |
| 非 setter `void` ZX             |   1 |        0 |    2 |   28 |    0 |   0 |    31 |

业务 `.d.zx` 函数声明为 1,009 条，非 CLI Store 为 36 个。Core 保留原有 3 处 `memory.write*` 与 6 处列写。其余扫描包的两类写操作均为 0。`memory.copyBytes`、`memory.fill*`、底层原子操作、Arena 手动管理、标准库句柄和原子接口、RX `<Call fn="memory.*">`、`storeAtomicCell` 与自举源码 `zig:*` 导入均为 0。

三个保护目录的跟踪文件和未跟踪文件检查均为零差异。

- `packages/compiler/src/rx/analysis/inference/optional`
- `packages/compiler/src/rx/analysis/inference/assignment`
- `packages/genz/src/analysis/uniqueness/atomic`

## 静态检查与三阶段自编译

- `git diff --check` 通过。修改的 Zig 文件逐一运行 `zig ast-check`，4/4 通过。修改的 RX/ZX 文件逐一运行 `zxc fmt "$f" --check` 和 `zxc lint "$f"`，初检均为 39/39。
- 在 `packages/compiler` 串行运行 `zig build bootstrap-stage -Doptimize=ReleaseSmall -Dgenerated-partitions=4`，依次从 Wave 106 stage2 构建 Wave 107 stage1、stage2 和 stage3，各通过 30/30 步。所有构建和生成命令均设置 `ZXC_RESIDENT_GENERATOR=0`。
- stage1 在 30 秒限时内完成 `main` 清单探活，分析 548 个入口、5,074 个模块，生成 4,462 个函数文件及 5,155 个生成项。推理、发射和写出耗时分别为 1,212、2,266、313 毫秒。

| 阶段   | SHA-256                                                            |
| ------ | ------------------------------------------------------------------ |
| stage1 | `bcb12acc69a9de7ac21be0e5b2daadb3dccd3094374ab5b375775e2755d4481e` |
| stage2 | `bcb12acc69a9de7ac21be0e5b2daadb3dccd3094374ab5b375775e2755d4481e` |
| stage3 | `bcb12acc69a9de7ac21be0e5b2daadb3dccd3094374ab5b375775e2755d4481e` |

`cmp` 确认三个二进制逐字节一致。

## 冷生成基准与产物比对

在 Darwin arm64、Zig 0.17.1 环境下，用两份自编译 ReleaseSmall stage2 运行同一份构建生成的 `main.json`，固定 `--partitions 4`。清单 SHA-256 为 `bbc92fdc9ce9a05fad075d15ffd6ba3c49d9c98131fc556795619803687977be`。每次使用独立的空输出和缓存目录，以 `/usr/bin/time -lp` 串行测量生成阶段。六次运行均为零复用。

| 轮次 | 先运行   | Wave 106 墙钟 / 用户 / 系统（秒） | Wave 107 墙钟 / 用户 / 系统（秒） | 配对 CPU 节省（秒） |
| ---: | -------- | --------------------------------: | --------------------------------: | ------------------: |
|    1 | Wave 106 |               4.82 / 14.84 / 2.87 |               4.22 / 12.57 / 2.86 |                2.28 |
|    2 | Wave 107 |               4.80 / 14.87 / 2.68 |               4.21 / 12.63 / 2.86 |                2.06 |
|    3 | Wave 106 |               4.87 / 14.88 / 2.91 |               4.23 / 12.62 / 2.81 |                2.36 |

墙钟中位数为 **4.82 → 4.22 秒**，CPU 中位数为 **17.71 → 15.43 秒**。配对 CPU 节省中位数为 **2.28 秒**，高于 1.50 秒目标。相对 Wave 80 固定历史基线的 3.01 秒墙钟和 14.59 秒 CPU，累计差值为 **+1.21 秒墙钟、+0.84 秒 CPU**。 [Wave 80 固定基线](wave-076-080.md)

峰值 RSS 的三轮中位数由 1,692,155,904 字节降至 1,563,049,984 字节。Wave 107 第三轮峰值为 1,818,607,616 字节，高于该轮 Wave 106。本次交错对照测得五项优化的合计收益。Wave 80 的数据沿用历史记录。

每轮对照两份生成目录的相对路径集合和文件内容，复核 SHA-256 并逐字节比较。排除 `.zxc-inputs` 后各 **11,158** 份 `.zig` 文件均一致，**PARITY_EXACT**。

## 六套串行验收

各项命令均加 `--summary all`。`$STAGE2` 指向 Wave 107 的 stage2 引导器。

| 顺序 | 目录                | 命令                                                                                | 结果                                      |
| ---: | ------------------- | ----------------------------------------------------------------------------------- | ----------------------------------------- |
|    1 | `packages/compiler` | `zig build -Doptimize=ReleaseSafe -Dstage0=""`                                      | 42/42 步                                  |
|    2 | `packages/compiler` | `zig build test -Doptimize=ReleaseSafe -Dgenerated-partitions=4 -Dstage0="$STAGE2"` | 34/34 步，372/372 测试                    |
|    3 | `packages/pkgs`     | `zig build -Doptimize=ReleaseSafe -Dgenerated-partitions=4 -Dstage0="$STAGE2"`      | 7/7 步                                    |
|    4 | `packages/cli`      | `zig build test -Doptimize=ReleaseSafe -Dgenerated-partitions=4 -Dstage0="$STAGE2"` | 105/105 步，34/34 测试，0 泄漏            |
|    5 | `packages/cli`      | `zig build -Doptimize=ReleaseSmall -Dgenerated-partitions=4 -Dstage0="$STAGE2"`     | 76/76 步，重建 CLI 后格式与 lint 各 39/39 |
|    6 | `packages/test`     | `zig build test-verification -Doptimize=ReleaseSafe -Dstage0="$STAGE2"`             | 72/72 步，公开 8/8、枚举 74/74、CLI 20/20 |

在 `.zig-cache/.cleanup-keep` 中保留 `.zig-cache/verification-tmp/wave107/stage2/bin/zxc-bootstrap`，并复核其 SHA-256。已删除 Wave 106 验收目录和 Wave 107 临时产物，确认 `NO_SERVE`。
