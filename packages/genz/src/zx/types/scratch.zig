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

allocator: std.mem.Allocator,
items: []u32 = &.{},
columns: Columns = .{},
dirty: u32 = 0,
pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn prepare(self: *Self, count: usize) std.mem.Allocator.Error!Columns {
    std.debug.assert(self.dirty == 0);

    if (!generated) return @import("scratch_seed.zig").prepare(self, count);

    const plan_entry = @import("generated_type_scratch_plan");
    const bind_entry = @import("generated_type_scratch_bind");
    const PlanInput = std.meta.Child(plan_entry.Input);
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    const plan_input: PlanInput = .{
        .length = self.items.len,
        .count = count,
    };

    const plan = (zx.columns.invoke(plan_entry.executeValue, fixed.allocator(), &plan_input) catch unreachable) orelse return error.OutOfMemory;

    if (plan.cells != 0) {
        const cells = std.math.cast(usize, plan.cells) orelse return error.OutOfMemory;
        const next = try self.allocator.alloc(u32, cells);

        @memset(next[0..@intCast(plan.fill)], @backingInt(unset));
        self.allocator.free(self.items);

        self.items = next;
    }

    const starts = bind_entry.executeValue(fixed.allocator(), plan.stride) catch unreachable;
    const words = self.items;
    const ids: []Id = @ptrCast(words);

    self.columns = .{
        .abi_types = ids[@intCast(starts.abi_types)..][0..count],
        .abi_layouts = ids[@intCast(starts.abi_layouts)..][0..count],
        .state_types = ids[@intCast(starts.state_types)..][0..count],
        .state_layouts = ids[@intCast(starts.state_layouts)..][0..count],
        .views = ids[@intCast(starts.views)..][0..count],
        .touched = words[@intCast(starts.touched)..][0..count],
    };

    return self.columns;
}

pub fn reset(self: *Self) void {
    if (!generated) return @import("scratch_seed.zig").reset(self);
    if (self.dirty == 0) return;

    const entry = @import("generated_type_scratch_reset");
    const Parameter = entry.Input;
    const Input = if (comptime @typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    const input: Input = .{
        .touched = self.columns.touched,
        .dirty = self.dirty,
    };

    const result = entry.executeValue(fixed.allocator(), if (comptime @typeInfo(Parameter) == .pointer) &input else input) catch unreachable;
    const fill: Id = @fromBackingInt(result.sentinel);

    for (self.columns.touched[0..@intCast(result.count)]) |row| {
        self.columns.abi_types[row] = fill;
        self.columns.abi_layouts[row] = fill;
        self.columns.state_types[row] = fill;
        self.columns.state_layouts[row] = fill;
        self.columns.views[row] = fill;
    }

    self.dirty = 0;
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.items);
}
