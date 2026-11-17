const std = @import("std");
const Lower = @import("../lower.zig");
const Self = @This();

abi_types: []u32,
abi_layouts: []u32,
state_types: []u32,
state_layouts: []u32,
views: []u32,
rows: []u32,
count: []u32,
pub fn borrow(lower: *const Lower) Self {
    const scratch = lower.type_scratch;

    return .{
        .abi_types = @ptrCast(lower.abi_types),
        .abi_layouts = @ptrCast(lower.abi_layouts),
        .state_types = @ptrCast(lower.state_types),
        .state_layouts = @ptrCast(lower.state_layouts),
        .views = @ptrCast(lower.view_types),
        .rows = if (scratch) |storage| storage.columns(lower.abi_types.len).touched else &.{},
        .count = if (scratch) |storage| @as(*[1]u32, @ptrCast(&storage.dirty)) else &.{},
    };
}

pub fn Touched(comptime Columns: type) type {
    return std.meta.Child(@typeInfo(@FieldType(Columns, "touched")).optional.child);
}

pub fn touch(self: *const Self, comptime T: type) T {
    return .{ .rows = @ptrCast(&self.rows), .count = @ptrCast(&self.count) };
}

pub fn columns(self: *const Self, comptime T: type, tracked: *const Touched(T)) T {
    return .{
        .abi_types = @ptrCast(&self.abi_types),
        .abi_layouts = @ptrCast(&self.abi_layouts),
        .state_types = @ptrCast(&self.state_types),
        .state_layouts = @ptrCast(&self.state_layouts),
        .views = @ptrCast(&self.views),
        .touched = if (self.count.len == 0) null else tracked,
    };
}
