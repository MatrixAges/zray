const std = @import("std");

pub const Column = struct {
    items: [*]u8,
    count: usize,
    stride: usize,
    width: usize,
};

pub fn RowOutput(comptime Row: type, comptime View: type, comptime fields: anytype) type {
    const names = @typeInfo(View).@"struct".field_names;

    return struct {
        const Self = @This();
        storage: []Row,
        columns: [names.len]Column,
        view: View,
        pub fn init(self: *Self) void {
            inline for (names, &self.columns) |name, *column| {
                @field(self.view, name) = @ptrCast(column);
            }

            self.bind(&.{});
        }
        pub fn rows(self: *const Self) []Row {
            return self.storage;
        }
        pub fn bind(self: *Self, storage: []Row) void {
            self.storage = storage;

            const bytes = std.mem.sliceAsBytes(storage);

            inline for (names, &self.columns) |name, *column| {
                const path: []const []const u8 = if (@hasField(@TypeOf(fields), name)) @field(fields, name) else &.{name};
                const field = comptime @import("rows.zig").fieldLayout(Row, path);

                column.* = .{
                    .items = if (storage.len == 0) bytes.ptr else bytes.ptr + field.offset,
                    .count = storage.len,
                    .stride = @sizeOf(Row),
                    .width = @sizeOf(field.type),
                };
            }
        }
    };
}
