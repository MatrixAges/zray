const std = @import("std");
const memory = @import("zx").memory;

pub fn Tail(comptime Row: type, comptime Destination: type, comptime fields: anytype) type {
    const Columns = std.meta.Child(@FieldType(Destination, "target"));

    return struct {
        const Self = @This();
        list: *std.ArrayList(Row),
        output: memory.RowOutput(Row, Columns, fields),
        length: u64,
        used: []u64,
        pub fn init(self: *Self, list: *std.ArrayList(Row)) void {
            self.list = list;

            self.output.init();
            self.output.bind(list.allocatedSlice());

            self.length = list.items.len;
            self.used = @as(*[1]u64, @ptrCast(&self.length));
        }

        pub fn commit(self: *Self) void {
            const rows = self.output.rows();

            self.list.items = rows[0..@intCast(self.length)];
            self.list.capacity = rows.len;
        }
    };
}
