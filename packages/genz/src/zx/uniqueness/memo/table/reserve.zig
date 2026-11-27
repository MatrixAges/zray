const std = @import("std");
const zx = @import("zx");
const entry = @import("generated_uniqueness_memo_reserve");
const Input = std.meta.Child(entry.Input);

pub fn grow(table: anytype, allocator: std.mem.Allocator, additional: u32) std.mem.Allocator.Error!void {
    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const input: Input = .{
        .keys = std.mem.sliceAsBytes(table.keys.items),
        .current = table.keys.items.len,
        .additional = additional,
    };

    const result = zx.columns.invoke(entry.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => std.debug.panic("memo table could not be rehashed: {s}", .{@errorName(err)}),
    };

    const limit: usize = @intCast(result.limit);
    const buckets = try prepare(table, allocator, limit, result.buckets);

    allocator.free(table.buckets);

    table.buckets = buckets;
    table.limit = limit;
}

pub fn prepare(table: anytype, allocator: std.mem.Allocator, limit: usize, buckets: []const u32) std.mem.Allocator.Error![]u32 {
    try table.keys.ensureTotalCapacity(allocator, limit);
    try table.values.ensureTotalCapacity(allocator, limit);

    return allocator.dupe(u32, buckets);
}
