const std = @import("std");
const ir = @import("zx").ir;
const Flow = @import("../flow.zig");
const Slots = @import("../slots.zig");
const Memo = @import("../memo.zig");
const layers = @import("layers/root.zig");
const entry = @import("generated_uniqueness_flow_solve");
const Plan = @import("../program/driver.zig").Api.FlowPlan;
const Error = std.mem.Allocator.Error;

const Request = struct {
    allocator: std.mem.Allocator,
    workspace: std.mem.Allocator,
    temporary: std.mem.Allocator,
    program: *const ir.Program,
    slots: Slots,
    texts: []const bool,
    contents: []const Memo.Digest,
    types: Memo.Digest,
    memo: ?*Memo,
};

const Frame = struct {
    request: Request,
    result: Flow = undefined,
    plan: layers.Plan = undefined,
    remembered: ?Flow.Remembered = null,
    walkers: []Flow.Walker = &.{},
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn solve(request: Request) Error!Flow {
    var frame: Frame = .{ .request = request };

    defer Flow.Walker.close(frame.walkers);

    const input: std.meta.Child(entry.Input) = .{
        .flow = @ptrCast(&frame),
        .remembered = request.memo != null,
    };

    try @import("../../expressions/evaluate.zig").execute(entry, &input);

    return frame.result;
}

pub fn initializeFlow(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const input = &frame.request;

    frame.result = try @import("initial.zig").create(input.allocator, input.program.*, input.slots, input.texts);
}

pub fn planFlow(handle: *const anyopaque) Error!Plan {
    const frame = Frame.borrow(handle);
    const input = &frame.request;

    frame.plan = (try layers.build(input.temporary, &input.program.functions, frame.result.held, input.memo != null)) orelse return .Recursive;

    return if (frame.plan.order.len == 0) .Empty else .Layered;
}

pub fn reserveFlowMemo(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const input = &frame.request;

    frame.remembered = try Flow.Remembered.init(input.temporary, input.memo.?, input.types, input.contents, input.program.functions.count());
}

pub fn flowLayerOrder(handle: *const anyopaque) []const u32 {
    return Frame.borrow(handle).plan.order;
}

pub fn flowLayerEnds(handle: *const anyopaque) []const u64 {
    return Frame.borrow(handle).plan.ends;
}

pub fn flowMemoHits(handle: *const anyopaque) []const bool {
    const frame = Frame.borrow(handle);

    return if (frame.remembered) |saved| saved.found else &.{};
}

pub fn openFlowWorkers(handle: *const anyopaque) Error!void {
    Frame.borrow(handle).walkers = try Flow.Walker.open();
}

pub fn solveFlowLayer(handle: *const anyopaque, first: u64, end: u64) Error!void {
    const frame = Frame.borrow(handle);
    const input = &frame.request;

    var layer: Flow.Layer = .{
        .flow = frame.result,
        .table = &input.program.functions,
        .slots = input.slots,
        .functions = frame.plan.order[@intCast(first)..@intCast(end)],
        .walkers = frame.walkers,
        .remembered = frame.remembered,
    };

    try layer.spread();
}

pub fn keepFlowMemo(handle: *const anyopaque, row: u64) void {
    const remembered = Frame.borrow(handle).remembered.?;

    remembered.memo.keepFlowed(remembered.keys[@intCast(row)]);
}

pub fn publishFlowMemo(handle: *const anyopaque, row: u64) Error!void {
    const frame = Frame.borrow(handle);
    const kept = frame.remembered.?;
    const flow = &frame.result;
    const index: usize = @intCast(row);

    try kept.memo.putFlowed(kept.keys[index], flow.held[index], flow.text_held[index], flow.written[index]);
}

pub fn solveRecursiveFlow(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const input = &frame.request;

    try @import("fixpoint.zig").settle(frame.result, input.temporary, input.workspace, &input.program.functions, input.slots);
}
