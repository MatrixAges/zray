const std = @import("std");
const columns = @import("zx").columns;
const generated = @import("parser_options").generated_parser;

pub const Range = struct {
    first: u32,
    count: u32,
    prefix: u32,
    root: u32,
    types: u32,
    native_modules: u32,
};

pub fn plan(first: usize, count: usize, prefix: usize, types: usize, native_modules: usize) std.mem.Allocator.Error!Range {
    if (comptime !generated) {
        const start = std.math.cast(u32, first) orelse return error.OutOfMemory;
        const incoming = std.math.cast(u32, count) orelse return error.OutOfMemory;

        if (prefix > @min(first, count)) return error.OutOfMemory;

        return .{
            .first = start,
            .count = incoming,
            .prefix = @intCast(prefix),
            .root = std.math.add(u32, start, incoming - @as(u32, @intCast(prefix))) catch return error.OutOfMemory,
            .types = std.math.cast(u32, types) orelse return error.OutOfMemory,
            .native_modules = std.math.cast(u32, native_modules) orelse return error.OutOfMemory,
        };
    }

    const rule = @import("generated_function_link_range");

    const input: std.meta.Child(rule.Input) = .{
        .first = first,
        .count = count,
        .prefix = prefix,
        .types = types,
        .native_modules = native_modules,
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    const result = columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    return columns.view(Range, result orelse return error.OutOfMemory);
}
