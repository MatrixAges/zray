const std = @import("std");
const zx = @import("zx");

pub fn prefixed(allocator: std.mem.Allocator, prefix: []const u8, comptime field: []const u8, rows: anytype) std.mem.Allocator.Error![]const []const u8 {
    const length = std.math.add(usize, rows.len, 1) catch return error.OutOfMemory;
    const output = try allocator.alloc([]const u8, length);
    output[0] = prefix;

    if (rows.len == 0) return output;

    const imports = output[1..];

    if (comptime !@import("parser_options").generated_parser) {
        for (rows, imports) |*row, *name| name.* = @field(row, field);

        return output;
    }

    const rule = @import("generated_gateway_imports");
    const memory = @import("zxc_standard").memory;
    const modules = memory.borrowTextColumn(field, rows);

    const input: std.meta.Child(rule.Input) = .{
        .modules = @ptrCast(&modules),
        .count = rows.len,
        .imports = @ptrCast(&imports),
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;

    return output;
}
