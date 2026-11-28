const std = @import("std");
const zx = @import("zx");
const Flow = @import("../flow.zig");
const Slots = @import("../slots.zig");
const Body = @import("body.zig");
const Walk = @import("walk.zig");
const Error = std.mem.Allocator.Error;
const Self = @This();

owner: std.mem.Allocator,
functions: *const zx.ir.FunctionTable,
walk: Walk,
bodies: []?*const Body.Facts,
pub fn open(flow: Flow, owner: std.mem.Allocator, workspace: std.mem.Allocator, functions: *const zx.ir.FunctionTable, slots: Slots) Error!Self {
    const bodies = try owner.alloc(?*const Body.Facts, functions.count());

    @memset(bodies, null);

    return .{
        .owner = owner,
        .functions = functions,
        .bodies = bodies,
        .walk = .{ .allocator = workspace, .flow = flow, .slots = slots },
    };
}

pub fn deinit(self: *Self) void {
    self.walk.deinit();
}

pub fn retain(self: *Self, index: u32) Error!void {
    if (self.bodies[index] == null) {
        self.bodies[index] = try self.walk.keep(self.owner, Body.View.at(self.functions, index));
    }
}

pub fn visit(self: *Self, index: u32, retained: bool) Error!bool {
    return self.walk.visit(index, Body.View.at(self.functions, index), if (retained) self.bodies[index] else null);
}
