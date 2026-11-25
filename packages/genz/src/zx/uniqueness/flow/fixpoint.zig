const std = @import("std");
const zx = @import("zx");
const Flow = @import("../flow.zig");
const Slots = @import("../slots.zig");
const Body = @import("body.zig");
const Walk = @import("walk.zig");
const create = @import("generated_uniqueness_flow_queue");
const run = @import("generated_uniqueness_flow_fixpoint");
const Error = std.mem.Allocator.Error;

const Frame = struct {
    owner: std.mem.Allocator,
    functions: *const zx.ir.FunctionTable,
    walk: Walk,
    bodies: []?*const Body.Facts,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn settle(flow: Flow, owner_arg: std.mem.Allocator, workspace: std.mem.Allocator, functions: *const zx.ir.FunctionTable, slots: Slots) Error!void {
    var owner = owner_arg;
    const size = functions.count();
    var indices = try owner.alloc(u32, size);
    var queued = try owner.alloc(u8, size);
    var first = try owner.alloc(u64, size + 1);

    @memset(first, 0);

    var items: []u32 = &.{};
    const Input = std.meta.Child(create.Input);

    const input: Input = .{
        .expressions = zx.columns.slice(@FieldType(Input, "expressions"), functions.expressions),
        .native_modules = functions.native_modules,
        .held = flow.held,
        .first = @ptrCast(&first),
        .items = @ptrCast(&items),
        .owner = @ptrCast(&owner),
        .indices = @ptrCast(&indices),
        .queued = @ptrCast(&queued),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const count = zx.columns.invoke(create.executeValue, empty.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    const bodies = try owner.alloc(?*const Body.Facts, size);

    @memset(bodies, null);

    var frame: Frame = .{
        .owner = owner,
        .functions = functions,
        .bodies = bodies,
        .walk = .{ .allocator = workspace, .flow = flow, .slots = slots },
    };

    defer frame.walk.deinit();

    const request: std.meta.Child(run.Input) = .{
        .flow = @ptrCast(&frame),
        .queue = &.{
            .indices = @ptrCast(&indices),
            .queued = @ptrCast(&queued),
            .first = first,
            .items = items,
            .count = count,
            .changed = null,
        },
    };

    run.executeIn(empty.allocator(), &request) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

pub fn retainFlowFacts(handle: *anyopaque, index: u32) Error!void {
    const frame = Frame.borrow(handle);

    if (frame.bodies[index] == null) {
        frame.bodies[index] = try frame.walk.keep(frame.owner, Body.View.at(frame.functions, index));
    }
}

pub fn visitRecursiveFlow(handle: *anyopaque, index: u32, retained: bool) Error!bool {
    const frame = Frame.borrow(handle);

    return frame.walk.visit(index, Body.View.at(frame.functions, index), if (retained) frame.bodies[index] else null);
}
