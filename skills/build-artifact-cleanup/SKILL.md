---
name: build-artifact-cleanup
description: 清理 zray 仓库累积的自举核验产物、Zig 构建缓存和文档中间文件。用于约六小时一次的留存检查、磁盘占用排查和阶段结束后的回收。
---

# 清理自举产物

复用 Codex 中的「zray 构建产物清理」定时任务，约每六小时运行一次。磁盘不足时从仓库根目录提前执行。

1. 在开始长时间核验或切换引导器时更新 `.zig-cache/.cleanup-keep`，用一行一个仓库内路径登记活动输出、当前 Source 工具和固定基线。手动和定时清理都会读取该文件。核验结束或工具被替换后移除对应的登记，尽量登记到实际文件或缓存条目，让旁边的过期产物可以回收。
2. 清理前核对活跃进程及其输出，用可重复的 `--keep <路径>` 补充本轮保留项。执行 `python3 scripts/clean_build_artifacts.py` 预览，再用相同参数加 `--apply`。脚本回收超过六小时的闲置核验目录、Zig 缓存、仓库及各包的旧 `zig-out`、Git 忽略且未被文档引用的 `docs/` 中间文件和 `.zig-cache/` 根目录旧日志。阶段结果、提交、构建配置和必要的产物哈希写入 `docs/` 正文。
3. 用 `df -h .` 核对实际可用空间，确认保留的工具和基线仍可用。若仍有明显占用，按目录核对来源，处理完所有符合条件的候选。定时任务有实际回收或遇到阻碍时报告结果。

新的隔离核验和批量集成测试在启动命令前设置以下路径，清理脚本会一并处理。同组性能对照沿用相同配置。

```sh
mkdir -p .zig-cache/verification-tmp .zig-cache/verification-global
export TMPDIR="$PWD/.zig-cache/verification-tmp"
export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/verification-global"
```

核验安装包时，把 `ZXC_CACHE_DIR` 指向 `.zig-cache/verification-tmp` 下对应场景的固定目录。工具链解包产物可随该场景一起回收。核验常驻生成器时使用短缓存路径，避免 Unix socket 路径超长让请求退回单次运行。
