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
    const BindInput = std.meta.Child(bind_entry.Input);
    const Table = std.meta.Child(@FieldType(BindInput, "tables"));
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

    const tables = self.borrow(Table);

    const input: BindInput = .{
        .items = @ptrCast(&self.items),
        .tables = &tables,
        .count = count,
        .stride = plan.stride,
    };

    bind_entry.executeIn(fixed.allocator(), &input) catch unreachable;

    return self.columns;
}

fn borrow(self: *Self, comptime Table: type) Table {
    return .{
        .abi_types = @ptrCast(&self.columns.abi_types),
        .abi_layouts = @ptrCast(&self.columns.abi_layouts),
        .state_types = @ptrCast(&self.columns.state_types),
        .state_layouts = @ptrCast(&self.columns.state_layouts),
        .views = @ptrCast(&self.columns.views),
        .touched = @ptrCast(&self.columns.touched),
    };
}

pub fn reset(self: *Self) void {
    if (!generated) return @import("scratch_seed.zig").reset(self);
    if (self.dirty == 0) return;

    const entry = @import("generated_type_scratch_reset");
    const Input = std.meta.Child(entry.Input);

    const input: Input = .{
        .abi_types = @ptrCast(&self.columns.abi_types),
        .abi_layouts = @ptrCast(&self.columns.abi_layouts),
        .state_types = @ptrCast(&self.columns.state_types),
        .state_layouts = @ptrCast(&self.columns.state_layouts),
        .views = @ptrCast(&self.columns.views),
        .touched = @ptrCast(&self.columns.touched),
        .dirty = self.dirty,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    entry.executeIn(fixed.allocator(), &input) catch unreachable;

    self.dirty = 0;
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.items);
}
