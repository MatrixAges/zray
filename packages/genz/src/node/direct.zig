const std = @import("std");
const zx = @import("zx");
const Storage = @import("storage.zig");
const stored = @import("stored.zig");
const Error = std.mem.Allocator.Error;
const Header = packed struct(u64) { offset: u32, tag: u32 };

pub fn append(storage: *Storage, allocator: std.mem.Allocator, comptime field: []const u8, values: anytype) Error!u32 {
    const entry = @import("generated_direct_ast_range");
    const table = &@field(storage, field);
    const start = table.tags.items.len;

    if (values.len == 0) return @intCast(start);
    if (values.len > std.math.maxInt(u32) - start) return error.OutOfMemory;
    try table.tags.ensureUnusedCapacity(allocator, values.len);
    try table.offsets.ensureUnusedCapacity(allocator, values.len);

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var local: [256]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&local, arena.allocator());
    const headers = try scratch.allocator().alloc(u64, values.len);
    var count: usize = 0;

    for (values, headers) |source, *packed_header| {
        const value = stored.copy(storage, allocator, source) catch break;
        const header = table.prepare(allocator, value) catch break;
        packed_header.* = @bitCast(Header{ .offset = header.offset, .tag = @backingInt(header.tag) });
        count += 1;
    }

    const input: std.meta.Child(entry.Input) = .{ .headers = headers[0..count] };

    const result = zx.columns.invoke(entry.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    const Tag = std.meta.Elem(@TypeOf(table.tags.items));

    for (result.tags) |tag| table.tags.appendAssumeCapacity(@as(Tag, @fromBackingInt(@intCast(tag))));

    table.offsets.appendSliceAssumeCapacity(result.offsets);

    if (count != values.len) return error.OutOfMemory;

    return @intCast(start);
}
