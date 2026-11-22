const std = @import("std");
const zx = @import("zx");

pub fn prefixed(allocator: std.mem.Allocator, prefix: []const u8, comptime field: []const u8, rows: anytype) std.mem.Allocator.Error![]const []const u8 {
    if (comptime @import("parser_options").generated_parser) {
        return prefixedColumns(allocator, prefix, zx.memory.borrowTextColumn(field, rows), rows.len);
    }

    const output = try reserve(allocator, prefix, rows.len);

    for (rows, output[1..]) |*row, *name| name.* = @field(row, field);

    return output;
}

pub fn prefixedColumns(allocator: std.mem.Allocator, prefix: []const u8, modules: zx.memory.TextColumn, count: usize) std.mem.Allocator.Error![]const []const u8 {
    const output = try reserve(allocator, prefix, count);

    if (count == 0) return output;

    const rule = @import("generated_gateway_imports");
    const imports = output[1..];

    const input: std.meta.Child(rule.Input) = .{
        .modules = @ptrCast(&modules),
        .count = count,
        .imports = @ptrCast(&imports),
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;

    return output;
}

fn reserve(allocator: std.mem.Allocator, prefix: []const u8, count: usize) std.mem.Allocator.Error![][]const u8 {
    const length = std.math.add(usize, count, 1) catch return error.OutOfMemory;
    const output = try allocator.alloc([]const u8, length);

    output[0] = prefix;

    return output;
}
