const std = @import("std");
pub const NamedId = struct { name: []const u8, id: u32 };

pub const ReadColumn = struct {
    bytes: []const u8,
    count: usize,
    stride: usize,
    offset: usize,
};

pub const TextColumn = ReadColumn;

pub inline fn borrow(comptime id: []const u8, items: anytype) if (@typeInfo(@TypeOf(items)).pointer.attrs.@"const") []const NamedId else []NamedId {
    const Item = std.meta.Child(@TypeOf(items));
    const Field = @FieldType(Item, id);
    const Raw = if (@typeInfo(Field) == .@"enum") @typeInfo(Field).@"enum".tag_type else Field;

    comptime {
        if (@sizeOf(Item) != @sizeOf(NamedId) or @alignOf(Item) != @alignOf(NamedId) or
            @FieldType(Item, "name") != []const u8 or Raw != u32 or
            @offsetOf(Item, "name") != @offsetOf(NamedId, "name") or
            @offsetOf(Item, id) != @offsetOf(NamedId, "id"))
        {
            @compileError("Incompatible layout for borrowing name and ID rows");
        }
    }

    return @ptrCast(items);
}

pub inline fn readName(source: *const anyopaque, index: u64) error{IndexOutOfBounds}![]const u8 {
    return (try read(source, index)).name;
}

pub inline fn readId(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!u32 {
    return (try read(source, index)).id;
}

pub inline fn borrowText(comptime field: []const u8, items: anytype) TextColumn {
    return borrowColumn([]const u8, field, items);
}

pub inline fn borrowColumn(comptime T: type, comptime field: []const u8, items: anytype) ReadColumn {
    const Item = std.meta.Child(@TypeOf(items));

    comptime if (@FieldType(Item, field) != T) @compileError("Incompatible borrowed column field");

    return .{ .bytes = std.mem.sliceAsBytes(items), .count = items.len, .stride = @sizeOf(Item), .offset = @offsetOf(Item, field) };
}

pub inline fn readText(source: *const anyopaque, index: u64) error{IndexOutOfBounds}![]const u8 {
    return readColumn([]const u8, source, index);
}

pub inline fn readColumnI32(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!i32 {
    return readColumn(i32, source, index);
}

pub inline fn readColumnU64(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!u64 {
    return readColumn(u64, source, index);
}

inline fn readColumn(comptime T: type, source: *const anyopaque, index: u64) error{IndexOutOfBounds}!T {
    const column: *const ReadColumn = @ptrCast(@alignCast(source));

    if (index >= column.count) return error.IndexOutOfBounds;

    const item = column.bytes.ptr + @as(usize, @intCast(index)) * column.stride + column.offset;

    return @as(*align(1) const T, @ptrCast(item)).*;
}

pub inline fn write(target: *const anyopaque, index: u64, name: []const u8, id: u32) error{IndexOutOfBounds}!void {
    const rows: *const []NamedId = @ptrCast(@alignCast(target));

    if (index >= rows.len) return error.IndexOutOfBounds;

    rows.*[@intCast(index)] = .{ .name = name, .id = id };
}

inline fn read(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!*const NamedId {
    const rows: *const []const NamedId = @ptrCast(@alignCast(source));

    if (index >= rows.len) return error.IndexOutOfBounds;

    return &rows.*[@intCast(index)];
}
