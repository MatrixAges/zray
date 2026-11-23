const std = @import("std");
const read = @import("rows.zig");
const write = @import("write_column.zig");

pub fn borrowRead(comptime mapping: anytype, rows: anytype) Fields(read.ReadColumn, mapping) {
    return borrow(read.ReadColumn, mapping, rows);
}

pub fn borrowWrite(comptime mapping: anytype, rows: anytype) Fields(write.Column, mapping) {
    return borrow(write.Column, mapping, rows);
}

fn Fields(comptime Column: type, comptime mapping: anytype) type {
    const fields = @typeInfo(@TypeOf(mapping)).@"struct".field_names;

    return struct {
        const Self = @This();
        columns: [fields.len]Column,
        count: usize,
        /// The ABI value refers to the descriptors in this borrow.
        pub inline fn bind(self: *const Self, comptime Shape: type) Shape {
            var result: Shape = undefined;
            const count: usize = @intFromBool(@hasField(Shape, "count") and !@hasField(@TypeOf(mapping), "count"));

            comptime std.debug.assert(@typeInfo(Shape).@"struct".field_names.len == fields.len + count);
            self.fill(&result);

            return result;
        }
        pub inline fn fill(self: *const Self, target: anytype) void {
            const Shape = std.meta.Child(@TypeOf(target));

            inline for (fields, 0..) |field, index| {
                @field(target, field) = @ptrCast(&self.columns[index]);
            }

            if (@hasField(Shape, "count") and !@hasField(@TypeOf(mapping), "count")) target.count = self.count;
        }
    };
}

inline fn borrow(comptime Column: type, comptime mapping: anytype, rows: anytype) Fields(Column, mapping) {
    const Row = std.meta.Child(@TypeOf(rows));
    var result: Fields(Column, mapping) = .{ .columns = undefined, .count = rows.len };

    inline for (@typeInfo(@TypeOf(mapping)).@"struct".field_names, 0..) |name, index| {
        const field = @field(mapping, name);
        const Value = @FieldType(Row, field);

        result.columns[index] = if (Column == read.ReadColumn)
            read.borrowColumn(Value, field, rows)

        else
            write.borrow(Value, field, rows);
    }

    return result;
}
