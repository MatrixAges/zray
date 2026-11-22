const std = @import("std");
const Bytes = []const u8;
const Kind = enum { value, strided, repeated, text, optional_text, words, texts, optional_texts, text_views, optional_text_views };

pub const Column = struct {
    source: [*]const u8,
    source_count: usize,
    storage: *std.ArrayList(u8),
    width: usize,
    stride: u32 = 0,
    kind: Kind,
    grow: *const fn (*anyopaque, std.mem.Allocator, usize) std.mem.Allocator.Error!void,
};

pub const Groups = []const []const Column;

pub fn bind(target: anytype, source: anytype, comptime copy_payloads: bool, comptime borrow_text: bool) Column {
    const Value = std.meta.Elem(@TypeOf(target.items));

    comptime {
        const Storage = std.meta.Child(@TypeOf(target));
        const Erased = std.ArrayList(u8);

        std.debug.assert(@sizeOf(Storage) == @sizeOf(Erased) and @alignOf(Storage) == @alignOf(Erased));
        std.debug.assert(@offsetOf(Storage, "items") == @offsetOf(Erased, "items"));
        std.debug.assert(@offsetOf(Storage, "capacity") == @offsetOf(Erased, "capacity"));
    }

    return .{
        .source = @ptrCast(source.ptr),
        .source_count = source.len,
        .storage = @ptrCast(target),
        .width = @sizeOf(Value),
        .kind = comptime kind(Value, copy_payloads, borrow_text),
        .grow = struct {
            fn ensure(storage: *anyopaque, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
                const column: *std.ArrayList(Value) = @ptrCast(@alignCast(storage));

                return column.ensureUnusedCapacity(allocator, additional);
            }
        }.ensure,
    };
}

pub fn borrowRowField(target: anytype, comptime name: []const u8, rows: anytype) Column {
    const Row = std.meta.Elem(@TypeOf(rows));
    const Value = std.meta.Elem(@TypeOf(target.items));

    comptime std.debug.assert(@FieldType(Row, name) == Value);

    var column = bind(target, @as([]const Value, &.{}), false, true);
    const bytes: [*]const u8 = @ptrCast(rows.ptr);
    column.source = if (rows.len == 0) bytes else bytes + @offsetOf(Row, name);
    column.source_count = rows.len;
    column.stride = @sizeOf(Row);
    column.kind = .strided;

    return column;
}

pub fn repeat(target: anytype, value: anytype) Column {
    const Value = std.meta.Elem(@TypeOf(target.items));
    var column = bind(target, @as(*const [1]Value, @ptrCast(value))[0..], false, false);

    column.kind = .repeated;

    return column;
}

pub fn matches(target: *const anyopaque, index: u64, count: u64) bool {
    for (group(target, index)) |column| {
        if (column.width != 0 and column.kind != .repeated and column.source_count != count) return false;
    }

    return true;
}

pub fn minimumLength(target: *const anyopaque, index: u64) u64 {
    var length: u64 = std.math.maxInt(u64);

    for (group(target, index)) |column| {
        if (column.width != 0 and column.kind != .repeated) {
            length = @min(length, column.source_count);
        }
    }

    return length;
}

fn kind(comptime Value: type, comptime copy_payloads: bool, comptime borrow_text: bool) Kind {
    if (!copy_payloads) return .value;
    if (Value == Bytes) return if (borrow_text) .value else .text;
    if (Value == ?Bytes) return if (borrow_text) .value else .optional_text;
    if (Value == []const Bytes) return if (borrow_text) .text_views else .texts;
    if (Value == ?[]const Bytes) return if (borrow_text) .optional_text_views else .optional_texts;

    const info = @typeInfo(Value);

    if (info == .pointer and info.pointer.size == .slice) {
        const Element = info.pointer.child;

        if (Element == u32 or (@typeInfo(Element) == .@"enum" and @typeInfo(Element).@"enum".tag_type == u32)) return .words;

        @compileError("Unsupported owned column element " ++ @typeName(Value));
    }

    if (info == .optional and @typeInfo(info.optional.child) == .pointer) @compileError("Unsupported owned optional column element " ++ @typeName(Value));

    return .value;
}

pub fn copy(resource: *const anyopaque, target: *const anyopaque, index: u64, first: u64, count: u64) bool {
    if (count == 0) return true;

    const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(resource));
    const fields = group(target, index);
    const start: usize = @intCast(first);
    const length: usize = @intCast(count);

    for (fields, 0..) |column, field| {
        copyColumn(allocator.*, column, start, length) catch {
            discardColumns(allocator.*, fields[0..field], length);

            return false;
        };
    }

    return true;
}

pub fn reserve(resource: *const anyopaque, target: *const anyopaque, index: u64, count: u64) std.mem.Allocator.Error!u64 {
    const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(resource));
    const fields = group(target, index);
    const length = std.math.cast(usize, count) orelse return error.OutOfMemory;

    for (fields) |column| {
        if (length > column.storage.capacity - column.storage.items.len) {
            try column.grow(column.storage, allocator.*, length);
        }
    }

    return fields[0].storage.items.len;
}

pub fn discard(resource: *const anyopaque, target: *const anyopaque, index: u64, count: u64) void {
    if (count == 0) return;

    const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(resource));

    discardColumns(allocator.*, group(target, index), @intCast(count));
}

pub fn publish(target: *const anyopaque, index: u64, count: u64) void {
    if (count == 0) return;
    for (group(target, index)) |column| column.storage.items.len += @intCast(count);
}

fn group(target: *const anyopaque, index: u64) []const Column {
    const groups: *const Groups = @ptrCast(@alignCast(target));

    return groups.*[@intCast(index)];
}

fn copyColumn(allocator: std.mem.Allocator, column: Column, first: usize, count: usize) std.mem.Allocator.Error!void {
    switch (column.kind) {
        .value => {
            if (column.width == 0) return;

            const source = column.source[first * column.width ..][0 .. count * column.width];
            const target = column.storage.items.ptr[column.storage.items.len * column.width ..][0..source.len];

            @memcpy(target, source);
        },
        .strided => {
            const target = column.storage.items.ptr[column.storage.items.len * column.width ..];
            const stride: usize = column.stride;
            const source = column.source[first * stride ..];

            for (0..count) |index| {
                @memcpy(target[index * column.width ..][0..column.width], source[index * stride ..][0..column.width]);
            }
        },
        .repeated => {
            const source = column.source[0..column.width];
            const target = column.storage.items.ptr[column.storage.items.len * column.width ..];

            for (0..count) |index| @memcpy(target[index * column.width ..][0..column.width], source);
        },
        .text => try cloneRange(Bytes, false, allocator, column, first, count),
        .optional_text => try cloneRange(?Bytes, false, allocator, column, first, count),
        .words => try cloneRange([]const u32, false, allocator, column, first, count),
        .texts => try cloneRange([]const Bytes, false, allocator, column, first, count),
        .optional_texts => try cloneRange(?[]const Bytes, false, allocator, column, first, count),
        .text_views => try cloneRange([]const Bytes, true, allocator, column, first, count),
        .optional_text_views => try cloneRange(?[]const Bytes, true, allocator, column, first, count),
    }
}

fn discardColumns(allocator: std.mem.Allocator, columns: []const Column, count: usize) void {
    var iterator = std.mem.reverseIterator(columns);

    while (iterator.next()) |column| switch (column.kind) {
        .value, .strided, .repeated => {},
        .text => releaseRange(Bytes, false, allocator, column, count),
        .optional_text => releaseRange(?Bytes, false, allocator, column, count),
        .words => releaseRange([]const u32, false, allocator, column, count),
        .texts => releaseRange([]const Bytes, false, allocator, column, count),
        .optional_texts => releaseRange(?[]const Bytes, false, allocator, column, count),
        .text_views => releaseRange([]const Bytes, true, allocator, column, count),
        .optional_text_views => releaseRange(?[]const Bytes, true, allocator, column, count),
    };
}

fn cloneRange(comptime Value: type, comptime borrow_text: bool, allocator: std.mem.Allocator, column: Column, first: usize, count: usize) std.mem.Allocator.Error!void {
    const source: [*]const Value = @ptrCast(@alignCast(column.source));
    const target: [*]Value = @ptrCast(@alignCast(column.storage.items.ptr));
    const tail = target[column.storage.items.len..][0..count];
    var copied: usize = 0;

    errdefer for (tail[0..copied]) |value| release(allocator, value, borrow_text);

    for (source[first..][0..count], tail) |value, *slot| {
        slot.* = try clone(allocator, value, borrow_text);
        copied += 1;
    }
}

fn releaseRange(comptime Value: type, comptime borrow_text: bool, allocator: std.mem.Allocator, column: Column, count: usize) void {
    const target: [*]const Value = @ptrCast(@alignCast(column.storage.items.ptr));

    for (target[column.storage.items.len..][0..count]) |value| release(allocator, value, borrow_text);
}

fn clone(allocator: std.mem.Allocator, value: anytype, comptime borrow_text: bool) std.mem.Allocator.Error!@TypeOf(value) {
    const Value = @TypeOf(value);

    if (comptime borrow_text and Value == Bytes) return value;

    return switch (@typeInfo(Value)) {
        .optional => if (value) |item| try clone(allocator, item, borrow_text) else null,
        .pointer => |pointer| if (@typeInfo(pointer.child) != .pointer or borrow_text)
            try allocator.dupe(pointer.child, value)
        else copy: {
            const output = try allocator.alloc(pointer.child, value.len);
            var initialized: usize = 0;

            errdefer {
                for (output[0..initialized]) |item| release(allocator, item, borrow_text);

                allocator.free(output);
            }

            for (value, output) |item, *slot| {
                slot.* = try clone(allocator, item, borrow_text);
                initialized += 1;
            }

            break :copy output;
        },
        else => unreachable,
    };
}

fn release(allocator: std.mem.Allocator, value: anytype, comptime borrow_text: bool) void {
    if (comptime borrow_text and @TypeOf(value) == Bytes) return;

    switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |item| release(allocator, item, borrow_text),
        .pointer => |pointer| {
            if (@typeInfo(pointer.child) == .pointer and !borrow_text) for (value) |item| release(allocator, item, borrow_text);

            allocator.free(value);
        },
        else => unreachable,
    }
}
