const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const reuse = @import("../scope/reuse.zig");
const scope = @import("../functions/scope.zig");
const rows = @import("../construction/publication.zig");
const Api = @import("../expressions/evaluate.zig").Api;
const Error = Lower.Error;
pub const Result = struct { declaration: u32, io: bool, process: bool };

const Frame = struct {
    lowering: *Lower,
    value: ir.Transform,
    worker: *Lower,
    elements: [2]node.ExpressionId = undefined,
    saved: [3][]const u8 = undefined,
    names: ?reuse.Names = null,
    used: [2]bool = @splat(false),
    helpers: [2]node.Block = @splat(.{}),
    result: Api.SortWorkerResult = undefined,
    helper: @import("../../node/blocks.zig").Sequence,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn build(self: *Lower, value: ir.Transform, child: node.ExpressionId, errors: ?[]const []const u8) Error!Result {
    var worker = scope.inherit(self, .Sort);

    try scope.reserve(&worker, self.allocator, .Sort);

    var frame: Frame = .{
        .lowering = self,
        .value = value,
        .worker = &worker,
        .helper = self.builder.statementSequence(self.workspace),
    };

    var scratch: std.heap.ArenaAllocator = .init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory: std.heap.BufferFirstAllocator = .init(&buffer, scratch.allocator());

    defer scratch.deinit();
    defer if (frame.names) |names| names.restore(self);
    defer frame.helper.deinit();

    const entry = @import("generated_execute_sort_worker");

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(&frame),
        .writer = @ptrCast(self),
        .lower = @ptrCast(self),
        .worker = @ptrCast(&worker),
        .child = @backingInt(child),
        .body_expr = @backingInt(value.body),
        .output_type = @backingInt(self.program.expression(value.body).type_id),
        .errors = errors,
    };

    const declaration = entry.executeIn(memory.allocator(), &input) catch |err| return rows.failure(err);

    return .{ .declaration = declaration, .io = worker.uses_io, .process = worker.uses_process };
}

pub fn bindSortWorkerNames(handle: *anyopaque, names: []const []const u8) void {
    const frame = Frame.borrow(handle);

    frame.names = reuse.bindNames(frame.lowering, frame.value.parameters, names, &frame.saved);
}

pub fn registerSortParameters(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    try @import("../state_value/locals.zig").registerOwned(frame.worker, frame.value.parameters);
}

pub fn readSortOperand(handle: *anyopaque, index: u64, raw: u32) Error!void {
    const frame = Frame.borrow(handle);
    const slot: usize = @intCast(index);
    const operand: node.ExpressionId = @fromBackingInt(raw);

    if (!frame.worker.used[@backingInt(frame.value.parameters[slot])]) {
        frame.elements[slot] = operand;

        return;
    }

    const list_type = frame.lowering.program.expression(frame.value.target).type_id;

    frame.elements[slot] = try @import("../state_value/elements.zig").read(frame.worker, &frame.helper, list_type, operand);
    frame.helpers[slot] = try frame.helper.block(frame.lowering.allocator);
    frame.used[slot] = true;

    frame.helper.clearRetainingCapacity();
}

pub fn finishSortWorker(handle: *anyopaque) Error!*const Api.SortWorkerResult {
    const frame = Frame.borrow(handle);
    const worker = frame.worker;
    const environment = frame.value.parameters[2];
    const references = try worker.referenceBlock();
    const elements: []const node.ExpressionId = &frame.elements;

    frame.result = .{
        .elements = @import("../../node/view.zig").slice([]const u32, elements),
        .used = &frame.used,
        .uses_allocator = worker.uses_allocator,
        .uses_io = worker.uses_io,
        .uses_process = worker.uses_process,
        .uses_environment = worker.used[@backingInt(environment)],
        .references_start = references.start,
        .references_count = references.len,
        .left_start = frame.helpers[0].start,
        .left_count = frame.helpers[0].len,
        .right_start = frame.helpers[1].start,
        .right_count = frame.helpers[1].len,
    };

    return &frame.result;
}
