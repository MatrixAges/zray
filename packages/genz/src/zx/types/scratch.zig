const std = @import("std");
const zx = @import("zx");
const Id = @import("../../node.zig").ExpressionId;
const Self = @This();
pub const unset: Id = @fromBackingInt(std.math.maxInt(u32));
const generated = @import("genz_options").generated_analysis;
const layout = if (generated) @import("generated_type_scratch_layout") else void;
const Column = if (generated) std.meta.Child(layout.Output) else enum { AbiTypes, AbiLayouts, StateTypes, StateLayouts, Views, Rows };

const columns_in_order: []const Column = if (generated)
    zx.staticSequence(layout, {})

else
    &.{ .AbiTypes, .AbiLayouts, .StateTypes, .StateLayouts, .Views, .Rows };

const columns_per_row = columns_in_order.len;

const initialized = for (columns_in_order, 0..) |column, index| {
    if (column == .Rows) break index;
} else @compileError("Type scratch layout requires a touched row column");

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
        const cells = std.math.mul(usize, count, columns_per_row) catch return error.OutOfMemory;
        const items = try self.allocator.alloc(Id, cells);

        fill(items[0 .. count * initialized]);
        self.allocator.free(self.items);

        self.items = items;
    }

    return self.columns(count);
}

fn capacity(self: *const Self) usize {
    return self.items.len / columns_per_row;
}

pub fn columns(self: *const Self, count: usize) Columns {
    const stride = self.capacity();
    const items = self.items;

    var result: Columns = undefined;

    inline for (columns_in_order, 0..) |column, index| {
        const values = items[index * stride ..][0..count];

        switch (column) {
            .AbiTypes => result.abi_types = values,
            .AbiLayouts => result.abi_layouts = values,
            .StateTypes => result.state_types = values,
            .StateLayouts => result.state_layouts = values,
            .Views => result.views = values,
            .Rows => result.touched = @ptrCast(values),
        }
    }

    return result;
}

pub fn fill(items: []Id) void {
    if (!generated) {
        @memset(items, unset);

        return;
    }

    const entry = @import("generated_type_scratch_fill");
    const bytes = std.mem.sliceAsBytes(items);
    const input: std.meta.Child(entry.Input) = .{ .buffer = @ptrCast(&bytes), .bytes = bytes.len };
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch unreachable;
}

pub fn reset(self: *Self) void {
    if (self.dirty == 0) return;

    const tables = self.columns(self.capacity());
    const rows = tables.touched[0..self.dirty];

    if (generated) {
        const entry = @import("generated_type_scratch_reset");
        const count: []u32 = @as(*[1]u32, @ptrCast(&self.dirty));

        const input: std.meta.Child(entry.Input) = .{
            .abi_types = @ptrCast(&tables.abi_types),
            .abi_layouts = @ptrCast(&tables.abi_layouts),
            .state_types = @ptrCast(&tables.state_types),
            .state_layouts = @ptrCast(&tables.state_layouts),
            .views = @ptrCast(&tables.views),
            .rows = rows,
            .count = @ptrCast(&count),
        };

        var fixed = std.heap.FixedBufferAllocator.init(&.{});

        zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch unreachable;

        return;
    }

    for (rows) |row| {
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
