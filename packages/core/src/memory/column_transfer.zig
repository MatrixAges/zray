const std = @import("std");
const column_set = @import("column_set.zig");
const Bytes = []const u8;
const Kind = enum { value, strided, repeated, text, optional_text, words, texts, optional_texts, text_views, optional_text_views };

pub const Column = struct {
    source: [*]const u8,
    source_count: usize,
    storage: *std.ArrayList(u8),
    width: usize,
    stride: u32 = 0,
    kind: Kind,
    grow: *const fn (*anyopaque, std.mem.Allocator, usize) bool,
    pub fn sourceLength(self: Column) ?u64 {
        return if (self.width != 0 and self.kind != .repeated) self.source_count else null;
    }
};

pub const Groups = []const []const Column;

pub fn bind(target: anytype, source: anytype, comptime copy_payloads: bool, comptime borrow_text: bool) Column {
    const Value = std.meta.Elem(@TypeOf(target.items));

    return .{
        .source = @ptrCast(source.ptr),
        .source_count = source.len,
        .storage = column_set.erase(target),
        .width = @sizeOf(Value),
        .kind = comptime kind(Value, copy_payloads, borrow_text),
        .grow = struct {
            fn ensure(storage: *anyopaque, allocator: std.mem.Allocator, additional: usize) bool {
                const column: *std.ArrayList(Value) = @ptrCast(@alignCast(storage));

                column.ensureUnusedCapacity(allocator, additional) catch return false;

                return true;
            }
        }.ensure,
    };
}

pub fn borrowRowField(target: anytype, comptime name: []const u8, rows: anytype) Column {
    const Row = std.meta.Elem(@TypeOf(rows));
    const Value = std.meta.Elem(@TypeOf(target.items));
    const Field = @FieldType(Row, name);

    comptime std.debug.assert(@sizeOf(Field) == @sizeOf(Value) and @alignOf(Field) == @alignOf(Value));

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

pub fn borrowGroup(target: *const anyopaque, index: u64, shape: anytype) std.meta.Child(@TypeOf(shape)) {
    const groups: *const Groups = @ptrCast(@alignCast(target));

    return @ptrCast(&groups.*[@intCast(index)]);
}

fn groupColumns(target: *const anyopaque) []const Column {
    return (@as(*const []const Column, @ptrCast(@alignCast(target)))).*;
}

pub fn countColumns(target: *const anyopaque) u64 {
    return groupColumns(target).len;
}

pub fn ownsPayload(target: *const anyopaque, index: u64) bool {
    return switch (groupColumns(target)[@intCast(index)].kind) {
        .value, .strided, .repeated => false,
        else => true,
    };
}

pub fn ownsTextItems(target: *const anyopaque, index: u64) bool {
    return switch (groupColumns(target)[@intCast(index)].kind) {
        .texts, .optional_texts => true,
        else => false,
    };
}

pub inline fn textList(target: *const anyopaque, index: u64, row: u64, staged: bool) ?[]const Bytes {
    const column = groupColumns(target)[@intCast(index)];
    const address = if (staged) column.storage.items.ptr else column.source;
    const item: usize = @intCast(row);
    const offset = if (staged) column.storage.items.len + item else item;

    return switch (column.kind) {
        .texts => @as([*]const []const Bytes, @ptrCast(@alignCast(address)))[offset],
        .optional_texts => @as([*]const ?[]const Bytes, @ptrCast(@alignCast(address)))[offset],
        else => unreachable,
    };
}

pub fn writeTextList(target: *const anyopaque, index: u64, row: u64, value: ?[]const Bytes) void {
    const column = groupColumns(target)[@intCast(index)];
    const address = column.storage.items.ptr;
    const offset = column.storage.items.len + @as(usize, @intCast(row));

    switch (column.kind) {
        .texts => @as([*][]const Bytes, @ptrCast(@alignCast(address)))[offset] = value.?,
        .optional_texts => @as([*]?[]const Bytes, @ptrCast(@alignCast(address)))[offset] = value,
        else => unreachable,
    }
}

pub fn reserveOne(resource: *const anyopaque, target: *const anyopaque, index: u64, count: u64) std.mem.Allocator.Error!u64 {
    const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(resource));
    const length = std.math.cast(usize, count) orelse return error.OutOfMemory;

    return reserveColumn(allocator.*, groupColumns(target)[@intCast(index)], length);
}

fn reserveColumn(allocator: std.mem.Allocator, column: Column, count: usize) std.mem.Allocator.Error!usize {
    if (count > column.storage.capacity - column.storage.items.len) {
        if (!column.grow(column.storage, allocator, count)) return error.OutOfMemory;
    }

    return column.storage.items.len;
}

pub fn publishOne(target: *const anyopaque, index: u64, count: u64) void {
    groupColumns(target)[@intCast(index)].storage.items.len += @intCast(count);
}

pub inline fn layout(target: *const anyopaque, index: u64, shape: anytype) std.meta.Child(@TypeOf(shape)) {
    return switch (groupColumns(target)[@intCast(index)].kind) {
        .value => .Contiguous,
        .strided, .repeated => .Projected,
        else => .Owned,
    };
}

pub inline fn borrowColumn(target: *const anyopaque, index: u64, shape: anytype) std.meta.Child(@TypeOf(shape)) {
    return @ptrCast(&groupColumns(target)[@intCast(index)]);
}

pub inline fn columnStride(target: *const anyopaque) u64 {
    const column: *const Column = @ptrCast(@alignCast(target));

    return column.stride;
}

pub inline fn columnLength(target: *const anyopaque, index: u64) u64 {
    return groupColumns(target)[@intCast(index)].source_count;
}

pub inline fn copyRange(target: *const anyopaque, index: u64, first: u64, count: u64) void {
    copyContiguous(groupColumns(target)[@intCast(index)], @intCast(first), @intCast(count));
}

pub inline fn copyCell(target: *const anyopaque, source_offset: u64, target_row: u64) void {
    const column: *const Column = @ptrCast(@alignCast(target));
    const storage = column.storage;
    const width = column.width;
    const start = (storage.items.len + @as(usize, @intCast(target_row))) * width;

    copyBytesAt(storage.items.ptr + start, column.source + @as(usize, @intCast(source_offset)), width);
}

pub fn retainItem(resource: *const anyopaque, target: *const anyopaque, index: u64, from: u64, to: u64) bool {
    const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(resource));
    const column = groupColumns(target)[@intCast(index)];

    switch (column.kind) {
        .value, .strided, .repeated, .texts, .optional_texts => unreachable,
        inline else => |format| {
            const payload = Payload(format);
            const source: [*]const payload.Value = @ptrCast(@alignCast(column.source));
            const destination: [*]payload.Value = @ptrCast(@alignCast(column.storage.items.ptr));
            const item = clone(allocator.*, source[@intCast(from)], payload.borrow_text) catch return false;

            destination[column.storage.items.len + @as(usize, @intCast(to))] = item;
        },
    }

    return true;
}

pub fn releaseItem(resource: *const anyopaque, target: *const anyopaque, index: u64, row: u64) void {
    const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(resource));
    const column = groupColumns(target)[@intCast(index)];

    switch (column.kind) {
        .value, .strided, .repeated, .texts, .optional_texts => unreachable,
        inline else => |format| {
            const payload = Payload(format);
            const destination: [*]const payload.Value = @ptrCast(@alignCast(column.storage.items.ptr));

            release(allocator.*, destination[column.storage.items.len + @as(usize, @intCast(row))], payload.borrow_text);
        },
    }
}

fn Payload(comptime kind_value: Kind) type {
    return struct {
        const Value = switch (kind_value) {
            .text => Bytes,
            .optional_text => ?Bytes,
            .words => []const u32,
            .texts, .text_views => []const Bytes,
            .optional_texts, .optional_text_views => ?[]const Bytes,
            .value, .strided, .repeated => unreachable,
        };

        const borrow_text = kind_value == .text_views or kind_value == .optional_text_views;
    };
}

inline fn copyBytesAt(target: [*]u8, source: [*]const u8, width: usize) void {
    @memcpy(target[0..width], source[0..width]);
}

inline fn copyContiguous(column: Column, first: usize, count: usize) void {
    if (column.width == 0 or count == 0) return;

    const source = column.source + first * column.width;
    const target = column.storage.items.ptr + column.storage.items.len * column.width;

    copyBytesAt(target, source, count * column.width);
}

fn copyBytes(column: Column, first: usize, count: usize) void {
    switch (column.kind) {
        .value => copyContiguous(column, first, count),
        .strided, .repeated => {
            const target = column.storage.items.ptr + column.storage.items.len * column.width;
            const source = column.source + first * @as(usize, column.stride);

            for (0..count) |index| {
                copyBytesAt(target + index * column.width, source + index * @as(usize, column.stride), column.width);
            }
        },
        else => unreachable,
    }
}

fn copyColumn(allocator: std.mem.Allocator, column: Column, first: usize, count: usize) std.mem.Allocator.Error!void {
    switch (column.kind) {
        .value, .strided, .repeated => copyBytes(column, first, count),
        inline else => |format| {
            const payload = Payload(format);

            try cloneRange(payload.Value, payload.borrow_text, allocator, column, first, count);
        },
    }
}

fn discardColumns(allocator: std.mem.Allocator, columns: []const Column, count: usize) void {
    var iterator = std.mem.reverseIterator(columns);

    while (iterator.next()) |column| switch (column.kind) {
        .value, .strided, .repeated => {},
        inline else => |format| {
            const payload = Payload(format);

            releaseRange(payload.Value, payload.borrow_text, allocator, column, count);
        },
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
