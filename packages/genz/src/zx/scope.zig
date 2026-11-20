const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const Reuse = @import("scope/reuse.zig");
const generated = @import("genz_options").generated_analysis;

pub fn lower(self: *Lower, scope: ir.ScopeRow) Lower.Error!node.ExpressionId {
    return lowerMode(self, scope, false);
}

pub fn lowerValue(self: *Lower, scope: ir.ScopeRow) Lower.Error!node.ExpressionId {
    return lowerMode(self, scope, true);
}

fn lowerMode(self: *Lower, scope: ir.ScopeRow, layout: bool) Lower.Error!node.ExpressionId {
    const state_symbols = try @import("state_value/locals.zig").scope(self, scope);

    defer self.state_symbols.removeMany(state_symbols);

    const values = @import("value_call/root.zig");
    const stacked = try @import("value_call/locals.zig").scope(self, scope, layout);

    defer self.stack_symbols.removeMany(stacked);

    const result_type = self.program.expression(scope.result).type_id;
    var scratch = std.heap.ArenaAllocator.init(self.workspace);

    defer scratch.deinit();

    const reuse = try Reuse.create(self, scope, scratch.allocator());

    defer if (reuse) |*plan| plan.restore(self);

    var consumed_last = false;
    var result: ?node.ExpressionId = null;

    if (scope.bindings.len != 0) {
        const binding = scope.bindings.at(scope.bindings.len - 1);

        if (binding.symbol) |symbol| {
            result = try @import("iteration_consumer.zig").lower(self, symbol, binding.value, scope.result, layout);
            consumed_last = result != null;
        }
    }

    if (result == null) result = if (layout) try values.expression(self, scope.result) else try self.expr(scope.result);

    var inline_spans: [64]u32 = undefined;
    const count = scope.bindings.len - @intFromBool(consumed_last);

    const spans = if (count <= inline_spans.len / 2)
        inline_spans[0 .. count * 2]

    else
        try self.workspace.alloc(u32, std.math.mul(usize, count, 2) catch return error.OutOfMemory);

    defer if (spans.len > inline_spans.len) self.workspace.free(spans);

    const starts = spans[0..count];
    const counts = spans[count..];
    var output: std.ArrayList(node.Statement) = .empty;

    defer output.deinit(self.allocator);

    var offset = count;

    while (offset > 0) {
        offset -= 1;

        output.clearRetainingCapacity();

        const span = try publishBinding(self, &output, scope, if (reuse) |*plan| plan else null, result_type, offset);

        starts[offset] = span.start;
        counts[offset] = span.len;
    }

    const body = try @import("../node/blocks.zig").tail(self.allocator, self.builder.nodes, starts, counts);

    return @import("aggregate.zig").finishStored(self, body, result.?, null);
}

fn publishBinding(self: *Lower, output: *std.ArrayList(node.Statement), scope: ir.ScopeRow, reuse: ?*const Reuse, result_type: ir.TypeId, offset: usize) Lower.Error!node.Block {
    if (reuse) |plan| if (try plan.publish(self, output, offset)) |block| return block;

    const binding = scope.bindings.at(offset);
    const route = @import("binding.zig").before(self, binding.value, binding.symbol, true);

    if (route == .Skip) return .{};
    if (route == .Task) return @import("tasks/root.zig").bind(self, self.names[@backingInt(binding.symbol.?)], binding.value, false);

    var sequence = self.builder.statementSequence(self.workspace);

    defer if (generated) sequence.deinit();

    const local = if (generated) &sequence else output;
    const by_value = if (binding.symbol) |symbol| self.stack_symbols.contains(symbol) else false;
    const borrowed = if (binding.symbol) |symbol| try @import("value_call/locals.zig").optionalCall(self, local, symbol, binding.value, result_type) else null;

    const value = borrowed orelse if (binding.symbol == null)
        try @import("iteration.zig").discard(self, binding.value)

    else if (by_value)
        try @import("value_call/root.zig").expression(self, binding.value)
    else
        try self.expr(binding.value);

    return @import("binding.zig").publish(self, local, .{
        .symbol = binding.symbol,
        .value = value,
        .by_value = by_value,
        .scope = true,
        .mutable = reuse != null and reuse.?.variables[offset],
    });
}
