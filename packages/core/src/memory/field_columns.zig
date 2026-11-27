const std = @import("std");
const read = @import("rows.zig");

pub fn ReadFields(comptime mapping: anytype) type {
    return Fields(read.ReadColumn, @TypeOf(mapping));
}

pub fn ListFields(comptime mapping: anytype) type {
    return Fields(read.ListColumn, @TypeOf(mapping));
}

pub fn borrowRead(comptime mapping: anytype, rows: anytype) ReadFields(mapping) {
    const Row = std.meta.Child(@TypeOf(rows));
    var result: ReadFields(mapping) = .{ .columns = undefined, .count = rows.len };

    inline for (@typeInfo(@TypeOf(mapping)).@"struct".field_names, &result.columns) |name, *output| {
        const field = @field(mapping, name);
        const Value = @FieldType(Row, field);

        output.* = read.borrowColumn(Value, field, rows);
    }

    return result;
}

pub fn borrowLists(comptime group: []const []const u8, comptime mapping: anytype, rows: anytype) ListFields(mapping) {
    const Row = std.meta.Child(read.fieldLayout(std.meta.Child(@TypeOf(rows)), group).type);
    var result: ListFields(mapping) = .{ .columns = undefined, .count = rows.len };

    inline for (@typeInfo(@TypeOf(mapping)).@"struct".field_names, &result.columns) |name, *output| {
        const field = @field(mapping, name);
        const Value = @FieldType(Row, field);

        output.* = read.borrowListPath(Value, group, &.{field}, rows);
    }

    return result;
}

fn Fields(comptime Column: type, comptime Mapping: type) type {
    const fields = @typeInfo(Mapping).@"struct".field_names;
    const maps_count = @hasField(Mapping, "count");

    return struct {
        const Self = @This();
        columns: [fields.len]Column,
        count: usize,
        pub inline fn column(self: *const Self, comptime field: []const u8) *const Column {
            return &self.columns[std.meta.fieldIndex(Mapping, field).?];
        }
        /// The ABI value refers to the descriptors in this borrow.
        pub inline fn bind(self: *const Self, comptime Shape: type) Shape {
            var result: Shape = undefined;
            const count: usize = @intFromBool(@hasField(Shape, "count") and !maps_count);

            comptime std.debug.assert(@typeInfo(Shape).@"struct".field_names.len == fields.len + count);
            self.fill(&result);

            return result;
        }
        pub inline fn fill(self: *const Self, target: anytype) void {
            const Shape = std.meta.Child(@TypeOf(target));

            inline for (fields, 0..) |field, index| {
                @field(target, field) = @ptrCast(&self.columns[index]);
            }

            if (@hasField(Shape, "count") and !maps_count) target.count = self.count;
        }
    };
}
