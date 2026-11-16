const std = @import("std");
const zx = @import("zx");
const Cache = @import("cache.zig");

pub const Plan = struct {
    reused: []const u64,
    pending: []const u64,
    offsets: []const u64,
    size: usize,
};

pub fn create(allocator: std.mem.Allocator, fetched: []const Cache.Fetched) std.mem.Allocator.Error!Plan {
    if (comptime !@import("parser_options").generated_parser) return @import("function_sources_seed.zig").create(allocator, fetched);

    const count = fetched.len;
    const capacity = std.math.mul(usize, count, 3) catch return error.OutOfMemory;
    const rows = try allocator.alloc(u64, capacity);
    const reused = rows[0..count];
    const pending = rows[count..][0..count];
    const offsets = rows[count * 2 ..];
    const sources = zx.memory.borrowReadColumn(?[]const u8, "source", fetched);
    const rule = @import("generated_function_sources_plan");

    const input: std.meta.Child(rule.Input) = .{
        .count = count,
        .sources = @ptrCast(&sources),
        .reused = @ptrCast(&reused),
        .pending = @ptrCast(&pending),
        .offsets = @ptrCast(&offsets),
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    const output = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    const hits: usize = @intCast(output.reused);

    return .{
        .reused = reused[0..hits],
        .pending = pending[0..@intCast(output.pending)],
        .offsets = offsets[0..hits],
        .size = std.math.cast(usize, output.size) orelse return error.OutOfMemory,
    };
}
