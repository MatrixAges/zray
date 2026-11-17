const std = @import("std");
const IndexError = error{IndexOutOfBounds};

pub const Column = struct {
    items: [*]u8,
    count: usize,
    stride: usize,
    width: usize,
};

/// The caller lends a mutable field of each row exclusively until the generated call returns.
pub inline fn borrow(comptime T: type, comptime field: []const u8, rows: anytype) Column {
    return borrowNested(T, &.{field}, rows);
}

pub inline fn borrowNested(comptime T: type, comptime fields: []const []const u8, rows: anytype) Column {
    const Row = std.meta.Child(@TypeOf(rows));
    const layout = comptime @import("rows.zig").fieldLayout(Row, fields);
    const Field = layout.type;

    comptime {
        if (@sizeOf(Field) != @sizeOf(T) or @alignOf(Field) != @alignOf(T)) {
            @compileError("Incompatible strided column field");
        }
    }

    const bytes: [*]u8 = @ptrCast(rows.ptr);

    return .{
        .items = if (rows.len == 0) bytes else bytes + layout.offset,
        .count = rows.len,
        .stride = @sizeOf(Row),
        .width = @sizeOf(T),
    };
}

pub inline fn writeU8(target: *const anyopaque, index: u64, value: u8) IndexError!void {
    return write(u8, target, index, value);
}

pub inline fn writeU32(target: *const anyopaque, index: u64, value: u32) IndexError!void {
    return write(u32, target, index, value);
}

pub inline fn writeU64(target: *const anyopaque, index: u64, value: u64) IndexError!void {
    return write(u64, target, index, value);
}

pub inline fn writeBytes(target: *const anyopaque, index: u64, value: []const u8) IndexError!void {
    return write([]const u8, target, index, value);
}

pub inline fn writeOptionalU32(target: *const anyopaque, index: u64, value: ?u32) IndexError!void {
    return write(?u32, target, index, value);
}

pub inline fn writeOptionalU8(target: *const anyopaque, index: u64, value: ?u8) IndexError!void {
    return write(?u8, target, index, value);
}

pub inline fn writeOptionalText(target: *const anyopaque, index: u64, value: ?[]const u8) IndexError!void {
    return write(?[]const u8, target, index, value);
}

pub inline fn writeTextList(target: *const anyopaque, index: u64, value: []const []const u8) IndexError!void {
    return write([]const []const u8, target, index, value);
}

pub inline fn write(comptime T: type, target: *const anyopaque, index: u64, value: T) IndexError!void {
    const column: *const Column = @ptrCast(@alignCast(target));

    if (index >= column.count or column.width != @sizeOf(T)) return error.IndexOutOfBounds;

    const address = column.items + @as(usize, @intCast(index)) * column.stride;

    @as(*align(1) T, @ptrCast(address)).* = value;
}
