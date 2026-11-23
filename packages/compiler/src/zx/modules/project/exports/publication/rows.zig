const std = @import("std");
const memory = @import("zx").memory;

pub const Names = struct { name: *const anyopaque };

pub fn Rows(comptime Row: type, comptime Shape: type, comptime Layout: type) type {
    return struct {
        const Self = @This();
        const fields = @typeInfo(Layout).@"struct".field_names;

        storage: memory.RowOutput(Row, Layout, .{}),
        columns: [fields.len]memory.ReadColumn,
        reads: memory.RowGrowth,
        pub fn column(self: *const Self, comptime name: []const u8) *const memory.ReadColumn {
            return &self.columns[std.meta.fieldIndex(Layout, name).?];
        }
        pub fn borrow(self: *Self, own: []const Row, forwarded: []const Row, copy_own: bool) Shape {
            self.storage.init();

            const borrowed = if (own.len == 0) forwarded else own;

            inline for (fields, 0..) |name, index| {
                self.columns[index] = memory.borrowReadColumn(@FieldType(Row, name), name, borrowed);
            }

            self.reads = .{ .target = &self.storage.buffer, .reads = &self.columns };

            return .{
                .own = std.mem.sliceAsBytes(own),
                .forwarded = std.mem.sliceAsBytes(forwarded),
                .stride = @sizeOf(Row),
                .copy_own = copy_own,
                .storage = @ptrCast(&self.storage.buffer),
                .buffer = @ptrCast(&self.storage.buffer.bytes),
                .reads = @ptrCast(&self.reads),
                .names = @ptrCast(self.column("name")),
            };
        }
    };
}

pub fn typedRows(comptime Row: type, bytes: []const u8) []const Row {
    if (bytes.len == 0) return &.{};

    return @alignCast(std.mem.bytesAsSlice(Row, bytes));
}
