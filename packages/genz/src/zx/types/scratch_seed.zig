const std = @import("std");
const Scratch = @import("scratch.zig");
const Id = @import("../../node.zig").ExpressionId;

pub fn prepare(self: *Scratch, count: usize) std.mem.Allocator.Error!Scratch.Columns {
    const width = 6;
    var stride = self.items.len / width;

    if (stride < count) {
        const cells = std.math.mul(usize, count, width) catch return error.OutOfMemory;
        const next = try self.allocator.alloc(u32, cells);

        @memset(next[0 .. count * (width - 1)], @backingInt(Scratch.unset));
        self.allocator.free(self.items);

        self.items = next;
        stride = count;
    }

    const words = self.items;
    const ids: []Id = @ptrCast(words);

    self.columns = .{
        .abi_types = ids[0..count],
        .abi_layouts = ids[stride..][0..count],
        .state_types = ids[2 * stride ..][0..count],
        .state_layouts = ids[3 * stride ..][0..count],
        .views = ids[4 * stride ..][0..count],
        .touched = words[5 * stride ..][0..count],
    };

    return self.columns;
}

pub fn reset(self: *Scratch) void {
    const tables = self.columns;

    for (tables.touched[0..self.dirty]) |row| {
        tables.abi_types[row] = Scratch.unset;
        tables.abi_layouts[row] = Scratch.unset;
        tables.state_types[row] = Scratch.unset;
        tables.state_layouts[row] = Scratch.unset;
        tables.views[row] = Scratch.unset;
    }

    self.dirty = 0;
}
