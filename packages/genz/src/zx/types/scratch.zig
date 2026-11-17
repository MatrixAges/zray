const std = @import("std");
const Id = @import("../../node.zig").ExpressionId;
const Self = @This();
pub const unset: Id = @fromBackingInt(std.math.maxInt(u32));
const column_count = 5;

pub const Columns = struct {
    abi_types: []Id,
    abi_layouts: []Id,
    state_types: []Id,
    state_layouts: []Id,
    views: []Id,
    touched: []u32,
};

allocator: std.mem.Allocator,
items: []Id = &.{},

dirty: u32 = 0,
pub fn prepare(self: *Self, count: usize) std.mem.Allocator.Error!Columns {
    std.debug.assert(self.dirty == 0);

    if (count > self.capacity()) {
        const cells = std.math.mul(usize, count, column_count + 1) catch return error.OutOfMemory;
        const items = try self.allocator.alloc(Id, cells);

        @memset(items[0 .. count * column_count], unset);
        self.allocator.free(self.items);

        self.items = items;
    }

    return self.columns(count);
}

fn capacity(self: *const Self) usize {
    return self.items.len / (column_count + 1);
}

pub fn columns(self: *const Self, count: usize) Columns {
    const stride = self.capacity();
    const items = self.items;

    return .{
        .abi_types = items[0..count],
        .abi_layouts = items[stride..][0..count],
        .state_types = items[2 * stride ..][0..count],
        .state_layouts = items[3 * stride ..][0..count],
        .views = items[4 * stride ..][0..count],
        .touched = @ptrCast(items[column_count * stride ..][0..count]),
    };
}

pub fn reset(self: *Self) void {
    const tables = self.columns(self.capacity());

    for (tables.touched[0..self.dirty]) |row| {
        tables.abi_types[row] = unset;
        tables.abi_layouts[row] = unset;
        tables.state_types[row] = unset;
        tables.state_layouts[row] = unset;
        tables.views[row] = unset;
    }

    self.dirty = 0;
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.items);
}
