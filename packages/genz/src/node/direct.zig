const std = @import("std");
const zx = @import("zx");
const node = @import("../node.zig");
const Storage = @import("storage.zig");
const stored = @import("stored.zig");
const Error = std.mem.Allocator.Error;
const Header = packed struct(u64) { offset: u32, tag: u32 };

const Rows = union(enum) {
    expressions: []const node.Expression,
    statements: []const node.Statement,
    declaration_rows: []const node.Declaration,
};

const Frame = struct {
    storage: *Storage,
    allocator: std.mem.Allocator,
    rows: Rows,
};

pub fn append(storage: *Storage, allocator: std.mem.Allocator, comptime field: []const u8, values: anytype) Error!u32 {
    const entry = @import("generated_direct_ast_range");
    const table = &@field(storage, field);
    const start = table.tags.items.len;

    if (values.len == 0) return @intCast(start);
    if (values.len > std.math.maxInt(u32) - start) return error.OutOfMemory;
    try table.tags.ensureUnusedCapacity(allocator, values.len);
    try table.offsets.ensureUnusedCapacity(allocator, values.len);

    var frame: Frame = .{ .storage = storage, .allocator = allocator, .rows = @unionInit(Rows, field, values) };
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var local: [256]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&local, arena.allocator());

    const input: std.meta.Child(entry.Input) = .{
        .rows = @ptrCast(&frame),
        .count = values.len,
    };

    const result = zx.columns.invoke(entry.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    const count: usize = @intCast(result.count);
    const Tag = std.meta.Elem(@TypeOf(table.tags.items));

    for (result.tags[0..count]) |tag| table.tags.appendAssumeCapacity(@as(Tag, @fromBackingInt(@intCast(tag))));

    table.offsets.appendSliceAssumeCapacity(result.offsets[0..count]);

    if (count != values.len) return error.OutOfMemory;

    return @intCast(start);
}

/// A failed preparation ends the batch and lets the caller publish the completed prefix.
pub fn prepareDirectAstRow(handle: *anyopaque, position: u64) Error!u64 {
    const frame: *Frame = @ptrCast(@alignCast(handle));

    return switch (frame.rows) {
        inline else => |values, field| row: {
            const value = stored.copy(frame.storage, frame.allocator, values[@intCast(position)]) catch return std.math.maxInt(u64);
            const table = &@field(frame.storage, @tagName(field));
            const header = table.prepare(frame.allocator, value) catch return std.math.maxInt(u64);

            break :row @bitCast(Header{ .offset = header.offset, .tag = @backingInt(header.tag) });
        },
    };
}
