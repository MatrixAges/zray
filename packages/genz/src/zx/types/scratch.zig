const std = @import("std");
const zx = @import("zx");
const Id = @import("../../node.zig").ExpressionId;
const Self = @This();
pub const unset: Id = @fromBackingInt(std.math.maxInt(u32));
const generated = @import("genz_options").generated_analysis;

pub const Columns = struct {
    abi_types: []Id = &.{},
    abi_layouts: []Id = &.{},
    state_types: []Id = &.{},
    state_layouts: []Id = &.{},
    views: []Id = &.{},
    touched: []u32 = &.{},
};

storage: zx.memory.U32Scratch,
columns: Columns = .{},
dirty: u32 = 0,
pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .storage = .{ .allocator = allocator } };
}

pub fn prepare(self: *Self, count: usize) std.mem.Allocator.Error!Columns {
    std.debug.assert(self.dirty == 0);

    if (!generated) return @import("scratch_seed.zig").prepare(self, count);

    const entry = @import("generated_type_scratch_prepare");
    const Input = std.meta.Child(entry.Input);
    const Table = std.meta.Child(@FieldType(Input, "tables"));
    var count_view = self.touchedCount();
    var touched: Touched(Table) = undefined;
    const tables = self.borrow(Table, &count_view, &touched);

    const input: Input = .{
        .storage = @ptrCast(&self.storage),
        .items = @ptrCast(&self.storage.items),
        .tables = &tables,
        .count = count,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    const ready = entry.executeIn(fixed.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    if (!ready) return error.OutOfMemory;

    return self.columns;
}

fn Touched(comptime Table: type) type {
    return std.meta.Child(@FieldType(Table, "touched"));
}

fn borrow(self: *Self, comptime Table: type, count: *[]u32, touched: *Touched(Table)) Table {
    touched.* = .{ .rows = @ptrCast(&self.columns.touched), .count = @ptrCast(count) };

    return .{
        .abi_types = @ptrCast(&self.columns.abi_types),
        .abi_layouts = @ptrCast(&self.columns.abi_layouts),
        .state_types = @ptrCast(&self.columns.state_types),
        .state_layouts = @ptrCast(&self.columns.state_layouts),
        .views = @ptrCast(&self.columns.views),
        .touched = touched,
    };
}

pub fn touchedCount(self: *Self) []u32 {
    return @as(*[1]u32, @ptrCast(&self.dirty));
}

pub fn reset(self: *Self) void {
    if (!generated) return @import("scratch_seed.zig").reset(self);

    const entry = @import("generated_type_scratch_reset");
    const Input = std.meta.Child(entry.Input);
    var count = self.touchedCount();
    var touched: Touched(Input) = undefined;
    const input = self.borrow(Input, &count, &touched);
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    entry.executeIn(fixed.allocator(), &input) catch unreachable;
}

pub fn deinit(self: *Self) void {
    self.storage.deinit();
}
