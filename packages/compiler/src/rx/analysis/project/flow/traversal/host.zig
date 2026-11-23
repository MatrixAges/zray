const std = @import("std");
const Inference = @import("../../constraints/traversal.zig").Host;
const Lowering = @import("../../../flow_compile/traversal.zig").Host;
const Flow = @import("../../flow.zig");
const entry = @import("generated_rx_traverse_flow");
const Input = std.meta.Child(entry.Input);
const Error = error{ OutOfMemory, InvalidSource, InvalidFlow };

pub const View = std.meta.Child(@FieldType(Input, "cursor"));

const State = struct {
    target: union(enum) { inference: *Inference, lowering: *Lowering },
    items: []const u32,
    cursor: View = undefined,
    fn borrow(handle: *const anyopaque) *State {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn run(target: anytype, plan: *const Flow.Plan) @TypeOf(target.closeCase()) {
    var state: State = .{
        .target = if (@TypeOf(target) == *Inference) .{ .inference = target } else .{ .lowering = target },
        .items = plan.items,
    };

    const input: Input = .{
        .frame = @ptrCast(&state),
        .cursor = &state.cursor,
        .kinds = plan.kinds,
        .items = plan.items,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return entry.executeValue(empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.InvalidSource, error.InvalidFlow => @errorCast(err),
        else => unreachable,
    };
}

pub fn refreshFlowCursor(handle: *const anyopaque) void {
    const state = State.borrow(handle);

    switch (state.target) {
        inline else => |target| {
            const current = target.frame();

            state.cursor = .{
                .first = current.cursor.first,
                .end = current.cursor.end,
                .region = std.meta.activeTag(current.payload),
            };
        },
    }
}

pub fn saveFlowCursor(handle: *const anyopaque, next: u64) void {
    switch (State.borrow(handle).target) {
        inline else => |target| target.frame().cursor.first = @intCast(next),
    }
}

pub fn callFlowBatch(handle: *const anyopaque, first: u64, end: u64) Error!void {
    const state = State.borrow(handle);

    switch (state.target) {
        inline else => |target| try target.calls(target.frame(), @intCast(first), state.items[first..end]),
    }
}

pub fn returnFlowValue(handle: *const anyopaque, row: u64, item: u32) Error!void {
    switch (State.borrow(handle).target) {
        inline else => |target| try target.result(target.frame(), @intCast(row), item),
    }
}

pub fn openFlowTask(handle: *const anyopaque, row: u64, item: u32, parallel: bool) Error!void {
    switch (State.borrow(handle).target) {
        inline else => |target| try target.task(target.frame(), @intCast(row), item, parallel),
    }
}

pub fn openFlowParallel(handle: *const anyopaque, row: u64, item: u32) Error!void {
    switch (State.borrow(handle).target) {
        inline else => |target| try target.parallel(target.frame(), @intCast(row), item),
    }
}

pub fn openFlowSelection(handle: *const anyopaque, row: u64, item: u32) Error!void {
    switch (State.borrow(handle).target) {
        inline else => |target| try target.selection(target.frame(), @intCast(row), item),
    }
}

pub fn openFlowCase(handle: *const anyopaque, row: u64) Error!void {
    switch (State.borrow(handle).target) {
        inline else => |target| try target.openCase(target.frame(), @intCast(row)),
    }
}

pub fn closeFlowTask(handle: *const anyopaque, parallel: bool) Error!void {
    switch (State.borrow(handle).target) {
        inline else => |target| try target.closeTask(parallel),
    }
}

pub fn closeFlowParallel(handle: *const anyopaque) Error!void {
    switch (State.borrow(handle).target) {
        inline else => |target| try target.closeParallel(),
    }
}

pub fn closeFlowSelection(handle: *const anyopaque) Error!void {
    switch (State.borrow(handle).target) {
        inline else => |target| try target.closeSelection(),
    }
}

pub fn closeFlowCase(handle: *const anyopaque) Error!void {
    switch (State.borrow(handle).target) {
        inline else => |target| try target.closeCase(),
    }
}

pub fn popFlowFrame(handle: *const anyopaque) void {
    switch (State.borrow(handle).target) {
        inline else => |target| target.pop(),
    }
}
