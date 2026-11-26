const std = @import("std");
const zx = @import("zx");
const Flow = @import("../flow.zig");
const Slots = @import("../slots.zig");
const Body = @import("body.zig");
const Walk = @import("walk.zig");
const create = @import("generated_uniqueness_flow_queue");
const advance = @import("generated_uniqueness_flow_advance");
const Error = std.mem.Allocator.Error;

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

    var walk: Walk = .{ .allocator = workspace, .flow = flow, .slots = slots };

    defer walk.deinit();

    var current_count = count;
    var changed: ?u32 = null;

    while (true) {
        const request: std.meta.Child(advance.Input) = .{
            .indices = @ptrCast(&indices),
            .queued = @ptrCast(&queued),
            .first = first,
            .items = items,
            .count = current_count,
            .changed = changed,
        };

        const visit = zx.columns.invoke(advance.executeValue, empty.allocator(), &request) catch unreachable;
        const index = visit.index orelse break;

        if (visit.retain and bodies[index] == null) {
            bodies[index] = try walk.keep(owner, Body.View.at(functions, index));
        }

        const grew = try walk.visit(index, Body.View.at(functions, index), if (visit.retain) bodies[index] else null);

        current_count = visit.count;
        changed = if (grew) index else null;
    }
}
