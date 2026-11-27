const std = @import("std");
const zx = @import("zx");

pub fn prefixed(allocator: std.mem.Allocator, prefix: []const u8, comptime field: []const u8, rows: anytype) std.mem.Allocator.Error![]const []const u8 {
    return prefixedColumns(allocator, prefix, zx.memory.borrowTextColumn(field, rows), rows.len);
}

pub fn prefixedColumns(allocator: std.mem.Allocator, prefix: []const u8, modules: zx.memory.TextColumn, count: usize) std.mem.Allocator.Error![]const []const u8 {
    if (count == 0) return allocator.dupe([]const u8, &.{prefix});

    const rule = @import("generated_gateway_imports");

    const input: std.meta.Child(rule.Input) = .{
        .prefix = prefix,
        .modules = @ptrCast(&modules),
        .count = count,
    };

    return zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
