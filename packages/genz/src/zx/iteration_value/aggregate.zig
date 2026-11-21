const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const operands = @import("operands.zig");
const emitting = @import("literals.zig");
const recursive_scratch_bytes = 1024;

pub fn lower(self: *Context, id: ir.ExprId) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("aggregate_seed.zig").lower(self, id);

    const lowering = self.lowering;
    const expression = lowering.program.expression(id);
    const type_expr = try @import("types.zig").get(self, expression.type_id);
    var scratch = std.heap.ArenaAllocator.init(lowering.workspace);
    var buffer: [recursive_scratch_bytes]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const allocator = memory.allocator();

    if (expression.value == .tuple) {
        const bindings = try emitting.Bindings.init(allocator, expression.value.tuple.len);
        _ = try operands.lower(lowering, allocator, bindings, expression.value.tuple, null, null);

        return emitting.lower(self, .{ .mode = .Tuple, .type_id = expression.type_id, .layout = type_expr, .bindings = bindings });
    }

    const object = expression.value.object;
    const saved = try self.cache.snapshot(allocator, object.evaluation);
    const counts = try allocator.alloc(u64, object.evaluation.len);
    const bindings = try emitting.Bindings.init(allocator, object.evaluation.len);

    defer self.cache.restore(lowering.allocator, object.evaluation, saved);

    const values = try operands.lower(lowering, allocator, bindings, object.evaluation, object.fields.values[0..object.fields.len], .{
        .context = self,
        .counts = counts,
    });

    return emitting.lower(self, .{
        .mode = .Object,
        .type_id = expression.type_id,
        .layout = type_expr,
        .bindings = bindings,
        .field_indices = object.fields.indices,
        .field_values = values,
        .evaluation = object.evaluation,
        .prior = counts,
    });
}
