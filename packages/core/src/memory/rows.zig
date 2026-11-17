const std = @import("std");
pub const NamedId = struct { name: []const u8, id: u32 };

pub const ReadColumn = struct {
    bytes: []const u8,
    count: usize,
    stride: usize,
    offset: usize,
};

pub const TextColumn = ReadColumn;

pub const IndirectTextColumn = struct {
    pointers: ReadColumn,
    text_offset: usize,
};

pub const ListColumn = struct {
    lists: ReadColumn,
    stride: usize,
    offset: usize,
};

pub const ListProjection = struct {
    sources: []const ListColumn,
    target: []ReadColumn,
};

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

pub inline fn borrowTextSlice(items: []const []const u8) TextColumn {
    return .{ .bytes = std.mem.sliceAsBytes(items), .count = items.len, .stride = @sizeOf([]const u8), .offset = 0 };
}

/// Non-null pointers must keep their text fields alive for the life of this view.
pub inline fn borrowIndirectText(comptime field: []const u8, comptime text: []const u8, items: anytype) IndirectTextColumn {
    const Item = std.meta.Child(@TypeOf(items));
    const Optional = @FieldType(Item, field);
    const Pointer = @typeInfo(Optional).optional.child;
    const target = @typeInfo(Pointer).pointer;

    comptime {
        if (target.size != .one or target.attrs.@"allowzero" or @FieldType(target.child, text) != []const u8) {
            @compileError("Incompatible indirect text field");
        }
    }

    return .{ .pointers = borrowColumn(Optional, field, items), .text_offset = @offsetOf(target.child, text) };
}

pub inline fn borrowColumn(comptime T: type, comptime field: []const u8, items: anytype) ReadColumn {
    return borrowNested(T, &.{field}, items);
}

pub inline fn borrowNested(comptime T: type, comptime fields: []const []const u8, items: anytype) ReadColumn {
    const Item = std.meta.Child(@TypeOf(items));
    const layout = comptime fieldLayout(Item, fields);

    comptime if (layout.type != T) @compileError("Incompatible borrowed column field");

    return .{ .bytes = std.mem.sliceAsBytes(items), .count = items.len, .stride = @sizeOf(Item), .offset = layout.offset };
}

pub inline fn borrowOptionalU32(comptime field: []const u8, items: anytype) ReadColumn {
    return borrowOptional(u32, field, items);
}

pub inline fn borrowOptionalU8(comptime field: []const u8, items: anytype) ReadColumn {
    return borrowOptional(u8, field, items);
}

inline fn borrowOptional(comptime T: type, comptime field: []const u8, items: anytype) ReadColumn {
    const Field = @FieldType(std.meta.Child(@TypeOf(items)), field);

    comptime requireOptional(T, Field);

    return borrowColumn(Field, field, items);
}

pub inline fn borrowList(comptime T: type, comptime field: []const u8, comptime member: []const u8, items: anytype) ListColumn {
    return borrowNestedList(T, field, &.{member}, items);
}

pub inline fn borrowNestedList(comptime T: type, comptime field: []const u8, comptime members: []const []const u8, items: anytype) ListColumn {
    const List = @FieldType(std.meta.Child(@TypeOf(items)), field);
    const Row = std.meta.Child(List);
    const layout = comptime fieldLayout(Row, members);

    comptime {
        if (@typeInfo(List).pointer.size != .slice) @compileError("Expected a slice field");

        if (T == ?u32 or T == ?u8) {
            requireOptional(@typeInfo(T).optional.child, layout.type);
        } else if (layout.type != T) {
            @compileError("Incompatible borrowed list column field");
        }
    }

    return .{ .lists = borrowColumn(List, field, items), .stride = @sizeOf(Row), .offset = layout.offset };
}

pub inline fn borrowSliceColumn(comptime fields: []const []const u8, items: anytype) ListColumn {
    const layout = comptime fieldLayout(std.meta.Child(@TypeOf(items)), fields);
    const List = layout.type;

    comptime if (@typeInfo(List).pointer.size != .slice) @compileError("Expected a slice field");

    return .{
        .lists = borrowNested(List, fields, items),
        .stride = @sizeOf(std.meta.Child(List)),
        .offset = 0,
    };
}

pub fn fieldLayout(comptime Item: type, comptime fields: []const []const u8) struct { type: type, offset: usize } {
    var current = Item;
    var offset: usize = 0;

    for (fields) |field| {
        offset += @offsetOf(current, field);
        current = @FieldType(current, field);
    }

    return .{ .type = current, .offset = offset };
}

fn requireOptional(comptime T: type, comptime Field: type) void {
    const Value = @typeInfo(Field).optional.child;
    const Raw = if (@typeInfo(Value) == .@"enum") @typeInfo(Value).@"enum".tag_type else Value;

    if (Raw != T or @sizeOf(Field) != @sizeOf(?T) or @alignOf(Field) != @alignOf(?T)) {
        @compileError("Incompatible optional integer column");
    }
}

pub inline fn readText(source: *const anyopaque, index: u64) error{IndexOutOfBounds}![]const u8 {
    return readColumn([]const u8, source, index);
}

pub inline fn readOptionalText(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!?[]const u8 {
    return readColumn(?[]const u8, source, index);
}

pub inline fn readTextList(source: *const anyopaque, index: u64) error{IndexOutOfBounds}![]const []const u8 {
    return readColumn([]const []const u8, source, index);
}

pub inline fn readIndirectText(source: *const anyopaque, index: u64) error{ IndexOutOfBounds, MissingField }![]const u8 {
    return (try readOptionalIndirectText(source, index)) orelse error.MissingField;
}

pub inline fn readOptionalIndirectText(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!?[]const u8 {
    const column: *const IndirectTextColumn = @ptrCast(@alignCast(source));
    const item = try readColumn(?[*]const u8, &column.pointers, index) orelse return null;

    return @as(*align(1) const []const u8, @ptrCast(item + column.text_offset)).*;
}

pub inline fn readColumnU8(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!u8 {
    return readColumn(u8, source, index);
}

pub inline fn readColumnBool(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!bool {
    return readColumn(bool, source, index);
}

pub inline fn readColumnI32(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!i32 {
    return readColumn(i32, source, index);
}

pub inline fn readColumnU32(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!u32 {
    return readColumn(u32, source, index);
}

pub inline fn readColumnU64(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!u64 {
    return readColumn(u64, source, index);
}

pub inline fn readColumnOptionalU32(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!?u32 {
    return readColumn(?u32, source, index);
}

pub inline fn readColumnOptionalU8(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!?u8 {
    return readColumn(?u8, source, index);
}

pub inline fn projectListColumns(projection: *const anyopaque, index: u64) error{IndexOutOfBounds}!void {
    const view: *const ListProjection = @ptrCast(@alignCast(projection));

    if (view.sources.len != view.target.len) return error.IndexOutOfBounds;

    for (view.sources, view.target) |*source, *column| {
        column.* = try listColumn(source, index);
    }
}

pub inline fn columnLength(source: *const anyopaque) u64 {
    const column: *const ReadColumn = @ptrCast(@alignCast(source));

    return column.count;
}

pub inline fn listLength(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!u64 {
    const column: *const ListColumn = @ptrCast(@alignCast(source));

    return (try readColumn([]const u8, &column.lists, index)).len;
}

pub inline fn readListText(source: *const anyopaque, index: u64, member: u64) error{IndexOutOfBounds}![]const u8 {
    const column = try listColumn(source, index);

    return readColumn([]const u8, &column, member);
}

pub inline fn borrowListBytes(source: *const anyopaque, index: u64) error{IndexOutOfBounds}![]const u8 {
    const column = try listColumn(source, index);

    return if (column.count == 0) &.{} else column.bytes[column.offset..];
}

pub inline fn readListOptionalU32(source: *const anyopaque, index: u64, member: u64) error{IndexOutOfBounds}!?u32 {
    const column = try listColumn(source, index);

    return readColumn(?u32, &column, member);
}

pub inline fn readListOptionalU8(source: *const anyopaque, index: u64, member: u64) error{IndexOutOfBounds}!?u8 {
    const column = try listColumn(source, index);

    return readColumn(?u8, &column, member);
}

inline fn listColumn(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!ReadColumn {
    const column: *const ListColumn = @ptrCast(@alignCast(source));
    const list = try readColumn([]const u8, &column.lists, index);

    return .{
        .bytes = list.ptr[0 .. list.len * column.stride],
        .count = list.len,
        .stride = column.stride,
        .offset = column.offset,
    };
}

pub inline fn readColumn(comptime T: type, source: *const anyopaque, index: u64) error{IndexOutOfBounds}!T {
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
