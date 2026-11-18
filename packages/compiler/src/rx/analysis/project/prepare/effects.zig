const Module = @import("modules/host.zig").State;
const Invocation = @import("invocation/host.zig").State;
const Flow = @import("indexed.zig").State;

const Status = enum(u8) {
    ready,
    out_of_memory,
    invalid_flow,
    fn outcome(value: error{ OutOfMemory, InvalidFlow }!void) Status {
        value catch |err| return switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.InvalidFlow => .invalid_flow,
        };

        return .ready;
    }
};

fn borrow(comptime State: type, handle: *const anyopaque) *State {
    return @ptrCast(@alignCast(@constCast(handle)));
}

fn beginModule(context: *const anyopaque, row: u64) callconv(.c) Status {
    return Status.outcome(borrow(Module, context).begin(@intCast(row)));
}

fn resolveStores(context: *const anyopaque) callconv(.c) Status {
    return Status.outcome(borrow(Module, context).stores());
}

fn prepareBody(context: *const anyopaque) callconv(.c) Status {
    return Status.outcome(borrow(Module, context).body());
}

fn importTypes(context: *const anyopaque) callconv(.c) Status {
    return Status.outcome(borrow(Module, context).types());
}

fn publishModule(context: *const anyopaque) callconv(.c) Status {
    return Status.outcome(borrow(Module, context).publish());
}

fn scanCall(context: *const anyopaque) callconv(.c) void {
    borrow(Invocation, context).scan();
}

fn parseArgument(context: *const anyopaque) callconv(.c) Status {
    return Status.outcome(borrow(Invocation, context).argument());
}

fn authorizeCall(context: *const anyopaque) callconv(.c) Status {
    return Status.outcome(borrow(Invocation, context).authorize());
}

fn resolveCallee(context: *const anyopaque) callconv(.c) Status {
    return Status.outcome(borrow(Invocation, context).resolve());
}

fn publishCall(context: *const anyopaque) callconv(.c) Status {
    return Status.outcome(borrow(Invocation, context).publish());
}

fn recordArgument(context: *const anyopaque) callconv(.c) Status {
    return Status.outcome(borrow(Invocation, context).record());
}

fn bindCall(context: *const anyopaque, slot: u64, item: u32) callconv(.c) Status {
    return Status.outcome(borrow(Flow, context).call(slot, item));
}

fn bindResult(context: *const anyopaque, slot: u64, item: u32) callconv(.c) void {
    borrow(Flow, context).result(slot, item);
}

fn bindTaskResult(context: *const anyopaque, slot: u64, item: u32) callconv(.c) void {
    borrow(Flow, context).taskResult(slot, item);
}

fn bindTask(context: *const anyopaque, slot: u64, item: u32, first: u32, count: u32, output: bool) callconv(.c) void {
    borrow(Flow, context).task(slot, item, first, count, output);
}

fn bindParallelTask(context: *const anyopaque, slot: u64, item: u32, first: u32, count: u32, task_id: u64) callconv(.c) void {
    borrow(Flow, context).parallelTask(slot, item, first, count, task_id);
}

fn bindGroup(context: *const anyopaque, item: u32, first: u32, count: u32) callconv(.c) void {
    borrow(Flow, context).group(item, first, count);
}

fn bindSelection(context: *const anyopaque, slot: u64, item: u32, conditional: bool, else_branch: bool) callconv(.c) Status {
    return Status.outcome(borrow(Flow, context).selection(slot, item, conditional, else_branch));
}

fn taskReturns(context: *const anyopaque, slot: u64) callconv(.c) Status {
    return Status.outcome(borrow(Flow, context).taskReturns(slot));
}

fn unreachableStep(context: *const anyopaque, slot: u64) callconv(.c) Status {
    return Status.outcome(borrow(Flow, context).unreachableStep(slot));
}

fn unsupportedStep(context: *const anyopaque, slot: u64) callconv(.c) Status {
    return Status.outcome(borrow(Flow, context).unsupportedStep(slot));
}

comptime {
    @export(&beginModule, .{ .name = "zxcRxPrepareBeginModule" });
    @export(&resolveStores, .{ .name = "zxcRxPrepareResolveStores" });
    @export(&prepareBody, .{ .name = "zxcRxPreparePrepareBody" });
    @export(&importTypes, .{ .name = "zxcRxPrepareImportTypes" });
    @export(&publishModule, .{ .name = "zxcRxPreparePublishModule" });
    @export(&scanCall, .{ .name = "zxcRxPrepareScanCall" });
    @export(&parseArgument, .{ .name = "zxcRxPrepareParseArgument" });
    @export(&authorizeCall, .{ .name = "zxcRxPrepareAuthorizeCall" });
    @export(&resolveCallee, .{ .name = "zxcRxPrepareResolveCallee" });
    @export(&publishCall, .{ .name = "zxcRxPreparePublishCall" });
    @export(&recordArgument, .{ .name = "zxcRxPrepareRecordArgument" });
    @export(&bindCall, .{ .name = "zxcRxPrepareBindCall" });
    @export(&bindResult, .{ .name = "zxcRxPrepareBindResult" });
    @export(&bindTaskResult, .{ .name = "zxcRxPrepareBindTaskResult" });
    @export(&bindTask, .{ .name = "zxcRxPrepareBindTask" });
    @export(&bindParallelTask, .{ .name = "zxcRxPrepareBindParallelTask" });
    @export(&bindGroup, .{ .name = "zxcRxPrepareBindGroup" });
    @export(&bindSelection, .{ .name = "zxcRxPrepareBindSelection" });
    @export(&taskReturns, .{ .name = "zxcRxPrepareTaskReturns" });
    @export(&unreachableStep, .{ .name = "zxcRxPrepareUnreachableStep" });
    @export(&unsupportedStep, .{ .name = "zxcRxPrepareUnsupportedStep" });
}
