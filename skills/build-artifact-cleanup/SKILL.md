---
name: build-artifact-cleanup
description: 清理 zray 仓库累积的自举核验产物、Zig 构建缓存和文档中间文件。用于约六小时一次的留存检查、磁盘占用排查和阶段结束后的回收。
---

# 清理自举产物

复用 Codex 中的「zray 构建产物清理」定时任务，约每六小时运行一次。磁盘不足时从仓库根目录提前执行。

1. 查当前构建、核验和清理进程及其输出。为仓库内正在读写的缓存、仍在使用的 `zig-out` 安装、Source 引导器和固定性能基线传 `--keep <路径>`，需要时重复传入。尽量指定实际使用的目录或缓存条目，让同级过期产物可以回收。已有清理在运行时沿用原进程。
2. 用 `python3 scripts/clean_build_artifacts.py` 加保留参数预览，再用相同参数加 `--apply`。默认回收超过六小时的闲置核验目录、Zig 缓存、仓库根目录和各包的旧 `zig-out`，以及 Git 忽略且未被文档引用的中间文件。保留源码、文档正文、用户记录、固定工具链和在用证据。阶段结果、提交、构建配置和必要的产物哈希写入 `docs`。
3. 用 `df -h .` 核对实际可用空间，确认保留的工具和基线仍可用。若仍有明显占用，按目录核对来源，处理完所有符合条件的候选。定时任务有实际回收或遇到阻碍时报告结果。

新的隔离核验和批量集成测试在启动命令前设置以下路径，清理脚本会一并处理。同组性能对照沿用相同配置。

```sh
mkdir -p .zig-cache/verification-tmp .zig-cache/verification-global
export TMPDIR="$PWD/.zig-cache/verification-tmp"
export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/verification-global"
```

核验安装包时，把 `ZXC_CACHE_DIR` 指向 `.zig-cache/verification-tmp` 下本轮核验使用的固定目录。每个安装包在其中解包的工具链可以随本轮产物一起回收。
