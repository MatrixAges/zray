const std = @import("std");
const memory = @import("zx").memory;

pub const Names = struct { name: *const anyopaque };

pub fn Rows(comptime Row: type, comptime Shape: type, comptime Layout: type) type {
    return struct {
        const Self = @This();
        const fields = @typeInfo(Layout).@"struct".field_names;
        own: []const Row,
        forwarded: []const Row,
        allocated: []Row,
        columns: [fields.len]memory.ReadColumn,
        pub fn column(self: *const Self, comptime name: []const u8) *const memory.ReadColumn {
            return &self.columns[std.meta.fieldIndex(Layout, name).?];
        }
        pub fn borrow(self: *Self, own: []const Row, forwarded: []const Row, copy_own: bool) Shape {
            self.own = own;
            self.forwarded = forwarded;
            self.allocated = &.{};

            const borrowed = if (own.len == 0) forwarded else own;

            inline for (fields, 0..) |name, index| {
                self.columns[index] = memory.borrowReadColumn(@FieldType(Row, name), name, borrowed);
            }

            return .{
                .own = own.len,
                .forwarded = forwarded.len,
                .copy_own = copy_own,
                .names = @ptrCast(self.column("name")),
            };
        }
        pub fn merge(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
            const first = self.own;
            const second = self.forwarded;
            const target = try allocator.alloc(Row, first.len + second.len);

            @memcpy(target[0..first.len], first);
            @memcpy(target[first.len..], second);

            self.allocated = target;

            inline for (fields, &self.columns) |name, *descriptor| {
                descriptor.* = memory.borrowReadColumn(@FieldType(Row, name), name, target);
            }
        }

        pub fn result(self: *const Self) []const Row {
            if (self.allocated.len != 0) return self.allocated;

            return if (self.own.len == 0) self.forwarded else self.own;
        }
    };
}
