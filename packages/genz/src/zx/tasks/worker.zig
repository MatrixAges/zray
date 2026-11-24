const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const view = @import("../../node/view.zig");
const Lower = @import("../lower.zig");
const rows = @import("../construction/publication.zig");
const reuse = @import("../scope/reuse.zig");
const scope = @import("../functions/scope.zig");
const Api = @import("../expressions/evaluate.zig").Api;

const Frame = struct {
    lowering: *Lower,
    body: ir.ExprId,
    result: ir.TypeId,
    errors: ir.TypeId,
    captures: []const ir.SymbolId,
    temporary: std.mem.Allocator,
    worker: Lower = undefined,
    names: ?reuse.Names = null,
    usage: Api.TaskWorkerUsage = undefined,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

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
    var origin: rows.OriginBuffer = .{};

    defer scratch.deinit();

    var frame: Frame = .{
        .lowering = self,
        .body = task.body,
        .result = task_type.result,
        .errors = task_type.errors,
        .captures = task.captures,
        .temporary = scratch.allocator(),
    };

    defer if (frame.names) |names| names.restore(self);

    const input: Input = .{
        .worker = @ptrCast(&frame),
        .writer = @ptrCast(self),
        .origin = @ptrCast(&origin),
        .captures = view.slice(@FieldType(Input, "captures"), task.captures),
        .process = process,
    };

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return rows.failure(err);

    return @fromBackingInt(result);
}

pub fn openTaskWorker(handle: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);

    frame.worker = scope.inherit(frame.lowering, .Task);

    try scope.reserve(&frame.worker, frame.temporary, .Task);
}

pub fn taskCaptureType(handle: *const anyopaque, symbol: u32) Lower.Error!u32 {
    const self = Frame.borrow(handle).lowering;
    const id: ir.TypeId = @fromBackingInt(self.program.symbols.types[symbol]);

    return @backingInt(try self.typeExpr(id));
}

pub fn bindTaskCaptureNames(handle: *const anyopaque, first: u32) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const saved = try frame.temporary.alloc([]const u8, frame.captures.len);
    const names = self.builder.nodes.field_columns.fields.name.values.items;

    frame.names = reuse.bindNames(self, frame.captures, names[first..][0..frame.captures.len], saved);
}

pub fn evaluateTaskWorker(handle: *const anyopaque) Lower.Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try frame.worker.expr(frame.body));
}

pub fn taskWorkerOutput(handle: *const anyopaque) Lower.Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try frame.lowering.typeExpr(frame.result));
}

pub fn taskWorkerErrors(handle: *const anyopaque) ?[]const []const u8 {
    const frame = Frame.borrow(handle);

    return frame.lowering.program.typeOf(frame.errors).error_set;
}

pub fn readTaskWorkerUsage(handle: *const anyopaque) *const Api.TaskWorkerUsage {
    const frame = Frame.borrow(handle);
    const worker = &frame.worker;

    frame.usage = .{
        .uses_allocator = worker.uses_allocator,
        .uses_io = worker.uses_io,
        .uses_process = worker.uses_process,
        .used = worker.used,
        .names = worker.names,
    };

    return &frame.usage;
}

pub fn readTaskReferenceBody(handle: *const anyopaque) Lower.Error!u64 {
    return rows.packSpan(try Frame.borrow(handle).worker.referenceBlock());
}
