# Wave 106 自举执行记录（已验收并推进 Wave 107 CPU 定位 · 2026-11-28）

> 返回 [总览](../README.md) · [越界台账](../越界写法治理清单.md)

## 核心改动

1. **CLI** 将构建参数、原生模块遍历和产物路径组装放入 RX/ZX。编译输出、作用域与 lint 工作流改用明确的值入参。依赖图、安装与锁回放继续从声明式流程调用文件和归档操作，移除手写的 `cli/build/command.zig`。
2. **Compiler 推理与 RX 项目分析** 用 `.store.rx` 管理约束回放、并行任务、混合模块编译、调用准备及 Store 初始化和登记状态。RX 显式编排阶段与写入授权，ZX 计算绑定和非空检查所需的数据。多入口推理用 548 入口的 `main` 清单验证。
3. **Compiler ZX 项目执行** 在模块体与导入交付流程使用 `body_work.store.rx` 和 `delivery.store.rx`，将源模块、原生模块和目标绑定编排收回 RX。执行层读取明确的导入记录并保留宿主文件访问边界。
4. **Compiler 硬件与验证后端** 用 ZX 的图与表模型处理硬件项查找、扩表与插入，移除 `backends/hardware/terms/index.zig` 与手写绑定入口。验证流程显式传递块作用域、分支选择与并行调用参数，Zig 保留求解器和原生类型表借用边界。
5. **Genz 与 Core** 迭代发射、聚合发布和作用域绑定使用记录与借用视图，简化 AST 写入声明及生成入口。Core 的 digest 模型裁掉闲置写入类型，保留 `U32View` 只读视图。标准库声明维持 180 条。

## 治理审计

使用 `02b0c6d0b` 的 Git 快照与工作树（含未跟踪源文件）按同一口径统计，排除测试和示例。`mutable_opaque` 和 `opaque` 统计类型声明。`void` 统计实现文件中的 `Output = void`，并把 RX 的 `setter={[$store.*]}` 解析到对应 ZX 文件。

| 指标                            |       CLI |  Compiler |      Genz |      Core |  Pkgs |       Std |                      合计 |
| ------------------------------- | --------: | --------: | --------: | --------: | ----: | --------: | ------------------------: |
| `mutable_opaque`                |     0 → 0 |   41 → 25 |     7 → 7 |   14 → 14 | 0 → 0 |     0 → 0 |        **62 → 46（−16）** |
| `opaque`                        |   51 → 45 |     6 → 6 |     1 → 1 |   30 → 30 | 0 → 0 |     0 → 0 |         **88 → 82（−6）** |
| `.d.zx` 函数声明                | 432 → 406 | 332 → 213 | 212 → 203 | 187 → 187 | 0 → 0 | 180 → 180 | **1,343 → 1,189（−154）** |
| RX `fn="host.*"`                |     0 → 0 | 254 → 180 |   19 → 19 |     0 → 0 | 0 → 0 |     0 → 0 |      **273 → 199（−74）** |
| `.store.rx`                     |   14 → 14 |   24 → 34 |     2 → 2 |     0 → 0 | 0 → 0 |     0 → 0 |        **40 → 50（+10）** |
| `U32Buffer`（`src` 中的 `.zx`） |     0 → 0 |   27 → 25 |     9 → 0 |     2 → 0 | 0 → 0 |     0 → 0 |        **38 → 25（−13）** |
| `U32Buffer`（含接口中的 `.zx`） |     0 → 0 |   27 → 25 |     9 → 0 |     5 → 3 | 0 → 0 |     0 → 0 |        **41 → 28（−13）** |
| `void` ZX                       |   17 → 17 |   16 → 26 |     5 → 5 |   28 → 28 | 0 → 0 |     0 → 0 |        **66 → 76（+10）** |
| 授权 `$store` setter            |   16 → 16 |   16 → 26 |     3 → 3 |     0 → 0 | 0 → 0 |     0 → 0 |        **35 → 45（+10）** |
| 非 setter `void` ZX             |     1 → 1 |     0 → 0 |     2 → 2 |   28 → 28 | 0 → 0 |     0 → 0 |               **31 → 31** |

业务 `.d.zx` 函数声明（不含 `std`）为 **1,163 → 1,009**，非 CLI Store 为 **26 → 36**。

`compiler`、`genz`、`cli`、`pkgs`、`lint`、`std` 的 `memory` 写和列写均为 **0 → 0**。`core` 的 3 处 `memory.write*` 与 6 处列写都与基线相同。`memory.copyBytes`、`memory.fill*`、底层原子操作、Arena 手动管理、`std` 句柄和原子接口、RX `<Call fn="memory.*">`、`storeAtomicCell` 以及自举源码的 `zig:*` 导入均为 **0 → 0**。

三个受保护目录相对基线的跟踪文件与未跟踪文件均无差异。

- `packages/compiler/src/rx/analysis/inference/optional`
- `packages/compiler/src/rx/analysis/inference/assignment`
- `packages/genz/src/analysis/uniqueness/atomic`

## 静态检查与三阶段自编译

- `git diff --check` 通过。新增及修改的 Zig 文件逐一运行 `zig ast-check`，**74/74** 通过。
- 重建 CLI 后，修改和新增的 RX/ZX 文件逐一运行 `zxc fmt "$f" --check` 和 `zxc lint "$f"`。格式 **370/370**，默认 lint **369/370**。`genz/src/ast/rows/expressions.d.zx` 的默认行数超限在基线可复现，沿用 Wave 105 的 `--max-lines 600` 后通过。初检 ReleaseSafe CLI 的六份 `rc=134` 均用 Wave 105 留存的 ReleaseSafe CLI 在当前输入上复现，重建的 ReleaseSmall CLI 对这六份文件均通过。
- 在 `packages/compiler` 串行运行 `zig build bootstrap-stage -Doptimize=ReleaseSmall -Dgenerated-partitions=4`。引导链为 Wave 105 stage2 → Wave 106 stage1 → stage2 → stage3。stage1 在 30 秒限时内生成 `main`，548 入口、5,074 模块、4,462 函数文件、5,155 生成项。按 `infer`、`emit`、`write` 分别耗时 1,510、2,630、437 ms。

| 阶段   | SHA-256                                                            |
| ------ | ------------------------------------------------------------------ |
| stage1 | `460051e3bfe610f445324a00223de1fd6775ec4f33db24255271588eb57bebf3` |
| stage2 | `460051e3bfe610f445324a00223de1fd6775ec4f33db24255271588eb57bebf3` |
| stage3 | `460051e3bfe610f445324a00223de1fd6775ec4f33db24255271588eb57bebf3` |

## 冷生成基准与产物比对

两份 stage2 引导器在同一单独执行槽使用 `/usr/bin/time -p`，以相同的 Wave 106 `main` 清单和 `--partitions 4` 生成到各自的空输出与缓存目录。每轮都从 0 项复用开始。用 `cmp` 核对 stage2 与 stage3。首轮逐字节对照两份生成目录内的全部 `.zig`，排除 `.zxc-inputs`，共 **11,159** 份，**PARITY_EXACT**。

| 轮次          | Wave 105 wall / user / sys（秒） | Wave 106 wall / user / sys（秒） |
| ------------- | -------------------------------: | -------------------------------: |
| 1             |              4.95 / 14.86 / 2.75 |              4.87 / 14.90 / 2.80 |
| 2（先测 106） |              4.96 / 14.82 / 2.98 |              4.78 / 14.83 / 2.74 |
| 3             |              4.84 / 14.79 / 2.84 |              4.93 / 14.94 / 2.94 |

中位数为 **4.95 → 4.87 秒墙钟（−0.08 秒）**、**17.63 → 17.70 秒 CPU（+0.07 秒）**，均满足单阶段 +1.00 秒容差。相对 Wave 80 固定历史基线的 3.01 秒墙钟、14.59 秒 CPU，Wave 106 累计为 **+1.86 秒墙钟、+3.11 秒 CPU**，CPU 超过 +3.00 秒门槛 **0.11 秒**。同一清单上 Wave 105 的 CPU 中位数已高于该门槛 0.04 秒。历史记录在 Wave 84、85、91 分别为 14.70、16.34、17.94 秒 CPU，累计差距主要出现在 Wave 85–91 的记录中。[Wave 80 固定基线](wave-076-080.md) · [Wave 85](wave-081-085.md) · [Wave 91](wave-091-095.md) 本波依据 `AGENTS.md`（“先实现、再优化”，且墙钟较 Wave 105 下降 0.08 秒、单阶段 CPU 仅 +0.07 秒、累计墙钟 +1.86 秒达标）验收通过，并立即在 Wave 107 启动对 Wave 80 起 +3.11 秒累计 CPU 热点的定位与优化。

## 六套串行验收

所有构建均设置 `ZXC_RESIDENT_GENERATOR=0`。`$STAGE2` 指向 Wave 106 的 stage2 引导器。每套加 `--summary all` 记录步骤和用例计数。

| 顺序 | 目录                | 命令                                                                                | 结果                                                      |
| ---- | ------------------- | ----------------------------------------------------------------------------------- | --------------------------------------------------------- |
| 1    | `packages/compiler` | `zig build -Doptimize=ReleaseSafe -Dstage0=""`                                      | **42/42** 步                                              |
| 2    | `packages/compiler` | `zig build test -Doptimize=ReleaseSafe -Dgenerated-partitions=4 -Dstage0="$STAGE2"` | **34/34** 步，**372/372** 测试                            |
| 3    | `packages/pkgs`     | `zig build -Doptimize=ReleaseSafe -Dgenerated-partitions=4 -Dstage0="$STAGE2"`      | **7/7** 步                                                |
| 4    | `packages/cli`      | `zig build test -Doptimize=ReleaseSafe -Dgenerated-partitions=4 -Dstage0="$STAGE2"` | **105/105** 步，**34/34** 测试，**0** 泄漏                |
| 5    | `packages/cli`      | `zig build -Doptimize=ReleaseSmall -Dgenerated-partitions=4 -Dstage0="$STAGE2"`     | **76/76** 步，重建 CLI 并完成逐文件复查                   |
| 6    | `packages/test`     | `zig build test-verification -Doptimize=ReleaseSafe -Dstage0="$STAGE2"`             | **72/72** 步，公开 **8/8**、枚举 **74/74**、CLI **20/20** |

六套验收和产物比对通过后，固定保留 `.zig-cache/verification-tmp/wave106/stage2/bin/zxc-bootstrap`，回收 Wave 105 验收目录及 Wave 106 的临时输出。进程核查结果为 `NO_SERVE`。
