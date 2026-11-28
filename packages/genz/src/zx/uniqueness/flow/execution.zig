const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Flow = @import("../flow.zig");
const Slots = @import("../slots.zig");
const Memo = @import("../memo.zig");
const entry = @import("generated_uniqueness_flow_solve");
const Api = @import("../program/driver.zig").Api;
const Fixpoint = @import("fixpoint.zig");
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
    scratch: std.mem.Allocator,
    recursive: ?Fixpoint = null,
    result: Flow = undefined,
    remembered: ?Flow.Remembered = null,
    walkers: []Flow.Walker = &.{},
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn solve(request: Request) Error!Flow {
    var scratch = std.heap.ArenaAllocator.init(request.workspace);

    defer scratch.deinit();

    var frame: Frame = .{ .request = request, .scratch = scratch.allocator() };

    defer Flow.Walker.close(frame.walkers);
    defer if (frame.recursive) |*recursive| recursive.deinit();

    const Input = std.meta.Child(entry.Input);
    const Functions = std.meta.Child(@FieldType(Input, "functions"));
    const functions = &request.program.functions;

    const input: Input = .{
        .flow = @ptrCast(&frame),
        .functions = &.{
            .native_modules = functions.native_modules,
            .expressions = zx.columns.slice(@FieldType(Functions, "expressions"), functions.expressions),
        },
        .remembered = request.memo != null,
    };

    entry.executeIn(frame.scratch, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    return frame.result;
}

pub fn initializeFlow(handle: *anyopaque) Error![]const []const bool {
    const frame = Frame.borrow(handle);
    const input = &frame.request;

    frame.result = try @import("initial.zig").create(input.allocator, input.program.*, input.slots, input.texts);

    return frame.result.held;
}

pub fn reserveFlowMemo(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const input = &frame.request;

    frame.remembered = try Flow.Remembered.init(input.temporary, input.memo.?, input.types, input.contents, input.program.functions.count());
}

pub fn openFlowWorkers(handle: *anyopaque) Error![]const bool {
    const frame = Frame.borrow(handle);

    frame.walkers = try Flow.Walker.open();

    return if (frame.remembered) |saved| saved.found else &.{};
}

pub fn solveFlowLayer(handle: *anyopaque, order: []const u32, first: u64, end: u64) Error!void {
    const frame = Frame.borrow(handle);
    const input = &frame.request;

    var layer: Flow.Layer = .{
        .flow = frame.result,
        .table = &input.program.functions,
        .slots = input.slots,
        .functions = order[@intCast(first)..@intCast(end)],
        .walkers = frame.walkers,
        .remembered = frame.remembered,
    };

    try layer.spread();
}

pub fn keepFlowMemo(handle: *anyopaque, row: u64) void {
    const remembered = Frame.borrow(handle).remembered.?;

    remembered.memo.keepFlowed(remembered.keys[@intCast(row)]);
}

pub fn publishFlowMemo(handle: *anyopaque, row: u64) Error!void {
    const frame = Frame.borrow(handle);
    const kept = frame.remembered.?;
    const flow = &frame.result;
    const index: usize = @intCast(row);

    try kept.memo.putFlowed(kept.keys[index], flow.held[index], flow.text_held[index], flow.written[index]);
}

pub fn openRecursiveFlow(handle: *anyopaque) Error!*const Api.FlowQueue {
    const frame = Frame.borrow(handle);
    const input = &frame.request;

    frame.recursive = try Fixpoint.open(frame.result, input.temporary, input.workspace, frame.scratch, &input.program.functions, input.slots);

    return &frame.recursive.?.queue;
}

pub fn retainFlowFacts(handle: *anyopaque, index: u32) Error!void {
    try Frame.borrow(handle).recursive.?.retain(index);
}

pub fn visitRecursiveFlow(handle: *anyopaque, index: u32, retained: bool) Error!bool {
    return Frame.borrow(handle).recursive.?.visit(index, retained);
}
