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
    pub fn describe(self: *const Column, comptime View: type) View {
        return .{
            .target = @ptrCast(self),
            .layout = switch (self.kind) {
                .value => .Contiguous,
                .strided, .repeated => .Projected,
                else => .Retained,
            },
            .stride = self.stride,
            .width = self.width,
            .text_lists = if (self.kind == .texts) @as([*]const []const Bytes, @ptrCast(@alignCast(self.source)))[0..self.source_count] else null,
            .optional_text_lists = if (self.kind == .optional_texts) @as([*]const ?[]const Bytes, @ptrCast(@alignCast(self.source)))[0..self.source_count] else null,
        };
    }
    pub fn reserve(self: Column, allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error!usize {
        if (count > self.storage.capacity - self.storage.items.len) {
            if (!self.grow(self.storage, allocator, count)) return error.OutOfMemory;
        }

        return self.storage.items.len;
    }

    pub fn appendBorrowed(self: Column, first: usize, count: usize) void {
        self.copyAt(first * self.width, 0, count);

        self.storage.items.len += count;
    }

    fn copyAt(self: Column, offset: usize, row: usize, count: usize) void {
        if (self.width == 0 or count == 0) return;

        const target = self.storage.items.ptr + (self.storage.items.len + row) * self.width;
        const length = count * self.width;

        @memcpy(target[0..length], self.source[offset..][0..length]);
    }
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

pub fn Description(comptime GroupsView: type, comptime group_count: usize, comptime column_count: usize) type {
    const Group = std.meta.Child(std.meta.Elem(GroupsView));
    const ColumnView = std.meta.Child(std.meta.Elem(@FieldType(Group, "columns")));

    return struct {
        const Self = @This();

        groups: [group_count]Group = undefined,
        group_views: [group_count]*const Group = undefined,
        columns: [column_count]ColumnView = undefined,
        column_views: [column_count]*const ColumnView = undefined,
        lengths: [column_count]*usize = undefined,
        length_views: [group_count][]const *usize = undefined,
        pub fn bind(self: *Self, groups: Groups) GroupsView {
            var first: usize = 0;

            for (groups, &self.groups, &self.group_views, &self.length_views) |group, *view, *reference, *lengths| {
                const end = first + group.len;

                for (group, self.columns[first..end], self.column_views[first..end], self.lengths[first..end]) |*column, *value, *pointer, *length| {
                    value.* = column.describe(ColumnView);
                    pointer.* = value;
                    length.* = &column.storage.items.len;
                }

                lengths.* = self.lengths[first..end];
                view.* = .{ .columns = self.column_views[first..end], .lengths = @ptrCast(lengths) };
                reference.* = view;
                first = end;
            }

            return &self.group_views;
        }
    };
}

pub fn copy(allocator: std.mem.Allocator, columns: []const Column, first: usize, count: usize) bool {
    if (count == 0) return true;

    for (columns, 0..) |column, field| {
        copyColumn(allocator, column, first, count) catch {
            discard(allocator, columns[0..field], count);

            return false;
        };
    }

    return true;
}

pub fn discard(allocator: std.mem.Allocator, columns: []const Column, count: usize) void {
    if (count != 0) discardColumns(allocator, columns, count);
}

pub fn publish(columns: []const Column, count: usize) void {
    for (columns) |column| column.storage.items.len += count;
}

pub fn cloneTextList(resource: *const anyopaque, source: []const Bytes) ?[]const Bytes {
    return clone(column_set.borrowAllocator(resource), source, false) catch null;
}

pub fn reserveOne(resource: *const anyopaque, target: *const anyopaque, count: u64) std.mem.Allocator.Error!u64 {
    const length = std.math.cast(usize, count) orelse return error.OutOfMemory;

    return columnFrom(target).reserve(column_set.borrowAllocator(resource), length);
}

pub inline fn copyRange(target: *const anyopaque, offset: u64, row: u64, count: u64) void {
    const column = columnFrom(target);
    const first: usize = @intCast(offset);
    const start: usize = @intCast(row);
    const length: usize = @intCast(count);

    column.copyAt(first, start, length);
}

pub fn retainItem(resource: *const anyopaque, target: *const anyopaque, from: u64, to: u64, retained: ?[]const Bytes) bool {
    const column = columnFrom(target);
    const row = column.storage.items.len + @as(usize, @intCast(to));
    const allocator = column_set.borrowAllocator(resource);

    switch (column.kind) {
        .value, .strided, .repeated => unreachable,
        inline else => |format| {
            const payload = Payload(format);
            const destination: [*]payload.Value = @ptrCast(@alignCast(column.storage.items.ptr));

            destination[row] = switch (format) {
                .texts => retained.?,
                .optional_texts => retained,
                else => item: {
                    const source: [*]const payload.Value = @ptrCast(@alignCast(column.source));

                    break :item clone(allocator, source[@intCast(from)], payload.borrow_text) catch return false;
                },
            };
        },
    }

    return true;
}

pub fn releaseItem(resource: *const anyopaque, target: *const anyopaque, row: u64) void {
    const column = columnFrom(target);

    switch (column.kind) {
        .value, .strided, .repeated => unreachable,
        inline else => |format| {
            const payload = Payload(format);
            const destination: [*]const payload.Value = @ptrCast(@alignCast(column.storage.items.ptr));

            release(column_set.borrowAllocator(resource), destination[column.storage.items.len + @as(usize, @intCast(row))], payload.borrow_text);
        },
    }
}

fn columnFrom(target: *const anyopaque) *const Column {
    return @ptrCast(@alignCast(target));
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

fn copyBytes(column: Column, first: usize, count: usize) void {
    switch (column.kind) {
        .value => column.copyAt(first * column.width, 0, count),
        .strided, .repeated => for (0..count) |row| {
            column.copyAt((first + row) * @as(usize, column.stride), row, 1);
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
