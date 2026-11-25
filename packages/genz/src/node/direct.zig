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
    tags: []u8 = &.{},
    offsets: []u32 = &.{},
};

pub fn append(storage: *Storage, allocator: std.mem.Allocator, comptime field: []const u8, values: anytype) Error!u32 {
    const entry = @import("generated_direct_ast_range");
    const table = &@field(storage, field);

    if (values.len == 0) return @intCast(table.tags.items.len);

    var frame: Frame = .{ .storage = storage, .allocator = allocator, .rows = @unionInit(Rows, field, values) };
    const lengths: zx.memory.ColumnLengths = &.{ &table.tags.items.len, &table.offsets.items.len };

    const input: std.meta.Child(entry.Input) = .{
        .rows = @ptrCast(&frame),
        .start = table.tags.items.len,
        .count = values.len,
        .tags = @ptrCast(&frame.tags),
        .offsets = @ptrCast(&frame.offsets),
        .lengths = @ptrCast(&lengths),
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}

pub fn prepareDirectAstRow(handle: *anyopaque, position: u64) Error!u64 {
    const frame: *Frame = @ptrCast(@alignCast(handle));

    return switch (frame.rows) {
        inline else => |values, field| row: {
            const value = try stored.copy(frame.storage, frame.allocator, values[@intCast(position)]);
            const table = &@field(frame.storage, @tagName(field));
            const header = try table.prepare(frame.allocator, value);
            frame.tags = std.mem.sliceAsBytes(table.tags.unusedCapacitySlice()[0..1]);
            frame.offsets = table.offsets.unusedCapacitySlice()[0..1];

            break :row @bitCast(Header{ .offset = header.offset, .tag = @backingInt(header.tag) });
        },
    };
}
