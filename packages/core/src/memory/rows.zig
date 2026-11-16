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
    const Item = std.meta.Child(@TypeOf(items));

    comptime if (@FieldType(Item, field) != T) @compileError("Incompatible borrowed column field");

    return .{ .bytes = std.mem.sliceAsBytes(items), .count = items.len, .stride = @sizeOf(Item), .offset = @offsetOf(Item, field) };
}

pub inline fn borrowOptionalU32(comptime field: []const u8, items: anytype) ReadColumn {
    const Field = @FieldType(std.meta.Child(@TypeOf(items)), field);

    comptime requireOptionalU32(Field);

    return borrowColumn(Field, field, items);
}

pub inline fn borrowList(comptime T: type, comptime field: []const u8, comptime member: []const u8, items: anytype) ListColumn {
    const List = @FieldType(std.meta.Child(@TypeOf(items)), field);
    const Row = std.meta.Child(List);
    const Field = @FieldType(Row, member);

    comptime {
        if (@typeInfo(List).pointer.size != .slice) @compileError("Expected a slice field");

        if (T == ?u32) {
            requireOptionalU32(Field);
        } else if (Field != T) {
            @compileError("Incompatible borrowed list column field");
        }
    }

    return .{ .lists = borrowColumn(List, field, items), .stride = @sizeOf(Row), .offset = @offsetOf(Row, member) };
}

fn requireOptionalU32(comptime Field: type) void {
    const Value = @typeInfo(Field).optional.child;
    const Raw = if (@typeInfo(Value) == .@"enum") @typeInfo(Value).@"enum".tag_type else Value;

    if (Raw != u32 or @sizeOf(Field) != @sizeOf(?u32) or @alignOf(Field) != @alignOf(?u32)) {
        @compileError("Incompatible optional u32 column");
    }
}

pub inline fn readText(source: *const anyopaque, index: u64) error{IndexOutOfBounds}![]const u8 {
    return readColumn([]const u8, source, index);
}

pub inline fn readOptionalText(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!?[]const u8 {
    return readColumn(?[]const u8, source, index);
}

pub inline fn readIndirectText(source: *const anyopaque, index: u64) error{ IndexOutOfBounds, MissingField }![]const u8 {
    return (try readOptionalIndirectText(source, index)) orelse error.MissingField;
}

pub inline fn readOptionalIndirectText(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!?[]const u8 {
    const column: *const IndirectTextColumn = @ptrCast(@alignCast(source));
    const item = try readColumn(?[*]const u8, &column.pointers, index) orelse return null;

    return @as(*align(1) const []const u8, @ptrCast(item + column.text_offset)).*;
}

pub inline fn readColumnBool(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!bool {
    return readColumn(bool, source, index);
}

pub inline fn readColumnI32(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!i32 {
    return readColumn(i32, source, index);
}

pub inline fn readColumnU64(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!u64 {
    return readColumn(u64, source, index);
}

pub inline fn readColumnOptionalU32(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!?u32 {
    return readColumn(?u32, source, index);
}

pub inline fn listLength(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!u64 {
    const column: *const ListColumn = @ptrCast(@alignCast(source));

    return (try readColumn([]const u8, &column.lists, index)).len;
}

pub inline fn readListText(source: *const anyopaque, index: u64, member: u64) error{IndexOutOfBounds}![]const u8 {
    const column = try listColumn(source, index);

    return readColumn([]const u8, &column, member);
}

pub inline fn readListOptionalU32(source: *const anyopaque, index: u64, member: u64) error{IndexOutOfBounds}!?u32 {
    const column = try listColumn(source, index);

    return readColumn(?u32, &column, member);
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
