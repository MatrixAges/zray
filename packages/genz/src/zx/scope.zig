const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const Reuse = @import("scope/reuse.zig");
const schedule = @import("scope/schedule_seed.zig");
const generated = @import("genz_options").generated_analysis;

pub fn lower(self: *Lower, scope: ir.ScopeRow) Lower.Error!node.ExpressionId {
    return lowerMode(self, scope, false);
}

pub fn lowerValue(self: *Lower, scope: ir.ScopeRow) Lower.Error!node.ExpressionId {
    return lowerMode(self, scope, true);
}

fn lowerMode(self: *Lower, scope: ir.ScopeRow, layout: bool) Lower.Error!node.ExpressionId {
    const values = @import("value_call/root.zig");
    const locals = try @import("value_call/locals.zig").scope(self, scope, layout);

    defer locals.release(self);

    var scratch = std.heap.ArenaAllocator.init(self.workspace);

    defer scratch.deinit();

    const reuse = try Reuse.create(self, scope, scratch.allocator());

    defer if (reuse) |*aliases| aliases.restore(self);

    if (generated) return @import("scope/execute.zig").regular(self, scope, layout, &reuse);

    const plan = schedule.result(self, scope);

    const consumed = if (plan.candidate) |last|
        try @import("iteration_consumer.zig").lower(self, last.symbol, last.value, scope.result, layout)
    else
        null;

    const result = consumed orelse if (layout) try values.expression(self, scope.result) else try self.expr(scope.result);
    var inline_spans: [64]u32 = undefined;
    const count = if (consumed != null) plan.consumed_count else plan.count;

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

    while (offset != 0) {
        output.clearRetainingCapacity();

        offset -= 1;

        const reused = if (reuse) |*active| try active.publishSeed(self, &output, offset) else null;
        const span = reused orelse try lowerBinding(self, &output, schedule.seedNext(self, scope, offset + 1), plan.type_id, &reuse);

        starts[offset] = span.start;
        counts[offset] = span.len;
    }

    const body = try @import("../node/blocks.zig").tail(self.allocator, self.builder.nodes, starts, counts);

    return @import("aggregate.zig").finishStored(self, body, result, null);
}

fn lowerBinding(self: *Lower, output: *std.ArrayList(node.Statement), binding: schedule.Binding, result_type: ir.TypeId, reuse: *const ?Reuse) Lower.Error!node.Block {
    return switch (binding.action) {
        .Reuse => (try reuse.*.?.publishSeed(self, output, binding.position)).?,
        .Skip => .{},
        .Task => @import("tasks/root.zig").bind(self, self.names[@backingInt(binding.symbol.?)], binding.value, false),
        .Discard, .Value, .Ordinary => publishBinding(self, output, binding, result_type, reuse.* != null and reuse.*.?.variables[binding.position]),
        .Iteration => unreachable,
    };
}

fn publishBinding(self: *Lower, output: *std.ArrayList(node.Statement), binding: schedule.Binding, result_type: ir.TypeId, mutable: bool) Lower.Error!node.Block {
    var sequence = self.builder.statementSequence(self.workspace);

    defer if (generated) sequence.deinit();

    const local = if (generated) &sequence else output;
    const borrowed = if (binding.symbol) |symbol| try @import("value_call/locals.zig").optionalCall(self, local, symbol, binding.value, result_type) else null;

    const value = borrowed orelse switch (binding.action) {
        .Discard => try @import("iteration.zig").discard(self, binding.value),
        .Value => try @import("value_call/root.zig").expression(self, binding.value),
        .Ordinary => try self.expr(binding.value),
        else => unreachable,
    };

    return @import("binding.zig").publish(self, local, .{
        .symbol = binding.symbol,
        .value = value,
        .by_value = binding.action == .Value,
        .scope = true,
        .mutable = mutable,
    });
}
