const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const Reuse = @import("scope/reuse.zig");
const schedule = @import("scope/schedule.zig");
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

    const plan = schedule.result(self, scope);
    var scratch = std.heap.ArenaAllocator.init(self.workspace);

    defer scratch.deinit();

    const reuse = try Reuse.create(self, scope, scratch.allocator());

    defer if (reuse) |*aliases| aliases.restore(self);

    const consumed = if (plan.candidate) |last|
        try @import("iteration_consumer.zig").lower(self, last.symbol, last.value, scope.result, layout)
    else
        null;

    const result = consumed orelse if (layout) try values.expression(self, scope.result) else try self.expr(scope.result);
    var inline_spans: [64]u32 = undefined;
    const count = plan.count - @intFromBool(consumed != null);

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
        output.clearRetainingCapacity();

        if (!generated) {
            if (reuse) |*changes| {
                const position = offset - 1;

                if (try changes.publish(self, &output, position)) |span| {
                    starts[position] = span.start;
                    counts[position] = span.len;
                    offset = position;

                    continue;
                }
            }
        }

        const changes = if (generated and reuse != null) reuse.?.state.changes else &.{};
        const binding = schedule.next(self, scope, offset, changes, false);

        const span = switch (binding.action) {
            .Reuse => (try reuse.?.publish(self, &output, binding.position)).?,
            .Skip => node.Block{},
            .Task => try @import("tasks/root.zig").bind(self, self.names[@backingInt(binding.symbol.?)], binding.value, false),
            .Discard, .Value, .Ordinary => try publishBinding(self, &output, binding, plan.type_id, reuse != null and reuse.?.variables[binding.position]),
            .Iteration => unreachable,
        };

        offset = binding.position;
        starts[offset] = span.start;
        counts[offset] = span.len;
    }

    const body = try @import("../node/blocks.zig").tail(self.allocator, self.builder.nodes, starts, counts);

    return @import("aggregate.zig").finishStored(self, body, result, null);
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
