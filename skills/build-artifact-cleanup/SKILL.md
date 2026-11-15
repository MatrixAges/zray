---
name: build-artifact-cleanup
description: 清理 zray 仓库累积的自举核验产物、Zig 构建缓存和文档中间文件。用于约六小时一次的留存检查、磁盘占用排查和阶段结束后的回收。
---

# 清理自举产物

从仓库根目录运行 `python3 scripts/clean_build_artifacts.py`。默认预览六小时前的候选并显示各 Zig 缓存目录的过期条目数。确认范围后，用相同参数加 `--apply`。约每六小时由现有定时任务执行一次，磁盘不足时提前执行。

1. 查当前构建、核验和清理进程及其输出。对正在读写的缓存传 `--keep <路径>`。当前 Source 工具和固定性能基线指定实际安装目录或缓存条目，留出同级过期条目供脚本回收。已有清理在运行时沿用原进程。
2. 核对预览，清理仓库内过期的核验目录、Zig 缓存及 Git 忽略且未被文档引用的中间文件。持续写入的核验目录按 Zig 缓存条目筛选。保留源码、Git 工作树、文档正文、用户记录、固定 Zig 工具链和仍被使用的证据。已有结论、提交、配置和必要的产物哈希留在 `docs`。
3. 完成后用 `df -h .` 核对卷的实际可用空间，确认保留的工具仍可用。按剩余目录的实际占用检查是否有漏掉的历史产物，处理完所有已确认符合条件的候选。

新的隔离核验和批量集成测试在启动命令前设置以下路径，清理脚本会一并处理。同组性能对照沿用相同配置。

```sh
mkdir -p .zig-cache/verification-tmp .zig-cache/verification-global
export TMPDIR="$PWD/.zig-cache/verification-tmp"
export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/verification-global"
```

核验安装包时，把 `ZXC_CACHE_DIR` 指向 `.zig-cache/verification-tmp` 下本轮核验使用的固定目录。每个安装包在其中解包的工具链可以随本轮产物一起回收。
