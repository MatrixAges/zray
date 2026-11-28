# Wave 108 自举执行记录（已验收 · 2026-11-28）

> 返回 [总览](../README.md) · [越界台账](../越界写法治理清单.md)

## 核心改动

1. **RX 项目分析。** 对象回放、字段访问、类型解析与统一、约束收集、流程遍历和语句生成改用 RX Store 与显式写入授权。该路径移除 13 个 `mutable_opaque` 和 111 条宿主声明。
2. **形式验证。** RX 编排块内绑定、表达式求值和返回值合并，Store 传递请求与结果。移除 3 个 `mutable_opaque` 和 13 条宿主声明，契约求值与布尔项绑定共用只读 `ContractSource`。
3. **生成输入。** 请求文档批次和目录扫描结果显式进入 Store，文件读取和原生布局转换保留在 Zig 边界。移除 2 个 `mutable_opaque` 和 3 条宿主声明。集成时把 10 种过渡期只读类型合并为 `GenerationIO` 和 `GenerationArtifact`。
4. **分区构建。** RX 调度缺失分区并发布状态，ZX 通过 Store setter 更新分区有效性。移除 `PartitionDriver` 和 5 条宿主声明。文件读取、BLAKE3 哈希和 Zig 子进程保留为原生操作。
5. **Genz。** 唯一性轮次、回放、流程求解和迭代转移改用有类型的请求与结果，移除 `Execution`、`FlowExecution` 和 27 条宿主声明。
6. **CLI。** 普通 RX 和 Gateway 构建共用后端流程，检查、构建和文件操作传递显式参数。移除 6 个 `opaque`、18 条宿主声明和最后一个非 setter `void` ZX。

集成补齐了生成入口的 Store 提交接口，并移除了失去调用者的 `ownership_host` 注册。`std:fs` 的两个 Zig 实现通过字段访问复用 Compiler 与 CLI 分别生成的 ABI 类型，ZX 公开签名保持一致。解析器类型排序使用独立的临时分配器，避免大输入的排序缓冲占用已为语法结果预留的容量。

## 治理审计

以 `988c6bf7d` 的 Git 快照和 Wave 108 工作树对照，包含未跟踪源文件，排除测试及示例。授权 setter 按 RX 中的 `setter={[$store.*]}` 解析到 ZX 实现，全部授权目标均可解析。

| 指标                            |     CLI | Compiler |    Genz |    Core | Pkgs |     Std |            合计 |
| ------------------------------- | ------: | -------: | ------: | ------: | ---: | ------: | --------------: |
| `mutable_opaque`                |     0→0 |     25→6 |     7→5 |   14→14 |  0→0 |     0→0 |       **46→25** |
| `opaque`                        |   45→39 |     6→10 |     1→1 |   30→30 |  0→0 |     0→0 |       **82→80** |
| `.d.zx` 函数声明                | 406→388 |   213→81 | 203→176 | 187→187 |  0→0 | 180→180 | **1,189→1,012** |
| RX `fn="host.*"`                |     0→0 |   180→86 |   19→28 |     0→0 |  0→0 |     0→0 |     **199→114** |
| `.store.rx`                     |   14→14 |    34→48 |     2→6 |     0→0 |  0→0 |     0→0 |       **50→68** |
| `U32Buffer`（`src` 中的 `.zx`） |     0→0 |    25→25 |     0→0 |     0→0 |  0→0 |     0→0 |           25→25 |
| `U32Buffer`（含接口中的 `.zx`） |     0→0 |    25→25 |     0→0 |     3→3 |  0→0 |     0→0 |           28→28 |
| `void` ZX                       |   17→16 |    26→39 |     5→7 |   28→28 |  0→0 |     0→0 |           76→90 |
| 授权 `$store` setter            |   16→16 |    26→39 |     3→7 |     0→0 |  0→0 |     0→0 |           45→62 |
| 非 setter `void` ZX             |     1→0 |      0→0 |     2→0 |   28→28 |  0→0 |     0→0 |       **31→28** |

业务 `.d.zx` 声明 **1,009→832**，非 CLI Store **36→54**。Genz 分区流程新增 9 处 `host.*` 写法，其中 6 处对应分区宿主接口，3 处调用标准库。

Core 保留 3 处直接内存写和 6 处列写。各包新增直接内存写、列写、原子操作、手动 Arena 管理、自举源码 `zig:*` 导入、RX `memory.*` 调用、标准库句柄和原子接口、非 setter `void` ZX 均为 0。以下保护目录的跟踪文件和未跟踪文件均为零差异。

- `packages/compiler/src/rx/analysis/inference/optional`
- `packages/compiler/src/rx/analysis/inference/assignment`
- `packages/genz/src/analysis/uniqueness/atomic`

## 静态检查与三阶段自编译

- `git diff --check` 通过。修改及新增的 Zig 文件逐一执行 `zig ast-check`，63/63 通过。354 个 RX/ZX 文件逐一执行 `zxc fmt "$f" --check` 和 `zxc lint "$f"`，两项均为 354/354。
- 从 Wave 107 stage2 开始，在 `packages/compiler` 串行运行 `zig build bootstrap-stage -Doptimize=ReleaseSmall -Dgenerated-partitions=4`。stage1、stage2、stage3 各通过 30/30 步。构建和生成均设置 `ZXC_RESIDENT_GENERATOR=0`。
- stage1 的 30 秒限时 `main.json` 探活在 **4.67 秒**完成，分析 548 个入口、5,108 个模块，写出 5,155 个生成项且零复用。推理、发射和写出分别用时 1,317、2,299、286 毫秒。

| 阶段   | SHA-256                                                            |
| ------ | ------------------------------------------------------------------ |
| stage1 | `a4c978c01b10c391e7b7684c35fd4d4fe9bc39f2bf896002c6df0e8792052a5e` |
| stage2 | `a4c978c01b10c391e7b7684c35fd4d4fe9bc39f2bf896002c6df0e8792052a5e` |
| stage3 | `a4c978c01b10c391e7b7684c35fd4d4fe9bc39f2bf896002c6df0e8792052a5e` |

`cmp` 确认三个二进制逐字节一致。

## 冷生成基准与产物比对

Darwin arm64、Zig 0.17.1 环境下，以同一份构建生成的 `main.json`、同样的 `--partitions 4` 配置，串行比较两个 ReleaseSmall stage2 引导器。清单 SHA-256 为 `3af12fddab4f3d4ae5ea1f4280896f30468074ccde7091f380d165ebeb1a8973`。每次使用独立空输出和缓存目录，通过 `/usr/bin/time -lp` 测量生成阶段，六次均为零复用。

| 轮次 | 先运行   | Wave 107 墙钟 / 用户 / 系统（秒） | Wave 108 墙钟 / 用户 / 系统（秒） |
| ---: | -------- | --------------------------------: | --------------------------------: |
|    1 | Wave 107 |               4.26 / 12.76 / 2.78 |               4.37 / 12.80 / 2.96 |
|    2 | Wave 108 |               4.37 / 12.74 / 2.81 |               4.40 / 12.87 / 2.78 |
|    3 | Wave 107 |               4.39 / 12.82 / 2.86 |               4.38 / 12.77 / 2.92 |

同轮中位数为墙钟 **4.37→4.38 秒**、CPU **15.55→15.69 秒**。相对本次 Wave 107 对照增加 **0.01 秒墙钟、0.14 秒 CPU**，相对 Wave 107 历史中位数增加 **0.16 秒墙钟、0.26 秒 CPU**。相对 Wave 80 固定基线增加 **1.37 秒墙钟、1.10 秒 CPU**。单阶段与累计差值分别通过 1.00 秒、3.00 秒门限。峰值 RSS 的三轮中位数为 1,677,377,536→1,682,423,808 字节。 [Wave 80 固定基线](wave-076-080.md)

三轮均核对生成的 Zig 相对路径集合及逐文件 SHA-256。排除 `.zxc-inputs` 后，每轮各 **11,158** 份 Zig 文件完全一致，**PARITY_EXACT**。

## 六套串行验收

各命令均加 `--summary all`。`$STAGE2` 指向 Wave 108 的 stage2 引导器。

| 顺序 | 目录                | 命令                                                                                | 结果                                      |
| ---: | ------------------- | ----------------------------------------------------------------------------------- | ----------------------------------------- |
|    1 | `packages/compiler` | `zig build -Doptimize=ReleaseSafe -Dstage0=""`                                      | 42/42 步                                  |
|    2 | `packages/compiler` | `zig build test -Doptimize=ReleaseSafe -Dgenerated-partitions=4 -Dstage0="$STAGE2"` | 34/34 步，372/372 测试                    |
|    3 | `packages/pkgs`     | `zig build -Doptimize=ReleaseSafe -Dgenerated-partitions=4 -Dstage0="$STAGE2"`      | 7/7 步                                    |
|    4 | `packages/cli`      | `zig build test -Doptimize=ReleaseSafe -Dgenerated-partitions=4 -Dstage0="$STAGE2"` | 105/105 步，34/34 测试，0 泄漏            |
|    5 | `packages/cli`      | `zig build -Doptimize=ReleaseSmall -Dgenerated-partitions=4 -Dstage0="$STAGE2"`     | 76/76 步，格式与 lint 复检各 354/354      |
|    6 | `packages/test`     | `zig build test-verification -Doptimize=ReleaseSafe -Dstage0="$STAGE2"`             | 72/72 步，公开 8/8、枚举 74/74、CLI 20/20 |

通过六套验收后，将 `.zig-cache/.cleanup-keep` 切换至 `.zig-cache/verification-tmp/wave108/stage2/bin/zxc-bootstrap`。已清理 Wave 107 验收目录及 Wave 108 临时产物，复核保留二进制的 SHA-256 并确认 `NO_SERVE`。
