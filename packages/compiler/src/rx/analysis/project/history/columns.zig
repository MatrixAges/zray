//! Column-wise operations over the shared tables, which store each row field in its own list. A table view has the
//! same fields as its storage, each holding that list's items.
const std = @import("std");
const zx = @import("zx");
const generated = @import("rx_options").generated_graph;

/// The length of every column of `Storage`.
pub fn Lengths(comptime Storage: type) type {
    return [@typeInfo(Storage).@"struct".field_names.len]usize;
}

pub fn measure(storage: anytype) Lengths(@TypeOf(storage.*)) {
    var result: Lengths(@TypeOf(storage.*)) = undefined;

    inline for (@typeInfo(@TypeOf(storage.*)).@"struct".field_names, 0..) |name, index| result[index] = @field(storage, name).items.len;

    return result;
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
    inline for (ranges) |range| {
        inline for (@typeInfo(@TypeOf(range.storage.*)).@"struct".field_names, 0..) |name, index| {
            try @field(range.storage, name).ensureUnusedCapacity(allocator, range.end[index] - range.start[index]);
        }
    }

    if (comptime generated) {
        const rule = @import("generated_rx_history_column_write");
        const Input = std.meta.Child(rule.Input);
        const Column = std.meta.Child(std.meta.Child(@FieldType(Input, "writes")));
        const capacity = comptime countColumns(@TypeOf(ranges));
        var descriptions: [capacity]Column = undefined;
        var writes: [capacity]*const Column = undefined;
        var targets: [capacity][]u8 = undefined;
        var count: usize = 0;

        inline for (ranges) |range| {
            inline for (@typeInfo(@TypeOf(range.storage.*)).@"struct".field_names, 0..) |name, index| {
                const source = @field(range.source, name)[range.start[index]..range.end[index]];

                if (source.len != 0) {
                    const tail = @field(range.storage, name).unusedCapacitySlice()[0..source.len];
                    targets[count] = std.mem.sliceAsBytes(tail);
                    descriptions[count] = .{ .source = std.mem.sliceAsBytes(source), .target = @ptrCast(&targets[count]) };
                    writes[count] = &descriptions[count];
                    count += 1;
                }
            }
        }

        if (count != 0) {
            const input: Input = .{ .writes = writes[0..count] };
            var empty = std.heap.FixedBufferAllocator.init(&.{});

            zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
        }
    }

    inline for (ranges) |range| {
        inline for (@typeInfo(@TypeOf(range.storage.*)).@"struct".field_names, 0..) |name, index| {
            const column = &@field(range.storage, name);

            if (comptime generated) {
                column.items.len += range.end[index] - range.start[index];
            } else {
                column.appendSliceAssumeCapacity(@field(range.source, name)[range.start[index]..range.end[index]]);
            }
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
