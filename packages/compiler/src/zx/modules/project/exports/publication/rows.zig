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
                .names = @ptrCast(self.column("name")),
            };
        }
        pub fn merge(self: *Self, allocator: std.mem.Allocator, own: []const u8, forwarded: []const u8) std.mem.Allocator.Error!void {
            const first = typedRows(Row, own);
            const second = typedRows(Row, forwarded);
            const target = try allocator.alloc(Row, first.len + second.len);

            @memcpy(target[0..first.len], first);
            @memcpy(target[first.len..], second);
            self.storage.bind(target);
            inline for (0..fields.len) |slot| self.reads.refreshCell(slot, target.len);
        }
    };
}

pub fn typedRows(comptime Row: type, bytes: []const u8) []const Row {
    if (bytes.len == 0) return &.{};

    return @alignCast(std.mem.bytesAsSlice(Row, bytes));
}
