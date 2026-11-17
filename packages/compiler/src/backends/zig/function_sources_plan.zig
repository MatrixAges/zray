const std = @import("std");
const zx = @import("zx");
const Cache = @import("cache.zig");
const rule = @import("generated_function_sources_plan");
const Input = std.meta.Child(rule.Input);
const Output = @typeInfo(@typeInfo(@TypeOf(rule.executeValue)).@"fn".return_type.?).error_union.payload;
const Lookup = std.meta.Child(@typeInfo(@FieldType(Input, "lookup")).optional.child);

pub const Plan = struct {
    reused: []const u64,
    pending: []const u64,
    offsets: []const u64,
    size: usize,
    records: struct { first: usize, end: usize },
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
    const kinds = zx.memory.borrowReadColumn(Cache.Fetched.Kind, "kind", fetched);

    const lookup: Lookup = .{
        .kinds = @ptrCast(&kinds),
        .absent = @backingInt(Cache.Fetched.Kind.absent),
        .reused = @ptrCast(&reused),
        .pending = @ptrCast(&pending),
    };

    const output = try run(.{ .count = count, .sources = @ptrCast(&sources), .offsets = @ptrCast(&offsets), .lookup = &lookup });
    const hits: usize = @intCast(output.reused);

    return .{
        .reused = reused[0..hits],
        .pending = pending[0..@intCast(output.pending)],
        .offsets = offsets[0..hits],
        .size = std.math.cast(usize, output.size) orelse return error.OutOfMemory,
        .records = .{ .first = @intCast(output.record_first orelse 0), .end = @intCast(output.record_end) },
    };
}

pub fn layout(sources: *const zx.memory.ReadColumn, offsets: []u64) std.mem.Allocator.Error!usize {
    const output = try run(.{ .count = offsets.len, .sources = @ptrCast(sources), .offsets = @ptrCast(&offsets), .lookup = null });

    if (output.pending != 0) unreachable;

    return std.math.cast(usize, output.size) orelse error.OutOfMemory;
}

fn run(input: Input) std.mem.Allocator.Error!Output {
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
