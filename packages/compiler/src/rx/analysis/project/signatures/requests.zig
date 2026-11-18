const std = @import("std");
const Id = @import("../../inference/types.zig").Id;

pub const Binding = struct { name: []const u8, value: Id };

bindings: std.MultiArrayList(Binding) = .empty,
tasks: std.ArrayList(u32) = .empty,
/// Task ids follow declaration order. Nested tasks publish their bindings in completion order.
pub fn recordTask(self: *@This(), allocator: std.mem.Allocator, first: usize, id: usize, binding: usize) std.mem.Allocator.Error!void {
    const row = std.math.add(usize, first, id) catch return error.OutOfMemory;
    const position = std.math.cast(u32, binding) orelse return error.OutOfMemory;

    if (row >= self.tasks.items.len) {
        const end = std.math.add(usize, row, 1) catch return error.OutOfMemory;

        try self.tasks.resize(allocator, end);
    }

    self.tasks.items[row] = position;
}
