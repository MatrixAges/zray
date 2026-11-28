const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const view = @import("../../node/view.zig");
const Lower = @import("../lower.zig");
const rows = @import("../construction/publication.zig");
const reuse = @import("../scope/reuse.zig");
const scope = @import("../functions/scope.zig");
const evaluation = @import("../expressions/evaluate.zig");
const Api = evaluation.Api;

pub fn lower(self: *Lower, id: ir.ExprId, process: bool) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("worker_seed.zig").lower(self, id, process);

    const expression = self.program.expression(id);
    const task = expression.value.task;
    const task_type = self.program.typeOf(expression.type_id).task;
    const entry = @import("generated_execute_task_worker");
    const Input = std.meta.Child(entry.Input);
    var scratch: std.heap.ArenaAllocator = .init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory: std.heap.BufferFirstAllocator = .init(&buffer, scratch.allocator());

    defer scratch.deinit();

    var worker = scope.inherit(self, .Task);

    try scope.reserve(&worker, scratch.allocator(), .Task);

    const names = try reuse.saveNames(self, task.captures, memory.allocator());

    defer names.restore(self);

    const input: Input = .{
        .worker = @ptrCast(&worker),
        .lower = @ptrCast(self),
        .writer = @ptrCast(self),
        .captures = view.slice(@FieldType(Input, "captures"), task.captures),
        .symbol_types = self.program.symbols.types,
        .body_expr = @backingInt(task.body),
        .result_type = @backingInt(task_type.result),
        .errors = self.program.typeOf(task_type.errors).error_set,
        .process = process,
    };

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return rows.failure(err);

    return @fromBackingInt(result);
}

pub fn bindTaskCaptureNames(frame: *anyopaque, captures: []const u32, first: u32) void {
    const lowering = evaluation.borrow(frame);
    const names = lowering.builder.nodes.field_columns.fields.name.values.items;

    reuse.setNames(lowering, captures, names[first..][0..captures.len]);
}

pub fn readWorkerState(allocator: std.mem.Allocator, handle: *anyopaque) Lower.Error!*const Api.WorkerState {
    const worker = evaluation.borrow(handle);
    const body = try allocator.create(Api.WorkerState);

    body.* = .{
        .uses_allocator = worker.uses_allocator,
        .uses_io = worker.uses_io,
        .uses_process = worker.uses_process,
        .used = worker.used,
        .names = worker.names,
    };

    return body;
}

pub fn readWorkerReferenceBody(handle: *anyopaque) Lower.Error!u64 {
    return rows.packSpan(try evaluation.borrow(handle).referenceBlock());
}
