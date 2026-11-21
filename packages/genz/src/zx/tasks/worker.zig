const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const emitting = @import("worker/emitting.zig");
const blocks = @import("../../node/blocks.zig");
const scope = @import("../functions/scope.zig");

pub fn lower(self: *Lower, id: ir.ExprId, process: bool) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("worker_seed.zig").lower(self, id, process);

    const declaration_index = self.task_declarations.count();
    const name = try emitting.reserve(self, declaration_index);
    const expression = self.program.expression(id);
    const task = expression.value.task;
    const task_type = self.program.typeOf(expression.type_id).task;
    var scratch = std.heap.ArenaAllocator.init(self.workspace);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    var worker = scope.inherit(self, .Task);

    try scope.reserve(&worker, temporary, .Task);

    const parameters = try emitting.prepare(self, task.captures, process);
    const names = try emitting.captureNames(self, temporary, task.captures, parameters.capture_first);

    defer names.restore(self);

    const result = try worker.expr(task.body);
    const output_type = try self.typeExpr(task_type.result);
    const errors = self.program.typeOf(task_type.errors).error_set;
    const first: u32 = @intCast(self.builder.nodes.statements.tags.items.len);

    try emitting.discard(self, &worker, task.captures, process);

    const count: u32 = @intCast(self.builder.nodes.statements.tags.items.len - first);
    const references = try worker.referenceBlock();
    const body = try blocks.tail(self.allocator, self.builder.nodes, &.{ first, references.start }, &.{ count, references.len });

    return emitting.finish(self, .{
        .name = name,
        .value = result,
        .output_type = output_type,
        .errors = errors,
        .parameters_first = parameters.first,
        .parameters_count = parameters.count,
        .body_first = body.start,
        .slot = declaration_index,
    });
}
