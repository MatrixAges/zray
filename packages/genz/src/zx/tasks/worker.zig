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
    captures: []const ir.SymbolId,
    temporary: std.mem.Allocator,
    worker: Lower = undefined,
    names: ?reuse.Names = null,
    body: Api.TaskWorkerBody = undefined,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
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
        .captures = task.captures,
        .temporary = scratch.allocator(),
    };

    frame.worker = scope.inherit(self, .Task);

    try scope.reserve(&frame.worker, scratch.allocator(), .Task);

    defer if (frame.names) |names| names.restore(self);

    const input: Input = .{
        .worker = @ptrCast(&frame),
        .lower = @ptrCast(self),
        .writer = @ptrCast(self),
        .origin = @ptrCast(&origin),
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

pub fn bindTaskCaptureNames(handle: *anyopaque, first: u32) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const saved = try frame.temporary.alloc([]const u8, frame.captures.len);
    const names = self.builder.nodes.field_columns.fields.name.values.items;

    frame.names = reuse.bindNames(self, frame.captures, names[first..][0..frame.captures.len], saved);
}

pub fn lowerTaskWorker(handle: *anyopaque, id: u32) Lower.Error!*const Api.TaskWorkerBody {
    const frame = Frame.borrow(handle);
    const worker = &frame.worker;
    const value = try worker.expr(@fromBackingInt(id));

    frame.body = .{
        .value = @backingInt(value),
        .uses_allocator = worker.uses_allocator,
        .uses_io = worker.uses_io,
        .uses_process = worker.uses_process,
        .used = worker.used,
        .names = worker.names,
    };

    return &frame.body;
}

pub fn readTaskReferenceBody(handle: *anyopaque) Lower.Error!u64 {
    return rows.packSpan(try Frame.borrow(handle).worker.referenceBlock());
}
