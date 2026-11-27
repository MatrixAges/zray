const std = @import("std");
const zx = @import("zx");
const Flow = @import("../flow.zig");
const Slots = @import("../slots.zig");
const Body = @import("body.zig");
const Walk = @import("walk.zig");
const create = @import("generated_uniqueness_flow_queue");
const Queue = @import("../program/driver.zig").Api.FlowQueue;
const Error = std.mem.Allocator.Error;
const Self = @This();

owner: std.mem.Allocator,
functions: *const zx.ir.FunctionTable,
walk: Walk,
bodies: []?*const Body.Facts,
queue: Queue,
pub fn open(flow: Flow, owner: std.mem.Allocator, workspace: std.mem.Allocator, scratch: std.mem.Allocator, functions: *const zx.ir.FunctionTable, slots: Slots) Error!Self {
    const size = functions.count();
    const Input = std.meta.Child(create.Input);

    const input: Input = .{
        .expressions = zx.columns.slice(@FieldType(Input, "expressions"), functions.expressions),
        .native_modules = functions.native_modules,
        .held = flow.held,
    };

    const queue = zx.columns.invoke(create.executeValue, scratch, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    const bodies = try owner.alloc(?*const Body.Facts, size);

    @memset(bodies, null);

    return .{
        .owner = owner,
        .functions = functions,
        .bodies = bodies,
        .walk = .{ .allocator = workspace, .flow = flow, .slots = slots },
        .queue = .{
            .first = queue.first,
            .items = queue.items,
            .indices = queue.indices,
            .queued = queue.queued,
            .count = queue.count,
        },
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
