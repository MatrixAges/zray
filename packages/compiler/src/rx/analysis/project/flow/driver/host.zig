const std = @import("std");
const Flow = @import("../../flow.zig");
const generated = @import("rx_options").generated_graph;
const Constraints = @import("../../constraints/traversal.zig").Host;
const Compile = @import("../../../flow_compile/traversal.zig").Host;
const Error = error{ InvalidFlow, InvalidSource, OutOfMemory };

pub fn run(state: anytype, plan: *const Flow.Plan, compiling: bool) Error!void {
    const entry = @import("generated_rx_prepared_flow_walk");
    const Input = std.meta.Child(entry.Input);
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    var words: [2]u64 = .{ 0, 0 };
    const cursor: []u64 = &words;

    const request: Input = .{
        .context = @ptrCast(state),
        .compiling = compiling,
        .target = @ptrCast(&words),
        .cursor = @ptrCast(&cursor),
        .kinds = plan.kinds,
        .items = plan.items,
    };

    return entry.executeIn(empty.allocator(), &request) catch |err| switch (@as(anyerror, err)) {
        error.InvalidSource => error.InvalidSource,
        error.InvalidFlow => error.InvalidFlow,
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

pub fn seed(state: anytype, plan: *const Flow.Plan) @TypeOf(state.closeCase()) {
    while (true) {
        const current = state.frame();
        const first = current.cursor.first;
        const event = current.cursor.advance(std.meta.activeTag(current.payload), plan);
        const next: usize = @intCast(event.next);

        switch (event.action) {
            .Done => return,
            .Calls => try state.calls(current, first, next),
            .Return => try state.result(current, first, next),
            .OpenTask => try state.task(current, first, next, false),
            .OpenParallelTask => try state.task(current, first, next, true),
            .OpenParallel => try state.parallel(current, first, next),
            .OpenSelection => try state.selection(current, first, next),
            .OpenCase => try state.openCase(current, first, next),
            .CloseTask, .CloseParallelTask => {
                try state.closeTask(event.action == .CloseParallelTask);

                state.pop();
            },
            .CloseParallel => {
                try state.closeParallel();

                state.pop();
            },
            .CloseSelection => {
                try state.closeSelection();

                state.pop();
            },
            .CloseCase => {
                try state.closeCase();

                state.pop();
            },
        }
    }
}

const Status = enum(u8) {
    ready,
    out_of_memory,
    invalid_flow,
    invalid_source,
    fn outcome(value: Error!void) Status {
        value catch |err| return switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.InvalidFlow => .invalid_flow,
            error.InvalidSource => .invalid_source,
        };

        return .ready;
    }
};

fn borrow(comptime Host: type, context: *anyopaque) *Host {
    return @ptrCast(@alignCast(context));
}

fn observe(context: *anyopaque, compiling: bool, snapshot: *[2]u64) callconv(.c) u8 {
    if (compiling) return snapshotFrame(borrow(Compile, context), snapshot);

    return snapshotFrame(borrow(Constraints, context), snapshot);
}

fn snapshotFrame(state: anytype, snapshot: *[2]u64) u8 {
    const frame = state.frame();

    snapshot.* = .{ frame.cursor.first, frame.cursor.end };

    return @backingInt(std.meta.activeTag(frame.payload));
}

fn move(state: anytype, comptime effect: []const u8, position: u64, extra: anytype) Status {
    const current = state.frame();
    const first = current.cursor.first;
    const next: usize = @intCast(position);

    current.cursor.first = next;

    return Status.outcome(@call(.auto, @field(std.meta.Child(@TypeOf(state)), effect), .{ state, current, first, next } ++ extra));
}

fn Moving(comptime effect: []const u8) type {
    return struct {
        fn call(context: *anyopaque, compiling: bool, next: u64) callconv(.c) Status {
            if (compiling) return move(borrow(Compile, context), effect, next, .{});

            return move(borrow(Constraints, context), effect, next, .{});
        }
    };
}

fn task(context: *anyopaque, compiling: bool, next: u64, parallel: bool) callconv(.c) Status {
    if (compiling) return move(borrow(Compile, context), "task", next, .{parallel});

    return move(borrow(Constraints, context), "task", next, .{parallel});
}

fn closeTask(context: *anyopaque, compiling: bool, parallel: bool) callconv(.c) Status {
    if (compiling) return Status.outcome(borrow(Compile, context).closeTask(parallel));

    return Status.outcome(borrow(Constraints, context).closeTask(parallel));
}

fn Closing(comptime effect: []const u8) type {
    return struct {
        fn call(context: *anyopaque, compiling: bool) callconv(.c) Status {
            if (compiling) return Status.outcome(@field(Compile, effect)(borrow(Compile, context)));

            return Status.outcome(@field(Constraints, effect)(borrow(Constraints, context)));
        }
    };
}

fn pop(context: *anyopaque, compiling: bool) callconv(.c) void {
    if (compiling) {
        borrow(Compile, context).pop();
    } else {
        borrow(Constraints, context).pop();
    }
}

comptime {
    if (generated) {
        @export(&observe, .{ .name = "zxcPreparedFlowObserve" });
        @export(&Moving("calls").call, .{ .name = "zxcPreparedFlowCalls" });
        @export(&Moving("result").call, .{ .name = "zxcPreparedFlowResult" });
        @export(&task, .{ .name = "zxcPreparedFlowTask" });
        @export(&Moving("parallel").call, .{ .name = "zxcPreparedFlowParallel" });
        @export(&Moving("selection").call, .{ .name = "zxcPreparedFlowSelection" });
        @export(&Moving("openCase").call, .{ .name = "zxcPreparedFlowOpenCase" });
        @export(&closeTask, .{ .name = "zxcPreparedFlowCloseTask" });
        @export(&Closing("closeParallel").call, .{ .name = "zxcPreparedFlowCloseParallel" });
        @export(&Closing("closeSelection").call, .{ .name = "zxcPreparedFlowCloseSelection" });
        @export(&Closing("closeCase").call, .{ .name = "zxcPreparedFlowCloseCase" });
        @export(&pop, .{ .name = "zxcPreparedFlowPop" });
    }
}
