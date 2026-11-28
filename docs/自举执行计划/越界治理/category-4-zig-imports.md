# 类别 4：`zig:*` 导入污染

> 返回：[越界写法治理清单](../越界写法治理清单.md)

## 一、类别 4：`zig:*` 导入污染（✅ 已清零）

- [x] 清零 `packages/compiler/src/` 全部 13 个文件、16 处 `from "zig:string"`，统一切换至 `std:string` 与纯 ZX（Wave 47 完成）。
- [x] 移除 [parser.zig](../../../packages/compiler/build/parser.zig) 中的 `zig:string` 注册。
- [x] 门禁确认：`packages/*/src/` 与 `packages/*/interfaces/` 中 `from "zig:" == 0`。

---
