//! Column-wise operations over the shared tables, which store each row field in its own list. A table view has the
//! same fields as its storage, each holding that list's items.
const std = @import("std");
const zx = @import("zx");
const generated = @import("rx_options").generated_graph;

/// The length of every column of `Storage`.
pub fn Lengths(comptime Storage: type) type {
    return LengthWords(Storage, usize);
}

fn LengthWords(comptime Storage: type, comptime Word: type) type {
    return [@typeInfo(Storage).@"struct".field_names.len]Word;
}

pub fn measure(storage: anytype) Lengths(@TypeOf(storage.*)) {
    return measureAs(usize, storage);
}

pub fn measureAs(comptime Word: type, storage: anytype) LengthWords(@TypeOf(storage.*), Word) {
    var result: LengthWords(@TypeOf(storage.*), Word) = undefined;

    inline for (@typeInfo(@TypeOf(storage.*)).@"struct".field_names, 0..) |name, index| result[index] = @field(storage, name).items.len;

    return result;
}

pub fn words(bytes: []const u8) zx.memory.ReadColumn {
    const width = @sizeOf(usize);

    return .{ .bytes = bytes, .count = bytes.len / width, .stride = width, .offset = 0 };
}

pub fn bindTransfers(columns: []zx.memory.column_transfer.Column, storage: anytype, source: anytype) void {
    inline for (@typeInfo(@TypeOf(storage.*)).@"struct".field_names, 0..) |name, index| {
        columns[index] = zx.memory.column_transfer.bind(&@field(storage, name), @field(source, name), false, true);
    }
}

/// Whether the rows `left` added between `left_start` and `left_end` equal those `right` added from `right_start` on.
pub fn equal(left: anytype, left_start: anytype, left_end: @TypeOf(left_start), right: @TypeOf(left), right_start: @TypeOf(left_start), right_end: @TypeOf(left_start)) bool {
    inline for (@typeInfo(@TypeOf(left)).@"struct".field_names, 0..) |name, index| {
        if (left_end[index] - left_start[index] != right_end[index] - right_start[index]) return false;
        if (!same(@field(left, name)[left_start[index]..left_end[index]], @field(right, name)[right_start[index]..right_end[index]])) return false;
    }

    return true;
}

/// Writes the selected ranges into reserved tails, sharing the payloads owned by the earlier analysis.
pub fn transplant(allocator: std.mem.Allocator, ranges: anytype) std.mem.Allocator.Error!void {
    if (comptime generated) {
        const rule = @import("generated_rx_history_column_write");
        const Input = std.meta.Child(rule.Input);
        const Transfer = zx.memory.column_transfer;
        const capacity = comptime countColumns(@TypeOf(ranges));
        var columns: [capacity]Transfer.Column = undefined;
        var lengths: [capacity]u64 = undefined;
        comptime var slot: usize = 0;

        inline for (ranges) |range| {
            inline for (@typeInfo(@TypeOf(range.storage.*)).@"struct".field_names, 0..) |name, index| {
                const source = @field(range.source, name)[range.start[index]..range.end[index]];

                columns[slot] = Transfer.bind(&@field(range.storage, name), source, false, true);
                lengths[slot] = source.len;
                slot += 1;
            }
        }

        const input: Input = .{ .lengths = &lengths };
        var buffer: [1024]u8 = undefined;
        var first = std.heap.BufferFirstAllocator.init(&buffer, allocator);
        var arena = std.heap.ArenaAllocator.init(first.allocator());

        defer arena.deinit();

        const plan = zx.columns.invoke(rule.executeValue, arena.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow => return error.OutOfMemory,
            else => unreachable,
        };

        for (plan) |range| {
            _ = try columns[@intCast(range.column)].reserve(allocator, @intCast(range.count));
        }

        for (plan) |range| {
            columns[@intCast(range.column)].appendBorrowed(0, @intCast(range.count));
        }

        return;
    }

    inline for (ranges) |range| {
        inline for (@typeInfo(@TypeOf(range.storage.*)).@"struct".field_names, 0..) |name, index| {
            try @field(range.storage, name).ensureUnusedCapacity(allocator, range.end[index] - range.start[index]);
        }
    }

    inline for (ranges) |range| {
        inline for (@typeInfo(@TypeOf(range.storage.*)).@"struct".field_names, 0..) |name, index| {
            @field(range.storage, name).appendSliceAssumeCapacity(@field(range.source, name)[range.start[index]..range.end[index]]);
        }
    }
}

fn countColumns(comptime Ranges: type) usize {
    var count: usize = 0;

    for (@typeInfo(Ranges).@"struct".field_types) |Range| {
        const Storage = std.meta.Child(@FieldType(Range, "storage"));
        count += @typeInfo(Storage).@"struct".field_names.len;
    }

    return count;
}

/// Structural equality: slices and single pointers compare what they reference.
pub fn same(left: anytype, right: @TypeOf(left)) bool {
    const T = @TypeOf(left);

    return switch (@typeInfo(T)) {
        .int, .bool, .@"enum", .void => left == right,
        .float => @as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(left)) == @as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(right)),
        .optional => if (left) |value| if (right) |other| same(value, other) else false else right == null,
        .array => same(left[0..], right[0..]),
        .pointer => |pointer| switch (pointer.size) {
            .one => left == right or same(left.*, right.*),
            .slice => slices(left, right),
            else => @compileError("cannot compare " ++ @typeName(T)),
        },
        .@"struct" => |info| {
            inline for (info.field_names) |name| if (!same(@field(left, name), @field(right, name))) return false;

            return true;
        },
        .@"union" => {
            if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;

            return switch (left) {
                inline else => |value, tag| same(value, @field(right, @tagName(tag))),
            };
        },
        else => @compileError("cannot compare " ++ @typeName(T)),
    };
}

fn slices(left: anytype, right: @TypeOf(left)) bool {
    const Element = std.meta.Elem(@TypeOf(left));

    if (left.len != right.len) return false;
    if (left.len == 0 or left.ptr == right.ptr) return true;
    if (comptime std.meta.hasUniqueRepresentation(Element)) return std.mem.eql(Element, left, right);
    for (left, right) |a, b| if (!same(a, b)) return false;

    return true;
}
