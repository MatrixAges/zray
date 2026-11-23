const std = @import("std");
pub const NamedId = struct { name: []const u8, id: u32 };
pub const NamedColumns = struct { names: []const []const u8, ids: []const u32 };

pub fn readNamedColumnName(source: *const anyopaque, index: u64) error{IndexOutOfBounds}![]const u8 {
    const columns: *const NamedColumns = @ptrCast(@alignCast(source));

    if (index >= columns.names.len) return error.IndexOutOfBounds;

    return columns.names[@intCast(index)];
}

pub fn readNamedColumnId(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!u32 {
    const columns: *const NamedColumns = @ptrCast(@alignCast(source));

    if (index >= columns.ids.len) return error.IndexOutOfBounds;

    return columns.ids[@intCast(index)];
}

pub fn allocateNamedRows(allocator: std.mem.Allocator, target: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    const output: *[]NamedId = @ptrCast(@alignCast(@constCast(target)));

    std.debug.assert(output.len == 0);

    output.* = try allocator.alloc(NamedId, std.math.cast(usize, count) orelse return error.OutOfMemory);
}

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

pub fn bindNamedRowView(source: *const anyopaque, index: u64, target: *const anyopaque) error{IndexOutOfBounds}!u64 {
    const rows: *[]const NamedId = @ptrCast(@alignCast(@constCast(target)));

    rows.* = try readColumn([]const NamedId, source, index);

    return rows.len;
}

pub inline fn borrowText(comptime field: []const u8, items: anytype) TextColumn {
    return borrowColumn([]const u8, field, items);
}

// The selected field may be inside a tagged union. Read it only on rows with the same active tag.
pub inline fn borrowProjectedText(items: anytype, sample: *const std.meta.Child(@TypeOf(items)), field: *const []const u8) TextColumn {
    const offset = @intFromPtr(field) - @intFromPtr(sample);
    const stride = @sizeOf(std.meta.Child(@TypeOf(items)));

    std.debug.assert(offset + @sizeOf([]const u8) <= stride);

    return .{ .bytes = std.mem.sliceAsBytes(items), .count = items.len, .stride = stride, .offset = offset };
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

pub inline fn borrowReferencedText(comptime field: []const u8, items: anytype) IndirectTextColumn {
    return borrowReferencedTextPath(&.{field}, items);
}

pub inline fn borrowReferencedTextPath(comptime fields: []const []const u8, items: anytype) IndirectTextColumn {
    const Pointer = std.meta.Child(@TypeOf(items));
    const info = @typeInfo(Pointer).pointer;
    const layout = comptime fieldLayout(info.child, fields);

    comptime {
        if (info.size != .one or info.attrs.@"allowzero" or layout.type != []const u8) @compileError("Expected references to rows with a text field");
    }

    return .{
        .pointers = .{ .bytes = std.mem.sliceAsBytes(items), .count = items.len, .stride = @sizeOf(Pointer), .offset = 0 },
        .text_offset = layout.offset,
    };
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
    return borrowListPath(T, &.{field}, members, items);
}

pub inline fn borrowListPath(comptime T: type, comptime fields: []const []const u8, comptime members: []const []const u8, items: anytype) ListColumn {
    const List = comptime fieldLayout(std.meta.Child(@TypeOf(items)), fields).type;
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

    return .{ .lists = borrowNested(List, fields, items), .stride = @sizeOf(Row), .offset = layout.offset };
}

pub fn bindSliceColumns(comptime View: type, comptime group: []const u8, items: anytype) [@typeInfo(View).@"struct".field_names.len]ReadColumn {
    const names = @typeInfo(View).@"struct".field_names;
    var result: [names.len]ReadColumn = undefined;

    inline for (names, &result) |name, *column| {
        column.* = borrowNested(@FieldType(View, name), &.{ group, name }, items);
    }

    return result;
}

inline fn sliceColumns(source: *const anyopaque) []const ReadColumn {
    const columns: *const []const ReadColumn = @ptrCast(@alignCast(source));

    return columns.*;
}

pub inline fn sliceColumnCount(source: *const anyopaque) u64 {
    return sliceColumns(source).len;
}

pub inline fn readSliceCell(source: *const anyopaque, buffer: *const anyopaque, layout: *const anyopaque, slot: u64, row: u64) error{IndexOutOfBounds}!void {
    const items = try readColumn([]const u8, &sliceColumns(source)[@intCast(slot)], row);

    @import("column_set.zig").writeViewCell(buffer, layout, slot, &items);
}

pub inline fn borrowOptionalList(comptime field: []const u8, comptime member: []const u8, items: anytype) ListColumn {
    const Optional = @FieldType(std.meta.Child(@TypeOf(items)), field);
    const Slice = @typeInfo(Optional).optional.child;
    const Row = std.meta.Child(Slice);

    comptime if (@typeInfo(Slice).pointer.size != .slice or @FieldType(Row, member) != []const u8) @compileError("Expected an optional slice with a text member");

    return .{
        .lists = borrowColumn(Optional, field, items),
        .stride = @sizeOf(Row),
        .offset = @offsetOf(Row, member),
    };
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

pub inline fn readOptionalTextList(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!?[]const []const u8 {
    return readColumn(?[]const []const u8, source, index);
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

pub inline fn readColumnOptionalBool(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!?bool {
    return readColumn(?bool, source, index);
}

pub inline fn readColumnI32(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!i32 {
    return readColumn(i32, source, index);
}

pub inline fn readColumnU16(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!u16 {
    return readColumn(u16, source, index);
}

pub inline fn readColumnU32(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!u32 {
    return readColumn(u32, source, index);
}

pub inline fn readColumnU64(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!u64 {
    return readColumn(u64, source, index);
}

pub inline fn readColumnU32List(source: *const anyopaque, index: u64) error{IndexOutOfBounds}![]const u32 {
    return readColumn([]const u32, source, index);
}

pub inline fn readColumnU64List(source: *const anyopaque, index: u64) error{IndexOutOfBounds}![]const u64 {
    return readColumn([]const u64, source, index);
}

pub inline fn readColumnU32Lists(source: *const anyopaque, index: u64) error{IndexOutOfBounds}![]const []const u32 {
    return readColumn([]const []const u32, source, index);
}

pub inline fn readFixedBytes(source: *const anyopaque, index: u64, width: u64) error{IndexOutOfBounds}![]const u8 {
    const column: *const ReadColumn = @ptrCast(@alignCast(source));

    if (index >= column.count or width > column.stride - column.offset) return error.IndexOutOfBounds;

    const first = @as(usize, @intCast(index)) * column.stride + column.offset;

    return column.bytes[first..][0..@intCast(width)];
}

pub inline fn readOptionalU64List(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!?[]const u64 {
    return readColumn(?[]const u64, source, index);
}

pub inline fn readColumnOptionalU32(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!?u32 {
    return readColumn(?u32, source, index);
}

pub inline fn readColumnOptionalU8(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!?u8 {
    return readColumn(?u8, source, index);
}

inline fn listProjection(projection: *const anyopaque) *const ListProjection {
    return @ptrCast(@alignCast(projection));
}

pub inline fn listProjectionSourceCount(projection: *const anyopaque) u64 {
    return listProjection(projection).sources.len;
}

pub inline fn listProjectionTargetCount(projection: *const anyopaque) u64 {
    return listProjection(projection).target.len;
}

pub inline fn requireColumnBounds(valid: bool) error{IndexOutOfBounds}!void {
    if (!valid) return error.IndexOutOfBounds;
}

pub inline fn projectListCell(projection: *const anyopaque, slot: u64, row: u64) error{IndexOutOfBounds}!void {
    const view = listProjection(projection);
    const column: usize = @intCast(slot);

    view.target[column] = try listColumn(&view.sources[column], row);
}

pub inline fn columnLength(source: *const anyopaque) u64 {
    const column: *const ReadColumn = @ptrCast(@alignCast(source));

    return column.count;
}

pub inline fn listLength(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!u64 {
    const column: *const ListColumn = @ptrCast(@alignCast(source));

    return (try readColumn([]const u8, &column.lists, index)).len;
}

pub inline fn optionalListLength(source: *const anyopaque, index: u64) error{IndexOutOfBounds}!?u64 {
    const column: *const ListColumn = @ptrCast(@alignCast(source));
    const list = try readColumn(?[]const u8, &column.lists, index) orelse return null;

    return list.len;
}

pub inline fn readOptionalTextListItem(source: *const anyopaque, index: u64, member: u64) error{IndexOutOfBounds}![]const u8 {
    const column: *const ListColumn = @ptrCast(@alignCast(source));
    const list = try readColumn(?[]const u8, &column.lists, index) orelse return error.IndexOutOfBounds;

    return readColumn([]const u8, &listItems(column, list), member);
}

pub inline fn readListText(source: *const anyopaque, index: u64, member: u64) error{IndexOutOfBounds}![]const u8 {
    const column = try listColumn(source, index);

    return readColumn([]const u8, &column, member);
}

pub inline fn readListOptionalText(source: *const anyopaque, index: u64, member: u64) error{IndexOutOfBounds}!?[]const u8 {
    const column = try listColumn(source, index);

    return readColumn(?[]const u8, &column, member);
}

pub inline fn borrowListBytes(source: *const anyopaque, index: u64) error{IndexOutOfBounds}![]const u8 {
    const column = try listColumn(source, index);

    return if (column.count == 0) &.{} else column.bytes[column.offset..];
}

pub inline fn readListBool(source: *const anyopaque, index: u64, member: u64) error{IndexOutOfBounds}!bool {
    const column = try listColumn(source, index);

    return readColumn(bool, &column, member);
}

pub inline fn readListIndex(source: *const anyopaque, index: u64, member: u64) error{IndexOutOfBounds}!u64 {
    const column = try listColumn(source, index);

    return try readColumn(usize, &column, member);
}

pub inline fn readListU32(source: *const anyopaque, index: u64, member: u64) error{IndexOutOfBounds}!u32 {
    const column = try listColumn(source, index);

    return readColumn(u32, &column, member);
}

pub inline fn readListU8(source: *const anyopaque, index: u64, member: u64) error{IndexOutOfBounds}!u8 {
    const column = try listColumn(source, index);

    return readColumn(u8, &column, member);
}

pub inline fn readListU64(source: *const anyopaque, index: u64, member: u64) error{IndexOutOfBounds}!u64 {
    const column = try listColumn(source, index);

    return readColumn(u64, &column, member);
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

    return listItems(column, list);
}

inline fn listItems(column: *const ListColumn, list: []const u8) ReadColumn {
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
