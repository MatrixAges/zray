const std = @import("std");
const Lower = @import("../lower.zig");
const Id = @import("../../node.zig").ExpressionId;

pub fn allocateAbi(allocator: std.mem.Allocator, count: usize, types: *[]Id, layouts: *[]Id) std.mem.Allocator.Error!void {
    const entry = @import("generated_lowering_workspace_abi");

    const input: std.meta.Child(entry.Input) = .{
        .abi_types = @ptrCast(types),
        .abi_layouts = @ptrCast(layouts),
        .count = count,
    };

    entry.executeIn(allocator, &input) catch |err| return failure(err);
}

pub fn prepareShared(self: *Lower) std.mem.Allocator.Error!void {
    const entry = @import("generated_lowering_workspace_shared");

    const input: std.meta.Child(entry.Input) = .{
        .abi_types = @ptrCast(&self.abi_types),
        .abi_layouts = @ptrCast(&self.abi_layouts),
        .state_types = @ptrCast(&self.state_types),
        .state_layouts = @ptrCast(&self.state_layouts),
        .views = @ptrCast(&self.view_types),
        .count = self.types.len,
    };

    entry.executeIn(self.allocator, &input) catch |err| return failure(err);
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
