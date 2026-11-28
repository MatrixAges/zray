# 类别 3：`packages/std` 越界接口

> 返回：[越界写法治理清单](../越界写法治理清单.md)

## 二、类别 3：`packages/std` 越界接口（✅ 已清零）

### 已完成销项

- [x] 移除 `packages/std/interfaces/string.d.zx` 中的 `StringSet = mutable_opaque`、`setAdd`、`setAddAll`（Wave 47）。
- [x] 移除 `packages/std/interfaces/bytes.d.zx` 中的 `bytes.loadAtomic`（Wave 47）。
- [x] 清零 `packages/cli/` 全部 `std:bytes.Writer` 用法（`diagnostics/normalize.zx` Wave 49；`backend/source/process/request.zx` Wave 52）。
- [x] 清零 `compiler/src/inputs/generation/`、`library/envelope/`、`backends/zig/cache/`、`inputs/resident/` 与 `backends/zig/state/publication/`（`StreamWriter` 同步删除）中的 `std:bytes.Writer`（Waves 50–52）。
- [x] **Wave 53（已完成）**：清零 `zx/modules/semantic_cache/envelope/`、`inputs/snapshot/records/`、`inputs/fingerprint/`（删除 `text_pair.zx`，`inputs/` 全局清零）、`genz/analysis/host/manifest/` 全部 `std:bytes.Writer`，并物理删除 `packages/std` 中的 `writeHexU64`（`std:bytes` `Writer`/`bytes.write*` **79 → 70**，显式 `Writer` **56 → 46**）。
- [x] **Wave 54（已完成）**：在 `packages/std` 新增纯值 `encodeU32sLe`/`encodeU64sLe`，清零 `zx/modules/semantic_cache/fingerprint/`（消除 `zx/modules/` 全局 `std:bytes.Writer` 及 `packages/compiler/` 全部 `Sha256State` 引用）与 `genz/analysis/partition/cache/`（消除 `packages/genz/` 全部 `writeDecimalU64`）（`std:bytes` `Writer`/`bytes.write*` **70 → 56**，显式 `Writer` **46 → 27**）。
- [x] **Wave 55（已完成）**：在 `packages/std` 新增纯值并发 `bytes.mask` 并物理删除 `writeMasked`、`writeU32sLe`、`writeU64sLe`、`writeDecimalU64`；清零 `genz/analysis/uniqueness/memo/disk/write/` 与 `compiler/backends/verilog/` 全部 `std:bytes.Writer` 并撤销 `verilog_host`（`writer.d.zx`）（`std:bytes` `Writer`/`bytes.write*` **56 → 40**，显式 `Writer` **27 → 16**，`void` ZX **647 → 624**）。
- [x] **Wave 56（已完成）**：清零 `core/ir/fingerprint/`、`genz/analysis/uniqueness/identity/content/` 与 `compiler/backends/zig/fingerprint/` 全部 `std:bytes.Writer`，并从 `packages/std` 彻底删除 `Writer = mutable_opaque`、`write`/`writeByte`/`writeU32Le`/`writeU64Le` 与 `bytes/writer.zig`（全仓 `std:bytes` `Writer`/`bytes.write*` **40 → 0**，显式 `Writer` **16 → 0**，`std` `mutable_opaque == 0`，`void` ZX **624 → 580**）。
- [x] **Wave 57（已完成 · 类别 3 全部清零）**：清零 `cli/build/workspace/`、`genz/analysis/state/ownership/{helper/name,projection/plan}/`、`genz/analysis/uniqueness/{flow/key,identity/{combine,program,types}}/` 全部 `Sha256State` 消费，并物理删除 `packages/std` 与 `packages/core` 中的 `Sha256State = opaque`、`resetSha256`/`updateSha256*`/`digestSha256` 与 `crypto/sha256_state.zig`（全仓 `Sha256State == 0`，`packages/std` `opaque/mutable_opaque == 0`，总 `opaque` **125 → 124**，`void` ZX **580 → 567**）。

### 全目录清零清单（✅ 100% 完成）

- [x] **`packages/compiler/src/backends/zig/fingerprint/`（含 `backends/zig/fingerprint.zig`）**：已将全部根/类型包/函数体/单元模块及 `source.zig`/`fingerprint.zig`/`batch.zig` 改为纯 `u8[]` / `crypto.sha256Parts` + 8 KiB `BufferFirstAllocator`（Wave 56）。
- [x] **`packages/compiler/src/zx/modules/semantic_cache/fingerprint/`**：已将列编码、上下文指纹、文件键与原生接口指纹全面改为纯 `u8[]`/`string`/`sha256Parts` 返回，清除 `Sha256State` 与 `Writer`（Wave 54）。
- [x] **`packages/compiler/src/backends/verilog/{layout,node,workflow}/`**：已全部改为纯 `string`/`string?` 返回，物理清除 `Writer`、`writeDecimalU64`、`capacity.zx`、`reserve.zx` 与 `verilog_host`（Wave 55）。
- [x] **`packages/core/src/ir/fingerprint/`**：已移除全部 `Writer`（新增 `statement.zx` 保持模块内聚精简），统一改为纯 `u8[]` 返回（Wave 56）。
- [x] **`packages/genz/src/analysis/partition/cache/`**：已移除 4 个文件（`external`/`members`/`prefix`/`state/model`）中的 `Writer` 与 `writeDecimalU64`（Wave 54）。
- [x] **`packages/genz/src/analysis/uniqueness/memo/disk/write/`**：已移除 7 个文件中的 `Writer`、`writeMasked`、`writeU32sLe`、`writeU64sLe` 与 `version.zx`/`count.zx`（Wave 55）。
- [x] **`packages/genz/src/analysis/uniqueness/identity/content/`**：已新增 `assemble.zx`（`crypto.sha256Parts`）并全部转为纯 `u8[]` 返回，同步移除 `content.zig` 中的 `std.Io.Writer.Hashing`（Wave 56）。
- [x] **`packages/std/interfaces/bytes.d.zx` & `packages/std/src/bytes/` 最终清理**：已物理删除 `Writer = mutable_opaque`、剩余 `write*` 声明与 `packages/std/src/bytes/writer.zig`（Wave 56）。
- [x] **`packages/std/interfaces/crypto.d.zx` & `packages/std/src/crypto/` 最终清理**：已彻底清除全部 `Sha256State` 消费并物理删除 `Sha256State = opaque`、`resetSha256`/`updateSha256*`/`digestSha256` 与 `packages/std/src/crypto/sha256_state.zig`（Wave 57）。

---
